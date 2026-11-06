import SpriteKit
import YoloMeetCore

/// A sequence of steps you move through with the panel or a clicker. Each step names the models it needs (catalog ids)
/// and builds the effects it draws. To add a story: create a file with `extension Story { static let name = Story(...) }`
/// and list it in `Story.all`.
struct Story: Identifiable {
    let id: String
    let title: String
    let steps: [Step]

    struct Step {
        let title: String
        let models: [String]
        let effects: () -> [Effect]
    }

    static let all: [Story] = [.hello]
}

// MARK: Story building blocks

/// Text anchored to the stage, re-evaluated every frame (counters, captions).
final class TextEffect: Effect {
    enum Placement { case topLeft, lowerThird }
    private let label = SKLabelNode(fontNamed: titleFont)
    private let background = SKShapeNode()
    private let placement: Placement
    private let text: (StageFrame) -> String

    init(_ placement: Placement, text: @escaping (StageFrame) -> String) {
        self.placement = placement
        self.text = text
        super.init()
        label.fontColor = .white
        label.verticalAlignmentMode = .center
        background.fillColor = NSColor.black.withAlphaComponent(0.55)
        background.lineWidth = 0
        node.addChild(background)
        node.addChild(label)
    }

    override func update(_ frame: StageFrame) {
        let u = frame.stage.unit
        label.text = text(frame)
        switch placement {
        case .topLeft:
            label.fontSize = 34 * u
            label.horizontalAlignmentMode = .left
            label.position = CGPoint(x: 36 * u, y: frame.stage.viewSize.height - 52 * u)
        case .lowerThird:
            label.fontSize = 30 * u
            label.horizontalAlignmentMode = .center
            label.position = CGPoint(x: frame.stage.viewSize.width / 2, y: 70 * u)
        }
        let rect = label.frame.insetBy(dx: -18 * u, dy: -10 * u)
        background.path = CGPath(roundedRect: rect, cornerWidth: 12 * u, cornerHeight: 12 * u, transform: nil)
    }
}

/// A lower-third title that shows for a few seconds when the step starts.
func titleCard(_ title: String) -> Effect {
    let effect = TextEffect(.lowerThird) { _ in title }
    effect.node.run(.sequence([.wait(forDuration: 3), .fadeOut(withDuration: 0.6)]))
    return effect
}

/// Glowing particle trails from both wrists of every tracked person.
final class SparkleHandsEffect: Effect {
    let model: String
    private static let wrists = [9, 10]
    private lazy var tracks = TrackedNodes(in: node) { () -> SKNode in
        let hands = SKNode()
        for (i, _) in Self.wrists.enumerated() { hands.addChild(Self.emitter(hue: i == 0 ? 0.55 : 0.85, target: self.node)) }
        return hands
    }

    init(model: String) { self.model = model }

    override func update(_ frame: StageFrame) {
        let detections = frame.outputs[model]?.detections.filter { $0.trackID != nil } ?? []
        let nodes = tracks.sync(detections.map { $0.trackID! }, at: frame.time)
        for (hands, detection) in zip(nodes, detections) {
            for (emitter, index) in zip(hands.children.compactMap { $0 as? SKEmitterNode }, Self.wrists) {
                guard let wrist = detection.keypoints[safe: index], wrist.confidence > 0.5 else {
                    emitter.particleBirthRate = 0
                    continue
                }
                let target = frame.stage.point(wrist.point)
                emitter.position = emitter.particleBirthRate == 0 ? target : emitter.position.approaching(target, frame.smoothing)
                emitter.particleBirthRate = 220
                emitter.particleScale = 0.5 * frame.stage.unit
                emitter.particleSpeed = 60 * frame.stage.unit
            }
        }
    }

    private static func emitter(hue: CGFloat, target: SKNode) -> SKEmitterNode {
        let emitter = SKEmitterNode()
        emitter.particleTexture = dotTexture
        emitter.particleBirthRate = 0
        emitter.particleLifetime = 0.9
        emitter.particleLifetimeRange = 0.4
        emitter.emissionAngleRange = .pi * 2
        emitter.particleSpeedRange = 40
        emitter.particleAlphaSpeed = -1.2
        emitter.particleScaleSpeed = -0.4
        emitter.particleBlendMode = .add
        emitter.particleColor = NSColor(hue: hue, saturation: 0.8, brightness: 1, alpha: 1)
        emitter.particleColorBlendFactor = 1
        emitter.targetNode = target  // particles stay where they were born: trails
        return emitter
    }
}

/// Soft round particle, generated once.
let dotTexture: SKTexture = {
    let size = 64
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    let center = CGPoint(x: size / 2, y: size / 2)
    context.drawRadialGradient(
        gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: CGFloat(size / 2), options: [])
    return SKTexture(cgImage: context.makeImage()!)
}()
