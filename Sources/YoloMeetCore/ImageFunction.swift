import Accelerate
import CoreAI
import CoreImage
import Foundation

/// A Core AI function with one image input (BCHW): renders an already-placed frame into the input on the GPU, converts
/// it to planar RGB in the model's value range, runs it and returns its outputs as Float32. Not reentrant.
nonisolated final class ImageFunction {
    let inputName: String
    let outputNames: [String]
    /// The input shape as exported; height and width are -1 when variable.
    let shape: [Int]
    let scalarType: NDArray.ScalarType
    /// Per-channel value of pixel 0 and pixel 255 after normalization (RGB).
    private let range: (low: [Float], high: [Float])
    private let function: InferenceFunction
    // Input buffers, reallocated when the input size changes.
    private var input: NDArray?
    private var staging: CVPixelBuffer?
    private var planes: [UInt8] = []
    private var floatPlane: [Float] = []
    private(set) var width = 0
    private(set) var height = 0
    private var scratch: [[Float]]
    /// No color management: raw pixel values reach the model, as in the training pipelines, with less GPU work.
    private static let context = CIContext(options: [
        .cacheIntermediates: false, .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
    ])

    /// Loads the `main` function of a `.aimodel`.
    static func load(_ url: URL) async throws -> InferenceFunction {
        let model: AIModel
        do {
            model = try await AIModel(contentsOf: url)
        } catch {
            // A stale specialization cache entry (asset replaced at the same path) fails instead of rebuilding.
            try? AIModelCache.default.deleteEntries(for: url)
            model = try await AIModel(contentsOf: url)
        }
        guard let function = try model.loadFunction(named: "main") else { throw YOLOModelError.invalid("no 'main'") }
        return function
    }

    /// - Parameter range: per-channel value of pixel 0 and 255 (RGB), e.g. 0...1 or -1...1.
    init(_ function: InferenceFunction, range: (low: [Float], high: [Float])) throws {
        let descriptor = function.descriptor
        guard let inputName = descriptor.inputNames.first,
            case .ndArray(let input)? = descriptor.inputDescriptor(of: inputName), input.shape.count == 4
        else { throw YOLOModelError.invalid("expected one BCHW input") }
        self.function = function
        self.inputName = inputName
        self.outputNames = descriptor.outputNames
        self.shape = input.shape
        self.scalarType = input.scalarType
        self.range = range
        scratch = Array(repeating: [], count: descriptor.outputNames.count)
    }

    /// Renders `placed` (already in input space: `width` x `height`, bottom-left origin) over `background` and runs the
    /// function. How `placed` was resampled is the caller's choice (`transformed(by:highQualityDownsample:)`).
    func run(_ placed: CIImage, width: Int, height: Int, background: CIColor) async throws -> [Tensor] {
        try allocate(width, height)
        guard input != nil, let staging else { throw YOLOModelError.invalid("cannot allocate input buffer") }
        Self.context.render(
            placed.composited(over: CIImage(color: background)), to: staging,
            bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: nil)
        try convert(staging)
        var outputs = try await function.run(inputs: [inputName: input!])
        return try outputNames.enumerated().map { i, name in
            guard let array = outputs.remove(name)?.ndArray else { throw YOLOModelError.invalid("missing \(name)") }
            return try floats(of: array, into: i)
        }
    }

    /// BGRA staging buffer → planar RGB in the input's type and range.
    private func convert(_ staging: CVPixelBuffer) throws {
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
    }

    private func allocate(_ width: Int, _ height: Int) throws {
        guard (width, height) != (self.width, self.height) else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw YOLOModelError.invalid("cannot allocate input buffer") }
        staging = buffer
        input = NDArray(shape: [1, 3, height, width], scalarType: scalarType)
        planes = [UInt8](repeating: 0, count: width * height * 4)
        floatPlane = [Float](repeating: 0, count: width * height)
        (self.width, self.height) = (width, height)
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
}
