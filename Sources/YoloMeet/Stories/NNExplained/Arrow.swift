import SpriteKit

/// A drawn arrow with a label above its middle, e.g. into a model's input. Add it to an effect's `node` and call `update`
/// every frame with its ends on stage (e.g. points of an object through `ParticleSystem.shownPoint`, so it follows it).
final class Arrow: SKNode {
    private let line = SKShapeNode()
    private let text: ShadowedLabel

    init(_ text: String, color: NSColor) {
        self.text = ShadowedLabel(text, font: "Archivo-SemiBold")
        super.init()
        line.strokeColor = color
        line.fillColor = color
        line.lineCap = .round
        self.text.label.verticalAlignmentMode = .bottom
        addChild(line)
        addChild(self.text)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `tail` and `tip`: stage points.
    func update(from tail: CGPoint, to tip: CGPoint, frame: StageFrame) {
        let u = frame.stage.unit
        let length = max(tail.distance(to: tip), 1)
        let along = CGVector(dx: (tip.x - tail.x) / length, dy: (tip.y - tail.y) / length)
        let (back, wide) = (16 * u, 9 * u)
        let base = CGPoint(x: tip.x - along.dx * back, y: tip.y - along.dy * back)
        let path = CGMutablePath()
        path.move(to: tail)
        path.addLine(to: base)
        // The head: a filled triangle.
        path.move(to: tip)
        path.addLine(to: CGPoint(x: base.x - along.dy * wide, y: base.y + along.dx * wide))
        path.addLine(to: CGPoint(x: base.x + along.dy * wide, y: base.y - along.dx * wide))
        path.closeSubpath()
        line.path = path
        line.lineWidth = 4 * u

        text.label.set(\.fontSize, 22 * u)
        text.position = CGPoint(x: (tail.x + tip.x) / 2, y: max(tail.y, tip.y) + 12 * u)
        text.sync(unit: u)
    }
}
