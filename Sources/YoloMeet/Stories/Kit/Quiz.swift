import CoreImage
import SpriteKit

/// A quiz on a step with branches (`Story.Step.branches`): labels in a column, top to bottom, each a title with a hint
/// under it, blurred but for the title's first letter. Hold Space and click one (the mouse: `Actionable(by: .click)`):
/// it comes clear, its title flies to the top of the stage, where the branch's own title shows (`ObjectTitle`, which
/// picks it up: `handOff`), and the story enters that branch (item i, branch i). Coming back, the title glides from the
/// top back into its place. Items whose branch was visited stay clear. As a title flies to the top, the other labels
/// fade out (`leaving`, for the step's other content too), since the branch's first step may follow with no transition.
final class QuizEffect: Effect {
    struct Item {
        /// The title, e.g. "Object detection": its first letter is the clue.
        let title: String
        /// The branch's title's subtitle (`ObjectTitle`), so it picks up the flown title.
        let subtitle: String
        /// The line under the title, e.g. "detect".
        let hint: String
    }

    /// The column, in fractions of the stage (x right, y up): the labels' left edge at `minX`, the first one's top at
    /// `maxY`, the last one's bottom at `minY`.
    private let column: CGRect
    /// Where the branch's object will be on stage (its center's x), for the title flying over it.
    private let titleX: (StageFrame) -> CGFloat
    private let items: [Item]
    private let labels: [QuizLabel]
    private let actions: [Actionable]
    /// The label flying (to the top, or back from it), and when it started.
    private var flight: (index: Int, out: Bool, start: TimeInterval)?
    /// The label coming clear before it flies, and when it started.
    private var unveiling: (index: Int, start: TimeInterval)?
    /// The label that has flown to the top, waiting there for the branch to show.
    private var parked: Int?
    private var started = false

    /// Seconds to come clear, then to wait, then to fly.
    static let unveil: TimeInterval = 0.5, pause: TimeInterval = 0.2, fly: TimeInterval = 0.8
    /// The labels' size in the column (the title's, at unit 1).
    static let size: CGFloat = 30

    /// How far a title has flown to the top (0...1, eased): the rest of the step fades out with it.
    private(set) var leaving: CGFloat = 0

    init(_ items: [Item], column: CGRect, titleX: @escaping (StageFrame) -> CGFloat) {
        (self.items, self.column, self.titleX) = (items, column, titleX)
        labels = items.map { QuizLabel($0.title, hint: $0.hint) }
        actions = items.map { _ in Actionable(grown: 1.08, by: .click) }
        super.init()
        for label in labels { node.addChild(label) }
    }

    override func update(_ frame: StageFrame) {
        let (u, size) = (frame.stage.unit, frame.stage.viewSize)
        if !started {
            started = true
            for i in labels.indices where frame.branches.visited.contains(i) { labels[i].reveal(at: nil) }
            // Back from a branch: its title starts at the top, where the branch's title stood.
            if let i = frame.branches.returned, labels.indices.contains(i) { flight = (i, false, frame.time) }
        }
        for label in labels { label.layout(unit: u) }
        let rest = Self.size / ObjectTitle.titleSize
        let (top, bottom) = (column.maxY * size.height, column.minY * size.height)
        let rowHeight = (labels.first?.height ?? 0) * rest
        let gap = labels.count > 1 ? (top - bottom - rowHeight) / CGFloat(labels.count - 1) : 0
        let busy = flight != nil || unveiling != nil || parked != nil
        let flying = parked ?? flight.flatMap { $0.out ? $0.index : nil }
        leaving = parked != nil ? 1 : flight.map { $0.out ? Self.eased((frame.time - $0.start) / Self.fly) : 0 } ?? 0

        for (i, label) in labels.enumerated() {
            let home = CGPoint(x: column.minX * size.width, y: top - CGFloat(i) * gap)
            let scale = rest * actions[i].scale
            let rect = CGRect(x: home.x, y: home.y - label.height * scale, width: label.width * scale, height: label.height * scale)
            if actions[i].update(frame, isOn: busy ? nil : { rect.contains($0) }) {
                if label.revealed {
                    flight = (i, true, frame.time)
                } else {
                    label.reveal(at: frame.time)
                    unveiling = (i, frame.time)
                }
            }
            label.unveil(frame)
            // At the top: the title centered over the branch's object, at the branch title's size.
            let up = ObjectTitle.top(over: titleX(frame), width: label.titleWidth, frame: frame)
            let away = CGPoint(x: up.x - label.titleWidth / 2, y: up.y)
            var (position, labelScale, hint) = (home, scale, CGFloat(1))
            if parked == i {
                (position, labelScale, hint) = (away, 1, 0)
            } else if let flight, flight.index == i {
                let t = frame.time - flight.start
                let k = flight.out ? Self.eased(t / Self.fly) : 1 - Self.eased(t / Self.fly)
                position = CGPoint(x: home.x + (away.x - home.x) * k, y: home.y + (away.y - home.y) * k)
                labelScale = scale + (1 - scale) * k
                hint = 1 - k
                if t >= Self.fly {
                    self.flight = nil
                    if flight.out {
                        ObjectTitle.handOff(items[i].title, subtitle: items[i].subtitle, at: up)
                        frame.branches.enter(i)
                        parked = i  // stays at the top until the branch shows
                    }
                }
            }
            label.position = position
            label.setScale(labelScale)
            label.hintAlpha = hint
            label.alpha = flying == nil || flying == i ? 1 : 1 - leaving
        }
        if let unveiling, frame.time - unveiling.start > Self.unveil + Self.pause {
            (flight, self.unveiling) = ((unveiling.index, true, frame.time), nil)
        }
    }
}

extension QuizEffect {
    /// Smoothstep of `t` clamped to 0...1.
    static func eased(_ t: TimeInterval) -> CGFloat {
        let t = CGFloat(min(max(t, 0), 1))
        return t * t * (3 - 2 * t)
    }
}

/// A quiz item: a title and a hint under it, blurred except the title's first letter until revealed, then clear. Its
/// origin is the title's top left; it is laid out at the branch title's size (`ObjectTitle.titleSize`) and scaled.
private final class QuizLabel: SKNode {
    private let first: ShadowedLabel
    private let rest: ShadowedLabel
    private let hint: ShadowedLabel
    private let full: ShadowedLabel
    /// The blurred part: the title but its first letter, and the hint.
    private let veil = SKEffectNode()
    /// Widens the veil's picture so the blur isn't cut at the text's edges.
    private let margin = SKSpriteNode(color: .clear, size: CGSize(width: 1, height: 1))
    private(set) var revealed = false
    /// When it started coming clear (nil: blurred, or clear at once).
    private var revealedAt: TimeInterval?
    private var radius: CGFloat = -1
    /// The blur's radius at the title's full size and unit 1 (scaled down with the label in the column).
    static let blur: CGFloat = 26
    private var unit: CGFloat = 1

    /// The hint's opacity (it fades away as the title flies to the top).
    var hintAlpha: CGFloat = 1 { didSet { hint.alpha = hintAlpha } }
    /// The title's width at the top (unscaled).
    var titleWidth: CGFloat { full.label.frame.width }
    /// Unscaled size, title and hint.
    var width: CGFloat { max(full.label.frame.width, hint.label.frame.width) }
    var height: CGFloat { (54 + 22) * unit }

    init(_ title: String, hint text: String) {
        first = ShadowedLabel(String(title.prefix(1)), font: Theme.titleFont)
        rest = ShadowedLabel(String(title.dropFirst()), font: Theme.titleFont)
        full = ShadowedLabel(title, font: Theme.titleFont)
        hint = ShadowedLabel(text, font: "GeistMono-Medium", color: NSColor(white: 1, alpha: 0.8))
        super.init()
        for label in [first, rest, full, hint] {
            label.label.horizontalAlignmentMode = .left
            label.label.verticalAlignmentMode = .top
        }
        full.alpha = 0
        veil.shouldRasterize = true
        for child in [margin, rest, hint] as [SKNode] { veil.addChild(child) }
        for child in [veil, first, full] as [SKNode] { addChild(child) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func layout(unit u: CGFloat) {
        unit = u
        for label in [first, rest, full] { label.label.set(\.fontSize, ObjectTitle.titleSize * u) }
        hint.label.set(\.fontSize, 22 * u)
        rest.position = CGPoint(x: first.label.frame.width, y: 0)
        hint.position = CGPoint(x: 0, y: -54 * u)
        for label in [first, rest, full, hint] { label.sync(unit: u) }
        let pad = 3 * QuizLabel.blur * u
        margin.set(\.size, CGSize(width: width + 2 * pad, height: height + 2 * pad))
        margin.set(\.position, CGPoint(x: width / 2, y: -height / 2))
    }

    /// Starts coming clear at `time`, or clear at once (nil).
    func reveal(at time: TimeInterval?) {
        revealed = true
        revealedAt = time
        if time == nil { show(clear: 1) }
    }

    /// Eases the blur away while it comes clear; call every frame.
    func unveil(_ frame: StageFrame) {
        guard revealed else { return blur(QuizLabel.blur * unit) }
        guard let start = revealedAt else { return }
        let t = min(max((frame.time - start) / QuizEffect.unveil, 0), 1)
        show(clear: CGFloat(t))
        if t >= 1 { revealedAt = nil }
    }

    /// `clear`: 0 blurred, 1 clear (the whole title as one label, so it reads as it will at the top).
    private func show(clear: CGFloat) {
        let e = clear * clear * (3 - 2 * clear)
        blur(QuizLabel.blur * unit * (1 - e))
        veil.alpha = clear >= 1 ? 0 : 1
        first.alpha = clear >= 1 ? 0 : 1
        full.alpha = clear >= 1 ? 1 : 0
        if clear >= 1 {
            // The hint, out of the veil, stays (it fades only as the title flies).
            if hint.parent === veil {
                hint.removeFromParent()
                addChild(hint)
            }
        }
    }

    private func blur(_ r: CGFloat) {
        let r = (r * 2).rounded() / 2
        guard r != radius else { return }
        radius = r
        veil.filter = r > 0 ? CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: r]) : nil
    }
}
