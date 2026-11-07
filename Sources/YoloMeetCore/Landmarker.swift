import CoreImage
import Foundation

/// MediaPipe's hand, pose and face landmarkers converted to Core AI, run like MediaPipe Tasks: a detector finds each
/// palm, body or face in the letterboxed frame, then a landmark model reads a square crop around it, rotated upright.
/// Results are detections with keypoints (in frame pixels), so tracking and pose effects work on them unchanged.
/// A model is a folder holding `detector.aimodel`, `landmarks.aimodel` and `metadata.json` (task: hand, pose, face).
public nonisolated final class Landmarker: @unchecked Sendable {
    public let id: String
    public let task: YOLOTask
    public let info: ModelInfo
    public var maxResults = 2

    private let detector: ImageFunction
    private let landmarks: ImageFunction
    private let config: Config
    /// Detector anchor centers, normalized.
    private let anchors: [CGPoint]

    /// Per-task settings from MediaPipe's graphs (detector anchors and ROI rules).
    struct Config {
        let detectorSize: Int
        let strides: [Int]
        /// Keypoints per detection.
        let keypoints: Int
        let landmarkSize: Int
        let landmarkCount: Int
        /// Values per landmark in the landmark output.
        let stride: Int
        let detectorRange: (low: [Float], high: [Float])
        let names: [String]
        let connections: [(Int, Int)]
        /// Square ROI around a detection, in frame pixels.
        let roi: (_ box: CGRect, _ keypoints: [CGPoint]) -> ROI

        static func of(_ task: YOLOTask) -> Config? {
            let unit = ([Float](repeating: 0, count: 3), [Float](repeating: 1, count: 3))
            let signed = ([Float](repeating: -1, count: 3), [Float](repeating: 1, count: 3))
            switch task {
            case .hand:
                // Palm: wrist (0) to middle finger base (2) points up; 2.6x, shifted toward the fingers.
                return Config(
                    detectorSize: 192, strides: [8, 16, 16, 16], keypoints: 7, landmarkSize: 224, landmarkCount: 21,
                    stride: 3, detectorRange: unit, names: ["Left", "Right"], connections: MediaPipeConnections.hand
                ) { box, k in
                    ROI(center: box.center, size: max(box.width, box.height), rotation: angle(k[0], k[2], target: .pi / 2))
                        .shifted(y: -0.5, height: box.height).scaled(2.6)
                }
            case .pose:
                // Body: centered on the hips (0), radius to the shoulders' point (1), pointing up; 1.25x.
                return Config(
                    detectorSize: 224, strides: [8, 16, 32, 32, 32], keypoints: 4, landmarkSize: 256, landmarkCount: 33,
                    stride: 5, detectorRange: signed, names: ["person"], connections: MediaPipeConnections.pose
                ) { _, k in
                    ROI(center: k[0], size: 2 * hypot(k[1].x - k[0].x, k[1].y - k[0].y), rotation: angle(k[0], k[1], target: .pi / 2))
                        .scaled(1.25)
                }
            case .face:
                // Face: level between the eyes (0, 1); 1.5x.
                return Config(
                    detectorSize: 128, strides: [8, 16, 16, 16], keypoints: 6, landmarkSize: 256, landmarkCount: 478,
                    stride: 3, detectorRange: signed, names: ["face"], connections: MediaPipeConnections.faceMesh
                ) { box, k in
                    ROI(center: box.center, size: max(box.width, box.height), rotation: angle(k[0], k[1], target: 0)).scaled(1.5)
                }
            default:
                return nil
            }
        }

        /// MediaPipe's ROI rotation: turns the `from` → `to` direction to `target` (radians, image y down).
        static func angle(_ from: CGPoint, _ to: CGPoint, target: CGFloat) -> CGFloat {
            let angle = target - atan2(-(to.y - from.y), to.x - from.x)
            return angle - 2 * .pi * ((angle + .pi) / (2 * .pi)).rounded(.down)
        }
    }

    /// A square region of the frame (pixels, top-left origin), rotated clockwise by `rotation` radians.
    struct ROI {
        var center: CGPoint
        var size: CGFloat
        var rotation: CGFloat

        func scaled(_ factor: CGFloat) -> ROI { ROI(center: center, size: size * factor, rotation: rotation) }

        /// Moves the center along the rotated vertical axis by `y` times `height`.
        func shifted(y: CGFloat, height: CGFloat) -> ROI {
            ROI(center: CGPoint(x: center.x - height * y * sin(rotation), y: center.y + height * y * cos(rotation)),
                size: size, rotation: rotation)
        }

        /// A point normalized to the region (0...1) in frame pixels.
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let (dx, dy) = ((x - 0.5) * size, (y - 0.5) * size)
            return CGPoint(
                x: center.x + dx * cos(rotation) - dy * sin(rotation), y: center.y + dx * sin(rotation) + dy * cos(rotation))
        }

        /// Places the region of `frame` into an `n` x `n` model input (Core Image coordinates).
        func crop(_ frame: CIImage, _ n: Int) -> CIImage {
            let extent = frame.extent
            let n = CGFloat(n)
            let transform = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: extent.height))  // to y down
                .concatenating(CGAffineTransform(translationX: -center.x, y: -center.y))
                .concatenating(CGAffineTransform(rotationAngle: -rotation))
                .concatenating(CGAffineTransform(scaleX: n / size, y: n / size))
                .concatenating(CGAffineTransform(translationX: n / 2, y: n / 2))
                .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: n))  // back to y up
            return frame.transformed(by: transform, highQualityDownsample: false)
        }
    }

    public static func load(from url: URL) async throws -> Landmarker {
        let metadata = try YOLOModel.readMetadata(at: url)
        guard let task = metadata["task"].flatMap(YOLOTask.init(rawValue:)), let config = Config.of(task) else {
            throw YOLOModelError.invalid("not a MediaPipe landmarker (no hand, pose or face task)")
        }
        let unit = ([Float](repeating: 0, count: 3), [Float](repeating: 1, count: 3))
        return Landmarker(
            id: url.deletingPathExtension().lastPathComponent, task: task, config: config,
            detector: try ImageFunction(try await ImageFunction.load(url.appending(path: "detector.aimodel")), range: config.detectorRange),
            landmarks: try ImageFunction(try await ImageFunction.load(url.appending(path: "landmarks.aimodel")), range: unit),
            info: ModelInfo(
                family: "MediaPipe", architecture: "CNN", parameters: metadata["params"].flatMap(Int.init),
                gflops: metadata["gflops"].flatMap(Double.init), isDynamic: false, precision: "FP32",
                bytes: YOLOModel.size(of: url)))
    }

    private init(id: String, task: YOLOTask, config: Config, detector: ImageFunction, landmarks: ImageFunction, info: ModelInfo) {
        self.id = id
        self.task = task
        self.config = config
        self.detector = detector
        self.landmarks = landmarks
        self.info = info
        // SSD anchors with a fixed size: two per cell for each layer, layers of equal stride sharing a grid.
        var anchors: [CGPoint] = []
        var layer = 0
        while layer < config.strides.count {
            let stride = config.strides[layer]
            var sharing = 0
            while layer < config.strides.count, config.strides[layer] == stride { (layer, sharing) = (layer + 1, sharing + 1) }
            let cells = Int((Double(config.detectorSize) / Double(stride)).rounded(.up))
            for y in 0..<cells {
                for x in 0..<cells {
                    let center = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(cells), y: (CGFloat(y) + 0.5) / CGFloat(cells))
                    anchors += Array(repeating: center, count: 2 * sharing)
                }
            }
        }
        self.anchors = anchors
    }

    public func predict(_ frame: CIImage) async throws -> ModelOutput {
        let start = CFAbsoluteTimeGetCurrent()
        let extent = frame.extent
        guard extent.width > 0, extent.height > 0 else { throw YOLOModelError.invalid("empty frame") }
        var output = ModelOutput(
            modelID: id, task: task, names: config.names, info: info, frameSize: extent.size)
        output.skeleton = config.connections
        output.inputSize = CGSize(width: config.detectorSize, height: config.detectorSize)
        // Detector on the letterboxed frame (black borders, as MediaPipe pads).
        let letterbox = ROI(
            center: CGPoint(x: extent.width / 2, y: extent.height / 2), size: max(extent.width, extent.height), rotation: 0)
        let raw = try await detector.run(
            letterbox.crop(frame, config.detectorSize), width: config.detectorSize, height: config.detectorSize,
            background: .black)
        for found in detections(raw, letterbox).prefix(maxResults) {
            let roi = config.roi(found.box, found.keypoints)
            let n = config.landmarkSize
            let named = Dictionary(uniqueKeysWithValues: zip(
                landmarks.outputNames, try await landmarks.run(roi.crop(frame, n), width: n, height: n, background: .black)))
            guard let points = named["Identity"], let presence = named["Identity_1"]?.values.first,
                sigmoid(presence) >= 0.5
            else { continue }
            var detection = Detection(box: .zero, confidence: found.score, classIndex: 0)
            detection.keypoints = (0..<config.landmarkCount).map { i in
                let v = { points.values[i * self.config.stride + $0] }
                let visibility = config.stride == 5 ? sigmoid(v(3)) : 1  // pose: per-landmark visibility
                var point = CGPoint(x: CGFloat(v(0)) / CGFloat(n), y: CGFloat(v(1)) / CGFloat(n))
                if let heatmap = named["Identity_3"] { point = refine(point, landmark: i, heatmap: heatmap) }
                return Keypoint(point: roi.point(point.x, point.y), confidence: visibility)
            }
            if task == .hand, let right = named["Identity_2"]?.values.first { detection.classIndex = right > 0.5 ? 1 : 0 }
            let xs = detection.keypoints.map(\.point.x), ys = detection.keypoints.map(\.point.y)
            detection.box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            output.detections.append(detection)
        }
        output.latency = CFAbsoluteTimeGetCurrent() - start
        return output
    }

    private func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-min(max(x, -100), 100))) }

    /// MediaPipe's pose refinement: the confidence-weighted center of the landmark's heatmap (`[1, h, w, landmarks]`)
    /// in a 7x7 window around it, when the heatmap is confident there (0.5).
    private func refine(_ point: CGPoint, landmark: Int, heatmap: Tensor) -> CGPoint {
        let (rows, cols, channels) = (heatmap.shape[1], heatmap.shape[2], heatmap.shape[3])
        let (row, col) = (Int(point.y * CGFloat(rows)), Int(point.x * CGFloat(cols)))
        guard (0..<rows).contains(row), (0..<cols).contains(col), landmark < channels else { return point }
        var (sum, weightedRow, weightedCol, best): (Float, Float, Float, Float) = (0, 0, 0, 0)
        for r in max(row - 3, 0)...min(row + 3, rows - 1) {
            for c in max(col - 3, 0)...min(col + 3, cols - 1) {
                let confidence = sigmoid(heatmap.values[(r * cols + c) * channels + landmark])
                sum += confidence
                best = max(best, confidence)
                weightedRow += Float(r) * confidence
                weightedCol += Float(c) * confidence
            }
        }
        guard best >= 0.5, sum > 0 else { return point }
        return CGPoint(x: CGFloat(weightedCol / Float(cols) / sum), y: CGFloat(weightedRow / Float(rows) / sum))
    }

    /// Decodes and merges the detector's candidates, best first, in frame pixels.
    private func detections(_ raw: [Tensor], _ letterbox: ROI) -> [(box: CGRect, keypoints: [CGPoint], score: Float)] {
        guard raw.count == 2 else { return [] }
        let (boxes, scores) = raw[0].values.count > raw[1].values.count ? (raw[0], raw[1]) : (raw[1], raw[0])
        let values = boxes.values.count / anchors.count
        let scale = CGFloat(config.detectorSize)
        var candidates: [(box: CGRect, keypoints: [CGPoint], score: Float)] = []
        for (i, anchor) in anchors.enumerated() {
            let score = sigmoid(scores.values[i])
            guard score >= 0.5 else { continue }
            let v = { CGFloat(boxes.values[i * values + $0]) / scale }
            let (cx, cy, w, h) = (v(0) + anchor.x, v(1) + anchor.y, v(2), v(3))
            let corner = letterbox.point(cx - w / 2, cy - h / 2)
            let box = CGRect(origin: corner, size: CGSize(width: w * letterbox.size, height: h * letterbox.size))
            let keypoints = (0..<config.keypoints).map { k in letterbox.point(v(4 + 2 * k) + anchor.x, v(5 + 2 * k) + anchor.y) }
            candidates.append((box, keypoints, score))
        }
        // MediaPipe's weighted NMS: overlapping candidates (IoU > 0.3) merge into a score-weighted average.
        candidates.sort { $0.score > $1.score }
        var merged: [(box: CGRect, keypoints: [CGPoint], score: Float)] = []
        while let best = candidates.first {
            let group = candidates.filter { iou($0.box, best.box) > 0.3 }
            candidates.removeAll { iou($0.box, best.box) > 0.3 }
            let total = CGFloat(group.reduce(0) { $0 + $1.score })
            func mean(_ value: (CGRect, [CGPoint]) -> CGFloat) -> CGFloat {
                group.reduce(0) { $0 + value($1.box, $1.keypoints) * CGFloat($1.score) } / total
            }
            merged.append((
                CGRect(x: mean { b, _ in b.minX }, y: mean { b, _ in b.minY }, width: mean { b, _ in b.width },
                       height: mean { b, _ in b.height }),
                (0..<config.keypoints).map { k in CGPoint(x: mean { _, p in p[k].x }, y: mean { _, p in p[k].y }) },
                best.score))
        }
        return merged
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let i = inter.width * inter.height
        return i / (a.width * a.height + b.width * b.height - i)
    }
}

private nonisolated extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
