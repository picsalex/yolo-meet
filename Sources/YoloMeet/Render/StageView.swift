import CoreImage
import MetalKit
import SpriteKit
import SwiftUI

/// The shareable output, rendered into one Metal drawable: camera frame (Core Image), the 2D content of effects drawn
/// `behind`, then the effects' 3D content (RealityKit), their particles (Metal), and their 2D content (SpriteKit).
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
        view.mouse = context.coordinator.mouse
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}
}

/// Locks the stage window to 16:9 so it shares cleanly, takes key presses so keys the stage doesn't use don't make
/// macOS beep (its keys reach effects through `StageKeys`), and passes the mouse and trackpad to `MouseGestures`.
private final class StageMTKView: MTKView {
    var mouse: MouseGestures?

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {}
    /// A click on the stage acts even when its window isn't the key one.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    /// An event's location in stage points (drawable pixels, bottom-left origin).
    private func stagePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let scale = bounds.width > 0 ? drawableSize.width / bounds.width : 1
        return CGPoint(x: p.x * scale, y: p.y * scale)
    }

    override func mouseEntered(with event: NSEvent) { mouse?.moved(to: stagePoint(event)) }
    override func mouseMoved(with event: NSEvent) { mouse?.moved(to: stagePoint(event)) }
    override func mouseExited(with event: NSEvent) { mouse?.moved(to: nil) }
    override func mouseDown(with event: NSEvent) { mouse?.pressed(at: stagePoint(event)) }
    override func mouseDragged(with event: NSEvent) { mouse?.moved(to: stagePoint(event)) }
    override func mouseUp(with event: NSEvent) {
        mouse?.released()
        if !bounds.contains(convert(event.locationInWindow, from: nil)) { mouse?.moved(to: nil) }
    }

    override func magnify(with event: NSEvent) {
        mouse?.magnified(by: event.magnification, phase: event.phase, at: stagePoint(event))
    }

    /// Command + scroll zooms; plain scrolling is left alone.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), event.momentumPhase.isEmpty else { return super.scrollWheel(with: event) }
        mouse?.scrolled(
            by: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas, at: stagePoint(event),
            time: CACurrentMediaTime())
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.contentAspectRatio = NSSize(width: 16, height: 9)
        window?.makeFirstResponder(self)
    }
}

final class StageRenderer: NSObject, MTKViewDelegate {
    let device = MTLCreateSystemDefaultDevice()!
    private let model: AppModel
    private let queue: any MTLCommandQueue
    private let context: CIContext
    private let renderer: SKRenderer
    private let scene = SKScene()
    /// 2D content of effects drawn `behind`: over the video, under the 3D layer and the particles.
    private let backRenderer: SKRenderer
    private let backScene = SKScene()
    /// Nil when RealityKit can't start.
    private let reality: RealityLayer?
    /// Nil if its shaders fail to compile.
    private lazy var particles = ParticleRenderer(device: device, pixelFormat: .bgra8Unorm)
    private var effects: [Effect] = []
    private lazy var stats = StatsEffect(model: model)
    private let gestures = HandGestures()
    let mouse = MouseGestures()
    private let pointing = Pointing()
    private lazy var gestureDebug = GestureDebugEffect(gestures: gestures)
    private var sceneVersion = -1
    /// How far the camera image has faded to black (0 shown, 1 hidden), toward `model.cameraHidden`.
    private var cameraFade: CGFloat = 0
    /// Seconds to fade the camera image out or in.
    private static let cameraFadeTime: CGFloat = 0.6
    private var lastTime = CACurrentMediaTime()
    private var frameRate = RateCounter()

    init(model: AppModel) {
        self.model = model
        queue = device.makeCommandQueue()!
        context = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false])
        renderer = SKRenderer(device: device)
        backRenderer = SKRenderer(device: device)
        for (scene, renderer) in [(scene, renderer), (backScene, backRenderer)] {
            scene.backgroundColor = .clear
            scene.scaleMode = .fill  // scene size tracks the drawable, so this is 1:1
            renderer.scene = scene
        }
        reality = RealityLayer(queue: queue)
        super.init()
        scene.addChild(stats.node)
        scene.addChild(gestureDebug.node)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTime, 0.1)
        lastTime = now
        model.renderFPS = Int(frameRate.tick().rounded())

        guard let drawable = view.currentDrawable, var commandBuffer = queue.makeCommandBuffer(),
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
        // Hiding the camera (H) fades it to black, and back, at a steady pace eased at both ends. Core Image blends in
        // linear light, which the eye sees as a curve (gamma about 2.2): the black's opacity follows that curve so the
        // image darkens and brightens evenly, the same both ways.
        let step = CGFloat(dt) / Self.cameraFadeTime
        cameraFade = model.cameraHidden ? min(cameraFade + step, 1) : max(cameraFade - step, 0)
        let eased = cameraFade * cameraFade * (3 - 2 * cameraFade)
        let black = 1 - pow(1 - eased, 2.2)
        let video = black == 0 ? placed
            : CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: black)).cropped(to: bounds).composited(over: placed)
        _ = try? context.startTask(toRender: video, from: bounds, to: destination, at: .zero)

        // Effects: rebuild on scene change, then update every frame.
        if model.sceneVersion != sceneVersion { swapEffects() }
        for scene in [scene, backScene] where scene.size != size { scene.size = size }
        var stageFrame = StageFrame(
            outputs: snapshot.outputs, stage: Stage(frameSize: frame.extent.size, viewSize: size), time: now, dt: dt,
            smooth: model.smoothing)
        // The step's own clock, starting over every `loop` seconds for a looping step.
        if stepStart == nil { stepStart = now }
        let elapsed = now - stepStart!
        if let loop = model.stepLoop, loop > 0 {
            (stageFrame.stepTime, stageFrame.loopCount) = (elapsed.truncatingRemainder(dividingBy: loop), Int(elapsed / loop))
        } else {
            stageFrame.stepTime = elapsed
        }
        stageFrame.keys = model.stageKeys.take()  // before gestures: a fist needs Command held
        if stageFrame.keys.pressed.contains("h") { model.cameraHidden.toggle() }  // shown from the next frame
        stageFrame.cameraHidden = model.cameraHidden
        let handGesture = gestures.update(stageFrame)  // every frame, to keep following the hands
        let mouseGesture = mouse.update(time: now)
        stageFrame.gesture = mouseGesture ?? handGesture  // the mouse wins while it acts
        stageFrame.charge = mouseGesture == nil ? gestures.charging : nil
        stageFrame.pointers = gestures.pointers + (mouse.pointer.map { [$0] } ?? [])
        pointing.next()
        stageFrame.pointing = pointing
        stageFrame.nextStep = { [model] in Task { model.next() } }  // after this frame
        for effect in effects { effect.update(stageFrame) }
        for debug in [stats, gestureDebug] as [Effect] {
            debug.node.isHidden = !model.debugMode
            if model.debugMode { debug.update(stageFrame) }
        }
        let overlay = MTLRenderPassDescriptor()
        overlay.colorAttachments[0].texture = drawable.texture
        overlay.colorAttachments[0].loadAction = .load
        overlay.colorAttachments[0].storeAction = .store
        if !backScene.children.isEmpty {
            backRenderer.update(atTime: now)
            backRenderer.render(withViewport: bounds, commandBuffer: commandBuffer, renderPassDescriptor: overlay)
        }
        if let reality, effects.contains(where: { !$0.entity.children.isEmpty }) {
            commandBuffer = reality.render(over: drawable.texture, size: size, dt: dt, after: commandBuffer)
        }
        let systems = effects.compactMap(\.particles)
        if !systems.isEmpty {
            particles?.render(systems, over: drawable.texture, stage: stageFrame.stage, time: now, dt: dt, commandBuffer: commandBuffer)
        }

        renderer.update(atTime: now)
        renderer.render(withViewport: bounds, commandBuffer: commandBuffer, renderPassDescriptor: overlay)

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// When the step on stage started (its first frame), for `StageFrame.stepTime`.
    private var stepStart: TimeInterval?

    private func swapEffects() {
        let fade = model.transition == .fade  // else none: an instant swap, the new effects continuing the old
        for effect in effects {
            if fade { effect.node.run(.sequence([.fadeOut(withDuration: 0.3), .removeFromParent()])) } else { effect.node.removeFromParent() }
            reality?.entities.remove(effect.entity)
        }
        effects = model.makeEffects()
        (sceneVersion, stepStart) = (model.sceneVersion, nil)
        for effect in effects {
            effect.continuing = !fade
            (effect.behind ? backScene : scene).addChild(effect.node)
            if fade {
                effect.node.alpha = 0
                effect.node.run(.fadeIn(withDuration: 0.4))
            }
            reality?.entities.append(effect.entity)
        }
    }

}
