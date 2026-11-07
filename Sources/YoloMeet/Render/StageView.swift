import CoreImage
import MetalKit
import SpriteKit
import SwiftUI

/// The shareable output: camera frame (Core Image) plus effects (SpriteKit), both rendered into one Metal drawable.
struct StageView: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> StageRenderer { StageRenderer(model: model) }

    func makeNSView(context: Context) -> MTKView {
        let view = StageMTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false  // Core Image writes into the drawable
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}
}

/// Locks the stage window to 16:9 so it shares cleanly.
private final class StageMTKView: MTKView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.contentAspectRatio = NSSize(width: 16, height: 9)
    }
}

final class StageRenderer: NSObject, MTKViewDelegate {
    let device = MTLCreateSystemDefaultDevice()!
    private let model: AppModel
    private let queue: any MTLCommandQueue
    private let context: CIContext
    private let renderer: SKRenderer
    private let scene = SKScene()
    private var effects: [Effect] = []
    private lazy var stats = StatsEffect(model: model)
    private var sceneVersion = -1
    private var lastTime = CACurrentMediaTime()
    private var frameRate = RateCounter()

    init(model: AppModel) {
        self.model = model
        queue = device.makeCommandQueue()!
        context = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false])
        renderer = SKRenderer(device: device)
        scene.backgroundColor = .clear
        scene.scaleMode = .fill  // scene size tracks the drawable, so this is 1:1
        renderer.scene = scene
        super.init()
        scene.addChild(stats.node)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTime, 0.1)
        lastTime = now
        model.renderFPS = Int(frameRate.tick().rounded())

        guard let drawable = view.currentDrawable, let commandBuffer = queue.makeCommandBuffer(),
            let pass = view.currentRenderPassDescriptor
        else { return }
        let size = view.drawableSize
        let bounds = CGRect(origin: .zero, size: size)

        guard let snapshot = model.pipeline.snapshot(predicting: model.smoothing) else {
            commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()  // clears to black
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        let frame = snapshot.frame
        // Camera: aspect-fill into the drawable on the GPU.
        let scale = max(size.width / frame.extent.width, size.height / frame.extent.height)
        let scaled = frame.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let placed = scaled.transformed(by: CGAffineTransform(
            translationX: (size.width - scaled.extent.width) / 2 - scaled.extent.minX,
            y: (size.height - scaled.extent.height) / 2 - scaled.extent.minY))
        // Metal textures are top-left origin; Core Image is bottom-left.
        let destination = CIRenderDestination(mtlTexture: drawable.texture, commandBuffer: commandBuffer)
        destination.isFlipped = true
        destination.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        _ = try? context.startTask(toRender: placed, from: bounds, to: destination, at: .zero)

        // Effects: rebuild on scene change, then update every frame.
        if model.sceneVersion != sceneVersion { swapEffects() }
        if scene.size != size { scene.size = size }
        let stageFrame = StageFrame(
            outputs: snapshot.outputs, stage: Stage(frameSize: frame.extent.size, viewSize: size), time: now, dt: dt,
            smooth: model.smoothing)
        for effect in effects { effect.update(stageFrame) }
        stats.node.isHidden = !model.showStats
        if model.showStats { stats.update(stageFrame) }

        renderer.update(atTime: now)
        let overlay = MTLRenderPassDescriptor()
        overlay.colorAttachments[0].texture = drawable.texture
        overlay.colorAttachments[0].loadAction = .load
        overlay.colorAttachments[0].storeAction = .store
        renderer.render(withViewport: bounds, commandBuffer: commandBuffer, renderPassDescriptor: overlay)

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func swapEffects() {
        for effect in effects {
            effect.node.run(.sequence([.fadeOut(withDuration: 0.3), .removeFromParent()]))
        }
        effects = model.makeEffects()
        sceneVersion = model.sceneVersion
        for effect in effects {
            effect.node.alpha = 0
            scene.addChild(effect.node)
            effect.node.run(.fadeIn(withDuration: 0.4))
        }
    }

}
