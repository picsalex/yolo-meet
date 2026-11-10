import CoreGraphics
import Foundation

/// The Ultralytics task a model was exported for, read from its metadata.
public enum YOLOTask: String, Sendable, CaseIterable, Codable {
    case detect, segment, pose, obb, classify, semantic, depth
    /// Keypoint tasks of MediaPipe and Apple Vision models.
    case hand, face

    public var title: String {
        switch self {
        case .detect: "Detect"
        case .segment: "Segment"
        case .pose: "Pose"
        case .obb: "OBB"
        case .classify: "Classify"
        case .semantic: "Semantic"
        case .depth: "Depth"
        case .hand: "Hand"
        case .face: "Face"
        }
    }
}

/// One detected object. Geometry is in frame pixels with a top-left origin.
public nonisolated struct Detection: Sendable {
    /// Axis-aligned box; for OBB this is the unrotated box centered on the object.
    public var box: CGRect
    public var confidence: Float
    public var classIndex: Int
    /// Stable identity across frames, assigned by `Tracker`.
    public var trackID: Int?
    /// OBB rotation in radians (clockwise in top-left image space).
    public var angle: Float = 0
    /// Pose keypoints, empty for other tasks.
    public var keypoints: [Keypoint] = []
}

nonisolated extension Detection {
    /// Sets the box around the keypoints at least `minConfidence` confident.
    func boxed(minConfidence: Float = 0) -> Detection {
        let bounds = keypoints.filter { $0.confidence >= minConfidence }.map(\.point).bounds
        guard !bounds.isNull else { return self }
        var detection = self
        detection.box = bounds
        return detection
    }
}

nonisolated extension [CGPoint] {
    /// The smallest rectangle around the points; null when there are none.
    var bounds: CGRect {
        let (xs, ys) = (map(\.x), map(\.y))
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

nonisolated extension CGRect {
    /// Intersection over union.
    func iou(_ other: CGRect) -> CGFloat {
        let inter = intersection(other)
        guard !inter.isNull else { return 0 }
        let i = inter.width * inter.height
        return i / (width * height + other.width * other.height - i)
    }
}

/// Logistic function, clamped so large logits stay finite.
nonisolated func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-min(max(x, -100), 100))) }

public nonisolated struct Keypoint: Sendable {
    public var point: CGPoint
    public var confidence: Float
}

/// Static facts about a loaded model, for display.
public nonisolated struct ModelInfo: Sendable {
    public let family: String
    /// "CNN" or "Transformer", from the export metadata.
    public let architecture: String?
    public let parameters: Int?
    public let gflops: Double?
    /// Variable input height and width (set per frame from `imgsz`).
    public let isDynamic: Bool
    public let precision: String
    /// Size of the `.aimodel` on disk.
    public let bytes: Int
}

/// Everything one model produced for one frame.
public nonisolated struct ModelOutput: Sendable {
    public let modelID: String
    public let task: YOLOTask
    public let names: [String]
    public let info: ModelInfo
    /// Size of the frame the geometry refers to.
    public let frameSize: CGSize
    /// Model input this result was computed at.
    public var inputSize = CGSize.zero
    /// Capture time of the frame (`CACurrentMediaTime`), set by the pipeline.
    public var time: Double = 0
    public var detections: [Detection] = []
    /// Full-frame overlay: instance masks (segment), class map (semantic) or colormap (depth).
    public var overlay: CGImage?
    /// Normalized depth (depth), to color with other colors than `overlay`'s.
    public var depth: DepthSteps?
    /// Top-5 `(classIndex, probability)` for classify.
    public var topClasses: [(index: Int, confidence: Float)] = []
    /// Model run time in seconds, preprocessing and decoding included.
    public var latency: Double = 0
    /// Results per second, measured by the pipeline.
    public var fps: Double = 0
    /// Keypoint pairs to connect; COCO's body skeleton unless the model has its own.
    public var skeleton: [(Int, Int)] = poseSkeleton

    public func name(of classIndex: Int) -> String {
        names.indices.contains(classIndex) ? names[classIndex] : "\(classIndex)"
    }
}

/// Standard COCO-17 skeleton, as pairs of keypoint indices.
nonisolated public let poseSkeleton: [(Int, Int)] = [
    (15, 13), (13, 11), (16, 14), (14, 12), (11, 12), (5, 11), (6, 12), (5, 6), (5, 7), (6, 8),
    (7, 9), (8, 10), (1, 2), (0, 1), (0, 2), (1, 3), (2, 4), (3, 5), (4, 6),
]

public nonisolated extension [ModelOutput] {
    /// The latest results, with detections carried forward to `time` at the speed they moved between the last two
    /// model runs (matched by track ID), at most `maxLead` seconds ahead. The video shows the newest frame while results
    /// describe an older one; this keeps boxes and keypoints on fast-moving hands instead of trailing them.
    func predicted(at time: Double, maxLead: Double = 0.15) -> ModelOutput? {
        guard count > 1, let b = last else { return last }
        let a = self[count - 2]
        guard b.time > a.time else { return b }
        let f = CGFloat((Swift.min(time, b.time + maxLead) - a.time) / (b.time - a.time))
        func mix(_ p: CGFloat, _ q: CGFloat) -> CGFloat { p + (q - p) * f }
        func mix(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: mix(p.x, q.x), y: mix(p.y, q.y)) }
        var output = b
        output.detections = b.detections.map { detection in
            guard let id = detection.trackID, let start = a.detections.first(where: { $0.trackID == id }) else {
                return detection
            }
            var moved = detection
            moved.box = CGRect(
                origin: mix(start.box.origin, detection.box.origin),
                size: CGSize(width: Swift.max(mix(start.box.width, detection.box.width), 0), height: Swift.max(mix(start.box.height, detection.box.height), 0)))
            moved.angle = Float(mix(CGFloat(start.angle), CGFloat(detection.angle)))
            if start.keypoints.count == detection.keypoints.count {
                for (i, p) in start.keypoints.enumerated() { moved.keypoints[i].point = mix(p.point, moved.keypoints[i].point) }
            }
            return moved
        }
        return output
    }
}

/// A depth map as gradient steps per pixel, row by row: 0 for the farthest, 255 for the nearest.
public nonisolated struct DepthSteps: Sendable {
    public let width: Int
    public let height: Int
    public let values: [UInt8]

    /// The map in `gradient` (256 colors, far to near).
    public func image(_ gradient: [(UInt8, UInt8, UInt8)]) -> CGImage? {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for (i, step) in values.enumerated() {
            let (r, g, b) = gradient[Int(step)]
            (rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]) = (r, g, b)
        }
        return makeImage(rgba: rgba, width: width, height: height)
    }
}
