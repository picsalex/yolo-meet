import CoreImage
import Foundation
import QuartzCore
import Vision
import YoloMeetCore

/// Camera frame → background replacement → models → tracked results.
/// Each model runs at its own rate on the newest frame and never queues up stale frames. The renderer asks for a
/// `snapshot` at display rate: the newest frame, with results predicted to its capture time.
nonisolated final class Pipeline: @unchecked Sendable {
    /// Where frames come from. `off`: the stage shows the background, or black, and models do not run.
    enum Input { case camera, media, off }

    private struct State {
        /// Newest frame and its capture time (`CACurrentMediaTime`).
        var frame: (time: TimeInterval, image: CIImage)?
        /// Recent results per model, oldest first.
        var history: [String: [ModelOutput]] = [:]
        var wanted: [String] = []
        var models: [YOLOModel] = []
        var loading: Set<String> = []
        var trackers: [String: Tracker] = [:]
        /// Models with a run in flight.
        var busy: Set<String> = []
        var background: CIImage?
        var mirror = true
        var input = Input.camera
        var settings = InferenceSettings()
        var errors: [String: String] = [:]
        var cameraRate = RateCounter()
        var cameraSize = CGSize.zero
        var modelRates: [String: RateCounter] = [:]
    }

    private let lock = NSLock()
    private var state = State()
    private let segmentation = PersonSegmentation()

    var latestOutputs: [String: ModelOutput] { lock.withLock { state.history.compactMapValues(\.last) } }
    /// Training sizes of the loaded models that follow the image size setting (variable-size, not classify).
    var trainingSizes: [Int] {
        lock.withLock { Set(state.models.filter { $0.info.isDynamic && $0.task != .classify }.map(\.trainingSize)).sorted() }
    }
    var errors: [String: String] { lock.withLock { state.errors } }
    /// Active models with no result yet (loading, compiling for this Mac, first run) and no error.
    var pending: Set<String> {
        lock.withLock {
            state.input != .off ? Set(state.wanted.filter { state.history[$0] == nil && state.errors[$0] == nil }) : []
        }
    }
    /// Called, on any thread, when `pending` may have changed. Set once before models are added.
    nonisolated(unsafe) var onPendingChange: @Sendable () -> Void = {}
    /// Input frames per second and their size.
    var camera: (fps: Double, size: CGSize) { lock.withLock { (state.cameraRate.rate, state.cameraSize) } }

    func setBackground(_ image: CIImage?) {
        lock.withLock {
            state.background = image
            if state.input == .off { state.frame = (CACurrentMediaTime(), offFrame()) }
        }
    }

    /// Switching input clears results and tracks; the stage stays black until the new input's first frame.
    func setInput(_ input: Input) {
        lock.withLock {
            guard state.input != input else { return }
            state.input = input
            state.history = [:]
            state.trackers = [:]
            state.frame = input == .off ? (CACurrentMediaTime(), offFrame()) : nil
        }
        onPendingChange()
    }

    /// Caller holds `lock`.
    private func offFrame() -> CIImage {
        let extent = CGRect(origin: .zero, size: state.cameraSize == .zero ? CGSize(width: 1920, height: 1080) : state.cameraSize)
        return state.background?.filling(extent) ?? CIImage(color: .black).cropped(to: extent)
    }
    func setMirror(_ mirror: Bool) { lock.withLock { state.mirror = mirror } }
    func setSettings(_ settings: InferenceSettings) { lock.withLock { state.settings = settings } }

    /// Called on the camera queue for every captured frame.
    func handle(_ buffer: CVPixelBuffer) {
        let (input, background, mirror) = lock.withLock { (state.input, state.background, state.mirror) }
        guard input == .camera else { return }  // a frame still in flight after switching input
        show(segmentation.composite(buffer, over: background, mirror: mirror), from: .camera)
    }

    /// Shows a frame from `input` and starts every idle model on it. Media frames come here directly.
    func show(_ frame: CIImage, from input: Input = .media) {
        let time = CACurrentMediaTime()
        let (idle, settings) = lock.withLock {
            guard state.input == input else { return ([YOLOModel](), state.settings) }
            state.frame = (time, frame)
            state.cameraRate.tick()
            state.cameraSize = frame.extent.size
            let idle = state.models.filter { !state.busy.contains($0.id) }
            state.busy.formUnion(idle.map(\.id))
            return (idle, state.settings)
        }
        // One task per idle model: a fast model is not held back by a slow one.
        for model in idle {
            Task.detached(priority: .userInitiated) { await self.infer(frame, at: time, model, settings) }
        }
    }

    /// The newest frame and every model's results: predicted to its capture time, or the latest as they are.
    func snapshot(predicting: Bool) -> (frame: CIImage, outputs: [String: ModelOutput])? {
        lock.withLock {
            state.frame.map { frame in
                (frame.image, state.history.compactMapValues { predicting ? $0.predicted(at: frame.time) : $0.last })
            }
        }
    }

    /// Makes `entries` the active models, in order, loading any that are not loaded yet.
    func setModels(_ entries: [(id: String, url: URL)]) {
        let ids = entries.map(\.id)
        let toLoad: [(id: String, url: URL)] = lock.withLock {
            state.wanted = ids
            state.models.removeAll { !ids.contains($0.id) }
            state.history = state.history.filter { ids.contains($0.key) }
            state.trackers = state.trackers.filter { ids.contains($0.key) }
            state.modelRates = state.modelRates.filter { ids.contains($0.key) }
            let pending = entries.filter { entry in
                !state.loading.contains(entry.id) && !state.models.contains { $0.id == entry.id }
            }
            state.loading.formUnion(pending.map(\.id))
            for entry in pending { state.errors[entry.id] = nil }  // a retry starts clean
            return pending
        }
        onPendingChange()
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
                if case .failure = result { self.onPendingChange() }
            }
        }
    }

    /// Runs one model (not reentrant: one run per instance at a time) and records its result.
    private func infer(_ frame: CIImage, at time: TimeInterval, _ model: YOLOModel, _ settings: InferenceSettings) async {
        (model.imgsz, model.confidence, model.iou) = (settings.imgsz, settings.confidence, settings.iou)
        do {
            var output = try await model.predict(frame)
            output.time = time
            let tracker = lock.withLock {
                output.fps = state.modelRates[model.id, default: RateCounter()].tick()
                let tracker = state.trackers[model.id] ?? Tracker()
                state.trackers[model.id] = tracker
                return tracker
            }
            tracker.update(&output.detections)
            let first = lock.withLock { () -> Bool in
                guard state.wanted.contains(model.id) else { return false }
                let first = state.history[model.id] == nil
                state.history[model.id, default: []].append(output)
                state.history[model.id]!.removeFirst(max(state.history[model.id]!.count - 2, 0))  // prediction uses the last two
                return first
            }
            if first { onPendingChange() }  // its first result: no longer pending
        } catch {
            lock.withLock { state.errors[model.id] = error.localizedDescription }
            onPendingChange()
        }
        lock.withLock { _ = state.busy.remove(model.id) }
    }
}

/// Applied to every model on stage. `imgsz` nil runs each model at its training size; fixed-size exports ignore it.
/// RF-DETR has no NMS, so no `iou`.
nonisolated struct InferenceSettings: Codable, Equatable {
    var imgsz: Int?
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
/// Segmentation takes ~19 ms at 1080p, so it runs on its own queue on the newest frame and every frame is blended with
/// the latest mask: the camera queue never waits for it.
private nonisolated final class PersonSegmentation: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PersonSegmentation", qos: .userInitiated)
    private let handler = VNSequenceRequestHandler()  // on `queue`
    private let request: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private let lock = NSLock()
    private var mask: CVPixelBuffer?  // guarded by `lock`
    private var busy = false  // guarded by `lock`
    private var fitted: (source: CIImage, extent: CGRect, image: CIImage)?  // camera queue

    func composite(_ buffer: CVPixelBuffer, over background: CIImage?, mirror: Bool) -> CIImage {
        let camera = CIImage(cvPixelBuffer: buffer).mirrored(mirror)
        guard let background else {
            lock.withLock { mask = nil }  // a stale mask must not cut out the next background
            return camera
        }
        nonisolated(unsafe) let buffer = buffer
        if lock.withLock({ mask == nil }) {
            queue.sync { segment(buffer) }  // first frame: wait for a mask, so the real room never shows
        } else if lock.withLock({ () -> Bool in defer { busy = true }; return !busy }) {
            queue.async {
                self.segment(buffer)
                self.lock.withLock { self.busy = false }
            }
        }
        guard let mask = lock.withLock({ mask }) else { return camera }
        let maskImage = CIImage(cvPixelBuffer: mask)
        let scaledMask = maskImage.transformed(by: CGAffineTransform(
            scaleX: camera.extent.width / maskImage.extent.width, y: camera.extent.height / maskImage.extent.height))
        return camera.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: fill(background, camera.extent),
            kCIInputMaskImageKey: scaledMask.mirrored(mirror),
        ])
    }

    /// On `queue`.
    private func segment(_ buffer: CVPixelBuffer) {
        guard (try? handler.perform([request], on: buffer)) != nil, let result = request.results?.first?.pixelBuffer
        else { return }
        lock.withLock { mask = result }
    }

    /// Aspect-fills the background over the frame, cached until either changes.
    private func fill(_ background: CIImage, _ extent: CGRect) -> CIImage {
        if let fitted, fitted.source === background, fitted.extent == extent { return fitted.image }
        let image = background.filling(extent)
        fitted = (background, extent, image)
        return image
    }
}

private nonisolated extension CIImage {
    func mirrored(_ mirror: Bool) -> CIImage { mirror ? oriented(.upMirrored) : self }

    /// Scaled to cover `extent`, centered and cropped to it.
    func filling(_ extent: CGRect) -> CIImage {
        let scale = max(extent.width / self.extent.width, extent.height / self.extent.height)
        let scaled = transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled.transformed(by: CGAffineTransform(
            translationX: extent.midX - scaled.extent.midX, y: extent.midY - scaled.extent.midY)
        ).cropped(to: extent)
    }
}

