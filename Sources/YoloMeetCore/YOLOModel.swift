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

/// An Ultralytics Core AI (`.aimodel`) model: GPU letterboxing, Core AI inference and task decoding.
/// Not reentrant: callers run one `predict` at a time per instance.
public nonisolated final class YOLOModel: @unchecked Sendable {
    public let id: String
    public let task: YOLOTask
    public let names: [String]
    public var confidence: Float = 0.25
    public var iou: Float = 0.45

    private let function: InferenceFunction
    private let inputName: String
    private let outputNames: [String]
    private var input: NDArray
    private let isHalf: Bool
    let width: Int
    let height: Int
    private let staging: CVPixelBuffer
    private var planes: [UInt8]
    private var scratch: [[Float]]
    private static let context = CIContext(options: [.cacheIntermediates: false])

    public static func load(from url: URL) async throws -> YOLOModel {
        let metadata = try readMetadata(at: url)
        guard let task = metadata["task"].flatMap(YOLOTask.init(rawValue:)) else {
            throw YOLOModelError.invalid("unknown task '\(metadata["task"] ?? "")'")
        }
        let model: AIModel
        do {
            model = try await AIModel(contentsOf: url)
        } catch {
            // A stale specialization cache entry (asset replaced at the same path) fails instead of rebuilding.
            try? AIModelCache.default.deleteEntries(for: url)
            model = try await AIModel(contentsOf: url)
        }
        guard let function = try model.loadFunction(named: "main") else { throw YOLOModelError.invalid("no 'main'") }
        return try YOLOModel(
            id: url.deletingPathExtension().lastPathComponent, task: task,
            names: parseNames(metadata["names"] ?? ""), function: function)
    }

    private init(id: String, task: YOLOTask, names: [String], function: InferenceFunction) throws {
        let descriptor = function.descriptor
        guard let inputName = descriptor.inputNames.first,
            case .ndArray(let shape)? = descriptor.inputDescriptor(of: inputName), shape.shape.count == 4
        else { throw YOLOModelError.invalid("expected one BCHW input") }
        self.id = id
        self.task = task
        self.names = names
        self.function = function
        self.inputName = inputName
        self.outputNames = descriptor.outputNames
        self.isHalf = shape.scalarType == .float16
        self.input = NDArray(shape: shape.shape, scalarType: shape.scalarType)
        (height, width) = (shape.shape[2], shape.shape[3])
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw YOLOModelError.invalid("cannot allocate input buffer") }
        staging = buffer
        planes = [UInt8](repeating: 0, count: width * height * 4)
        scratch = Array(repeating: [], count: descriptor.outputNames.count)
    }

    /// Runs the model on a frame. Output geometry is in the frame's pixel space (top-left origin).
    public func predict(_ frame: CIImage) async throws -> ModelOutput {
        let start = CFAbsoluteTimeGetCurrent()
        let geometry = try prepareInput(frame)
        var outputs = try await function.run(inputs: [inputName: input])
        var tensors: [Tensor] = []
        for (i, name) in outputNames.enumerated() {
            guard let array = outputs.remove(name)?.ndArray else { throw YOLOModelError.invalid("missing \(name)") }
            tensors.append(try floats(of: array, into: i))
        }
        var output = ModelOutput(modelID: id, task: task, names: names, frameSize: frame.extent.size)
        decode(tensors, geometry: geometry, into: &output)
        output.latency = CFAbsoluteTimeGetCurrent() - start
        return output
    }

    // MARK: Preprocessing

    /// Renders the frame into the model input on the GPU (letterbox, center-crop or stretch, per task) and converts
    /// it to planar RGB 0-1.
    private func prepareInput(_ frame: CIImage) throws -> Geometry {
        let extent = frame.extent
        guard extent.width > 0, extent.height > 0 else { throw YOLOModelError.invalid("empty frame") }
        let (w, h) = (CGFloat(width), CGFloat(height))
        let geometry: Geometry
        switch task {
        case .classify:
            let g = max(w / extent.width, h / extent.height)
            geometry = Geometry(gainX: g, gainY: g, padX: (w - extent.width * g) / 2, padY: (h - extent.height * g) / 2)
        case .depth:
            geometry = Geometry(gainX: w / extent.width, gainY: h / extent.height, padX: 0, padY: 0)
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
        let (count, width, height, isHalf) = (width * height, width, height, isHalf)
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
            func write<T: BitwiseCopyable>(_ type: T.Type, _ convert: (inout vImage_Buffer, inout vImage_Buffer) -> Void)
                throws
            {
                try Self.withPointer(type, to: &input) { pointer, channelStride, rowStride in
                    for (c, var src) in rgb.enumerated() {
                        var dst = vImage_Buffer(
                            data: pointer + c * channelStride, height: vImagePixelCount(height),
                            width: vImagePixelCount(width), rowBytes: rowStride * MemoryLayout<T>.stride)
                        convert(&src, &dst)
                    }
                }
            }
            if isHalf {
                try write(Float16.self) { vImageConvert_Planar8toPlanar16F(&$0, &$1, vImage_Flags(kvImageNoFlags)) }
            } else {
                try write(Float.self) { vImageConvert_Planar8toPlanarF(&$0, &$1, 1, 0, vImage_Flags(kvImageNoFlags)) }
            }
        }
        return geometry
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
