import SpriteKit
import simd

/// A network made of particles (`NetworkLayout`: a brain, a perceptron, YOLO's architecture): neurons are small balls, synapses lines. It
/// forms at once, its particles flying from wherever the story's particles are (the previous step's layout); without a
/// layout, they swirl as a cloud (on the right third of the stage at first). A fist closed on the particles gathers them
/// into a ball that follows the fist; opening the hand forms the layout there, or, on the cloud alone, moves the story to
/// its next step (`frame.nextStep`), which forms there. Both hands pinching zoom (around the point between them, to look inside) when they move apart or closer, and move it
/// when they move together; one hand pinching moves it too. A fist on it breaks it again (fists need Command held). Keys:
/// R turns a slow spin on or off (off at first), Q/D turn and Z/S tilt while held, 0 resets the view.
///
/// Action mode (Space held): the neuron a fingertip touches grows its particles and shows as a neuron, a disc with a
/// ring and its bias inside, described beside it ("neuron - bias …"); a synapse a fingertip touches lights up with its
/// weight in its middle. Nothing else shows values. 2D content follows the particles as they show
/// (`ParticleSystem.shownPoint`), so it stays on them when the network moves.
final class NetworkEffect: Effect {
    /// Half the layout's size on stage at zoom 1 and unit 1.
    static let size: CGFloat = 170
    /// The touched neuron's smallest radius on stage (at unit 1), so its value reads at any zoom.
    static let focusRadius: CGFloat = 20

    private let network: NeuralNetwork
    /// Nil: only the cloud.
    private let layout: NetworkLayout?
    private var system: ParticleSystem { network.system }
    /// One per neuron: grows it while pointed at.
    private let items: [Actionable]
    /// Where the neurons are on stage this frame (as the particles show them), their depth (-1 back, 1 front) and radius.
    private var onStage: [(point: CGPoint, depth: Float, radius: CGFloat)] = []

    /// Where the cloud or network is, in stage points; nil until the first frame places it where the previous step left it.
    private var home: CGPoint?
    private var zoom: CGFloat = 1
    private var shown: (home: CGPoint, zoom: CGFloat)?
    private var base: (home: CGPoint, zoom: CGFloat) = (.zero, 1)
    /// When the layout formed; nil while the particles are a cloud.
    private var formed: TimeInterval?
    /// Forms the layout on the first frame it's ready.
    private var formNow = true
    /// Whether the current gesture started on the particles.
    private let grip = Grip()
    private var turning: KeyTurn

    private let labels = SKNode()
    private let title: ObjectTitle
    /// The touched neuron's or block's description, in a column beside the whole layout, a line to it.
    private let neuronInfo = Callouts([""], font: "Archivo-SemiBold", size: 20, line: NetworkEffect.gold.withAlphaComponent(0.85))
    /// The layout's headers (e.g. under its columns).
    private let headers: [ShadowedLabel]
    /// Gold outlines of the touched blocks (a block, or all of a touched header's).
    private let outlines = SKShapeNode()
    /// The touched neuron, drawn as one: a disc with a ring, its bias inside.
    private let focus = SKSpriteNode(texture: NetworkEffect.disc, size: CGSize(width: 64, height: 64))
    private let focusValue = SKLabelNode(fontNamed: "GeistMono-Medium")
    private let line = SKSpriteNode(color: NetworkEffect.gold, size: CGSize(width: 1, height: 1))
    private let weight = ShadowedLabel("", font: "GeistMono-Medium", color: NetworkEffect.gold)
    /// The neuron and synapse last described, so their labels fade out in place.
    private var described: (neuron: Int?, synapse: Int?) = (nil, nil)

    private static let gold = NSColor(red: 1, green: 0.78, blue: 0.22, alpha: 1)
    /// A neuron's look: a white disc with a blue ring, 64 points across.
    private static let disc: SKTexture = {
        let (size, width) = (128, CGFloat(10))
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rect = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: width / 2 + 2, dy: width / 2 + 2)
        context.setFillColor(.white)
        context.fillEllipse(in: rect)
        context.setStrokeColor(CGColor(red: 0.3, green: 0.75, blue: 1, alpha: 1))
        context.setLineWidth(width)
        context.strokeEllipse(in: rect)
        return SKTexture(cgImage: context.makeImage()!)
    }()

    init(_ network: NeuralNetwork, _ layout: NetworkLayout?) {
        (self.network, self.layout) = (network, layout)
        items = layout?.neurons.map { _ in Actionable(grown: layout!.grown) } ?? []
        turning = KeyTurn(
            restingTilt: layout?.restingTilt ?? 0, restingTurn: layout?.restingTurn ?? 0, autoSpeed: 0.25, spinning: false)
        headers = layout?.headers.map { ShadowedLabel($0.text, font: Theme.titleFont) } ?? []
        title = ObjectTitle(layout?.title ?? "", subtitle: layout?.subtitle ?? "")
        super.init()
        particles = network.system

        (focusValue.fontSize, focusValue.fontColor, focusValue.verticalAlignmentMode) = (17, Theme.darkBlue, .center)
        focus.addChild(focusValue)
        focus.isHidden = true
        line.anchorPoint = CGPoint(x: 0, y: 0.5)
        line.isHidden = true
        (focus.zPosition, neuronInfo.zPosition, weight.zPosition, outlines.zPosition) = (10, 20, 20, 15)
        outlines.strokeColor = Self.gold
        weight.label.verticalAlignmentMode = .bottom
        weight.alpha = 0
        for child in [line, focus, outlines, neuronInfo, weight] + headers { labels.addChild(child) }
        labels.alpha = 0
        node.addChild(labels)
        node.addChild(title)
    }

    override func update(_ frame: StageFrame) {
        let u = frame.stage.unit
        let start = CGPoint(x: frame.stage.viewSize.width * 2 / 3, y: frame.stage.viewSize.height / 2)
        // Where the previous step left the particles, back on stage (a zoomed-in center can be off it).
        let stage = CGRect(origin: .zero, size: frame.stage.viewSize).insetBy(dx: 80 * u, dy: 80 * u)
        var home = self.home ?? network.home.map { CGPoint(x: min(max($0.x, stage.minX), stage.maxX), y: min(max($0.y, stage.minY), stage.maxY)) } ?? start
        let cloud = 220 * u

        if formNow, let shape = layout?.shape { form(shape, frame) }
        if layout == nil, system.mode == .form { system.scatter(kick: 0.6) }  // back from a layout
        let reach = formed != nil ? 1.2 * Self.size * u * zoom : 1.1 * cloud
        if let gesture = grip.update(frame, isOn: { home.distance(to: $0) < reach }) {
            if gesture.phase == .began { base = (home, zoom) }
            switch gesture.kind {
            case let .fist(location):
                if gesture.phase == .began {
                    system.scatter(kick: formed != nil ? 1 : 0.4)
                    formed = nil
                }
                home = location
                if gesture.phase == .ended {
                    if let shape = layout?.shape { form(shape, frame) }  // at its zoom
                    if layout == nil { frame.nextStep() }  // the cloud, gathered and let go: on to the next step
                }
            case let .drag(start, location) where formed != nil:
                home = CGPoint(x: base.home.x + location.x - start.x, y: base.home.y + location.y - start.y)
            case let .zoom(scale, center) where formed != nil:
                // Around the point between the hands, which stays where it is: zoom in on a part to look inside it.
                zoom = min(max(base.zoom * scale, 0.5), 12)
                let k = zoom / base.zoom
                home = CGPoint(x: center.x + (base.home.x - center.x) * k, y: center.y + (base.home.y - center.y) * k)
            default: break
            }
        }
        turning.update(frame)
        if frame.keys.pressed.contains("0") { (home, zoom) = (start, 1) }
        (self.home, network.home) = (home, home)

        let k = frame.smoothing
        let now: (home: CGPoint, zoom: CGFloat) = shown.map { ($0.home.approaching(home, k), $0.zoom.approaching(zoom, k)) } ?? (home, zoom)
        shown = now
        var gathering = false
        if grip.held, case .fist = frame.gesture?.kind { gathering = true }
        system.center = now.home
        system.radius = gathering ? 70 * u : cloud
        system.size = Self.size * u * now.zoom * grip.scale
        system.rotation = turning.rotation
        system.pointSize = 3 * Float(max(now.zoom, 1)).squareRoot()  // so the network still reads, zoomed in
        system.follow(time: frame.time, dt: frame.dt)

        // Labels once the particles have mostly landed; they go at once with a fist.
        let lit = formed.map { frame.time - $0 > 0.8 } ?? false
        labels.alpha = labels.alpha.approaching(lit ? 1 : 0, CGFloat(1 - exp(-frame.dt * (lit ? 3 : 14))))
        labels.isHidden = labels.alpha < 0.01
        guard let layout, !labels.isHidden else {
            title.update(beside: .zero, visible: false, frame: frame)
            system.highlight = nil
            return
        }
        let bounds = CGRect(enclosing: layout.outline.map { system.shownPoint($0).point })
        title.update(beside: bounds, visible: now.zoom < 1.6, frame: frame)
        for (label, header) in zip(headers, layout.headers) {
            label.label.set(\.fontSize, 24 * u)
            label.label.verticalAlignmentMode = .top
            label.position = system.shownPoint(header.point).point
            label.sync(unit: u)
        }
        updateNetwork(frame, layout, bounds: bounds)
    }

    private func form(_ shape: ParticleShape, _ frame: StageFrame) {
        system.form(shape)
        (formed, formNow) = (frame.time, false)
    }

    /// `bounds`: the whole layout on stage.
    private func updateNetwork(_ frame: StageFrame, _ layout: NetworkLayout, bounds: CGRect) {
        let u = frame.stage.unit
        onStage = zip(layout.neurons, items).map { neuron, item in
            let (point, depth) = system.shownPoint(neuron.point)
            return (point, depth, CGFloat(layout.reach(neuron)) * system.size * item.scale)
        }
        // Blocks: their 8 corners on stage (at their grown size), and the outline around them, which the whole box
        // (front, sides, depth) is inside.
        let corners: [[CGPoint]?] = zip(layout.neurons, items).map { neuron, item in
            neuron.box.map { box in
                let half = box * Float(item.scale)
                return (0..<8).map { k in
                    system.shownPoint(neuron.point + half * SIMD3(k & 1 == 0 ? -1 : 1, k & 2 == 0 ? -1 : 1, k & 4 == 0 ? -1 : 1)).point
                }
            }
        }
        let hulls = corners.map { $0.map(convexHull) }

        // Action mode: per fingertip, the nearest neuron (or block) its touch circle reaches, else the nearest synapse.
        let reach = Pointer.reach * u
        let touches = { (i: Int, p: CGPoint) -> Bool in
            guard let hull = hulls[i] else { return self.onStage[i].point.distance(to: p) < self.onStage[i].radius + reach }
            return p.isInside(hull) || hull.indices.contains { segmentDistance(p, hull[$0], hull[($0 + 1) % hull.count]) < reach }
        }
        var pointedNeurons = Set<Int>()
        var pointedSynapse: Int?
        var pointedHeaders = Set<Int>()
        if frame.keys.held.contains("space") || frame.keys.released.contains("space") {
            for pointer in frame.pointers {
                if let h = headers.indices.first(where: {
                    headers[$0].calculateAccumulatedFrame().insetBy(dx: -reach, dy: -reach).contains(pointer.location)
                }) {
                    pointedHeaders.insert(h)
                    frame.pointing.mark(pointer.hand)
                    continue
                }
                let gap = { (i: Int) in self.onStage[i].point.distance(to: pointer.location) }
                if let i = onStage.indices.filter({ touches($0, pointer.location) }).min(by: { gap($0) < gap($1) }) {
                    pointedNeurons.insert(i)
                } else if let s = layout.synapses.indices.filter({ layout.synapses[$0].weight != nil })
                    .min(by: { distance(pointer.location, $0) < distance(pointer.location, $1) }),
                    distance(pointer.location, s) < reach {
                    pointedSynapse = s
                    frame.pointing.mark(pointer.hand)
                }
            }
        }
        for (i, item) in items.enumerated() {
            _ = item.update(frame, isOn: pointedNeurons.contains(i) ? { touches(i, $0) } : nil)
        }
        // The neuron grown most (one at a time) grows its particles.
        let grown = items.indices.max { items[$0].scale < items[$1].scale }!
        system.highlight = items[grown].scale > 1.001 ? (grown + 1, layout.neurons[grown].point, Float(items[grown].scale)) : nil

        // The touched neuron as a disc with its bias, popping in as it grows (and out as it shrinks back), at least
        // `focusRadius`; its description on the right, the line ending at the disc's edge. A block shows what it is.
        if let i = pointedNeurons.min() {
            described.neuron = i
            let neuron = layout.neurons[i]
            neuronInfo.setText(neuron.info ?? String(format: "neuron - bias %+.2f", neuron.bias), at: 0)
            focusValue.set(\.text, String(format: "%+.2f", neuron.bias))
        }
        // Its description in a column beside the whole layout, on the part's side (or the other one when it wouldn't
        // fit on stage), a line to the block's nearest corner (or the disc's edge) on that side; with no room beside
        // the layout (zoomed in), beside the block itself.
        var anchor: CGPoint?
        var around = bounds
        var left: Bool?
        if let i = described.neuron {
            let item = items[i]
            let shown = min(max((item.scale - 1) / (item.grown - 1), 0), 1)
            let block = layout.neurons[i].info != nil
            let radius = block ? onStage[i].radius : max(onStage[i].radius + 2 * u, Self.focusRadius * u) * shown
            focus.isHidden = block || shown < 0.01
            focus.position = onStage[i].point
            focus.setScale(radius / 32)
            let center = onStage[i].point
            left = neuronInfo.side(of: 0, anchor: center, around: bounds, frame: frame)
            if left == nil {
                around = corners[i].map { CGRect(enclosing: $0) }
                    ?? CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
                left = neuronInfo.side(of: 0, anchor: center, around: around, frame: frame) ?? (center.x > frame.stage.viewSize.width / 2)
            }
            let onLeft = left!
            anchor = corners[i].map { $0.min { onLeft ? $0.x < $1.x : $0.x > $1.x }! }
                ?? CGPoint(x: center.x + (onLeft ? -radius : radius), y: center.y)
        }
        neuronInfo.update(anchors: [anchor], around: around, left: left, visible: !pointedNeurons.isEmpty, frame: frame)

        // Gold: a touched header, and the outlines of the touched blocks and of a touched header's.
        for (h, label) in headers.enumerated() { label.label.set(\.fontColor, pointedHeaders.contains(h) ? Self.gold : .white) }
        let outlined = pointedNeurons.union(pointedHeaders.flatMap { layout.headers[$0].members })
        let path = CGMutablePath()
        for i in outlined {
            guard let corner = corners[i] else { continue }
            // The 12 edges: corners differing on one axis.
            for k in 0..<8 { for bit in [1, 2, 4] where k & bit == 0 {
                path.move(to: corner[k])
                path.addLine(to: corner[k | bit])
            } }
        }
        outlines.path = path
        outlines.lineWidth = 2 * u

        // The touched synapse lit, its weight over its middle.
        if let s = pointedSynapse {
            described.synapse = s
            weight.label.set(\.text, String(format: "weight %+.2f", layout.synapses[s].weight ?? 0))
        }
        if let s = described.synapse {
            let (a, b) = (onStage[layout.synapses[s].a].point, onStage[layout.synapses[s].b].point)
            line.position = a
            line.zRotation = atan2(b.y - a.y, b.x - a.x)
            line.xScale = a.distance(to: b)
            line.yScale = 3 * u * max(1, (system.size / (Self.size * u)).squareRoot())
            weight.label.set(\.fontSize, 16 * u)
            weight.position = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 + 6 * u)
            weight.sync(unit: u)
        }
        line.isHidden = pointedSynapse == nil
        weight.alpha = weight.alpha.approaching(pointedSynapse != nil ? 1 : 0, CGFloat(1 - exp(-frame.dt * 12)))
    }

    /// From a stage point to a synapse on stage.
    private func distance(_ p: CGPoint, _ s: Int) -> CGFloat {
        guard let synapse = layout?.synapses[s] else { return .infinity }
        return segmentDistance(p, onStage[synapse.a].point, onStage[synapse.b].point)
    }
}

/// From a point to the segment from `a` to `b`.
private func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let (dx, dy) = (b.x - a.x, b.y - a.y)
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / max(dx * dx + dy * dy, 1e-6)))
    return p.distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
}

/// The convex outline around points, in order (Andrew's monotone chain).
private func convexHull(_ points: [CGPoint]) -> [CGPoint] {
    let sorted = points.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
    let cross = { (o: CGPoint, a: CGPoint, b: CGPoint) in (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
    var lower: [CGPoint] = [], upper: [CGPoint] = []
    for p in sorted {
        while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
        lower.append(p)
    }
    for p in sorted.reversed() {
        while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
        upper.append(p)
    }
    return lower.dropLast() + upper.dropLast()
}
