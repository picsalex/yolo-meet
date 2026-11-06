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
    /// Longest input side for variable-size exports. Fixed exports keep their own size; classify keeps its training size.
    public var imgsz: Int

    private let function: InferenceFunction
    private let inputName: String
    let outputNames: [String]
    private let scalarType: NDArray.ScalarType
    /// The export's input size, nil when its height and width are variable.
    private let fixedSize: (width: Int, height: Int)?
    /// The size the model was exported (or trained) at.
    private let exportSize: Int
    // Input buffers, reallocated when the input size changes.
    private var input: NDArray?
    private var staging: CVPixelBuffer?
    private var planes: [UInt8] = []
    private var floatPlane: [Float] = []
    private(set) var width = 0
    private(set) var height = 0
    private var scratch: [[Float]]
    /// Per-channel value of pixel 0 and pixel 255 after normalization (RGB).
    private let range: (low: [Float], high: [Float])
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Loads any Ultralytics or RF-DETR Core AI export; the family and task are inferred when metadata lacks them.
    public static func load(from url: URL) async throws -> YOLOModel {
        let metadata = try readMetadata(at: url)
        let model: AIModel
        do {
            model = try await AIModel(contentsOf: url)
        } catch {
            // A stale specialization cache entry (asset replaced at the same path) fails instead of rebuilding.
            try? AIModelCache.default.deleteEntries(for: url)
            model = try await AIModel(contentsOf: url)
        }
        guard let function = try model.loadFunction(named: "main") else { throw YOLOModelError.invalid("no 'main'") }
        return try YOLOModel(url: url, metadata: metadata, function: function)
    }

    private init(url: URL, metadata: [String: String], function: InferenceFunction) throws {
        let descriptor = function.descriptor
        guard let inputName = descriptor.inputNames.first,
            case .ndArray(let shape)? = descriptor.inputDescriptor(of: inputName), shape.shape.count == 4
        else { throw YOLOModelError.invalid("expected one BCHW input") }
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
        range = mean.count == 3 && std.count == 3
            ? ((0..<3).map { -mean[$0] / std[$0] }, (0..<3).map { (1 - mean[$0]) / std[$0] })
            : ([0, 0, 0], [1, 1, 1])
        fixedSize = shape.shape[2] > 0 && shape.shape[3] > 0 ? (shape.shape[3], shape.shape[2]) : nil
        exportSize = fixedSize.map { max($0.width, $0.height) }
            ?? Int(Self.parseNumbers(metadata["imgsz"] ?? "").max() ?? 640)
        imgsz = exportSize
        info = ModelInfo(
            family: isDETR ? "RF-DETR" : "YOLO", architecture: metadata["architecture"],
            parameters: metadata["params"].flatMap(Int.init), gflops: metadata["gflops"].flatMap(Double.init),
            isDynamic: fixedSize == nil, precision: shape.scalarType == .float16 ? "FP16" : "FP32",
            bytes: Self.size(of: url))
        self.function = function
        self.inputName = inputName
        self.outputNames = descriptor.outputNames
        self.scalarType = shape.scalarType
        scratch = Array(repeating: [], count: descriptor.outputNames.count)
    }

    /// Runs the model on a frame. Output geometry is in the frame's pixel space (top-left origin).
    public func predict(_ frame: CIImage) async throws -> ModelOutput {
        let start = CFAbsoluteTimeGetCurrent()
        let geometry = try prepareInput(frame)
        var outputs = try await function.run(inputs: [inputName: input!])
        var tensors: [Tensor] = []
        for (i, name) in outputNames.enumerated() {
            guard let array = outputs.remove(name)?.ndArray else { throw YOLOModelError.invalid("missing \(name)") }
            tensors.append(try floats(of: array, into: i))
        }
        var output = ModelOutput(modelID: id, task: task, names: names, info: info, frameSize: frame.extent.size)
        output.inputSize = CGSize(width: width, height: height)
        decode(tensors, geometry: geometry, into: &output)
        output.latency = CFAbsoluteTimeGetCurrent() - start
        return output
    }

    // MARK: Preprocessing

    /// Renders the frame into the model input on the GPU (letterbox, center-crop or stretch) and converts it to planar
    /// RGB, scaled to 0-1 (YOLO) or ImageNet-normalized (RF-DETR).
    private func prepareInput(_ frame: CIImage) throws -> Geometry {
        let extent = frame.extent
        guard extent.width > 0, extent.height > 0 else { throw YOLOModelError.invalid("empty frame") }
        try allocate(inputSize(for: extent))
        guard input != nil, let staging else { throw YOLOModelError.invalid("cannot allocate input buffer") }
        let (w, h) = (CGFloat(width), CGFloat(height))
        let geometry: Geometry
        switch task {
        case _ where isDETR, .depth:
            geometry = Geometry(gainX: w / extent.width, gainY: h / extent.height, padX: 0, padY: 0)
        case .classify:
            let g = max(w / extent.width, h / extent.height)
            geometry = Geometry(gainX: g, gainY: g, padX: (w - extent.width * g) / 2, padY: (h - extent.height * g) / 2)
        default:
            let g = min(w / extent.width, h / extent.height)
            geometry = Geometry(gainX: g, gainY: g, padX: (w - extent.width * g) / 2, padY: (h - extent.height * g) / 2)
        }
        // Core Image is bottom-left origin while padY is measured from the top row.
        let placed = frame.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                .concatenating(CGAffineTransform(scaleX: geometry.gainX, y: geometry.gainY))
                .concatenating(CGAffineTransform(
                    translationX: geometry.padX, y: h - geometry.padY - extent.height * geometry.gainY)))
        let gray = CIImage(color: CIColor(red: 114 / 255, green: 114 / 255, blue: 114 / 255))
        Self.context.render(
            placed.composited(over: gray), to: staging, bounds: CGRect(x: 0, y: 0, width: w, height: h),
            colorSpace: CGColorSpaceCreateDeviceRGB())

        CVPixelBufferLockBaseAddress(staging, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(staging, .readOnly) }
        var source = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(staging), height: vImagePixelCount(height),
            width: vImagePixelCount(width), rowBytes: CVPixelBufferGetBytesPerRow(staging))
        let (count, width, height, isHalf, range) = (width * height, width, height, scalarType == .float16, range)
        let normalized = range.low != [0, 0, 0] || range.high != [1, 1, 1]
        try planes.withUnsafeMutableBytes { planes in
            func plane(_ i: Int) -> vImage_Buffer {
                vImage_Buffer(
                    data: planes.baseAddress! + i * count, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width)
            }
            // Memory order is B, G, R, A.
            var (blue, green, red, alpha) = (plane(0), plane(1), plane(2), plane(3))
            vImageConvert_ARGB8888toPlanar8(&source, &blue, &green, &red, &alpha, vImage_Flags(kvImageNoFlags))
            let rgb = [red, green, blue]
            func write<T: BitwiseCopyable>(
                _ type: T.Type, _ convert: (inout vImage_Buffer, inout vImage_Buffer, Int) -> Void
            ) throws {
                try Self.withPointer(type, to: &self.input!) { pointer, channelStride, rowStride in
                    for (c, var src) in rgb.enumerated() {
                        var dst = vImage_Buffer(
                            data: pointer + c * channelStride, height: vImagePixelCount(height),
                            width: vImagePixelCount(width), rowBytes: rowStride * MemoryLayout<T>.stride)
                        convert(&src, &dst, c)
                    }
                }
            }
            let flags = vImage_Flags(kvImageNoFlags)
            switch (isHalf, normalized) {
            case (true, false):
                try write(Float16.self) { src, dst, _ in vImageConvert_Planar8toPlanar16F(&src, &dst, flags) }
            case (true, true):
                // Normalize in Float32, then narrow to the half-precision input.
                try floatPlane.withUnsafeMutableBytes { floats in
                    var float = vImage_Buffer(
                        data: floats.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                        rowBytes: width * 4)
                    try write(Float16.self) { src, dst, c in
                        vImageConvert_Planar8toPlanarF(&src, &float, range.high[c], range.low[c], flags)
                        vImageConvert_PlanarFtoPlanar16F(&float, &dst, flags)
                    }
                }
            case (false, _):
                try write(Float.self) { src, dst, c in
                    vImageConvert_Planar8toPlanarF(&src, &dst, range.high[c], range.low[c], flags)
                }
            }
        }
        return geometry
    }

    /// Fixed exports keep their size. Variable ones take `imgsz` on the frame's long side and the frame's aspect, in
    /// multiples of 32 (Ultralytics' rectangular inference: little padding, fewer pixels); classify stays square.
    private func inputSize(for extent: CGRect) -> (width: Int, height: Int) {
        if let fixedSize { return fixedSize }
        guard task != .classify else { return (exportSize, exportSize) }
        let side = CGFloat(min(max(imgsz, 128), 2048))
        let gain = side / max(extent.width, extent.height)
        func fit(_ length: CGFloat) -> Int { Int((length * gain / 32).rounded(.up)) * 32 }
        return (fit(extent.width), fit(extent.height))
    }

    private func allocate(_ size: (width: Int, height: Int)) throws {
        guard size != (width, height) else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, size.width, size.height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw YOLOModelError.invalid("cannot allocate input buffer") }
        staging = buffer
        input = NDArray(shape: [1, 3, size.height, size.width], scalarType: scalarType)
        planes = [UInt8](repeating: 0, count: size.width * size.height * 4)
        floatPlane = [Float](repeating: 0, count: size.width * size.height)
        (width, height) = size
    }

    /// The input's mutable view is lifetime-bound, so it is reached through an `inout` array.
    private static func withPointer<T: BitwiseCopyable>(
        _ type: T.Type, to array: inout NDArray, _ body: (UnsafeMutablePointer<T>, Int, Int) throws -> Void
    ) throws {
        try array.mutableView(as: type).withUnsafeMutablePointer { pointer, _, strides in
            guard strides[3] == 1 else { throw YOLOModelError.invalid("non-contiguous input") }
            try body(pointer, strides[1], strides[2])
        }
    }

    /// Copies an output into a reusable Float32 buffer.
    private func floats(of array: NDArray, into slot: Int) throws -> Tensor {
        let shape = array.shape
        let count = shape.reduce(1, *)
        if scratch[slot].count != count { scratch[slot] = [Float](repeating: 0, count: count) }
        try scratch[slot].withUnsafeMutableBufferPointer { destination in
            switch array.scalarType {
            case .float32:
                guard let elements = array.view(as: Float.self).contiguousElements, elements.count == count else {
                    throw YOLOModelError.invalid("non-contiguous output")
                }
                elements.withUnsafeBufferPointer { destination.baseAddress!.update(from: $0.baseAddress!, count: count) }
            case .float16:
                guard let elements = array.view(as: Float16.self).contiguousElements, elements.count == count else {
                    throw YOLOModelError.invalid("non-contiguous output")
                }
                elements.withUnsafeBufferPointer { source in
                    var src = vImage_Buffer(
                        data: UnsafeMutableRawPointer(mutating: source.baseAddress!), height: 1,
                        width: vImagePixelCount(count), rowBytes: count * 2)
                    var dst = vImage_Buffer(
                        data: destination.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                    vImageConvert_Planar16FtoPlanarF(&src, &dst, vImage_Flags(kvImageNoFlags))
                }
            default:
                throw YOLOModelError.invalid("unsupported output type \(array.scalarType)")
            }
        }
        return Tensor(values: scratch[slot], shape: shape)
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
