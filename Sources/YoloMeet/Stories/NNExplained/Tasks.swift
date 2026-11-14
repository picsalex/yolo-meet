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
        guard let from = inference.shape, let corners = picture.pictureCorners else { return layout }
        let cells = resultCells
        let cellOf = pictureCells(of: from, corners: corners, cells: cells).cellOf
        let colors = catDrawing(cells)
        let points = cellOf.map { c -> SIMD3<Float> in
            let x = (Float(c % cells) + .random(in: 0..<1)) / Float(cells), y = (Float(c / cells) + .random(in: 0..<1)) / Float(cells)
            return [(x - 0.5) * resultSide, (0.5 - y) * resultSide, .random(in: -0.004...0.004)]
        }
        layout.shape = ParticleShape(
            points: from.points, offsets: zip(points, from.points).map { $0 - $1 }, parts: [],
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

    /// The part of the cat picture `semanticZoom` zooms into (its canvas, y up): the cat's cheek against the sky, above
    /// the grass, so the three classes meet. `zoomCells` pixels on a side, `zoomSide` in the shape's units.
    static let zoomWindow = CGRect(x: 13, y: 11, width: 24, height: 24)
    static let zoomCells = 12
    static let zoomSide: Float = 2.4

    /// A zoom pixel's center in the shape (column, row from the top).
    static func zoomPoint(_ column: Int, _ row: Int) -> SIMD3<Float> {
        let n = Float(zoomCells)
        return [((Float(column) + 0.5) / n - 0.5) * zoomSide, (0.5 - (Float(row) + 0.5) / n) * zoomSide, 0]
    }

    /// Each zoom pixel's class (`TaskOutputEffect.semanticClasses`), row by row from the top: the cat picture's class
    /// at its center.
    static let zoomClasses: [Int] = {
        let (n, big) = (zoomCells, 200)
        let classes = catClasses(big)
        let w = zoomWindow
        return (0..<n * n).map { cell in
            let cx = w.minX + (CGFloat(cell % n) + 0.5) / CGFloat(n) * w.width
            let cy = w.maxY - (CGFloat(cell / n) + 0.5) / CGFloat(n) * w.height
            let (x, y) = (min(Int(cx / 100 * CGFloat(big)), big - 1), min(Int((100 - cy) / 100 * CGFloat(big)), big - 1))
            return TaskOutputEffect.semanticClass(classes[y * big + x])
        }
    }()

    /// `semantic` zoomed into `zoomWindow`: its pixels become large squares in their class's color (the window's
    /// particles grow into them, the others fly in), so each pixel's class reads; `TaskOutputEffect` writes its ID on it.
    static func semanticZoom(of semantic: NetworkLayout) -> NetworkLayout {
        let (cells, side) = (zoomCells, zoomSide)
        let layout = NetworkLayout(
            title: "A class per pixel", subtitle: "zoomed in · each pixel's class ID, 0 sky, 1 grass, 2 cat",
            neurons: [], synapses: [], neuronSize: 0.02, restingTilt: 0)
        (layout.base, layout.splits, layout.splitsFrom) = (semantic.base ?? semantic, true, semantic)
        let h = side / 2
        layout.outline = [[-h, -h, 0], [h, h, 0], [-h, h, 0], [h, -h, 0]]
        guard let previous = semantic.settled ?? semantic.shape else { return layout }
        // The window's particles grow into its pixels (a few dozen each), each moving the least it can; the rest of
        // the picture turns black (unseen), moves the little it needs to fill the grid evenly, and lights up once
        // there, so each pixel ends up a solid square (the gaps between them showing the grid).
        let n = previous.points.count
        let w = zoomWindow
        var members = [[Int]](repeating: [], count: cells * cells)
        var cellOf = [Int](repeating: -1, count: n)
        for i in 0..<n {
            let p = previous.points[i]
            let (cx, cy) = (CGFloat(p.x / resultSide + 0.5) * 100, CGFloat(p.y / resultSide + 0.5) * 100)
            guard w.contains(CGPoint(x: cx, y: cy)) else { continue }
            let column = min(Int((cx - w.minX) / w.width * CGFloat(cells)), cells - 1)
            let row = min(Int((w.maxY - cy) / w.height * CGFloat(cells)), cells - 1)
            cellOf[i] = row * cells + column
            members[row * cells + column].append(i)
        }
        let inWindow = cellOf.map { $0 >= 0 }
        let fill: Float = 0.9
        // A point of pixel `c` at (fx, fy) in its square (0...1 each, from its top left), toward the viewer by `z`.
        let place = { (c: Int, fx: Float, fy: Float, z: Float) -> SIMD3<Float> in
            let x = (Float(c % cells) + 0.5 + (fx - 0.5) * fill) / Float(cells), y = (Float(c / cells) + 0.5 + (fy - 0.5) * fill) / Float(cells)
            return [(x - 0.5) * side, (0.5 - y) * side, z + .random(in: -0.004...0.004)]
        }
        var points = previous.points
        for (c, ids) in members.enumerated() where !ids.isEmpty {
            // On an even grid of their own, top to bottom in rows, each row left to right: as they sit.
            let slots = Int(Float(ids.count).squareRoot().rounded(.up)), rows = (ids.count + slots - 1) / slots
            let byHeight = ids.sorted { previous.points[$0].y > previous.points[$1].y }
            let sorted = stride(from: 0, to: byHeight.count, by: slots).flatMap {
                byHeight[$0..<min($0 + slots, byHeight.count)].sorted { previous.points[$0].x < previous.points[$1].x }
            }
            for (k, i) in sorted.enumerated() {
                points[i] = place(c, (Float(k % slots) + 0.5) / Float(slots), (Float(k / slots) + 0.5) / Float(rows), 0.01)
            }
        }
        // The rest: into the pixel of the grid (as large as the picture) they're over once the picture closes the
        // window's hole, each particle moving straight away from the window's center by as much as keeps them evenly
        // spread (in a square ring around the window, the area out to it shrinks by the window's): close to it, a few
        // pixels; far from it, barely.
        let center = resultPoint(CGPoint(x: w.midX, y: w.midY))
        let (hole, edge) = (Float(w.width / 200) * resultSide, resultSide / 2)
        for i in 0..<n where !inWindow[i] {
            let d = SIMD2(previous.points[i].x - center.x, previous.points[i].y - center.y)
            let r = max(abs(d.x), abs(d.y))  // square rings: the window's edge is one
            let u = d / max(r, 1e-6)
            let reach = [u.x > 0 ? (edge - center.x) / u.x : u.x < 0 ? (-edge - center.x) / u.x : .infinity,
                         u.y > 0 ? (edge - center.y) / u.y : u.y < 0 ? (-edge - center.y) / u.y : .infinity].min()!
            let closed = reach * ((r * r - hole * hole) / max(reach * reach - hole * hole, 1e-6)).squareRoot()
            let q = SIMD2(center.x, center.y) + u * min(max(closed, 0), reach)
            let (fx, fy) = (min(max(q.x / side + 0.5, 0), 0.9999) * Float(cells), min(max(0.5 - q.y / side, 0), 0.9999) * Float(cells))
            cellOf[i] = Int(fy) * cells + Int(fx)
            points[i] = place(cellOf[i], fx - fx.rounded(.down), fy - fy.rounded(.down), 0)
        }
        let classColor = TaskOutputEffect.semanticClasses.map { $0.color.rgb }
        layout.shape = ParticleShape(
            points: previous.points, offsets: zip(points, previous.points).map { $0 - $1 }, parts: [],
            colors: (0..<n).map { inWindow[$0] ? classColor[zoomClasses[cellOf[$0]]] * zoomGlide : .zero })
        layout.arrivedColors = ParticleColors(cellOf.map { classColor[zoomClasses[$0]] * zoomBrightness })
        return layout
    }

    /// Particle colors in the zoom's squares, all there (hundreds each), and of the few gliding into them first.
    static let zoomBrightness: Float = 1.2
    static let zoomGlide: Float = 6

    /// The seven tasks' layouts on the results picture (detection is `results` itself).
    /// `pause` runs between layouts (e.g. so the app draws meanwhile).
    static func tasks(_ results: NetworkLayout, between pause: () async -> Void = {}) async -> TaskLayouts {
        let n = resultCells
        let classes = catClasses(n)
        let cat = TaskOutputEffect.catColor.rgb * resultBrightness
        let segment = task(results, "Instance segmentation", "a mask per object · its outline as a polygon") { cell, color in
            classes[cell] == Scene.cat.rawValue ? color + (cat - color) * 0.6 : color
        }
        await pause()
        let semantic = task(results, "Semantic segmentation", "a class for every pixel · no separate objects") { cell, _ in
            TaskOutputEffect.semanticClasses[TaskOutputEffect.semanticClass(classes[cell])].color.rgb * resultBrightness
        }
        await pause()
        let classify = task(results, "Image classification", "one class for the whole image, with its confidence")
        await pause()
        let pose = task(results, "Pose estimation", "keypoints per object · e.g. ears, eyes, nose")
        await pause()
        let tilted = catDrawing(n, tilt: TaskOutputEffect.tilt)
        let obb = task(results, "Oriented bounding boxes", "a rotated box fits a tilted object tightly") { cell, _ in
            tilted[cell] * resultBrightness
        }
        await pause()
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
        await pause()
        let depth = task(
            results, "Depth estimation", "how far every pixel is · near bright, far dark", tilt: 0.2, turn: -0.4,
            color: { cell, _ in Palette.inferno(near[cell]) * 1.1 }, depth: { near[$0] * 0.45 })
        await pause()
        let zoom = semanticZoom(of: semantic)
        return TaskLayouts(
            detect: results, segment: segment, semantic: semantic, semanticZoom: zoom, classify: classify,
            pose: pose, obb: obb, depth: depth)
    }
}

/// The tasks' layouts, in the story's order.
struct TaskLayouts {
    let detect, segment, semantic, semanticZoom, classify, pose, obb, depth: NetworkLayout
    /// The seven tasks, with their names.
    var all: [(name: String, layout: NetworkLayout)] {
        [("Detect", detect), ("Segment", segment), ("Semantic", semantic), ("Classify", classify), ("Pose", pose),
         ("OBB", obb), ("Depth", depth)]
    }
}

/// The recap: the cat picture on top, an arrow down into YOLO, and arrows splitting from it to the seven tasks'
/// outputs in a row, each a small copy of its step's picture.
extension NetworkLayout {
    static let recapPicture = (center: SIMD3<Float>(0, 0.95, 0), side: Float(0.72))
    static let recapModel = (center: SIMD3<Float>(0, -0.15, 0), scale: Float(0.42))
    static let recapThumbSide: Float = 0.5
    static func recapThumb(_ k: Int) -> SIMD3<Float> { [Float(k - 3) * 0.62, -1.3, 0] }
    /// Particles in the picture and in each output (the rest make the model).
    static let recapCopy = 5_500 * NeuralNetwork.scale

    /// From `tasks.depth` (the last task's picture), in two glides: first the picture, whole, to the input's place on top
    /// (its `prelude`, in the input's colors); then out of it, each particle to the same place in one of the seven
    /// tasks' small pictures (colored as in its step, so each comes down as a picture, through the model, splitting
    /// to its place), or into the model, shrunk; an eighth stays as the input.
    static func recap(_ tasks: TaskLayouts, architecture: NetworkLayout) -> NetworkLayout {
        let layout = NetworkLayout(
            title: "Conclusion", subtitle: "one image in · one YOLO model · 7 tasks out",
            neurons: [], synapses: [], neuronSize: 0.02, restingTilt: 0)
        layout.splits = true
        let picture = recapPicture, model = recapModel, side = recapThumbSide
        // The model's extent, shrunk, for the arrows.
        let ys = architecture.outline.map { $0.y * model.scale + model.center.y }
        let (modelTop, modelBottom) = (ys.max()!, ys.min()!)
        let modelRight = architecture.outline.map { $0.x * model.scale + model.center.x }.max()!
        let pictureBottom = picture.center.y - picture.side / 2
        layout.arrows = [("", [0, pictureBottom - 0.05, 0], [0, modelTop + 0.06, 0])]
            + (0..<7).map { k in ("", [0, modelBottom - 0.05, 0], recapThumb(k) + [0, side / 2 + 0.05, 0]) }
        layout.headers = tasks.all.enumerated().map { k, task in (task.name, recapThumb(k) - [0, side / 2 + 0.05, 0], []) }
            // Beside the model, centered on it (headers hang from their point, so a little above the middle).
            + [("YOLO", [modelRight + 0.3, (modelTop + modelBottom) / 2 + 0.03, model.center.z], [])]
        layout.brace = (modelRight + 0.05, modelTop + 0.02, modelBottom - 0.02, model.center.z)
        layout.headerSize = 19
        layout.outline = [picture.center + [picture.side / 2, picture.side / 2, 0], recapThumb(0) - [side / 2, side / 2 + 0.15, 0],
                          recapThumb(6) + [side / 2, -side / 2 - 0.15, 0], picture.center - [picture.side / 2, -picture.side / 2, 0]]
        guard let from = tasks.depth.settled, let blocks = architecture.shape else { return layout }
        let n = from.points.count
        // Light adds up: denser copies get dimmer colors, so they look as bright as the large picture.
        let dim = { (count: Int, side: Float) -> Float in
            min(Float(n) / (resultSide * resultSide) / (Float(count) / (side * side)), 1)
        }
        let sources = [tasks.detect] + tasks.all.map(\.layout)
        let centers = [picture.center] + (0..<7).map(recapThumb)
        let sides = [picture.side] + Array(repeating: side, count: 7)
        let order = Array(0..<n).shuffled()
        // First: every particle to its place in the input picture.
        let inputScale = picture.side / resultSide
        let input = from.points.map { p -> SIMD3<Float> in
            var q = p * inputScale
            q.z = .random(in: -0.002...0.002)
            return picture.center + q
        }
        let prelude = NetworkLayout(title: layout.title, subtitle: layout.subtitle, neurons: [], synapses: [], neuronSize: 0.02, restingTilt: 0)
        (prelude.splits, prelude.splitsFrom, prelude.outline) = (true, tasks.depth, layout.outline)
        let inputColors = (tasks.detect.settled ?? tasks.detect.shape)?.colors.map { $0.map { $0 * dim(n, picture.side) * 1.3 } }
        prelude.shape = ParticleShape(
            points: from.points, offsets: zip(input, from.points).map { $0 - $1 }, parts: [],
            colors: inputColors ?? Array(repeating: nil, count: n))
        (layout.prelude, layout.splitsFrom) = (prelude, prelude)
        var points = input, colors = [SIMD3<Float>?](repeating: nil, count: n)
        for (copy, source) in sources.enumerated() {
            guard let shape = source.settled ?? source.shape else { continue }
            let scale = sides[copy] / resultSide
            let brightness = dim(recapCopy, sides[copy]) * 1.3
            for i in order[copy * recapCopy..<min((copy + 1) * recapCopy, n)] {
                var p = shape.points[i] * scale
                p.z = p.z * 0.5 + .random(in: -0.002...0.002)
                points[i] = centers[copy] + p
                colors[i] = shape.colors[i].map { $0 * brightness }
            }
        }
        // The model: the architecture's blocks and connections (not its dust), shrunk, from as many of its particles.
        let solid = blocks.parts.indices.filter { blocks.parts[$0] != dustPart }.shuffled()
        for (k, i) in order[min(8 * recapCopy, n)...].enumerated() {
            points[i] = recapModel.center + blocks.points[solid[k % solid.count]] * recapModel.scale
        }
        // On the way, dim (they all leave the input together, adding up) and the model's unseen; lit once there.
        let inModel = Set(order[min(8 * recapCopy, n)...])
        let onTheWay = (0..<n).map { i -> SIMD3<Float>? in inModel.contains(i) ? .zero : colors[i].map { $0 * 0.3 } }
        layout.shape = ParticleShape(
            points: input, offsets: zip(points, input).map { $0 - $1 }, parts: [], colors: onTheWay)
        layout.arrivedColors = ParticleColors(colors)
        return layout
    }
}

/// A task's output drawn in 2D over the results picture (`NetworkLayout.tasks`), following its particles as they
/// show: the cat's box, its mask's polygon, the semantic classes' legend, the depth scale, the top classes, the
/// cat's keypoints, or its oriented box beside the axis-aligned one. It fades in once the picture has formed.
final class TaskOutputEffect: Effect {
    enum Output { case box, mask, semantic, pixelClasses, depth, classes, keypoints, oriented }

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
    /// spikes).
    static func outline() -> [CGPoint] {
        let n = 200
        let classes = NetworkLayout.catClasses(n)
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
    static let upright = outline()

    /// A canvas point turned by `tilt` around the cat's center.
    static func turned(_ p: CGPoint, by a: CGFloat) -> CGPoint {
        let c = NetworkLayout.catCenter, (dx, dy) = (p.x - c.x, p.y - c.y)
        return CGPoint(x: c.x + dx * cos(a) - dy * sin(a), y: c.y + dx * sin(a) + dy * cos(a))
    }

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
    /// The zoom's class IDs, one per pixel; the square sweeping over them as they show; the pixel pointed at, its class.
    private var ids: [SKLabelNode] = []
    private let scan = SKShapeNode()
    private let pointed = SKShapeNode()
    private let pointedInfo = ShadowedLabel("", font: "GeistMono-Medium")
    private let pointedChip = SKShapeNode()
    private var readySince: TimeInterval?
    /// How long the IDs take to show, pixel after pixel, as the model labels them.
    static let scanDuration: TimeInterval = 2.4

    init(_ network: NeuralNetwork, _ layout: NetworkLayout, _ output: Output) {
        (self.network, self.layout, self.output) = (network, layout, output)
        super.init()
        node.addChild(content)
        content.alpha = 0
        for child in [shape, dots, gradient, box, oriented] as [SKNode] { content.addChild(child) }
        let names: [String] = switch output {
        case .semantic: Self.semanticClasses.map(\.name)
        case .pixelClasses: Self.semanticClasses.enumerated().map { "\($0.offset)  \($0.element.name)" }
        case .classes: Self.topClasses.map { "\($0.name) \(Int($0.confidence * 100))%" }
        case .depth: ["near", "far"]
        default: []
        }
        for name in names {
            let text = ShadowedLabel(name, font: output == .classes ? Theme.ultralytics.labelFont : "GeistMono-Medium")
            (text.label.verticalAlignmentMode, text.label.horizontalAlignmentMode) = (.center, .left)
            texts.append(text)
            if output == .semantic || output == .pixelClasses || output == .classes {
                let bar = SKShapeNode()
                bar.lineWidth = 0
                bars.append(bar)
                content.addChild(bar)
            }
            content.addChild(text)
        }
        if output == .depth {
            let scale = CGContext.bitmap(width: 1, height: 64)
            for k in 0..<64 {  // near at the top
                let c = Palette.inferno(1 - Float(k) / 63)
                scale.setFillColor(CGColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1))
                scale.fill(CGRect(x: 0, y: 63 - k, width: 1, height: 1))
            }
            gradient.texture = SKTexture(cgImage: scale.makeImage()!)
        }
        gradient.isHidden = output != .depth
        if output == .pixelClasses {
            for cell in NetworkLayout.zoomClasses {
                let id = SKLabelNode(fontNamed: "GeistMono-Medium")
                (id.text, id.verticalAlignmentMode, id.horizontalAlignmentMode, id.alpha) = ("\(cell)", .center, .center, 0)
                ids.append(id)
                content.addChild(id)
            }
            (scan.lineWidth, scan.fillColor) = (0, NSColor(white: 1, alpha: 0.35))
            pointed.fillColor = .clear
            pointed.strokeColor = .white
            content.addChild(scan)
            content.addChild(pointed)
            (pointedChip.fillColor, pointedChip.lineWidth) = (NSColor(white: 0, alpha: 0.8), 0)
            content.addChild(pointedChip)
            content.addChild(pointedInfo)
            (pointedInfo.label.verticalAlignmentMode, pointedInfo.label.horizontalAlignmentMode) = (.center, .left)
        }
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
        if ready { readySince = readySince ?? frame.time } else { readySince = nil }
        guard !content.isHidden else { return }
        if output == .pixelClasses { return pixelClasses(frame) }
        let stage = { (c: CGPoint) in system.shownPoint(NetworkLayout.resultPoint(c)).point }
        let picture = CGRect(enclosing: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 100)].map(stage))
        let catBox = CGRect(enclosing: [Self.catBox.origin, CGPoint(x: Self.catBox.maxX, y: Self.catBox.maxY)].map(stage))
        let color = Theme.ultralyticsYellow
        shape.set(\.lineWidth, (output == .mask ? 2 : output == .keypoints ? 3 : 2.5) * u)

        switch output {
        case .box:
            box.update(to: catBox, text: Self.label, color: color, theme: .ultralytics, unit: u, k: 1)
        case .mask:
            box.update(to: catBox, text: Self.label, color: color, theme: .ultralytics, unit: u, k: 1)
            shape.path = CGPath.closed(Self.upright.map(stage))
            shape.set(\.strokeColor, .white)
            shape.set(\.fillColor, .clear)
            // The polygon's vertices, every few.
            let path = CGMutablePath()
            for p in Self.upright.enumerated().filter({ $0.offset % 4 == 0 }).map({ stage($0.element) }) {
                path.addEllipse(in: CGRect(x: p.x - 2.5 * u, y: p.y - 2.5 * u, width: 5 * u, height: 5 * u))
            }
            dots.path = path
            dots.set(\.fillColor, .white)
            dots.set(\.strokeColor, .clear)
        case .keypoints:
            box.update(to: catBox, text: Self.label, color: color, theme: .ultralytics, unit: u, k: 1)
            let skeleton = Self.skeleton(stage, joint: 5 * u)
            (shape.path, dots.path) = (skeleton.limbs, skeleton.joints)
            shape.set(\.strokeColor, NNColors.limb)
            dots.set(\.fillColor, NNColors.joint)
            dots.set(\.strokeColor, .white)
            dots.set(\.lineWidth, 1.5 * u)
        case .oriented:
            let corners = Self.catBoxCorners(tilt: Self.tilt).map(stage)
            oriented.update(to: corners, text: Theme.ultralytics.label("cat", 0.92), color: color, theme: .ultralytics, unit: u, k: 1)
        case .semantic, .classes, .depth:
            column(beside: picture, frame: frame)
        case .pixelClasses:
            break
        }
    }

    /// The zoom's class IDs, written on their pixels one after the other (row by row, a square sweeping over them), its
    /// legend beside; with Space held, the pixel a fingertip points at outlined, with its place and class.
    private func pixelClasses(_ frame: StageFrame) {
        let u = frame.stage.unit
        let system = network.system
        let n = NetworkLayout.zoomCells
        let h = NetworkLayout.zoomSide / 2
        let corners = [SIMD3<Float>(-h, -h, 0), [h, -h, 0], [h, h, 0], [-h, h, 0]].map { system.shownPoint($0).point }
        column(beside: CGRect(enclosing: corners), frame: frame)
        let pitch = corners[0].distance(to: corners[1]) / CGFloat(n)
        let elapsed = frame.time - (readySince ?? frame.time)
        let reached = elapsed / Self.scanDuration * Double(ids.count)  // pixels labeled so far
        for (k, id) in ids.enumerated() {
            id.position = system.shownPoint(NetworkLayout.zoomPoint(k % n, k / n)).point
            id.set(\.fontSize, pitch * 0.5)
            id.alpha = CGFloat(min(max(reached - Double(k), 0), 1)) * 0.95
        }
        // The square over the pixel being labeled, gone once all are.
        let current = Int(reached)
        scan.isHidden = current >= ids.count
        if !scan.isHidden {
            let c = system.shownPoint(NetworkLayout.zoomPoint(current % n, current / n)).point
            scan.path = CGPath(rect: CGRect(x: c.x - pitch / 2, y: c.y - pitch / 2, width: pitch, height: pitch), transform: nil)
        }

        // The pointed pixel: the fingertip's place in the grid (the picture faces the viewer, so a plane's corners do).
        var hit: Int?
        if frame.keys.held.contains("space") {
            for pointer in frame.pointers {
                let (o, x, y) = (corners[3], corners[2], corners[0])  // top left, top right, bottom left
                let (ax, ay) = (CGVector(dx: x.x - o.x, dy: x.y - o.y), CGVector(dx: y.x - o.x, dy: y.y - o.y))
                let d = CGVector(dx: pointer.location.x - o.x, dy: pointer.location.y - o.y)
                let det = ax.dx * ay.dy - ax.dy * ay.dx
                guard abs(det) > 1 else { continue }
                let (fx, fy) = ((d.dx * ay.dy - d.dy * ay.dx) / det, (ax.dx * d.dy - ax.dy * d.dx) / det)
                guard (0..<1).contains(fx), (0..<1).contains(fy) else { continue }
                hit = Int(fy * CGFloat(n)) * n + Int(fx * CGFloat(n))
                frame.pointing.mark(pointer.hand)
                break
            }
        }
        pointed.isHidden = hit == nil
        pointedInfo.isHidden = hit == nil
        pointedChip.isHidden = hit == nil
        guard let hit else { return }
        let c = system.shownPoint(NetworkLayout.zoomPoint(hit % n, hit / n)).point
        pointed.path = CGPath(rect: CGRect(x: c.x - pitch / 2, y: c.y - pitch / 2, width: pitch, height: pitch), transform: nil)
        pointed.lineWidth = 3 * u
        let name = Self.semanticClasses[NetworkLayout.zoomClasses[hit]].name
        pointedInfo.label.set(\.text, "pixel (\(hit % n), \(hit / n)) → \(NetworkLayout.zoomClasses[hit]) \(name)")
        pointedInfo.label.set(\.fontSize, 16 * u)
        // On a dark chip beside the pixel, over the grid.
        let pad = 8 * u
        pointedInfo.position = CGPoint(x: c.x + pitch / 2 + 6 * u + pad, y: c.y)
        pointedInfo.sync(unit: u)
        let size = pointedInfo.label.frame.size
        pointedChip.path = CGPath(
            roundedRect: CGRect(x: c.x + pitch / 2 + 6 * u, y: c.y - size.height / 2 - pad / 2, width: size.width + 2 * pad, height: size.height + pad),
            cornerWidth: 5 * u, cornerHeight: 5 * u, transform: nil)
    }

    /// The cat box's corners on the canvas (0...100), turned by `tilt` around the cat's center
    /// (`NetworkLayout.catCenter`, as the tilted cat is drawn).
    static func catBoxCorners(tilt: CGFloat = 0) -> [CGPoint] {
        [catBox.origin, CGPoint(x: catBox.maxX, y: catBox.minY), CGPoint(x: catBox.maxX, y: catBox.maxY), CGPoint(x: catBox.minX, y: catBox.maxY)]
            .map { tilt == 0 ? $0 : turned($0, by: tilt) }
    }

    /// The cat's pose skeleton, its canvas points placed by `place`: the limbs as lines, the joints as discs of radius
    /// `joint`. Shared by the pose step and the recap, so they draw the same cat.
    static func skeleton(_ place: (CGPoint) -> CGPoint, joint: CGFloat) -> (limbs: CGPath, joints: CGPath) {
        let points = keypoints.map(place)
        let limbs = CGMutablePath(), joints = CGMutablePath()
        for (a, b) in self.limbs {
            limbs.move(to: points[a])
            limbs.addLine(to: points[b])
        }
        for p in points { joints.addEllipse(in: CGRect(x: p.x - joint, y: p.y - joint, width: 2 * joint, height: 2 * joint)) }
        return (limbs, joints)
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
                text.label.set(\.horizontalAlignmentMode, .left)
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
                text.label.set(\.horizontalAlignmentMode, .left)
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

/// The recap's outputs drawn over their small pictures, as in their steps but thin: the cat's box (detect), its
/// outline (segment), its top class (classify), its skeleton (pose), its rotated box (OBB). It fades in once the
/// particles have arrived.
final class RecapEffect: Effect {
    private let network: NeuralNetwork
    private let layout: NetworkLayout
    private let content = SKNode()
    private let boxes = SKShapeNode()
    private let outline = SKShapeNode()
    private let limbs = SKShapeNode()
    private let joints = SKShapeNode()
    private let brace = SKShapeNode()
    private let topClass = ShadowedLabel("tabby cat 71%", font: Theme.ultralytics.labelFont)

    init(_ network: NeuralNetwork, _ layout: NetworkLayout) {
        (self.network, self.layout) = (network, layout)
        super.init()
        node.addChild(content)
        content.alpha = 0
        for child in [boxes, outline, limbs, joints, brace, topClass] as [SKNode] { content.addChild(child) }
        (boxes.strokeColor, boxes.fillColor) = (Theme.ultralyticsYellow, .clear)
        (outline.strokeColor, outline.fillColor) = (.white, .clear)
        (limbs.strokeColor, joints.fillColor, joints.strokeColor) = (NNColors.limb, NNColors.joint, .clear)
        (topClass.label.verticalAlignmentMode, topClass.label.horizontalAlignmentMode) = (.top, .center)
        (brace.strokeColor, brace.fillColor, brace.lineCap, brace.lineJoin) = (.white, .clear, .round, .round)
    }

    override func update(_ frame: StageFrame) {
        let u = frame.stage.unit
        let system = network.system
        let ready = network.formed === layout && system.mode == .form && network.split >= 1
        content.alpha = content.alpha.approaching(ready ? 1 : 0, CGFloat(1 - exp(-frame.dt * (ready ? 3 : 14))))
        content.isHidden = content.alpha < 0.01
        guard !content.isHidden else { return }
        // A point of the cat picture's canvas in output `k`'s small picture, on stage.
        let side = NetworkLayout.recapThumbSide
        let at = { (k: Int, c: CGPoint) -> CGPoint in
            system.shownPoint(NetworkLayout.recapThumb(k) + [(Float(c.x) / 100 - 0.5) * side, (Float(c.y) / 100 - 0.5) * side, 0]).point
        }
        // The detect box, and the OBB step's turned one.
        let paths = CGMutablePath()
        paths.addPath(CGPath.closed(TaskOutputEffect.catBoxCorners().map { at(0, $0) }))
        paths.addPath(CGPath.closed(TaskOutputEffect.catBoxCorners(tilt: TaskOutputEffect.tilt).map { at(5, $0) }))
        (boxes.path, boxes.lineWidth) = (paths, 2 * u)

        (outline.path, outline.lineWidth) = (CGPath.closed(TaskOutputEffect.upright.map { at(1, $0) }), 1.5 * u)

        let skeleton = TaskOutputEffect.skeleton({ at(4, $0) }, joint: 3 * u)
        (limbs.path, limbs.lineWidth, joints.path) = (skeleton.limbs, 2 * u, skeleton.joints)

        // A "}" spanning the model, its tip toward "YOLO".
        if let b = layout.brace {
            let top = system.shownPoint([b.x, b.top, b.z]).point, bottom = system.shownPoint([b.x, b.bottom, b.z]).point
            let (w, mid) = (0.07 * (top.y - bottom.y), (top.y + bottom.y) / 2)
            let r = min(w, (top.y - bottom.y) / 4), (x, spine) = (top.x, top.x + w / 2)
            let curl = CGMutablePath()
            curl.move(to: top)
            curl.addQuadCurve(to: CGPoint(x: spine, y: top.y - r), control: CGPoint(x: spine, y: top.y))
            curl.addLine(to: CGPoint(x: spine, y: mid + r))
            curl.addQuadCurve(to: CGPoint(x: x + w, y: mid), control: CGPoint(x: spine, y: mid))
            curl.addQuadCurve(to: CGPoint(x: spine, y: mid - r), control: CGPoint(x: spine, y: mid))
            curl.addLine(to: CGPoint(x: spine, y: bottom.y + r))
            curl.addQuadCurve(to: bottom, control: CGPoint(x: spine, y: bottom.y))
            (brace.path, brace.lineWidth) = (curl, 2 * u)
        }

        // The top class over the classify picture's top.
        topClass.label.set(\.fontSize, 13 * u)
        topClass.position = at(3, CGPoint(x: 50, y: 97))
        topClass.sync(unit: u)
    }
}
