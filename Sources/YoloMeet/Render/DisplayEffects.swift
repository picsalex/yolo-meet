import SpriteKit
import YoloMeetCore

/// The default rendering for each task, used by Display mode and reusable in stories.
func displayEffects(for task: YOLOTask, model: String) -> [Effect] {
    switch task {
    case .detect: [BoxesEffect(model: model)]
    case .segment: [OverlayEffect(model: model), BoxesEffect(model: model)]
    case .pose: [PoseEffect(model: model)]
    case .obb: [OrientedBoxesEffect(model: model)]
    case .classify: [ClassifyEffect(model: model)]
    case .semantic: [OverlayEffect(model: model)]
    case .depth: [OverlayEffect(model: model, alpha: 0.7)]
    }
}

/// Rounded boxes with a label chip, smoothed per track.
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
        let nodes = tracks.sync(detections.map { $0.trackID! }, at: frame.time)
        for (node, detection) in zip(nodes, detections) {
            node.update(
                to: frame.stage.rect(detection.box), text: label(detection, output!),
                color: .palette(detection.classIndex), unit: frame.stage.unit, k: frame.smoothing)
        }
    }
}

final class BoxNode: SKNode {
    private let shape = SKShapeNode()
    private let chip = SKShapeNode()
    private let label = SKLabelNode(fontNamed: labelFont)
    private var rect: CGRect?

    override init() {
        super.init()
        label.horizontalAlignmentMode = .left
        label.verticalAlignmentMode = .bottom
        label.fontColor = .white
        chip.lineWidth = 0
        [shape, chip, label].forEach(addChild)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(to target: CGRect, text: String, color: NSColor, unit: CGFloat, k: CGFloat) {
        let rect = rect?.approaching(target, k) ?? target
        self.rect = rect
        let radius = min(8 * unit, rect.width / 2, rect.height / 2)
        shape.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        shape.strokeColor = color
        shape.lineWidth = 3 * unit
        shape.fillColor = color.withAlphaComponent(0.08)

        let pad = 5 * unit
        label.text = text
        label.fontSize = 15 * unit
        label.position = CGPoint(x: rect.minX + pad, y: rect.maxY + pad + 2 * unit)
        let chipRect = label.frame.insetBy(dx: -pad, dy: -pad / 2)
        chip.path = CGPath(roundedRect: chipRect, cornerWidth: pad, cornerHeight: pad, transform: nil)
        chip.fillColor = color
    }
}

/// Skeletons with keypoints, smoothed per track.
final class PoseEffect: Effect {
    let model: String
    let minConfidence: Float = 0.5
    private lazy var tracks = TrackedNodes(in: node) { PoseNode() }

    init(model: String) { self.model = model }

    override func update(_ frame: StageFrame) {
        let detections = frame.outputs[model]?.detections.filter { $0.trackID != nil } ?? []
        let nodes = tracks.sync(detections.map { $0.trackID! }, at: frame.time)
        for (node, detection) in zip(nodes, detections) {
            let points = detection.keypoints.map { $0.confidence >= minConfidence ? frame.stage.point($0.point) : nil }
            node.update(to: points, color: .palette(detection.trackID!), unit: frame.stage.unit, k: frame.smoothing)
        }
    }
}

final class PoseNode: SKNode {
    private let bones = SKShapeNode()
    private let joints = SKShapeNode()
    /// Smoothed keypoints in stage space; nil while not visible.
    private(set) var points: [CGPoint?] = []

    override init() {
        super.init()
        bones.lineCap = .round
        joints.strokeColor = .white
        [bones, joints].forEach(addChild)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(to targets: [CGPoint?], color: NSColor, unit: CGFloat, k: CGFloat) {
        if points.count != targets.count { points = targets }
        points = zip(points, targets).map { current, target in
            guard let target else { return nil }
            return current?.approaching(target, k) ?? target
        }
        let bonePath = CGMutablePath()
        for (a, b) in poseSkeleton {
            guard let p = points[safe: a] ?? nil, let q = points[safe: b] ?? nil else { continue }
            bonePath.move(to: p)
            bonePath.addLine(to: q)
        }
        bones.path = bonePath
        bones.strokeColor = color
        bones.lineWidth = 4 * unit

        let jointPath = CGMutablePath()
        let r = 4 * unit
        for case let p? in points { jointPath.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
        joints.path = jointPath
        joints.fillColor = color
        joints.lineWidth = 1.5 * unit
    }
}

/// Rotated boxes with a label, smoothed per track.
final class OrientedBoxesEffect: Effect {
    let model: String
    private lazy var tracks = TrackedNodes(in: node) { OrientedBoxNode() }

    init(model: String) { self.model = model }

    override func update(_ frame: StageFrame) {
        guard let output = frame.outputs[model] else { _ = tracks.sync([], at: frame.time); return }
        let detections = output.detections.filter { $0.trackID != nil }
        let nodes = tracks.sync(detections.map { $0.trackID! }, at: frame.time)
        for (node, detection) in zip(nodes, detections) {
            node.update(
                to: corners(of: detection).map(frame.stage.point), text: output.name(of: detection.classIndex),
                color: .palette(detection.classIndex), unit: frame.stage.unit, k: frame.smoothing)
        }
    }
}

final class OrientedBoxNode: SKNode {
    private let shape = SKShapeNode()
    private let label = SKLabelNode(fontNamed: labelFont)
    private var points: [CGPoint] = []

    override init() {
        super.init()
        label.verticalAlignmentMode = .bottom
        [shape, label].forEach(addChild)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(to targets: [CGPoint], text: String, color: NSColor, unit: CGFloat, k: CGFloat) {
        points = points.count == targets.count ? zip(points, targets).map { $0.approaching($1, k) } : targets
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        shape.path = path
        shape.strokeColor = color
        shape.fillColor = color.withAlphaComponent(0.12)
        shape.lineWidth = 2.5 * unit
        label.text = text
        label.fontSize = 13 * unit
        label.fontColor = color
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
    private var rows: [(label: SKLabelNode, bar: SKShapeNode, width: CGFloat)] = []

    init(model: String) {
        self.model = model
        super.init()
        for _ in 0..<5 {
            let label = SKLabelNode(fontNamed: labelFont)
            label.horizontalAlignmentMode = .left
            label.verticalAlignmentMode = .center
            label.fontColor = .white
            let bar = SKShapeNode()
            bar.lineWidth = 0
            node.addChild(bar)
            node.addChild(label)
            rows.append((label, bar, 0))
        }
    }

    override func update(_ frame: StageFrame) {
        guard let output = frame.outputs[model] else { return }
        let u = frame.stage.unit
        for (i, row) in rows.enumerated() {
            let top = output.topClasses[safe: i]
            let y = frame.stage.viewSize.height - (40 + CGFloat(i) * 34) * u
            let width = row.width.approaching(CGFloat(top?.confidence ?? 0) * 320 * u, frame.smoothing)
            rows[i].width = width
            row.bar.path = CGPath(
                roundedRect: CGRect(x: 24 * u, y: y - 13 * u, width: max(width, 1), height: 26 * u),
                cornerWidth: 6 * u, cornerHeight: 6 * u, transform: nil)
            row.bar.fillColor = NSColor.palette(i).withAlphaComponent(0.85)
            row.label.text = top.map { "\(output.name(of: $0.index).replacingOccurrences(of: "_", with: " ")) \(Int($0.confidence * 100))%" }
            row.label.fontSize = 16 * u
            row.label.position = CGPoint(x: 32 * u, y: y)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
