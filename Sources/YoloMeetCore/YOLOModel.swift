import Accelerate
import CoreAI
import CoreImage
import Foundation

public nonisolated enum YOLOModelError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let reason): "Invalid model: \(reason)" }
    }
}

/// A Core AI (`.aimodel`) vision model — Ultralytics YOLO or RF-DETR: GPU resizing, Core AI inference and task
/// decoding. Not reentrant: callers run one `predict` at a time per instance.
public nonisolated final class YOLOModel: @unchecked Sendable {
    public let id: String
    public let task: YOLOTask
    public let names: [String]
    public let info: ModelInfo
    /// RF-DETR: stretched, ImageNet-normalized input and query-based (NMS-free) outputs.
    let isDETR: Bool
    public var confidence: Float
    public var iou: Float = 0.45
    /// Longest input side for variable-size exports; nil runs at the training size, as Ultralytics does. Fixed exports
    /// keep their own size; classify keeps its training size.
    public var imgsz: Int?

    private let function: ImageFunction
    var outputNames: [String] { function.outputNames }
    /// The export's input size, nil when its height and width are variable.
    private let fixedSize: (width: Int, height: Int)?
    /// The size the model was trained (and exported) at.
    public let trainingSize: Int
    /// The current input size.
    var width: Int { function.width }
    var height: Int { function.height }

    /// Loads any Ultralytics or RF-DETR Core AI export; the family and task are inferred when metadata lacks them.
    public static func load(from url: URL) async throws -> YOLOModel {
        try YOLOModel(url: url, metadata: try readMetadata(at: url), function: try await ImageFunction.load(url))
    }

    private init(url: URL, metadata: [String: String], function: InferenceFunction) throws {
        let descriptor = function.descriptor
        // RF-DETR's exporter names its outputs; Ultralytics' are output0/output1 and its metadata carries the task.
        let outputs = Set(descriptor.outputNames)
        isDETR = metadata["family"] == "rfdetr" || outputs.isSuperset(of: ["dets", "labels"])
        guard
            let task = metadata["task"].flatMap(YOLOTask.init(rawValue:))
                ?? (isDETR ? (outputs.contains("masks") ? .segment : outputs.contains("keypoints") ? .pose : .detect) : nil)
        else { throw YOLOModelError.invalid("not an Ultralytics or RF-DETR export (no task in its metadata)") }
        if !isDETR, [.detect, .segment, .pose, .obb].contains(task),
            case .ndArray(let head)? = descriptor.outputDescriptor(of: descriptor.outputNames[0]), head.shape.count == 3,
            (0..<head.shape[1]).contains(head.shape[2])  // [1, 300, 6]; raw heads have more (or variable, -1) anchors
        {
            throw YOLOModelError.invalid("end-to-end (nms) export; re-export with the default head: yolo export format=coreai")
        }
        self.id = url.deletingPathExtension().lastPathComponent
        self.task = task
        self.names = Self.parseNames(metadata["names"] ?? "")
        self.confidence = isDETR ? 0.5 : 0.25
        // RF-DETR expects ImageNet normalization; its raw export does not record it.
        let mean = Self.parseNumbers(metadata["mean"] ?? (isDETR ? "0.485, 0.456, 0.406" : ""))
        let std = Self.parseNumbers(metadata["std"] ?? (isDETR ? "0.229, 0.224, 0.225" : ""))
        let range: (low: [Float], high: [Float]) = mean.count == 3 && std.count == 3
            ? ((0..<3).map { -mean[$0] / std[$0] }, (0..<3).map { (1 - mean[$0]) / std[$0] })
            : ([0, 0, 0], [1, 1, 1])
        self.function = try ImageFunction(function, range: range)
        let shape = self.function.shape
        fixedSize = shape[2] > 0 && shape[3] > 0 ? (shape[3], shape[2]) : nil
        trainingSize = fixedSize.map { max($0.width, $0.height) }
            ?? Int(Self.parseNumbers(metadata["imgsz"] ?? "").max() ?? 640)
        info = ModelInfo(
            family: isDETR ? "RF-DETR" : "YOLO", architecture: metadata["architecture"],
            parameters: metadata["params"].flatMap(Int.init), gflops: metadata["gflops"].flatMap(Double.init),
            isDynamic: fixedSize == nil, precision: self.function.scalarType == .float16 ? "FP16" : "FP32",
            bytes: Self.size(of: url))
    }

    /// Runs the model on a frame. Output geometry is in the frame's pixel space (top-left origin).
    public func predict(_ frame: CIImage) async throws -> ModelOutput {
        let start = CFAbsoluteTimeGetCurrent()
        let extent = frame.extent
        guard extent.width > 0, extent.height > 0 else { throw YOLOModelError.invalid("empty frame") }
        let (w, h) = inputSize(for: extent)
        let geometry = geometry(for: extent, width: CGFloat(w), height: CGFloat(h))
        // Core Image is bottom-left origin while padY is measured from the top row.
        // Resampled like the training pipelines: plain bilinear (OpenCV INTER_LINEAR, torchvision without antialias)
        // for YOLO and RF-DETR; classify's PIL resize is antialiased, closest to Core Image's high-quality downsample.
        let placed = frame.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                .concatenating(CGAffineTransform(scaleX: geometry.gainX, y: geometry.gainY))
                .concatenating(CGAffineTransform(
                    translationX: geometry.padX, y: CGFloat(h) - geometry.padY - extent.height * geometry.gainY)),
            highQualityDownsample: task == .classify && !isDETR)
        let tensors = try await function.run(
            placed, width: w, height: h, background: CIColor(red: 114 / 255, green: 114 / 255, blue: 114 / 255))
        var output = ModelOutput(modelID: id, task: task, names: names, info: info, frameSize: frame.extent.size)
        output.inputSize = CGSize(width: width, height: height)
        decode(tensors, geometry: geometry, into: &output)
        output.latency = CFAbsoluteTimeGetCurrent() - start
        return output
    }

    // MARK: Preprocessing

    /// Letterbox (YOLO), center crop (classify) or stretch (RF-DETR, depth) of the frame into a `w` x `h` input.
    private func geometry(for extent: CGRect, width w: CGFloat, height h: CGFloat) -> Geometry {
        switch task {
        case _ where isDETR, .depth:
            return Geometry(gainX: w / extent.width, gainY: h / extent.height, padX: 0, padY: 0)
        case .classify:
            let g = max(w / extent.width, h / extent.height)
            return Geometry(gainX: g, gainY: g, padX: (w - extent.width * g) / 2, padY: (h - extent.height * g) / 2)
        default:
            let g = min(w / extent.width, h / extent.height)
            return Geometry(gainX: g, gainY: g, padX: (w - extent.width * g) / 2, padY: (h - extent.height * g) / 2)
        }
    }

    /// Fixed exports keep their size. Variable ones take `imgsz` on the frame's long side and the frame's aspect, in
    /// multiples of 32 (Ultralytics' rectangular inference: little padding, fewer pixels); classify stays square.
    private func inputSize(for extent: CGRect) -> (width: Int, height: Int) {
        if let fixedSize { return fixedSize }
        guard task != .classify else { return (trainingSize, trainingSize) }
        let side = CGFloat(min(max(imgsz ?? trainingSize, 128), 2048))
        let gain = side / max(extent.width, extent.height)
        func fit(_ length: CGFloat) -> Int { Int((length * gain / 32).rounded(.up)) * 32 }
        return (fit(extent.width), fit(extent.height))
    }

    // MARK: Metadata

    static func readMetadata(at url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url.appendingPathComponent("metadata.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["creatorDefinedMetadata"] as? [String: String] ?? [:]
    }

    static func parseNumbers(_ string: String) -> [Float] {
        string.matches(of: /-?\d+(?:\.\d+)?(?:[eE]-?\d+)?/).compactMap { Float($0.output) }
    }

    /// Total size of an asset directory in bytes.
    public static func size(of url: URL) -> Int {
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        return (files?.allObjects as? [URL] ?? []).reduce(0) { total, file in
            total + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Parses Ultralytics' Python-dict names string, e.g. `{0: 'person', 1: "people's"}`.
    static func parseNames(_ string: String) -> [String] {
        let pairs = string.matches(of: /(\d+):\s*(?:'([^']*)'|"([^"]*)")/).compactMap { match -> (Int, String)? in
            guard let index = Int(match.1) else { return nil }
            return (index, String(match.2 ?? match.3 ?? ""))
        }
        var names = [String](repeating: "", count: (pairs.map(\.0).max() ?? -1) + 1)
        for (index, name) in pairs { names[index] = name }
        return names
    }
}

/// A model output as Float32 values in row-major order.
nonisolated struct Tensor {
    let values: [Float]
    let shape: [Int]
}

/// Maps model-input pixels back to frame pixels: `frame = (input - pad) / gain`.
nonisolated struct Geometry {
    let gainX: CGFloat, gainY: CGFloat, padX: CGFloat, padY: CGFloat

    func point(_ x: Float, _ y: Float) -> CGPoint {
        CGPoint(x: (CGFloat(x) - padX) / gainX, y: (CGFloat(y) - padY) / gainY)
    }

    func rect(cx: Float, cy: Float, w: Float, h: Float) -> CGRect {
        let center = point(cx, cy)
        let size = CGSize(width: CGFloat(w) / gainX, height: CGFloat(h) / gainY)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
}
