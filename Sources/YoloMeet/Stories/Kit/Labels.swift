import CoreImage
import SpriteKit

/// An object's title and subtitle, beside its top right corner (or its top left near the stage's right edge), fading
/// in and out. Add it to an effect's `node` and call `update` every frame.
final class ObjectTitle: SKNode {
    private let titleNode: ShadowedLabel
    private let subtitleNode: ShadowedLabel
    private var title: SKLabelNode { titleNode.label }
    private var subtitle: SKLabelNode { subtitleNode.label }
    private var shown: CGPoint?
    /// The last title shown, with its text, so a step that continues the previous one picks it up.
    private static var last: (text: String, at: CGPoint)?
    private var key: String { "\(title.text ?? "")\n\(subtitle.text ?? "")" }

    init(_ title: String, subtitle: String = "") {
        titleNode = ShadowedLabel(title, font: Theme.titleFont)
        subtitleNode = ShadowedLabel(subtitle, font: Self.subtitleFont, color: Self.subtitleColor)
        super.init()
        for node in [titleNode, subtitleNode] {
            node.label.verticalAlignmentMode = .top
            addChild(node)
        }
        alpha = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `rect`: the object on stage (stage points).
    func update(beside rect: CGRect, visible: Bool, frame: StageFrame) {
        let u = frame.stage.unit
        title.set(\.fontSize, 44 * u)
        subtitle.set(\.fontSize, 15 * u)
        let width = max(title.frame.width, subtitle.frame.width)
        let right = rect.maxX + 24 * u + width < frame.stage.viewSize.width - 24 * u
        for label in [title, subtitle] { label.set(\.horizontalAlignmentMode, right ? .left : .right) }
        // Kept on stage: with no room on either side, it moves in over the object's top.
        let target = CGPoint(x: right ? rect.maxX + 24 * u : max(rect.minX - 24 * u, 24 * u + width), y: rect.maxY + 30 * u)
        place(at: target, visible: visible, frame: frame)
    }

    /// At the top of the stage, centered over the object (`rect`, stage points), kept on stage; with the camera hidden (H),
    /// centered on the stage whatever the object's place.
    func update(above rect: CGRect, visible: Bool, frame: StageFrame) {
        let u = frame.stage.unit
        title.set(\.fontSize, Self.titleSize * u)
        subtitle.set(\.fontSize, 15 * u)
        for label in [title, subtitle] { label.set(\.horizontalAlignmentMode, .center) }
        let width = max(title.frame.width, subtitle.frame.width)
        place(at: Self.top(over: rect.midX, width: width, frame: frame), visible: visible, frame: frame)
    }

    /// The title's size at unit 1, in `Theme.titleFont`.
    static let titleSize: CGFloat = 44
    /// The subtitle's font and color (also a quiz's hints, `QuizEffect`).
    static let subtitleFont = "GeistMono-Medium", subtitleColor = NSColor(white: 1, alpha: 0.8)

    /// Where `update(above:)` puts a title `width` wide over an object centered on `x`: its top center.
    static func top(over x: CGFloat, width: CGFloat, frame: StageFrame) -> CGPoint {
        let (u, size) = (frame.stage.unit, frame.stage.viewSize)
        let half = width / 2 + 24 * u
        return CGPoint(x: frame.cameraHidden ? size.width / 2 : min(max(x, half), size.width - half), y: size.height - 30 * u)
    }

    /// A title shown by something else at `point` (its top center, e.g. a label flown to the top of the stage): the
    /// next title with the same text starts there if it shows at once (`showAtOnce`), then eases to its own place.
    static func handOff(_ title: String, subtitle: String, at point: CGPoint) {
        last = ("\(title)\n\(subtitle)", point)
    }

    /// Shows the title at once, picking up a title handed off (`handOff`) or the previous step's, its subtitle fading
    /// in under it: e.g. when it takes over from a label that flew there.
    func showAtOnce() {
        alpha = 1
        subtitleNode.alpha = 0
        subtitleNode.run(.sequence([.wait(forDuration: 0.25), .fadeIn(withDuration: 0.5)]))
    }

    /// Eases the title (its top) toward `target`, the subtitle under it. It fades in and out in place: hidden, it
    /// stays where it was, and it shows up again right at its target; when it changes place while showing, it moves.
    private func place(at target: CGPoint, visible: Bool, frame: StageFrame) {
        let u = frame.stage.unit
        if visible {
            // A new title already showing (a step continuing the previous one, with no transition) with the same
            // text starts where the previous one stood, then eases to its own place.
            let previous = Self.last.flatMap { $0.text == key ? $0.at : nil }
            let ease = CGFloat(1 - exp(-frame.dt * 7))  // about half a second, calmer than following a hand
            shown = alpha < 0.01 ? target : (shown ?? previous)?.approaching(target, ease) ?? target
            Self.last = (key, shown!)
        }
        guard shown != nil else { return }
        titleNode.position = shown!
        subtitleNode.position = CGPoint(x: shown!.x, y: shown!.y - 52 * u)
        for node in [titleNode, subtitleNode] { node.sync(unit: u) }
        alpha = alpha.approaching(visible ? 1 : 0, fade(frame))
    }
}

/// Descriptions with a line to a point of an object (its parts), in a column on each side of it: a part left of the
/// object's middle gets its label on the left. Labels keep clear of each other and follow their parts smoothly. Add it
/// to an effect's `node` and call `update` every frame.
final class Callouts: SKNode {
    private struct Item {
        let text: ShadowedLabel
        var label: SKLabelNode { text.label }
        let line = SKShapeNode()
        var shown: CGPoint?
    }
    private var items: [Item]
    private let size: CGFloat

    /// `size`: the text's size at unit 1; `line`: the color of the lines and their dots.
    init(_ texts: [String], font: String = "GeistMono-Medium", size: CGFloat = 16, line: NSColor = NSColor(white: 1, alpha: 0.6)) {
        items = texts.map { text in
            let label = ShadowedLabel(text, font: font)
            label.label.verticalAlignmentMode = .center
            return Item(text: label)
        }
        self.size = size
        super.init()
        for item in items {
            item.line.strokeColor = line
            item.line.fillColor = line.withAlphaComponent(1)
            addChild(item.line)
            addChild(item.text)
        }
        alpha = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The side a description goes on beside `rect` (true: left): its anchor's side (or `left`), or the other one when
    /// it wouldn't fit on stage there; nil when it fits on neither.
    func side(of index: Int, anchor: CGPoint, around rect: CGRect, left forced: Bool? = nil, frame: StageFrame) -> Bool? {
        let u = frame.stage.unit
        items[index].label.set(\.fontSize, size * u)
        let (width, margin) = (items[index].label.frame.width, 16 * u)
        let fits = { (left: Bool) in
            left ? rect.minX - 40 * u - width >= margin : rect.maxX + 40 * u + width <= frame.stage.viewSize.width - margin
        }
        let preferred = forced ?? (anchor.x < rect.midX)
        return fits(preferred) ? preferred : fits(!preferred) ? !preferred : nil
    }

    /// Changes the text of a description (e.g. a value of the part it points at).
    func setText(_ text: String, at index: Int) { items[index].label.set(\.text, text) }

    /// `anchors`: each description's point on stage, in the order of the texts (nil hides it); `rect`: the object on
    /// stage, which the columns stand beside. A label goes on its anchor's side of the object (`left` forces one side),
    /// or on the other side when it wouldn't fit on stage there.
    func update(anchors: [CGPoint?], around rect: CGRect, left forced: Bool? = nil, visible: Bool, frame: StageFrame) {
        let u = frame.stage.unit
        let appearing = alpha < 0.01
        alpha = alpha.approaching(visible ? 1 : 0, fade(frame))
        let margin = 16 * u  // kept from the stage's edges
        let onLeft = items.indices.map { i in
            anchors[i].map { side(of: i, anchor: $0, around: rect, left: forced, frame: frame) ?? forced ?? ($0.x < rect.midX) }
        }
        // Each side's labels from top to bottom, at their anchors' heights, at least `gap` apart, centered on them.
        var targets = [CGPoint?](repeating: nil, count: items.count)
        let gap = 30 * u
        for left in [true, false] {
            let side = anchors.indices.filter { onLeft[$0] == left }
                .sorted { anchors[$0]!.y > anchors[$1]!.y }
            var ys: [CGFloat] = []
            for i in side { ys.append(min(anchors[i]!.y, (ys.last ?? .infinity) - gap)) }
            let shift = side.isEmpty ? 0 : (side.map { anchors[$0]!.y }.reduce(0, +) - ys.reduce(0, +)) / CGFloat(side.count)
            let x = left ? rect.minX - 40 * u : rect.maxX + 40 * u
            for (i, y) in zip(side, ys) { targets[i] = CGPoint(x: x, y: y + shift) }
        }
        for i in items.indices {
            let item = items[i]
            guard let target = targets[i], let anchor = anchors[i] else {
                item.text.isHidden = true
                item.line.isHidden = true
                continue
            }
            let left = target.x < rect.midX
            // Kept on stage: a long label that fits on neither side moves in over the object.
            let width = item.label.frame.width
            let x = left ? max(target.x, margin + width) : min(target.x, frame.stage.viewSize.width - margin - width)
            // Fading in, a label starts right at its place rather than sliding there from where it last was.
            let shown = appearing || item.text.isHidden
                ? CGPoint(x: x, y: target.y)
                : items[i].shown?.approaching(CGPoint(x: x, y: target.y), frame.smoothing) ?? CGPoint(x: x, y: target.y)
            items[i].shown = shown
            (item.text.isHidden, item.line.isHidden) = (false, false)
            item.label.set(\.horizontalAlignmentMode, left ? .right : .left)
            item.text.position = shown
            item.text.sync(unit: u)
            // Line from beside the label to the part, with a dot on the part.
            let path = CGMutablePath()
            path.move(to: CGPoint(x: shown.x + (left ? 8 : -8) * u, y: shown.y))
            path.addLine(to: anchor)
            let r = 3 * u
            path.addEllipse(in: CGRect(x: anchor.x - r, y: anchor.y - r, width: 2 * r, height: 2 * r))
            item.line.path = path
            item.line.lineWidth = 1.2 * u
        }
    }
}

/// A white label over a soft, blurred dark copy of itself, readable over light backgrounds too. Set its text, size and
/// alignment on `label` and move the node itself, then call `sync()`. The blurred shadow is cached until its size or
/// alignment changes.
final class ShadowedLabel: SKNode {
    let label: SKLabelNode
    private let shadow: SKLabelNode
    private let blur = SKEffectNode()

    init(_ text: String, font: String, color: NSColor = .white) {
        (label, shadow) = (SKLabelNode(fontNamed: font), SKLabelNode(fontNamed: font))
        super.init()
        for l in [shadow, label] { l.text = text }
        label.fontColor = color
        shadow.fontColor = NSColor(white: 0, alpha: 0.85)
        blur.shouldRasterize = true
        blur.addChild(shadow)
        addChild(blur)
        addChild(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Copies the label's text and layout to the shadow, slightly lower, blurred over about a fifth of the text's height.
    func sync(unit u: CGFloat) {
        if shadow.text != label.text {
            shadow.text = label.text
            blur.filter = nil  // redrawn below
        }
        shadow.set(\.fontSize, label.fontSize)
        shadow.set(\.horizontalAlignmentMode, label.horizontalAlignmentMode)
        shadow.set(\.verticalAlignmentMode, label.verticalAlignmentMode)
        shadow.set(\.position, CGPoint(x: 0, y: -1.5 * u))
        let radius = (label.fontSize * 0.2).rounded()
        if blur.filter?.value(forKey: kCIInputRadiusKey) as? CGFloat != radius {
            blur.filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        }
    }
}

/// Per-frame blend for fading labels in or out in about a quarter of a second.
private func fade(_ frame: StageFrame) -> CGFloat { CGFloat(1 - exp(-frame.dt * 12)) }
