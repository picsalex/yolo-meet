import SpriteKit

/// Text anchored to the stage, re-evaluated every frame (counters, captions).
final class TextEffect: Effect {
    enum Placement { case topLeft, lowerThird }
    private let label = SKLabelNode(fontNamed: Theme.titleFont)
    private let background = SKShapeNode()
    private let placement: Placement
    private let text: (StageFrame) -> String
    /// The background as last drawn: it is drawn again only when the text's place or size changes.
    private var drawn: CGRect?

    init(_ placement: Placement, text: @escaping (StageFrame) -> String) {
        self.placement = placement
        self.text = text
        super.init()
        label.fontColor = .white
        label.verticalAlignmentMode = .center
        background.fillColor = Theme.darkBlue.withAlphaComponent(0.85)
        background.lineWidth = 0
        node.addChild(background)
        node.addChild(label)
    }

    override func update(_ frame: StageFrame) {
        let u = frame.stage.unit
        // Written only when they change: SpriteKit lays text out again on every write.
        label.set(\.text, text(frame))
        switch placement {
        case .topLeft:
            label.set(\.fontSize, 34 * u)
            label.set(\.horizontalAlignmentMode, .left)
            label.position = CGPoint(x: 36 * u, y: frame.stage.viewSize.height - 52 * u)
        case .lowerThird:
            label.set(\.fontSize, 30 * u)
            label.set(\.horizontalAlignmentMode, .center)
            label.position = CGPoint(x: frame.stage.viewSize.width / 2, y: 70 * u)
        }
        let rect = label.frame.insetBy(dx: -18 * u, dy: -10 * u)
        guard rect != drawn else { return }
        drawn = rect
        background.path = CGPath(roundedRect: rect, cornerWidth: 12 * u, cornerHeight: 12 * u, transform: nil)
    }
}

/// A lower-third title that shows for a few seconds when the step starts.
func titleCard(_ title: String) -> Effect {
    let effect = TextEffect(.lowerThird) { _ in title }
    effect.node.run(.sequence([.wait(forDuration: 3), .fadeOut(withDuration: 0.6)]))
    return effect
}

/// A lower-third card while a story gets ready (`Story.prepare`): its title, and dots that keep moving so the stage
/// reads as working, not frozen.
func loadingCard(_ title: String) -> Effect {
    TextEffect(.lowerThird) { frame in
        let dots = Int(frame.time * 3) % 4
        return "Preparing \(title)" + String(repeating: ".", count: dots) + String(repeating: " ", count: 3 - dots)
    }
}
