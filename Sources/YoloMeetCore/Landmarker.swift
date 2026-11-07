import CoreImage
import Foundation

/// MediaPipe's hand, pose and face landmarkers converted to Core AI, run like MediaPipe Tasks: a detector finds each
/// palm, body or face in the letterboxed frame, then a landmark model reads a square crop around it, rotated upright.
/// Results are detections with keypoints (in frame pixels), so tracking and pose effects work on them unchanged.
/// Like MediaPipe on video, each result's next crop comes from its landmarks, and the detector only runs while fewer
/// than `Config.maxResults` are tracked (every frame with none, every `redetectEvery` frames otherwise). A new instance's
/// first frame is MediaPipe's IMAGE mode: detector, then landmarks. Crops run at the same time, on one copy of the
/// landmark model each.
/// A model is a folder holding `detector.aimodel`, `landmarks.aimodel` and `metadata.json` (task: hand, pose, face).
public nonisolated final class Landmarker: @unchecked Sendable {
    public let id: String
    public let task: YOLOTask
    public let info: ModelInfo
    let redetectEvery = 10

    private let detector: ImageFunction
    /// One per result: a model instance runs one input at a time.
    private let landmarks: [ImageFunction]
    private let config: Config
    /// Detector anchor centers, normalized.
    private let anchors: [CGPoint]
    /// Landmark output indices: points, presence, and hand's handedness and pose's heatmap.
    private let outputs: (points: Int, presence: Int, handedness: Int?, heatmap: Int?)
    /// Crops for the next frame, from this frame's landmarks, and the frame they are in.
    private var tracked: [ROI] = []
    private var trackedExtent = CGRect.null
    private var sinceDetection = 0

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
        /// The presence output is a logit (face); hand and pose output a probability.
        var presenceIsLogit = false
        /// Results tracked at once, each on its own copy of the landmark model: two hands, one body, one face (the
        /// scenes show one person).
        var maxResults = 1
        let detectorRange: (low: [Float], high: [Float])
        let names: [String]
        let connections: [(Int, Int)]
        /// Square ROI around a detection, in frame pixels.
        let roi: (_ box: CGRect, _ keypoints: [CGPoint]) -> ROI
        /// The next frame's ROI from this frame's landmarks (all of the model's points, frame pixels).
        let track: (_ landmarks: [CGPoint]) -> ROI

        static let unit = ([Float](repeating: 0, count: 3), [Float](repeating: 1, count: 3))

        static func of(_ task: YOLOTask) -> Config? {
            let signed = ([Float](repeating: -1, count: 3), [Float](repeating: 1, count: 3))
            switch task {
            case .hand:
                // Palm: wrist (0) to middle finger base (2) points up; 2.6x, shifted toward the fingers.
                // Tracked: the wrist, finger bases and lower joints, wrist toward the middle knuckles pointing up; 2x.
                return Config(
                    detectorSize: 192, strides: [8, 16, 16, 16], keypoints: 7, landmarkSize: 224, landmarkCount: 21,
                    stride: 3, maxResults: 2, detectorRange: unit, names: ["Left", "Right"], connections: MediaPipeConnections.hand,
                    roi: { box, k in
                        ROI(center: box.center, size: max(box.width, box.height), rotation: angle(k[0], k[2], target: .pi / 2))
                            .shifted(y: -0.5, height: box.height).scaled(2.6)
                    },
                    track: { k in
                        let knuckles = CGPoint(x: ((k[5].x + k[13].x) / 2 + k[9].x) / 2, y: ((k[5].y + k[13].y) / 2 + k[9].y) / 2)
                        let rotation = angle(k[0], knuckles, target: .pi / 2)
                        let (roi, height) = ROI.around([0, 1, 2, 3, 5, 6, 9, 10, 13, 14, 17, 18].map { k[$0] }, rotation: rotation)
                        return roi.shifted(y: -0.1, height: height).scaled(2)
                    })
            case .pose:
                // Body: centered on the hips (0), radius to the shoulders' point (1), pointing up; 1.25x.
                // Tracked: the same rule on the landmark model's two extra points (33, 34).
                let body = { (k: [CGPoint]) in
                    ROI(center: k[0], size: 2 * hypot(k[1].x - k[0].x, k[1].y - k[0].y), rotation: angle(k[0], k[1], target: .pi / 2))
                        .scaled(1.25)
                }
                return Config(
                    detectorSize: 224, strides: [8, 16, 32, 32, 32], keypoints: 4, landmarkSize: 256, landmarkCount: 33,
                    stride: 5, detectorRange: signed, names: ["person"], connections: MediaPipeConnections.pose,
                    roi: { _, k in body(k) }, track: { k in body([k[33], k[34]]) })
            case .face:
                // Face: level between the eyes (0, 1); 1.5x. Tracked: around all landmarks, level between the eye
                // corners (33, 263).
                let face = { (box: CGRect, eyes: [CGPoint]) in
                    ROI(center: box.center, size: max(box.width, box.height), rotation: angle(eyes[0], eyes[1], target: 0)).scaled(1.5)
                }
                return Config(
                    detectorSize: 128, strides: [8, 16, 16, 16], keypoints: 6, landmarkSize: 256, landmarkCount: 478,
                    stride: 3, presenceIsLogit: true, detectorRange: signed, names: ["face"],
                    connections: MediaPipeConnections.faceMesh, roi: face, track: { k in face(k.bounds, [k[33], k[263]]) })
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

        /// Axis-aligned bounds, ignoring the rotation.
        var bounds: CGRect { CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size) }

        func scaled(_ factor: CGFloat) -> ROI { ROI(center: center, size: size * factor, rotation: rotation) }

        /// The smallest rectangle rotated by `rotation` around `points`, squared on its long side; and its height.
        static func around(_ points: [CGPoint], rotation: CGFloat) -> (roi: ROI, height: CGFloat) {
            let (c, s) = (cos(rotation), sin(rotation))
            let local = points.map { CGPoint(x: $0.x * c + $0.y * s, y: -$0.x * s + $0.y * c) }  // inverse of `point`
            let box = local.bounds
            let center = CGPoint(x: box.midX * c - box.midY * s, y: box.midX * s + box.midY * c)
            return (ROI(center: center, size: max(box.width, box.height), rotation: rotation), box.height)
        }

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
        let metadata = try ModelAsset.metadata(at: url)
        guard let task = metadata["task"].flatMap(YOLOTask.init(rawValue:)), let config = Config.of(task) else {
            throw ModelError.invalid("not a MediaPipe landmarker (no hand, pose or face task)")
        }
        let detector = try ImageFunction(
            try await ImageFunction.load(url.appending(path: "detector.aimodel")), range: config.detectorRange)
        var landmarks: [ImageFunction] = []
        for _ in 0..<config.maxResults {
            landmarks.append(try ImageFunction(try await ImageFunction.load(url.appending(path: "landmarks.aimodel")), range: Config.unit))
        }
        return try Landmarker(
            id: url.deletingPathExtension().lastPathComponent, task: task, config: config, detector: detector,
            landmarks: landmarks,
            info: ModelAsset.info(
                at: url, metadata: metadata, family: "MediaPipe", architecture: "CNN", isDynamic: false,
                precision: detector.precision))
    }

    private init(id: String, task: YOLOTask, config: Config, detector: ImageFunction, landmarks: [ImageFunction], info: ModelInfo) throws {
        self.id = id
        self.task = task
        self.config = config
        self.detector = detector
        self.landmarks = landmarks
        self.info = info
        let names = landmarks[0].outputNames
        guard let points = names.firstIndex(of: "Identity"), let presence = names.firstIndex(of: "Identity_1") else {
            throw ModelError.invalid("landmark model without points and presence")
        }
        outputs = (points, presence, task == .hand ? names.firstIndex(of: "Identity_2") : nil, names.firstIndex(of: "Identity_3"))
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
        guard extent.width > 0, extent.height > 0 else { throw ModelError.invalid("empty frame") }
        var output = ModelOutput(
            modelID: id, task: task, names: config.names, info: info, frameSize: extent.size)
        output.skeleton = config.connections
        output.inputSize = CGSize(width: config.detectorSize, height: config.detectorSize)
        if extent != trackedExtent { (tracked, trackedExtent) = ([], extent) }  // another input
        var rois = tracked
        if rois.isEmpty || (rois.count < config.maxResults && sinceDetection >= redetectEvery) {
            sinceDetection = 0
            // Detector on the letterboxed frame (black borders, as MediaPipe pads). Tracked results take precedence.
            let letterbox = ROI(
                center: CGPoint(x: extent.width / 2, y: extent.height / 2), size: max(extent.width, extent.height), rotation: 0)
            let raw = try await detector.run(
                letterbox.crop(frame, config.detectorSize), width: config.detectorSize, height: config.detectorSize,
                background: .black)
            for found in detections(raw, letterbox) where rois.count < config.maxResults {
                let roi = config.roi(found.box, found.keypoints)
                if !rois.contains(where: { $0.bounds.iou(roi.bounds) > 0.5 }) { rois.append(roi) }
            }
        } else {
            sinceDetection += 1
        }
        let n = config.landmarkSize
        let crops = try await withThrowingTaskGroup(of: (Int, [Tensor]).self) { group in
            for (i, (roi, function)) in zip(rois, landmarks).enumerated() {
                group.addTask { (i, try await function.run(roi.crop(frame, n), width: n, height: n, background: .black)) }
            }
            return try await group.reduce(into: [Int: [Tensor]]()) { $0[$1.0] = $1.1 }
        }
        tracked = []
        for (i, roi) in rois.enumerated() {
            guard let raw = crops[i] else { continue }
            let score = raw[outputs.presence].values[0]
            let (values, presence) = (raw[outputs.points].values, config.presenceIsLogit ? sigmoid(score) : score)
            guard presence >= 0.5 else { continue }  // lost
            let heatmap = outputs.heatmap.map { raw[$0] }
            var points: [Keypoint] = (0..<values.count / config.stride).map { i in
                let v = { values[i * self.config.stride + $0] }
                var point = CGPoint(x: CGFloat(v(0)) / CGFloat(n), y: CGFloat(v(1)) / CGFloat(n))
                if let heatmap { point = refine(point, landmark: i, heatmap: heatmap) }
                // Pose has a visibility per landmark.
                return Keypoint(point: roi.point(point.x, point.y), confidence: config.stride == 5 ? sigmoid(v(3)) : 1)
            }
            let next = config.track(points.map(\.point))
            guard !tracked.contains(where: { $0.bounds.iou(next.bounds) > 0.5 }) else { continue }  // two crops, one object
            tracked.append(next)
            points.removeLast(points.count - config.landmarkCount)  // pose's extra points only steer the crop
            var detection = Detection(box: .zero, confidence: presence, classIndex: 0)
            detection.keypoints = points
            if let handedness = outputs.handedness { detection.classIndex = raw[handedness].values[0] > 0.5 ? 1 : 0 }
            output.detections.append(detection.boxed())
        }
        output.latency = CFAbsoluteTimeGetCurrent() - start
        return output
    }

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
            let group = candidates.filter { $0.box.iou(best.box) > 0.3 }
            candidates.removeAll { $0.box.iou(best.box) > 0.3 }
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
}

private nonisolated extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
