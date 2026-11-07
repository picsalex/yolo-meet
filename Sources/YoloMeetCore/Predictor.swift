import CoreImage
import Foundation

/// A model the pipeline runs on frames: Ultralytics YOLO and RF-DETR, MediaPipe landmarkers, or Apple Vision.
/// Not reentrant: one `predict` at a time per instance.
public nonisolated protocol Predictor: AnyObject, Sendable {
    var id: String { get }
    var task: YOLOTask { get }
    var info: ModelInfo { get }
    /// The size the model runs at by default (its training size).
    var trainingSize: Int { get }
    /// Applies the panel's inference settings; models without such settings ignore them.
    func configure(imgsz: Int?, confidence: Float, iou: Float)
    func predict(_ frame: CIImage) async throws -> ModelOutput
}

public nonisolated enum Predictors {
    /// Loads a model by id: `vision-*` ids are Apple Vision; a folder with a detector is a MediaPipe landmarker;
    /// anything else is a YOLO or RF-DETR export.
    public static func load(id: String, from url: URL) async throws -> any Predictor {
        if id.hasPrefix("vision-") { return try VisionLandmarker(id: id) }
        if FileManager.default.fileExists(atPath: url.appending(path: "detector.aimodel").path) {
            return try await Landmarker.load(from: url)
        }
        return try await YOLOModel.load(from: url)
    }
}

nonisolated extension YOLOModel: Predictor {
    public func configure(imgsz: Int?, confidence: Float, iou: Float) {
        (self.imgsz, self.confidence, self.iou) = (imgsz, confidence, iou)
    }
}

nonisolated extension Landmarker: Predictor {
    public var trainingSize: Int { 0 }
    /// MediaPipe's own thresholds (0.5) apply, as in MediaPipe Tasks.
    public func configure(imgsz: Int?, confidence: Float, iou: Float) {}
}

nonisolated extension VisionLandmarker: Predictor {
    public var trainingSize: Int { 0 }
    public func configure(imgsz: Int?, confidence: Float, iou: Float) {}
}
