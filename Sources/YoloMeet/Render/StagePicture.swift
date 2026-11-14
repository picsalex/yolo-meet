import CoreImage
import ImageIO
import Metal

/// Takes the stage's picture for the iPad pen app's pad: what was just drawn, scaled down, as a JPEG.
///
/// One at a time: the next is taken once the last one left for the pad, so a slow link gets fewer pictures rather than
/// late ones. The stage's frame only waits for a scaled copy on the GPU: reading it back and making the JPEG happen
/// off the main thread. While the pen is away from the pad (`idle`), a few a second are enough.
final class StagePicture {
    /// The most pictures a second, and while idle; the picture's height in pixels at most, and the JPEG's quality (0
    /// to 1).
    nonisolated static let (rate, idleRate, height, quality) = (20.0, 4.0, 720.0, 0.4)

    private let device: any MTLDevice
    /// The scaled copy, and its pixels read back: one of each is enough, as one picture is made at a time.
    private var copy: (any MTLTexture)?
    private var pixels: UnsafeMutableRawPointer?
    private var isBusy = false
    private var lastTime = 0.0

    init(device: any MTLDevice) { self.device = device }

    isolated deinit { pixels?.deallocate() }

    /// Takes the picture of `texture` as it is when `commandBuffer`'s work so far is done, unless one is still on its
    /// way or it's too soon after the last. `send` gets the JPEG on the main thread, and calls `done` when it left.
    func take(
        of texture: any MTLTexture, at time: TimeInterval, idle: Bool, with context: CIContext,
        in commandBuffer: any MTLCommandBuffer, send: @escaping @MainActor (Data, _ done: @escaping @MainActor () -> Void) -> Void
    ) {
        guard !isBusy, time - lastTime >= 1 / (idle ? Self.idleRate : Self.rate), texture.height > 0 else { return }
        let scale = min(1, Self.height / CGFloat(texture.height))
        let (width, height) = (Int((CGFloat(texture.width) * scale).rounded()), Int((CGFloat(texture.height) * scale).rounded()))
        if copy?.width != width || copy?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            (descriptor.usage, descriptor.storageMode) = ([.renderTarget, .shaderRead, .shaderWrite], .shared)
            copy = device.makeTexture(descriptor: descriptor)
            pixels?.deallocate()
            pixels = .allocate(byteCount: width * height * 4, alignment: 16)
        }
        // Both textures have their first row at the top, so nothing flips on the way.
        let color = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let copy, let pixels, let image = CIImage(mtlTexture: texture, options: [.colorSpace: color]) else { return }
        let destination = CIRenderDestination(mtlTexture: copy, commandBuffer: commandBuffer)
        destination.colorSpace = color
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard (try? context.startTask(toRender: scaled, to: destination)) != nil else { return }
        (isBusy, lastTime) = (true, time)
        // Only used here until the picture has left: the next is taken after that.
        nonisolated(unsafe) let (drawn, buffer) = (copy, pixels)
        commandBuffer.addCompletedHandler { _ in
            let jpeg = Self.jpeg(of: drawn, through: buffer)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let jpeg else { return self.isBusy = false }
                    send(jpeg) { self.isBusy = false }
                }
            }
        }
    }

    /// The texture's pixels (BGRA, opaque) as a JPEG, read back into `pixels` (as many bytes as the texture has).
    private nonisolated static func jpeg(of texture: any MTLTexture, through pixels: UnsafeMutableRawPointer) -> Data? {
        let (width, height, rowBytes) = (texture.width, texture.height, texture.width * 4)
        texture.getBytes(pixels, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let data = NSMutableData()
        // The image reads the pixels where they are, until the JPEG is made below: they are kept for the next picture.
        guard let provider = CGDataProvider(dataInfo: nil, data: pixels, size: rowBytes * height, releaseData: { _, _, _ in }),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent),
            let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: Self.quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
