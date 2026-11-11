import SpriteKit
import simd

/// A network made of particles (`NetworkLayout`: a brain, a perceptron, YOLO's architecture): neurons are small balls, synapses lines. It
/// forms at once, its particles flying from wherever the story's particles are (the previous step's layout); without a
/// layout, they swirl as a cloud (on the right third of the stage at first). A fist closed on the particles gathers them
/// into a ball that follows the fist; opening the hand forms the layout there, or, on the cloud alone, moves the story to
/// its next step (`frame.nextStep`), which forms there. Both hands pinching zoom (around the point between them, to look inside) when they move apart or closer, and move it
/// when they move together; one hand pinching moves it too. A fist on it breaks it again (fists need Command held). Keys:
/// R turns a slow spin on or off (off at first), Q/D turn and Z/S tilt while held, 0 resets the view. With the camera
/// hidden (H), it moves to the middle of the stage, and back to its last position with the camera when it shows again.
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
    /// Where it is while the camera is hidden (H): in the middle of the stage at first, moved by the gestures meanwhile;
    /// dropped when the camera comes back, and `home` (the last position with the camera) takes over again.
    private var centered: CGPoint?
    private var zoom: CGFloat = 1
    private var shown: (home: CGPoint, zoom: CGFloat)?
    private var base: (home: CGPoint, zoom: CGFloat) = (.zero, 1)
    /// When the layout formed; nil while the particles are a cloud.
    private var formed: TimeInterval?
    /// Forms the layout on the first frame it's ready.
    private var formNow = true
    /// How lit each block of a flow is (0...1), and as last painted.
    private var glow: [Float] = [], painted: [Float] = []
    /// Whether a layout that moves on after forming has arrived and formed again without offsets (`settled`).
    private var settled = false
    /// Whether the particles are forming the layout's `prelude` (it forms itself when that's done).
    private var staging = false
    /// Whether the current gesture started on the particles.
    private let grip = Grip()
    private var turning: KeyTurn

    private let labels = SKNode()
    private let title: ObjectTitle
    /// The touched neuron's or block's description, in a column beside the whole layout, a line to it.
    private let neuronInfo = Callouts([""], font: "Archivo-SemiBold", size: 20, line: NetworkEffect.gold.withAlphaComponent(0.85))
    /// The layout's headers (e.g. under its columns).
    private let headers: [ShadowedLabel]
    /// The layout's arrows (e.g. into its input).
    private let arrows: [Arrow]
    /// The flow's result beside the output arrow (`NetworkLayout.flowResult`), shown once the particles are through.
    private let result: ShadowedLabel
    /// The layout's measurements (e.g. a picture's width and height).
    private let dimensions: [Dimension]
    /// The previous step's title, fading out (after a first frame to place it), when this one continues it with another.
    private var leavingTitle: (title: ObjectTitle, first: Bool)?
    /// Arrows of the previous step that this one no longer has, fading out (with their ends in the layout).
    private var leaving: [(arrow: Arrow, tail: SIMD3<Float>, tip: SIMD3<Float>)] = []
    /// Gold outlines of the touched blocks (a block, or all of a touched header's).
    private let outlines = SKShapeNode()
    /// The touched neuron, drawn as one: a disc with a ring, its bias inside.
    private let focus = SKSpriteNode(texture: NetworkEffect.disc, size: CGSize(width: 64, height: 64))
    private let focusValue = SKLabelNode(fontNamed: "GeistMono-Medium")
    private let line = SKSpriteNode(color: NetworkEffect.gold, size: CGSize(width: 1, height: 1))
    private let weight = ShadowedLabel("", font: "GeistMono-Medium", color: NetworkEffect.gold)
    /// The side the described neuron's label took (true: left), kept while it's described.
    private var labelSide: (neuron: Int, left: Bool)?
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
        arrows = layout?.arrows.map { Arrow($0.text, color: NetworkEffect.gold) } ?? []
        dimensions = layout?.dimensions.map { Dimension($0.text) } ?? []
        title = ObjectTitle(layout?.title ?? "", subtitle: layout?.subtitle ?? "")
        result = ShadowedLabel(layout?.flowResult ?? "", font: "Archivo-SemiBold")
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
        (result.label.horizontalAlignmentMode, result.label.verticalAlignmentMode, result.alpha) = (.left, .center, 0)
        for child in [line, focus, outlines, neuronInfo, weight, result] + headers + arrows + dimensions { labels.addChild(child) }
        labels.alpha = 0
        node.addChild(labels)
        node.addChild(title)
    }

    override func update(_ frame: StageFrame) {
        let u = frame.stage.unit
        let start = CGPoint(x: frame.stage.viewSize.width * 2 / 3, y: frame.stage.viewSize.height / 2)
        // Where the previous step left the particles, back on stage (a zoomed-in center can be off it).
        let stage = CGRect(origin: .zero, size: frame.stage.viewSize).insetBy(dx: 80 * u, dy: 80 * u)
        let middle = CGPoint(x: frame.stage.viewSize.width / 2, y: frame.stage.viewSize.height / 2)
        var home = frame.cameraHidden
            ? centered ?? middle
            : self.home ?? network.home.map { CGPoint(x: min(max($0.x, stage.minX), stage.maxX), y: min(max($0.y, stage.minY), stage.maxY)) } ?? start
        let cloud = 220 * u

        if formNow, let shape = layout?.shape { form(shape, frame) }
        if layout == nil, system.mode == .form { system.scatter(kick: 0.6) }  // back from a layout
        // A gesture takes hold anywhere on the formed layout as it shows on stage (with a margin), e.g. its picture or
        // a far block; on the cloud, within its radius.
        let onLayout = formed != nil && !(layout?.outline.isEmpty ?? true)
            ? CGRect(enclosing: layout!.outline.map { system.shownPoint($0).point }).insetBy(dx: -40 * u, dy: -40 * u) : nil
        let reach = formed != nil ? 1.2 * Self.size * u * zoom : 1.1 * cloud
        if let gesture = grip.update(frame, isOn: { onLayout?.contains($0) ?? (home.distance(to: $0) < reach) }) {
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
        if frame.keys.pressed.contains("0") { (home, zoom) = (frame.cameraHidden ? middle : start, 1) }
        if frame.cameraHidden {
            centered = home
        } else {
            (self.home, network.home, centered) = (home, home, nil)
        }

        let k = frame.smoothing
        let now: (home: CGPoint, zoom: CGFloat) = shown.map { ($0.home.approaching(home, k), $0.zoom.approaching(zoom, k)) } ?? (home, zoom)
        shown = now
        var gathering = false
        if grip.held, case .fist = frame.gesture?.kind { gathering = true }
        system.center = now.home
        system.radius = gathering ? 70 * u : cloud
        system.size = Self.size * u * now.zoom * grip.scale
        // The view turns smoothly to a new step's (e.g. to show layers side by side) and with the keys.
        let turn = CGFloat(1 - exp(-frame.dt * 4))
        let rotation = network.rotation.map { simd_slerp($0, turning.rotation, Float(turn)) } ?? turning.rotation
        (system.rotation, network.rotation) = (rotation, rotation)
        system.pointSize = 3 * Float(max(now.zoom, 1)).squareRoot()  // so the network still reads, zoomed in
        system.follow(time: frame.time, dt: frame.dt)

        // Particles flowing through the layout, on the step's timeline.
        if let flow = layout?.flow, network.formed === layout, system.mode == .form {
            let (points, colors, inside) = flow.frame(at: Float(frame.stepTime), again: frame.loopCount > 0)
            system.place(flow.particles, at: points, colors: colors)
            // Blocks light up gold as the pixels go through them (quickly), and cool down after (slowly).
            if glow.count != flow.blocks.count { (glow, painted) = (Array(repeating: 0, count: flow.blocks.count), Array(repeating: -1, count: flow.blocks.count)) }
            let gold = SIMD3<Float>(1, 0.78, 0.22) * 1.4
            for b in flow.blocks.indices {
                let target = 1 - exp(-Float(inside[b]) / 120)
                glow[b] += (target - glow[b]) * Float(1 - exp(-frame.dt * (target > glow[b] ? 10 : 2)))
                if abs(glow[b] - painted[b]) > 0.01 {
                    painted[b] = glow[b]
                    system.paint(flow.blocks[b], color: system.color + (gold - system.color) * glow[b])
                }
            }
        }
        // A splitting layout's parts come apart once it has formed (and back together for any other), eased.
        let splitting = formed != nil && layout?.splits == true
        let pace = Float(frame.dt) / 1.5
        network.split = splitting ? min(network.split + pace, 1) : max(network.split - 2 * pace, 0)
        if staging, network.split >= 1, let shape = layout?.shape { form(shape, frame) }  // the prelude done: on to the layout
        // Arrived, the same points without offsets (nothing moves), so a block grows where it is when touched.
        if splitting, !staging, !settled, network.split >= 1, let shape = layout?.settled {
            system.form(shape, staggered: false)
            settled = true
        }
        let e = network.split
        system.explode = settled ? 0 : e * e * (3 - 2 * e)

        // Labels once the particles have mostly landed (and split); they go at once with a fist.
        let lit = formed.map { frame.time - $0 > 0.8 && !staging && (!splitting || network.split > 0.9) } ?? false
        labels.alpha = labels.alpha.approaching(lit ? 1 : 0, CGFloat(1 - exp(-frame.dt * (lit ? 3 : 14))))
        labels.isHidden = labels.alpha < 0.01
        guard let layout, !labels.isHidden else {
            title.update(above: .zero, visible: false, frame: frame)
            system.highlight = nil
            return
        }
        let bounds = CGRect(enclosing: layout.outline.map { system.shownPoint($0).point })
        title.update(above: bounds, visible: true, frame: frame)  // at the top, out of the way: it stays when zoomed in
        if let (old, first) = leavingTitle {
            old.update(above: bounds, visible: first, frame: frame)  // placed where it stood, then fading out
            leavingTitle = old.alpha < 0.01 ? nil : (old, false)
            if leavingTitle == nil { old.removeFromParent() }
        }
        // Arrows new to this step fade in (they start hidden only when continuing the previous step), old ones out.
        let fading = CGFloat(1 - exp(-frame.dt * 6))
        for (arrow, ends) in zip(arrows, layout.arrows) {
            let feeds = (layout.arrowFeeds[ends.text] ?? []).map { $0.map { system.shownPoint($0).point } }
            arrow.update(from: system.shownPoint(ends.tail).point, to: system.shownPoint(ends.tip).point, feeds: feeds, frame: frame)
            arrow.alpha = arrow.alpha.approaching(1, fading)
        }
        // The flow's result past the output arrow's tip: in once the pixels are through, out as the timeline starts over.
        if let flow = layout.flow, layout.flowResult != nil, let output = layout.arrows.last {
            let through = network.formed === layout && Float(frame.stepTime) > flow.end
            result.alpha = result.alpha.approaching(through ? 1 : 0, CGFloat(1 - exp(-frame.dt * (through ? 5 : 8))))
            result.label.set(\.fontSize, 30 * u)
            result.label.set(\.fontColor, Self.gold)
            let tip = system.shownPoint(output.tip).point
            result.position = CGPoint(x: tip.x + 14 * u, y: tip.y)
            result.sync(unit: u)
        }
        for (dimension, ends) in zip(dimensions, layout.dimensions) {
            dimension.update(from: system.shownPoint(ends.from).point, to: system.shownPoint(ends.to).point, frame: frame)
        }
        for old in leaving {
            old.arrow.update(from: system.shownPoint(old.tail).point, to: system.shownPoint(old.tip).point, frame: frame)
            old.arrow.alpha = old.arrow.alpha.approaching(0, fading)
            if old.arrow.alpha < 0.01 { old.arrow.removeFromParent() }
        }
        leaving.removeAll { $0.arrow.parent == nil }
        for (label, header) in zip(headers, layout.headers) {
            label.label.set(\.fontSize, layout.headerSize * u)
            label.label.verticalAlignmentMode = .top
            label.position = system.shownPoint(header.point).point
            label.sync(unit: u)
        }
        updateNetwork(frame, layout, bounds: bounds)
    }

    private func form(_ shape: ParticleShape, _ frame: StageFrame) {
        let previous = network.formed
        // From the layout its prelude follows, the prelude first (e.g. some neurons moving out of the brain); the
        // layout itself forms from it once it's done (`update`).
        if let prelude = layout?.prelude, let first = prelude.shape, system.mode == .form, previous != nil, previous === prelude.splitsFrom {
            system.form(first, staggered: false)
            (network.formed, network.split, staging, settled) = (prelude, 0, true, false)
            (formed, formNow) = (frame.time, false)
            return
        }
        (staging, settled) = (false, false)
        // A variant of the layout already there (some particles moved), or a layout gliding on from it, forms without
        // restarting the particles' flight.
        let variant = layout.flatMap { layout in previous.map { layout.isVariant(of: $0) } } ?? false
        let follows = previous != nil && previous === layout?.splitsFrom
        system.form(shape, staggered: !((variant || follows) && system.mode == .form))
        network.formed = layout
        (formed, formNow) = (frame.time, false)
        // A layout that moves on after forming starts from where the one it follows left the particles, else at its end.
        if let layout, layout.splits { network.split = previous != nil && previous === layout.splitsFrom ? 0 : 1 }
        if continuing, variant, let layout {
            // No transition from the same object: its title and labels are already there and stay; only what this
            // step adds or drops fades (its arrows here).
            formed = frame.time - 1
            // The same title stays; a new one fades in as the previous one fades out where it stood.
            let sameTitle = previous.map { $0.title == layout.title && $0.subtitle == layout.subtitle } ?? true
            (labels.alpha, title.alpha) = (1, sameTitle ? 1 : 0)
            if !sameTitle, let previous {
                let old = ObjectTitle(previous.title, subtitle: previous.subtitle)
                old.alpha = 1
                node.addChild(old)
                leavingTitle = (old, true)
            }
            let before = Set(previous?.arrows.map(\.text) ?? []), now = Set(layout.arrows.map(\.text))
            for (arrow, ends) in zip(arrows, layout.arrows) where !before.contains(ends.text) { arrow.alpha = 0 }
            for ends in previous?.arrows ?? [] where !now.contains(ends.text) {
                let arrow = Arrow(ends.text, color: Self.gold)
                labels.addChild(arrow)
                leaving.append((arrow, ends.tail, ends.tip))
            }
        }
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
                // The nearest touched, but the one already described while it's still touched: a fingertip between two
                // blocks (shaking a little) sticks to one rather than switching back and forth.
                let gap = { (i: Int) in self.onStage[i].point.distance(to: pointer.location) }
                let touched = onStage.indices.filter { touches($0, pointer.location) }
                let current = described.neuron.flatMap { touched.contains($0) ? $0 : nil }
                if let i = current ?? touched.min(by: { gap($0) < gap($1) }) {
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
        let grown = items.indices.max { items[$0].scale < items[$1].scale }  // nil: no neurons (e.g. a picture)
        system.highlight = grown.flatMap { items[$0].scale > 1.001 ? ($0 + 1, layout.neurons[$0].point, Float(items[$0].scale)) : nil }

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
            // Steady while the part pops in: the side it took first, as long as the label fits there, and beside a
            // block at its full grown size rather than its size as it grows (which overshoots).
            let kept = labelSide?.neuron == i ? labelSide?.left : nil
            left = neuronInfo.side(of: 0, anchor: center, around: bounds, left: kept, frame: frame)
            if left == nil {
                let still = layout.neurons[i].box.map { box in
                    let half = box * Float(item.grown)
                    return CGRect(enclosing: (0..<8).map { k in
                        system.shownPoint(layout.neurons[i].point + half * SIMD3(k & 1 == 0 ? -1 : 1, k & 2 == 0 ? -1 : 1, k & 4 == 0 ? -1 : 1)).point
                    })
                }
                let rest = max(onStage[i].radius / item.scale * item.grown + 2 * u, Self.focusRadius * u)
                around = still ?? CGRect(x: center.x - rest, y: center.y - rest, width: 2 * rest, height: 2 * rest)
                left = neuronInfo.side(of: 0, anchor: center, around: around, left: kept, frame: frame)
                    ?? kept ?? (center.x > frame.stage.viewSize.width / 2)
            }
            let onLeft = left!
            labelSide = (i, onLeft)
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
