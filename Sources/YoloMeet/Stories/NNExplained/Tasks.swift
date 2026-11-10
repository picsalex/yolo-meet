import SpriteKit
import simd
import YoloMeetCore

/// What YOLO outputs for each of its tasks, shown on the cat picture: the particles become one large picture (the
/// results), recolored per task (a mask, class colors, depth), and `TaskOutputEffect` draws the rest in 2D over it
/// (boxes, polygons, keypoints, classes, legends), in the style of the app's live overlays.
extension NetworkLayout {
    /// The results picture: pixels on a side, and its side in the shape's units (centered on the shape's origin).
    static let resultCells = 200
    static let resultSide: Float = 2.4

    /// A point of the cat picture's 100 × 100 canvas (y up) in the results picture, `z` toward the viewer.
    static func resultPoint(_ c: CGPoint, z: Float = 0) -> SIMD3<Float> {
        [(Float(c.x) / 100 - 0.5) * resultSide, (Float(c.y) / 100 - 0.5) * resultSide, z]
    }

    /// The canvas pixel (column, row from the top) a point of the results picture is in.
    static func resultCell(_ p: SIMD3<Float>) -> Int {
        let n = resultCells
        let x = min(max(Int((p.x / resultSide + 0.5) * Float(n)), 0), n - 1)
        let y = min(max(Int((0.5 - p.y / resultSide) * Float(n)), 0), n - 1)
        return y * n + x
    }

    /// The model's output on its input: the picture `inference` flows from, large, every particle part of it (the
    /// picture's own keep their place in it, the architecture's fill in), gliding from where `inference` leaves them.
    static func results(after inference: NetworkLayout, picture: NetworkLayout) -> NetworkLayout {
        let layout = NetworkLayout(
            title: "Object detection", subtitle: "a box, a class and a confidence per object",
            neurons: [], synapses: [], neuronSize: 0.02, restingTilt: 0)
        (layout.splits, layout.splitsFrom) = (true, inference)
        let h = resultSide / 2
        layout.outline = [[-h, -h, 0], [h, h, 0], [-h, h, 0], [h, -h, 0]]
        guard let from = inference.shape else { return layout }
        let n = from.points.count, cells = resultCells
        let (lo, hi) = (picture.outline[picture.outline.count - 2], picture.outline[picture.outline.count - 1])
        let quota = (n + cells * cells - 1) / (cells * cells)
        var cellOf = [Int](repeating: -1, count: n), counts = [Int](repeating: 0, count: cells * cells)
        for i in 0..<n where from.parts[i] == dustPart {
            let p = from.points[i]
            let (fx, fy) = ((p.x - lo.x) / (hi.x - lo.x), (hi.y - p.y) / (hi.y - lo.y))
            let c = min(max(Int(fy * Float(cells)), 0), cells - 1) * cells + min(max(Int(fx * Float(cells)), 0), cells - 1)
            if counts[c] < quota { (cellOf[i], counts[c]) = (c, counts[c] + 1) }
        }
        var open = counts.indices.flatMap { Array(repeating: $0, count: quota - counts[$0]) }.shuffled()
        for i in 0..<n where cellOf[i] < 0 { cellOf[i] = open.popLast()! }
        let colors = catPicture(cells)
        let points = cellOf.map { c -> SIMD3<Float> in
            let x = (Float(c % cells) + .random(in: 0..<1)) / Float(cells), y = (Float(c / cells) + .random(in: 0..<1)) / Float(cells)
            return [(x - 0.5) * resultSide, (0.5 - y) * resultSide, .random(in: -0.004...0.004)]
        }
        layout.shape = ParticleShape(
            points: from.points, offsets: zip(points, from.points).map { $0 - $1 }, parts: Array(repeating: 0, count: n),
            colors: cellOf.map { colors[$0] * resultBrightness })
        return layout
    }

    /// Particle colors over the camera, for the results' density.
    static let resultBrightness: Float = 1.55

    /// `results` with its own title, its particles recolored by pixel (`color`: the pixel, its picture color) and moved
    /// toward the viewer (`depth`, in the shape's units), and its view.
    static func task(
        _ results: NetworkLayout, _ title: String, _ subtitle: String, tilt: Float = 0, turn: Float = 0,
        color: ((Int, SIMD3<Float>) -> SIMD3<Float>)? = nil, depth: ((Int) -> Float)? = nil
    ) -> NetworkLayout {
        let layout = NetworkLayout(title: title, subtitle: subtitle, neurons: [], synapses: [], neuronSize: 0.02, restingTilt: tilt)
        (layout.base, layout.restingTurn, layout.outline) = (results, turn, results.outline)
        guard var shape = results.settled else { return layout }
        for i in shape.points.indices {
            let cell = resultCell(shape.points[i])
            if let color { shape.colors[i] = color(cell, shape.colors[i] ?? .one) }
            if let depth { shape.points[i].z += depth(cell) }
        }
        layout.shape = shape
        return layout
    }

    /// The seven tasks' layouts on the results picture (detection is `results` itself).
    static func tasks(_ results: NetworkLayout) -> TaskLayouts {
        let n = resultCells
        let classes = catClasses(n)
        let cat = TaskOutputEffect.catColor.rgb * resultBrightness
        let segment = task(results, "Instance segmentation", "a mask per object · its outline as a polygon") { cell, color in
            classes[cell] == Scene.cat.rawValue ? color + (cat - color) * 0.6 : color
        }
        let semantic = task(results, "Semantic segmentation", "a class for every pixel · no separate objects") { cell, _ in
            TaskOutputEffect.semanticClasses[TaskOutputEffect.semanticClass(classes[cell])].color.rgb * resultBrightness
        }
        let classify = task(results, "Image classification", "one class for the whole image, with its confidence")
        let pose = task(results, "Pose estimation", "keypoints per object · e.g. ears, eyes, nose")
        let tilted = catDrawing(n, tilt: TaskOutputEffect.tilt)
        let obb = task(results, "Oriented bounding boxes", "a rotated box fits a tilted object tightly") { cell, _ in
            tilted[cell] * resultBrightness
        }
        // Depth: the sky far, the grass coming closer toward the bottom, the cat nearest (rounder in its middle).
        let near = (0..<n * n).map { cell -> Float in
            let (cx, cy) = ((Float(cell % n) + 0.5) / Float(n) * 100, 100 - (Float(cell / n) + 0.5) / Float(n) * 100)
            switch Scene(rawValue: classes[cell]) {
            case .cat:
                let bulge = max(0, 1 - pow((cx - 50) / 30, 2) - pow((cy - 42) / 28, 2)).squareRoot()
                return 0.85 + 0.15 * bulge
            case .grass: return 0.2 + 0.45 * (1 - cy / 22)
            default: return 0.06 * (1 - cy / 100)
            }
        }
        let depth = task(
            results, "Depth estimation", "how far every pixel is · near bright, far dark", tilt: 0.2, turn: -0.4,
            color: { cell, _ in TaskOutputEffect.inferno(near[cell]) * 1.1 }, depth: { near[$0] * 0.45 })
        return TaskLayouts(
            detect: results, segment: segment, semantic: semantic, classify: classify, pose: pose, obb: obb, depth: depth)
    }
}

/// The tasks' layouts, in the story's order.
struct TaskLayouts {
    let detect, segment, semantic, classify, pose, obb, depth: NetworkLayout
}

/// A task's output drawn in 2D over the results picture (`NetworkLayout.tasks`), following its particles as they
/// show: the cat's box, its mask's polygon, the semantic classes' legend, the depth scale, the top classes, the
/// cat's keypoints, or its oriented box beside the axis-aligned one. It fades in once the picture has formed.
final class TaskOutputEffect: Effect {
    enum Output { case box, mask, semantic, depth, classes, keypoints, oriented }

    /// COCO's cat (class 15), in the Ultralytics palette, as the live boxes color it.
    static let catColor = Theme.ultralytics.color(15)
    /// The cat's box on the canvas (its ears to its chin), its confidence.
    static let catBox = CGRect(x: 16, y: 14, width: 68, height: 74)
    static let label = Theme.ultralytics.label("cat", 0.94)
    /// The cat's tilt in the oriented-box step, radians counterclockwise.
    static let tilt: CGFloat = 0.42
    static let semanticClasses: [(name: String, color: NSColor)] = [
        ("sky", .hex("4C8DFF")), ("grass", .hex("3FD16B")), ("cat", .hex("FF3D8B")),
    ]
    static func semanticClass(_ scene: Int) -> Int {
        switch NetworkLayout.Scene(rawValue: scene) {
        case .grass: 1
        case .cat: 2
        default: 0  // the sun is sky
        }
    }
    static let topClasses: [(name: String, confidence: CGFloat)] = [
        ("tabby cat", 0.71), ("tiger cat", 0.14), ("Egyptian cat", 0.08), ("lynx", 0.03), ("Persian cat", 0.01),
    ]
    /// The cat's keypoints on the canvas and the limbs joining them.
    static let keypoints: [CGPoint] = [
        CGPoint(x: 24, y: 88), CGPoint(x: 76, y: 88), CGPoint(x: 38, y: 65), CGPoint(x: 62, y: 65),  // ear tips, ear bases
        CGPoint(x: 39, y: 48.5), CGPoint(x: 61, y: 48.5), CGPoint(x: 50, y: 33), CGPoint(x: 50, y: 15),  // eyes, nose, chin
    ]
    static let limbs = [(0, 2), (1, 3), (2, 3), (2, 4), (3, 5), (4, 6), (5, 6), (6, 7)]

    /// The cat's outline on the canvas, from its class map (rays out of its center: its head is round, its ears
    /// spikes), tilted by `tilt`.
    static func outline(tilt: CGFloat = 0) -> [CGPoint] {
        let n = 200
        let classes = NetworkLayout.catClasses(n, tilt: tilt)
        let center = NetworkLayout.catCenter
        let isCat = { (p: CGPoint) -> Bool in
            let (x, y) = (Int(p.x / 100 * CGFloat(n)), Int((100 - p.y) / 100 * CGFloat(n)))
            return (0..<n).contains(x) && (0..<n).contains(y) && classes[y * n + x] == NetworkLayout.Scene.cat.rawValue
        }
        return (0..<120).map { k in
            let a = CGFloat(k) / 120 * 2 * .pi
            let direction = CGPoint(x: cos(a), y: sin(a))
            var reach: CGFloat = 0
            for step in stride(from: CGFloat(1), through: 60, by: 0.5) {
                if isCat(CGPoint(x: center.x + direction.x * step, y: center.y + direction.y * step)) { reach = step }
            }
            return CGPoint(x: center.x + direction.x * reach, y: center.y + direction.y * reach)
        }
    }
    private static let upright = outline()

    /// A canvas point turned by `tilt` around the cat's center.
    static func turned(_ p: CGPoint, by a: CGFloat) -> CGPoint {
        let c = NetworkLayout.catCenter, (dx, dy) = (p.x - c.x, p.y - c.y)
        return CGPoint(x: c.x + dx * cos(a) - dy * sin(a), y: c.y + dx * sin(a) + dy * cos(a))
    }

    /// Inferno, the depth colormap (as the live depth map): dark purple (far, 0) to pale yellow (near, 1).
    static func inferno(_ t: Float) -> SIMD3<Float> { Palette.inferno(t) }

    private let network: NeuralNetwork
    private let layout: NetworkLayout
    private let output: Output
    private var start: TimeInterval?
    /// Everything it draws, faded in once the picture has formed.
    private let content = SKNode()

    private let box = BoxNode()
    private let oriented = OrientedBoxNode()
    private let shape = SKShapeNode()
    private let dots = SKShapeNode()
    private var texts: [ShadowedLabel] = []
    private var bars: [SKShapeNode] = []
    private let gradient = SKSpriteNode()

    init(_ network: NeuralNetwork, _ layout: NetworkLayout, _ output: Output) {
        (self.network, self.layout, self.output) = (network, layout, output)
        super.init()
        node.addChild(content)
        content.alpha = 0
        for child in [shape, dots, gradient, box, oriented] as [SKNode] { content.addChild(child) }
        let names: [String] = switch output {
        case .semantic: Self.semanticClasses.map(\.name)
        case .classes: Self.topClasses.map { "\($0.name) \(Int($0.confidence * 100))%" }
        case .depth: ["near", "far"]
        default: []
        }
        for name in names {
            let text = ShadowedLabel(name, font: output == .classes ? Theme.ultralytics.labelFont : "GeistMono-Medium")
            (text.label.verticalAlignmentMode, text.label.horizontalAlignmentMode) = (.center, .left)
            texts.append(text)
            if output == .semantic || output == .classes {
                let bar = SKShapeNode()
                bar.lineWidth = 0
                bars.append(bar)
                content.addChild(bar)
            }
            content.addChild(text)
        }
        if output == .depth {
            let colors = (0..<64).map { k -> CGColor in  // near at the top
                let c = Self.inferno(1 - Float(k) / 63)
                return CGColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
            }
            let image = NSImage(size: NSSize(width: 1, height: 64), flipped: false) { rect in
                for (k, color) in colors.enumerated() {
                    NSGraphicsContext.current?.cgContext.setFillColor(color)
                    NSGraphicsContext.current?.cgContext.fill(CGRect(x: 0, y: CGFloat(63 - k), width: 1, height: 1))
                }
                return true
            }
            gradient.texture = SKTexture(image: image)
        }
        gradient.isHidden = output != .depth
    }

    override func update(_ frame: StageFrame) {
        let u = frame.stage.unit
        let system = network.system
        if start == nil { start = frame.time }
        // Once the picture has formed (and arrived, gliding), not while it's scattered.
        let ready = network.formed === layout && system.mode == .form && frame.time - start! > 0.9
            && (!layout.splits || network.split >= 1)
        // Its own fade, on a node of its own: the stage fades `node` in as the step starts.
        content.alpha = content.alpha.approaching(ready ? 1 : 0, CGFloat(1 - exp(-frame.dt * (ready ? 4 : 14))))
        content.isHidden = content.alpha < 0.01
        guard !content.isHidden else { return }
        let stage = { (c: CGPoint) in system.shownPoint(NetworkLayout.resultPoint(c)).point }
        let picture = CGRect(enclosing: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 100)].map(stage))
        let catBox = CGRect(enclosing: [Self.catBox.origin, CGPoint(x: Self.catBox.maxX, y: Self.catBox.maxY)].map(stage))
        let color = Theme.ultralyticsYellow  // as the live boxes
        shape.lineWidth = 2.5 * u

        switch output {
        case .box:
            box.update(to: catBox, text: Self.label, color: color, theme: .ultralytics, unit: u, k: 1)
        case .mask:
            box.update(to: catBox, text: Self.label, color: color, theme: .ultralytics, unit: u, k: 1)
            shape.path = polygon(Self.upright.map(stage))
            (shape.strokeColor, shape.fillColor) = (.white, .clear)
            shape.lineWidth = 2 * u
            // The polygon's vertices, every few.
            let path = CGMutablePath()
            for p in Self.upright.enumerated().filter({ $0.offset % 4 == 0 }).map({ stage($0.element) }) {
                path.addEllipse(in: CGRect(x: p.x - 2.5 * u, y: p.y - 2.5 * u, width: 5 * u, height: 5 * u))
            }
            (dots.path, dots.fillColor, dots.strokeColor) = (path, .white, .clear)
        case .keypoints:
            box.update(to: catBox, text: Self.label, color: color, theme: .ultralytics, unit: u, k: 1)
            let points = Self.keypoints.map(stage)
            let lines = CGMutablePath()
            for (a, b) in Self.limbs {
                lines.move(to: points[a])
                lines.addLine(to: points[b])
            }
            (shape.path, shape.strokeColor, shape.lineWidth) = (lines, NSColor.hex("FF8000"), 3 * u)
            let joints = CGMutablePath()
            for p in points { joints.addEllipse(in: CGRect(x: p.x - 5 * u, y: p.y - 5 * u, width: 10 * u, height: 10 * u)) }
            (dots.path, dots.fillColor, dots.strokeColor, dots.lineWidth) = (joints, NSColor.hex("00D4BB"), .white, 1.5 * u)
        case .oriented:
            let corners = [
                Self.catBox.origin, CGPoint(x: Self.catBox.maxX, y: Self.catBox.minY), CGPoint(x: Self.catBox.maxX, y: Self.catBox.maxY),
                CGPoint(x: Self.catBox.minX, y: Self.catBox.maxY),
            ].map { stage(Self.turned($0, by: Self.tilt)) }
            oriented.update(to: corners, text: Theme.ultralytics.label("cat", 0.92), color: color, theme: .ultralytics, unit: u, k: 1)
        case .semantic, .classes, .depth:
            column(beside: picture, frame: frame)
        }
    }

    /// A closed path through `points`.
    private func polygon(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    /// The legend, the top classes or the depth scale, in a column beside the picture (on its left when there's no
    /// room on its right).
    private func column(beside picture: CGRect, frame: StageFrame) {
        let u = frame.stage.unit
        let width: CGFloat = output == .classes ? 300 * u : output == .depth ? 70 * u : 120 * u
        let gap = 28 * u
        let right = picture.maxX + gap + width < frame.stage.viewSize.width - 16 * u
        let x = right ? picture.maxX + gap : picture.minX - gap - width
        switch output {
        case .depth:
            // The scale: near at the top, far at the bottom, as tall as the picture's middle half.
            let height = picture.height * 0.6
            gradient.size = CGSize(width: 18 * u, height: height)
            gradient.position = CGPoint(x: x + 9 * u, y: picture.midY)
            for (k, text) in texts.enumerated() {
                text.label.set(\.fontSize, 15 * u)
                text.label.horizontalAlignmentMode = .left
                text.position = CGPoint(x: x + 26 * u, y: picture.midY + (k == 0 ? 1 : -1) * (height / 2 - 8 * u))
                text.sync(unit: u)
            }
        default:
            let rows = texts.count
            let step = 34 * u
            for (k, text) in texts.enumerated() {
                let y = picture.midY + (CGFloat(rows - 1) / 2 - CGFloat(k)) * step
                let bar = bars[k]
                if output == .classes {
                    // A bar per class, as long as its confidence (out of 180 points), the name after it.
                    let length = max(Self.topClasses[k].confidence * 180 * u, 4 * u)
                    bar.path = CGPath(roundedRect: CGRect(x: x, y: y - 11 * u, width: length, height: 22 * u), cornerWidth: 5 * u, cornerHeight: 5 * u, transform: nil)
                    bar.fillColor = Self.catColor.withAlphaComponent(k == 0 ? 0.95 : 0.6)
                    text.label.set(\.fontSize, 16 * u)
                    text.position = CGPoint(x: x + length + 8 * u, y: y)
                } else {
                    // A swatch per class, its name beside it.
                    bar.path = CGPath(roundedRect: CGRect(x: x, y: y - 10 * u, width: 20 * u, height: 20 * u), cornerWidth: 4 * u, cornerHeight: 4 * u, transform: nil)
                    bar.fillColor = Self.semanticClasses[k].color
                    text.label.set(\.fontSize, 16 * u)
                    text.position = CGPoint(x: x + 30 * u, y: y)
                }
                text.label.horizontalAlignmentMode = .left
                text.sync(unit: u)
            }
        }
    }
}

extension NSColor {
    /// Its red, green and blue (sRGB, 0...1).
    var rgb: SIMD3<Float> {
        let c = usingColorSpace(.sRGB) ?? self
        return [Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent)]
    }
}
