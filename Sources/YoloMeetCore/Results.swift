import CoreGraphics

/// The Ultralytics task a model was exported for, read from its metadata.
public enum YOLOTask: String, Sendable, CaseIterable {
    case detect, segment, pose, obb, classify, semantic, depth

    public var title: String {
        switch self {
        case .detect: "Detect"
        case .segment: "Segment"
        case .pose: "Pose"
        case .obb: "OBB"
        case .classify: "Classify"
        case .semantic: "Semantic"
        case .depth: "Depth"
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
    public let inputWidth: Int
    public let inputHeight: Int
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
    public var detections: [Detection] = []
    /// Full-frame overlay: instance masks (segment), class map (semantic) or colormap (depth).
    public var overlay: CGImage?
    /// Top-5 `(classIndex, probability)` for classify.
    public var topClasses: [(index: Int, confidence: Float)] = []
    /// Model run time in seconds, preprocessing and decoding included.
    public var latency: Double = 0
    /// Results per second, measured by the pipeline.
    public var fps: Double = 0

    public func name(of classIndex: Int) -> String {
        names.indices.contains(classIndex) ? names[classIndex] : "\(classIndex)"
    }
}

/// Standard COCO-17 skeleton, as pairs of keypoint indices.
public let poseSkeleton: [(Int, Int)] = [
    (15, 13), (13, 11), (16, 14), (14, 12), (11, 12), (5, 11), (6, 12), (5, 6), (5, 7), (6, 8),
    (7, 9), (8, 10), (1, 2), (0, 1), (0, 2), (1, 3), (2, 4), (3, 5), (4, 6),
]
