import SpriteKit

/// A drawn arrow with a label above its middle, e.g. into a model's input. Add it to an effect's `node` and call `update`
/// every frame with its ends on stage (e.g. points of an object through `ParticleSystem.shownPoint`, so it follows it).
final class Arrow: SKNode {
    private let line = SKShapeNode()
    private let head = SKShapeNode()
    private let text: ShadowedLabel

    init(_ text: String, color: NSColor) {
        self.text = ShadowedLabel(text, font: "Archivo-SemiBold")
        super.init()
        (line.strokeColor, line.fillColor, line.lineCap, line.lineJoin) = (color, .clear, .round, .round)
        (head.fillColor, head.lineWidth) = (color, 0)
        self.text.label.verticalAlignmentMode = .bottom
        addChild(line)
        addChild(head)
        addChild(self.text)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `tail` and `tip`: stage points. `feeds`: lines into the tail (stage points each, ending at it), e.g. from each of
    /// several outputs joining into the arrow.
    func update(from tail: CGPoint, to tip: CGPoint, feeds: [[CGPoint]] = [], frame: StageFrame) {
        let u = frame.stage.unit
        let length = max(tail.distance(to: tip), 1)
        let along = CGVector(dx: (tip.x - tail.x) / length, dy: (tip.y - tail.y) / length)
        let (back, wide) = (13 * u, 7.5 * u)
        let base = CGPoint(x: tip.x - along.dx * back, y: tip.y - along.dy * back)
        let path = CGMutablePath()
        for feed in feeds where feed.count > 1 { path.addLines(between: feed) }
        path.move(to: tail)
        path.addLine(to: base)
        line.path = path
        // The head: a filled triangle.
        let triangle = CGMutablePath()
        triangle.move(to: tip)
        triangle.addLine(to: CGPoint(x: base.x - along.dy * wide, y: base.y + along.dx * wide))
        triangle.addLine(to: CGPoint(x: base.x + along.dy * wide, y: base.y - along.dx * wide))
        triangle.closeSubpath()
        head.path = triangle
        line.lineWidth = 3 * u

        text.label.set(\.fontSize, 18 * u)
        text.position = CGPoint(x: (tail.x + tip.x) / 2, y: max(tail.y, tip.y) + 10 * u)
        text.sync(unit: u)
    }
}
