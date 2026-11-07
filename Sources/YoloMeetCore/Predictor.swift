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

public nonisolated enum ModelError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let reason): "Invalid model: \(reason)" }
    }
}

/// A model folder on disk (`.aimodel`, or a MediaPipe bundle of two).
nonisolated enum ModelAsset {
    /// The creator-defined metadata of its `metadata.json`.
    static func metadata(at url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url.appending(path: "metadata.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["creatorDefinedMetadata"] as? [String: String] ?? [:]
    }

    /// Total size of the folder in bytes.
    static func size(of url: URL) -> Int {
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { total, file in
            total + (((file as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }) ?? 0)
        }
    }

    static func info(
        at url: URL, metadata: [String: String], family: String, architecture: String?, isDynamic: Bool, precision: String
    ) -> ModelInfo {
        ModelInfo(
            family: family, architecture: architecture, parameters: metadata["params"].flatMap(Int.init),
            gflops: metadata["gflops"].flatMap(Double.init), isDynamic: isDynamic, precision: precision,
            bytes: size(of: url))
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
