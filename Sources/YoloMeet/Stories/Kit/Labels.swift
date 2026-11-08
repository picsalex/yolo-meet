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

    init(_ title: String, subtitle: String = "") {
        titleNode = ShadowedLabel(title, font: Theme.titleFont)
        subtitleNode = ShadowedLabel(subtitle, font: "GeistMono-Medium", color: NSColor(white: 1, alpha: 0.8))
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
        for label in [title, subtitle] { label.horizontalAlignmentMode = right ? .left : .right }
        let target = CGPoint(x: right ? rect.maxX + 24 * u : rect.minX - 24 * u, y: rect.maxY + 30 * u)
        shown = shown?.approaching(target, frame.smoothing) ?? target
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

    init(_ texts: [String]) {
        items = texts.map { text in
            let label = ShadowedLabel(text, font: "GeistMono-Medium")
            label.label.verticalAlignmentMode = .center
            return Item(text: label)
        }
        super.init()
        for item in items {
            item.line.strokeColor = NSColor(white: 1, alpha: 0.6)
            item.line.fillColor = .white
            addChild(item.line)
            addChild(item.text)
        }
        alpha = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Changes the text of a description (e.g. a value of the part it points at).
    func setText(_ text: String, at index: Int) { items[index].label.set(\.text, text) }

    /// `anchors`: each description's point on stage, in the order of the texts (nil hides it); `rect`: the object on
    /// stage, which the columns stand beside.
    func update(anchors: [CGPoint?], around rect: CGRect, visible: Bool, frame: StageFrame) {
        let u = frame.stage.unit
        alpha = alpha.approaching(visible ? 1 : 0, fade(frame))
        // Each side's labels from top to bottom, at their anchors' heights, at least `gap` apart, centered on them.
        var targets = [CGPoint?](repeating: nil, count: items.count)
        let gap = 30 * u
        for left in [true, false] {
            let side = anchors.indices.filter { anchors[$0].map { ($0.x < rect.midX) == left } ?? false }
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
            item.label.set(\.fontSize, 16 * u)
            // Kept on stage: a long label near the edge moves in over the object.
            let (width, margin) = (item.label.frame.width, 16 * u)
            let x = left ? max(target.x, margin + width) : min(target.x, frame.stage.viewSize.width - margin - width)
            let shown = items[i].shown?.approaching(CGPoint(x: x, y: target.y), frame.smoothing) ?? CGPoint(x: x, y: target.y)
            items[i].shown = shown
            (item.text.isHidden, item.line.isHidden) = (false, false)
            item.label.horizontalAlignmentMode = left ? .right : .left
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
