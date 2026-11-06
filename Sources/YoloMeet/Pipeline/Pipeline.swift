import CoreImage
import Foundation
import Vision
import YoloMeetCore

/// Camera frame → background replacement → models → tracked results.
/// The renderer reads `latestFrame` and `latestOutputs` at display rate; inference runs at its own rate on the newest
/// frame and never queues up stale frames.
nonisolated final class Pipeline: @unchecked Sendable {
    private struct State {
        var frame: CIImage?
        var outputs: [String: ModelOutput] = [:]
        var wanted: [String] = []
        var models: [YOLOModel] = []
        var loading: Set<String> = []
        var trackers: [String: Tracker] = [:]
        var busy = false
        var background: CIImage?
        var mirror = true
        var settings = InferenceSettings()
        var errors: [String: String] = [:]
        var cameraRate = RateCounter()
        var cameraSize = CGSize.zero
        var modelRates: [String: RateCounter] = [:]
    }

    private let lock = NSLock()
    private var state = State()
    private let segmentation = PersonSegmentation()

    var latestFrame: CIImage? { lock.withLock { state.frame } }
    var latestOutputs: [String: ModelOutput] { lock.withLock { state.outputs } }
    var errors: [String: String] { lock.withLock { state.errors } }
    /// Captured frames per second and their size.
    var camera: (fps: Double, size: CGSize) { lock.withLock { (state.cameraRate.rate, state.cameraSize) } }

    func setBackground(_ image: CIImage?) { lock.withLock { state.background = image } }
    func setMirror(_ mirror: Bool) { lock.withLock { state.mirror = mirror } }
    func setSettings(_ settings: InferenceSettings) { lock.withLock { state.settings = settings } }

    /// Called on the camera queue for every captured frame.
    func handle(_ buffer: CVPixelBuffer) {
        let (background, mirror) = lock.withLock { (state.background, state.mirror) }
        let frame = segmentation.composite(buffer, over: background, mirror: mirror)
        let run: (models: [YOLOModel], settings: InferenceSettings)? = lock.withLock {
            state.frame = frame
            state.cameraRate.tick()
            state.cameraSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            guard !state.busy, !state.models.isEmpty else { return nil }
            state.busy = true
            return (state.models, state.settings)
        }
        guard let run else { return }
        Task.detached(priority: .userInitiated) { await self.infer(frame, run.models, run.settings) }
    }

    /// Makes `entries` the active models, in order, loading any that are not loaded yet.
    func setModels(_ entries: [(id: String, url: URL)]) {
        let ids = entries.map(\.id)
        let toLoad: [(id: String, url: URL)] = lock.withLock {
            state.wanted = ids
            state.models.removeAll { !ids.contains($0.id) }
            state.outputs = state.outputs.filter { ids.contains($0.key) }
            state.trackers = state.trackers.filter { ids.contains($0.key) }
            state.modelRates = state.modelRates.filter { ids.contains($0.key) }
            let pending = entries.filter { entry in
                !state.loading.contains(entry.id) && !state.models.contains { $0.id == entry.id }
            }
            state.loading.formUnion(pending.map(\.id))
            return pending
        }
        for entry in toLoad {
            Task.detached(priority: .userInitiated) {
                let result: Result<YOLOModel, any Error>
                do { result = .success(try await YOLOModel.load(from: entry.url)) } catch { result = .failure(error) }
                self.lock.withLock {
                    self.state.loading.remove(entry.id)
                    switch result {
                    case .success(let model) where self.state.wanted.contains(entry.id):
                        self.state.errors[entry.id] = nil
                        self.state.models.append(model)
                        // Copy first: reading `state` inside the sort while `state.models` is mutated aborts.
                        let order = self.state.wanted
                        self.state.models.sort { order.firstIndex(of: $0.id)! < order.firstIndex(of: $1.id)! }
                    case .failure(let error): self.state.errors[entry.id] = error.localizedDescription
                    default: break
                    }
                }
            }
        }
    }

    private func infer(_ frame: CIImage, _ models: [YOLOModel], _ settings: InferenceSettings) async {
        var outputs: [String: ModelOutput] = [:]
        for model in models {
            (model.imgsz, model.confidence, model.iou) = (settings.imgsz, settings.confidence, settings.iou)
            do {
                var output = try await model.predict(frame)
                let tracker = lock.withLock {
                    output.fps = state.modelRates[model.id, default: RateCounter()].tick()
                    let tracker = state.trackers[model.id] ?? Tracker()
                    state.trackers[model.id] = tracker
                    return tracker
                }
                tracker.update(&output.detections)
                outputs[model.id] = output
            } catch {
                lock.withLock { state.errors[model.id] = error.localizedDescription }
            }
        }
        lock.withLock {
            state.outputs = outputs.filter { state.wanted.contains($0.key) }
            state.busy = false
        }
    }
}

/// Applied to every model on stage. Fixed-size exports ignore `imgsz`; RF-DETR has no NMS, so no `iou`.
nonisolated struct InferenceSettings: Codable, Equatable {
    var imgsz = 640
    var confidence: Float = 0.25
    var iou: Float = 0.45

    static var saved: InferenceSettings {
        UserDefaults.standard.data(forKey: "inference").flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? .init()
    }

    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "inference") }
}

/// Events per second over the last second.
nonisolated struct RateCounter {
    private var times: [CFAbsoluteTime] = []

    var rate: Double {
        guard let first = times.first, let last = times.last, last > first else { return 0 }
        return Double(times.count - 1) / (last - first)
    }

    @discardableResult
    mutating func tick() -> Double {
        let now = CFAbsoluteTimeGetCurrent()
        times.append(now)
        times.removeAll { now - $0 > 1 }
        return rate
    }
}

/// Replaces the background behind people using Vision's person segmentation (temporally smoothed per sequence).
private nonisolated final class PersonSegmentation {
    private let handler = VNSequenceRequestHandler()
    private let request: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private var fitted: (source: CIImage, extent: CGRect, image: CIImage)?

    func composite(_ buffer: CVPixelBuffer, over background: CIImage?, mirror: Bool) -> CIImage {
        let camera = CIImage(cvPixelBuffer: buffer).mirrored(mirror)
        guard let background, (try? handler.perform([request], on: buffer)) != nil,
            let mask = request.results?.first?.pixelBuffer
        else { return camera }
        let maskImage = CIImage(cvPixelBuffer: mask)
        let scaledMask = maskImage.transformed(by: CGAffineTransform(
            scaleX: camera.extent.width / maskImage.extent.width, y: camera.extent.height / maskImage.extent.height))
        return camera.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: fill(background, camera.extent),
            kCIInputMaskImageKey: scaledMask.mirrored(mirror),
        ])
    }

    /// Aspect-fills the background over the frame, cached until either changes.
    private func fill(_ background: CIImage, _ extent: CGRect) -> CIImage {
        if let fitted, fitted.source === background, fitted.extent == extent { return fitted.image }
        let scale = max(extent.width / background.extent.width, extent.height / background.extent.height)
        let scaled = background.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let image = scaled.transformed(by: CGAffineTransform(
            translationX: extent.midX - scaled.extent.midX, y: extent.midY - scaled.extent.midY)
        ).cropped(to: extent)
        fitted = (background, extent, image)
        return image
    }
}

private nonisolated extension CIImage {
    func mirrored(_ mirror: Bool) -> CIImage { mirror ? oriented(.upMirrored) : self }
}

