import SpriteKit

/// A measurement along an object's side, as on a technical drawing: a thin line with a tick at each end and its size
/// beside the middle (e.g. "32 px" along a picture's edge). Add it to an effect's `node` and call `update` every frame
/// with its ends on stage (e.g. through `ParticleSystem.shownPoint`, so it follows the object).
final class Dimension: SKNode {
    private let line = SKShapeNode()
    private let text: ShadowedLabel

    init(_ text: String) {
        self.text = ShadowedLabel(text, font: "GeistMono-Medium", color: NSColor(white: 1, alpha: 0.85))
        super.init()
        line.strokeColor = NSColor(white: 1, alpha: 0.6)
        line.lineCap = .round
        addChild(line)
        addChild(self.text)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `from` and `to`: the ends, stage points. The size goes on the side the line's normal points to (`from` → `to`
    /// turned a quarter turn clockwise: below a line drawn left to right, left of one drawn top to bottom).
    func update(from: CGPoint, to: CGPoint, frame: StageFrame) {
        let u = frame.stage.unit
        let length = max(from.distance(to: to), 1)
        let along = CGVector(dx: (to.x - from.x) / length, dy: (to.y - from.y) / length)
        let normal = CGVector(dx: along.dy, dy: -along.dx)
        let tick = 6 * u
        let path = CGMutablePath()
        path.move(to: from)
        path.addLine(to: to)
        for end in [from, to] {
            path.move(to: CGPoint(x: end.x - normal.dx * tick, y: end.y - normal.dy * tick))
            path.addLine(to: CGPoint(x: end.x + normal.dx * tick, y: end.y + normal.dy * tick))
        }
        line.path = path
        line.lineWidth = 1.5 * u

        text.label.set(\.fontSize, 16 * u)
        // Beside the middle, on the normal's side: aligned away from the line.
        let horizontal = abs(normal.dx) > abs(normal.dy)
        text.label.horizontalAlignmentMode = horizontal ? (normal.dx < 0 ? .right : .left) : .center
        text.label.verticalAlignmentMode = horizontal ? .center : (normal.dy < 0 ? .top : .bottom)
        let gap = 10 * u
        text.position = CGPoint(x: (from.x + to.x) / 2 + normal.dx * gap, y: (from.y + to.y) / 2 + normal.dy * gap)
        text.sync(unit: u)
    }
}
