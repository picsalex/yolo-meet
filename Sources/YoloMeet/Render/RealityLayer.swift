import CoreGraphics
import Metal
import RealityKit

/// The stage's 3D layer: RealityKit draws the effects' entities over the video (it keeps the texture's contents)
/// through an orthographic camera in stage points, between the video and the 2D pass.
final class RealityLayer {
    private let renderer: RealityRenderer
    private let camera = Entity()
    private let queue: any MTLCommandQueue
    /// Orders the 3D pass, which RealityKit submits on its own, after the video and before the 2D pass.
    private let event: any MTLEvent
    private var eventValue: UInt64 = 0

    var entities: RealityRenderer.EntityCollection {
        get { renderer.entities }
        set { renderer.entities = newValue }
    }

    init(queue: any MTLCommandQueue) {
        self.queue = queue
        event = queue.device.makeEvent()!
        renderer = try! RealityRenderer()
        renderer.cameraSettings.colorBackground = .outputTexture()
        renderer.cameraSettings.isToneMappingEnabled = false  // colors as given, like SpriteKit
        renderer.entities.append(camera)
        renderer.activeCamera = camera
        // Studio lighting for lit materials (e.g. imported .usdz models): a soft environment, bright above and dim
        // below, and a key light from the upper left. Unlit materials and particles ignore it.
        renderer.lighting.resource = try? EnvironmentResource(equirectangular: Self.studio)
        let key = DirectionalLight()
        key.light.intensity = 2500
        key.look(at: .zero, from: [-1, 1, 1], relativeTo: nil)
        renderer.entities.append(key)
    }

    /// An equirectangular environment: white at the top, fading to dark grey at the bottom.
    private static let studio: CGImage = {
        let (width, height) = (256, 128)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(
            colorsSpace: space, colors: [CGColor(gray: 0.15, alpha: 1), CGColor(gray: 0.5, alpha: 1), CGColor(gray: 1, alpha: 1)] as CFArray,
            locations: [0, 0.5, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])  // y up: top is bright
        return context.makeImage()!
    }()

    /// Commits `commandBuffer` (the video), draws the 3D layer over `texture`, and returns a new command buffer that
    /// waits for it.
    func render(
        over texture: any MTLTexture, size: CGSize, dt: TimeInterval, after commandBuffer: any MTLCommandBuffer
    ) -> any MTLCommandBuffer {
        var lens = OrthographicCameraComponent()
        (lens.near, lens.far, lens.scale) = (1, 4000, Float(size.height / 2))  // scale: half the visible height
        camera.components.set(lens)
        camera.position = [Float(size.width / 2), Float(size.height / 2), 2000]
        let (videoDone, layerDone) = (eventValue + 1, eventValue + 2)
        eventValue = layerDone
        commandBuffer.encodeSignalEvent(event, value: videoDone)
        commandBuffer.commit()
        let next = queue.makeCommandBuffer()!
        do {
            try renderer.updateAndRender(
                deltaTime: dt, cameraOutput: .init(.singleProjection(colorTexture: texture)),
                actionsBeforeRender: [.wait(for: event, value: videoDone)], actionsAfterRender: [.signal(event, value: layerDone)])
            next.encodeWaitForEvent(event, value: layerDone)
        } catch {
            next.encodeWaitForEvent(event, value: videoDone)  // no 3D this frame
        }
        return next
    }
}
