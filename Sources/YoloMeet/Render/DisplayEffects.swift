import SpriteKit
import YoloMeetCore

/// The default rendering for each task, used by Display mode and reusable in stories.
/// `custom`: an imported model, whose keypoints may not be the COCO body layout the skeleton connects.
func displayEffects(for task: YOLOTask, model: String, custom: Bool) -> [Effect] {
    switch task {
    case .detect: [BoxesEffect(model: model)]
    case .segment: [OverlayEffect(model: model), BoxesEffect(model: model)]
    case .pose, .hand, .face: [PoseEffect(model: model, skeleton: !custom)]
    case .obb: [OrientedBoxesEffect(model: model)]
    case .classify: [ClassifyEffect(model: model)]
    case .semantic: [OverlayEffect(model: model)]
    case .depth: [OverlayEffect(model: model, alpha: 0.7)]
    }
}

/// Boxes with a label chip in the model vendor's style, smoothed per track.
final class BoxesEffect: Effect {
    let model: String
    let filter: (Detection, ModelOutput) -> Bool
    let label: (Detection, ModelOutput) -> String
    private lazy var tracks = TrackedNodes(in: node) { BoxNode() }

    init(
        model: String, filter: @escaping (Detection, ModelOutput) -> Bool = { _, _ in true },
        label: @escaping (Detection, ModelOutput) -> String = { d, o in
            "\(o.name(of: d.classIndex)) \(Int(d.confidence * 100))%"
        }
    ) {
        self.model = model
        self.filter = filter
        self.label = label
    }

    override func update(_ frame: StageFrame) {
        let output = frame.outputs[model]
        let detections = output?.detections.filter { d in d.trackID != nil && filter(d, output!) } ?? []
        let nodes = tracks.sync(detections.map { $0.trackID! }, in: frame)
        let theme = Theme.of(output)
        for (node, detection) in zip(nodes, detections) {
            node.update(
                to: frame.stage.rect(detection.box), text: label(detection, output!),
                color: theme.color(detection.classIndex), theme: theme, unit: frame.stage.unit, k: frame.smoothing)
        }
    }
}

final class BoxNode: SKNode {
    private let shape = SKShapeNode()
    private let chip = SKShapeNode()
    private let label = SKLabelNode()
    private var rect: CGRect?

    override init() {
        super.init()
        label.horizontalAlignmentMode = .left
        label.verticalAlignmentMode = .bottom
        chip.lineWidth = 0
        [shape, chip, label].forEach(addChild)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Square, unfilled box with the label chip flush on its top-left edge, as both vendors' annotators draw them.
    func update(to target: CGRect, text: String, color: NSColor, theme: Theme, unit: CGFloat, k: CGFloat) {
        let rect = rect?.approaching(target, k) ?? target
        self.rect = rect
        let line = theme.lineWidth * unit
        shape.path = CGPath(rect: rect, transform: nil)
        shape.set(\.strokeColor, color)
        shape.set(\.lineWidth, line)

        let pad = 5 * unit
        label.set(\.fontName, theme.labelFont)
        label.set(\.text, text)
        label.set(\.fontSize, 15 * unit)
        label.set(\.fontColor, theme.textColor(on: color))
        label.position = CGPoint(x: rect.minX - line / 2 + pad, y: rect.maxY + line / 2 + pad / 2)
        let size = label.frame.size
        chip.path = CGPath(
            rect: CGRect(x: rect.minX - line / 2, y: rect.maxY + line / 2, width: size.width + 2 * pad, height: size.height + pad),
            transform: nil)
        chip.set(\.fillColor, color)
    }
}

/// Skeletons in the vendor's colors (left, right and center limbs; outlined joints), smoothed per track. Without
/// `skeleton`, only the joints are drawn. `opacity` applies to the whole drawing (the stage fades `node` itself in);
/// `theme` replaces the model's colors.
final class PoseEffect: Effect {
    let model: String
    let skeleton: Bool
    let theme: Theme?
    let minConfidence: Float = 0.5
    private let layer = SKNode()
    private lazy var tracks = TrackedNodes(in: layer) { PoseNode() }

    init(model: String, skeleton: Bool = true, opacity: CGFloat = 1, theme: Theme? = nil) {
        self.model = model
        self.skeleton = skeleton
        self.theme = theme
        super.init()
        layer.alpha = opacity
        node.addChild(layer)
    }

    override func update(_ frame: StageFrame) {
        let output = frame.outputs[model]
        let theme = self.theme ?? Theme.of(output)
        let detections = output?.detections.filter { $0.trackID != nil } ?? []
        let nodes = tracks.sync(detections.map { $0.trackID! }, in: frame)
        for (node, detection) in zip(nodes, detections) {
            let points = detection.keypoints.map { $0.confidence >= minConfidence ? frame.stage.point($0.point) : nil }
            node.update(
                to: points, skeleton: skeleton ? output?.skeleton ?? [] : [], theme: theme, unit: frame.stage.unit,
                smoothing: frame.smoothing(gap:))
        }
    }
}

final class PoseNode: SKNode {
    /// Limbs grouped by body side: COCO keypoints with odd indices are on the left, even (non-zero) on the right.
    /// Themes without sides (MediaPipe, Apple Vision) color all three alike.
    private let left = SKShapeNode()
    private let right = SKShapeNode()
    private let center = SKShapeNode()
    private let joints = SKShapeNode()
    /// Smoothed keypoints in stage space; nil while not visible.
    private(set) var points: [CGPoint?] = []

    override init() {
        super.init()
        for limb in [left, right, center] { limb.lineCap = .round }
        [center, left, right, joints].forEach(addChild)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(
        to targets: [CGPoint?], skeleton: [(Int, Int)], theme: Theme, unit: CGFloat, smoothing: (CGFloat) -> CGFloat
    ) {
        // A dense mesh (MediaPipe's 478-point face) is drawn as thin lines without joints.
        let mesh = targets.count > 100
        if points.count != targets.count { points = targets }
        points = zip(points, targets).map { current, target in
            guard let target else { return nil }
            guard let current else { return target }
            return current.approaching(target, smoothing(hypot(target.x - current.x, target.y - current.y)))
        }
        let paths = (left: CGMutablePath(), right: CGMutablePath(), center: CGMutablePath())
        for (a, b) in skeleton {
            guard let p = points[safe: a] ?? nil, let q = points[safe: b] ?? nil else { continue }
            let side = a % 2 == b % 2 && a != 0 && b != 0 ? (a % 2 == 1 ? paths.left : paths.right) : paths.center
            side.move(to: p)
            side.addLine(to: q)
        }
        for (limb, path, color) in [(left, paths.left, theme.leftLimb), (right, paths.right, theme.rightLimb),
                                    (center, paths.center, theme.centerLimb)] {
            limb.path = path
            limb.set(\.strokeColor, color)
            limb.set(\.lineWidth, (mesh ? 0.75 : theme.limbWidth) * unit)
        }

        let jointPath = CGMutablePath()
        let r = theme.jointRadius * unit
        for case let p? in mesh ? [] : points { jointPath.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
        joints.path = jointPath
        joints.set(\.fillColor, theme.joint)
        joints.set(\.strokeColor, theme.jointOutline)
        joints.set(\.lineWidth, 1.5 * unit)
    }
}

/// Rotated boxes with a label, smoothed per track.
final class OrientedBoxesEffect: Effect {
    let model: String
    private lazy var tracks = TrackedNodes(in: node) { OrientedBoxNode() }

    init(model: String) { self.model = model }

    override func update(_ frame: StageFrame) {
        guard let output = frame.outputs[model] else { _ = tracks.sync([], in: frame); return }
        let detections = output.detections.filter { $0.trackID != nil }
        let nodes = tracks.sync(detections.map { $0.trackID! }, in: frame)
        let theme = Theme.of(output)
        for (node, detection) in zip(nodes, detections) {
            node.update(
                to: corners(of: detection).map(frame.stage.point), text: output.name(of: detection.classIndex),
                color: theme.color(detection.classIndex), font: theme.labelFont, unit: frame.stage.unit, k: frame.smoothing)
        }
    }
}

final class OrientedBoxNode: SKNode {
    private let shape = SKShapeNode()
    private let label = SKLabelNode()
    private var points: [CGPoint] = []

    override init() {
        super.init()
        label.verticalAlignmentMode = .bottom
        [shape, label].forEach(addChild)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(to targets: [CGPoint], text: String, color: NSColor, font: String, unit: CGFloat, k: CGFloat) {
        points = points.count == targets.count ? zip(points, targets).map { $0.approaching($1, k) } : targets
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        shape.path = path
        shape.set(\.strokeColor, color)
        shape.set(\.lineWidth, 2.5 * unit)
        label.set(\.fontName, font)
        label.set(\.text, text)
        label.set(\.fontSize, 13 * unit)
        label.set(\.fontColor, color)
        label.position = points.max { $0.y < $1.y }.map { CGPoint(x: $0.x, y: $0.y + 4 * unit) } ?? .zero
    }
}

/// A full-frame image from the model (instance masks, semantic class map, depth colormap).
final class OverlayEffect: Effect {
    let model: String
    private let sprite = SKSpriteNode()
    private var shown: CGImage?

    init(model: String, alpha: CGFloat = 1) {
        self.model = model
        super.init()
        sprite.anchorPoint = .zero
        sprite.alpha = alpha
        node.addChild(sprite)
    }

    override func update(_ frame: StageFrame) {
        let image = frame.outputs[model]?.overlay
        if image !== shown {
            shown = image
            sprite.texture = image.map { SKTexture(cgImage: $0) }
            sprite.texture?.filteringMode = .linear
        }
        sprite.isHidden = image == nil
        let rect = frame.stage.frameRect
        sprite.position = rect.origin
        sprite.size = rect.size
    }
}

/// Top-5 classes as animated bars in the top-left corner.
final class ClassifyEffect: Effect {
    let model: String
    private var rows: [(label: SKLabelNode, bar: SKShapeNode, width: CGFloat, shown: (index: Int, percent: Int)?)] = []

    init(model: String) {
        self.model = model
        super.init()
        for _ in 0..<5 {
            let label = SKLabelNode(fontNamed: Theme.ultralytics.labelFont)
            label.horizontalAlignmentMode = .left
            label.verticalAlignmentMode = .center
            label.fontColor = .white
            let bar = SKShapeNode()
            bar.lineWidth = 0
            node.addChild(bar)
            node.addChild(label)
            rows.append((label, bar, 0, nil))
        }
    }

    override func update(_ frame: StageFrame) {
        guard let output = frame.outputs[model] else { return }
        let theme = Theme.of(output)
        let u = frame.stage.unit
        for (i, row) in rows.enumerated() {
            let top = output.topClasses[safe: i]
            let y = frame.stage.viewSize.height - (40 + CGFloat(i) * 34) * u
            let width = row.width.approaching(CGFloat(top?.confidence ?? 0) * 320 * u, frame.smoothing)
            rows[i].width = width
            row.bar.path = CGPath(
                roundedRect: CGRect(x: 24 * u, y: y - 13 * u, width: max(width, 1), height: 26 * u),
                cornerWidth: 6 * u, cornerHeight: 6 * u, transform: nil)
            row.bar.set(\.fillColor, theme.color(i).withAlphaComponent(0.85))
            row.label.set(\.fontColor, theme.textColor(on: theme.color(i)))
            let shown = top.map { (index: $0.index, percent: Int($0.confidence * 100)) }
            if shown?.index != row.shown?.index || shown?.percent != row.shown?.percent {
                rows[i].shown = shown
                row.label.text = shown.map { "\(output.name(of: $0.index).replacingOccurrences(of: "_", with: " ")) \($0.percent)%" }
            }
            row.label.set(\.fontSize, 16 * u)
            row.label.position = CGPoint(x: 32 * u, y: y)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
