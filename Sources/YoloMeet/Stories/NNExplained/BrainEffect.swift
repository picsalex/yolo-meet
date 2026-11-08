import SpriteKit
import simd

/// A swirling cloud of particles in the middle of the stage. A fist closed on it gathers the particles into a ball that
/// follows the fist; opening the hand forms a brain there, with a network inside it made of the same
/// particles: neurons (small balls) joined by synapses (lines). Both hands pinching zoom (around the point between them,
/// to look inside) when they move apart or closer, and move it when they move together; one hand pinching moves it too.
/// A fist on the brain breaks it again (fists need Space held). Keys: R turns a slow spin on or off (off at first), Q/D
/// turn and Z/S tilt while held, 0 resets the view.
///
/// Action mode (Space held): the neuron a fingertip touches grows its particles and shows as a neuron, a disc with a
/// ring and its activation inside, described beside it ("neuron - bias …"); a synapse a fingertip touches lights up
/// with its weight in its middle. Nothing else shows values. Releasing Space on a neuron activates it: a gold disc with
/// a bold ring (again: back to particles). 2D content follows the particles as they show
/// (`ParticleSystem.shownPoint`), so it stays on them when the brain moves.
final class BrainEffect: Effect {
    /// Half the brain's size on stage at zoom 1 and unit 1.
    static let size: CGFloat = 170
    /// A neuron's radius in the brain's -1...1 units, and the touched neuron's smallest radius on stage (at unit 1), so
    /// its value reads at any zoom.
    static let (neuronSize, focusRadius): (Float, CGFloat) = (0.022, 20)
    /// Particles per neuron, for all the synapses, and for the brain's surface (the rest).
    nonisolated static let (perNeuron, forSynapses, total) = (60, 12_000, 60_000)

    private struct Neuron {
        let point: SIMD3<Float>
        let bias: Float
        /// Activated: a gold disc instead of particles.
        let disc = SKSpriteNode(texture: BrainEffect.goldDisc, size: CGSize(width: 64, height: 64))
        let activation = Float.random(in: 0...1)
        let item = Actionable(grown: 1.8)
        var gold = false
    }
    private struct Synapse {
        let a, b: Int
        let weight: Float
    }

    private let system = ParticleSystem(count: BrainEffect.total)
    /// The brain's surface, built once per run in the background (it takes most of a second).
    private static let surface = Task.detached(priority: .userInitiated) { Brain.shape(total - 300 * perNeuron - forSynapses) }
    /// The surface, neurons and synapses as one shape (neuron `i` is part `i + 1`); nil until the surface is ready.
    private var brain: ParticleShape?
    /// Some of the surface's points, to frame the brain for its title.
    private var outline: [SIMD3<Float>] = []
    private var neurons: [Neuron]
    private let synapses: [Synapse]
    /// Where the neurons are on stage this frame (as the particles show them), their depth (-1 back, 1 front) and radius.
    private var onStage: [(point: CGPoint, depth: Float, radius: CGFloat)] = []

    /// Where the cloud or brain is, in stage points; nil until the first frame places it in the middle.
    private var home: CGPoint?
    private var zoom: CGFloat = 1
    private var shown: (home: CGPoint, zoom: CGFloat)?
    private var base: (home: CGPoint, zoom: CGFloat) = (.zero, 1)
    private var formed: TimeInterval?
    /// Whether the current gesture started on the particles.
    private var held = false
    private var turning = KeyTurn(restingTilt: 0.2, autoSpeed: 0.25, spinning: false)

    private let network = SKNode()
    private let title: ObjectTitle
    private let neuronInfo = Callouts([""])
    /// The touched neuron, drawn as one: a disc with a ring, its activation inside.
    private let focus = SKSpriteNode(texture: BrainEffect.whiteDisc, size: CGSize(width: 64, height: 64))
    private let focusValue = SKLabelNode(fontNamed: "GeistMono-Medium")
    private let line = SKSpriteNode(color: BrainEffect.gold, size: CGSize(width: 1, height: 1))
    private let weight = ShadowedLabel("", font: "GeistMono-Medium", color: BrainEffect.gold)
    /// The neuron and synapse last described, so their labels fade out in place.
    private var described: (neuron: Int?, synapse: Int?) = (nil, nil)

    private static let gold = NSColor(red: 1, green: 0.78, blue: 0.22, alpha: 1)
    private static let whiteDisc = disc(fill: .white, ring: NSColor(red: 0.3, green: 0.75, blue: 1, alpha: 1), width: 10)
    private static let goldDisc = disc(fill: gold, ring: NSColor(red: 0.62, green: 0.4, blue: 0, alpha: 1), width: 16)

    override init() {
        // 300 neurons, each joined to its three nearest by a synapse.
        neurons = (0..<300).map { _ in Neuron(point: Brain.inside(), bias: .random(in: -1...1)) }
        let points = neurons.map(\.point)
        var pairs = Set<[Int]>()
        for (i, point) in points.enumerated() {
            let nearest = points.indices.filter { $0 != i }.sorted {
                simd_distance(points[$0], point) < simd_distance(points[$1], point)
            }
            for j in nearest.prefix(3) { pairs.insert([min(i, j), max(i, j)]) }
        }
        synapses = pairs.map { Synapse(a: $0[0], b: $0[1], weight: .random(in: -1...1)) }
        title = ObjectTitle("Neural network", subtitle: "\(neurons.count) neurons · \(synapses.count) synapses · zoom in")
        super.init()
        particles = system
        system.brightness = 0.45
        Task {
            let surface = await Self.surface.value
            outline = stride(from: 0, to: surface.points.count, by: 200).map { surface.points[$0] }
            brain = withNetwork(on: surface)
        }

        // Activated neurons by depth, then the touched synapse and the labels over them.
        let discs = SKNode()
        for neuron in neurons {
            neuron.disc.isHidden = true
            discs.addChild(neuron.disc)
        }
        (focusValue.fontSize, focusValue.fontColor, focusValue.verticalAlignmentMode) = (19, Theme.darkBlue, .center)
        focus.addChild(focusValue)
        focus.isHidden = true
        line.anchorPoint = CGPoint(x: 0, y: 0.5)
        line.isHidden = true
        (line.zPosition, focus.zPosition, neuronInfo.zPosition, weight.zPosition) = (20, 30, 40, 40)
        weight.label.verticalAlignmentMode = .bottom
        weight.alpha = 0
        for child in [discs, line, focus, neuronInfo, weight] { network.addChild(child) }
        network.alpha = 0
        node.addChild(network)
        node.addChild(title)
    }

    /// The surface plus the network: each neuron a small ball of particles, the synapses lines of particles spread by
    /// length; in random order, so each particle flies to a random point.
    private func withNetwork(on surface: ParticleShape) -> ParticleShape {
        var points = surface.points
        var parts = [Int](repeating: 0, count: points.count)
        for (i, neuron) in neurons.enumerated() {
            for _ in 0..<Self.perNeuron {
                points.append(neuron.point + randomDirection() * Self.neuronSize)
                parts.append(i + 1)
            }
        }
        let lengths = synapses.map { simd_distance(neurons[$0.a].point, neurons[$0.b].point) }
        let total = lengths.reduce(0, +)
        var (s, start) = (0, Float(0))
        for k in 0..<Self.forSynapses {
            let at = (Float(k) + .random(in: 0..<1)) / Float(Self.forSynapses) * total
            while s < synapses.count - 1, start + lengths[s] < at { (start, s) = (start + lengths[s], s + 1) }
            let (a, b) = (neurons[synapses[s].a].point, neurons[synapses[s].b].point)
            points.append(a + (b - a) * min(max((at - start) / lengths[s], 0), 1))
            parts.append(0)
        }
        let order = points.indices.shuffled()
        return ParticleShape(
            points: order.map { points[$0] }, offsets: Array(repeating: .zero, count: points.count), parts: order.map { parts[$0] })
    }

    override func update(_ frame: StageFrame) {
        let u = frame.stage.unit
        let middle = CGPoint(x: frame.stage.viewSize.width / 2, y: frame.stage.viewSize.height / 2)
        var home = self.home ?? middle
        let cloud = 220 * u

        if let gesture = frame.gesture {
            if gesture.phase == .began {
                let reach = formed != nil ? 1.2 * Self.size * u * zoom : 1.1 * cloud
                held = home.distance(to: gesture.location) < reach
                base = (home, zoom)
            }
            switch gesture.kind {
            case _ where !held: break
            case let .fist(location):
                if gesture.phase == .began {
                    system.scatter(kick: formed != nil ? 1 : 0.4)
                    formed = nil
                }
                home = location
                if gesture.phase == .ended, let brain {
                    system.form(brain)
                    (formed, zoom) = (frame.time, 1)
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
            if gesture.phase == .ended { held = false }
        }
        turning.update(frame)
        if frame.keys.pressed.contains("0") { (home, zoom) = (middle, 1) }
        self.home = home

        let k = frame.smoothing
        let now: (home: CGPoint, zoom: CGFloat) = shown.map { ($0.home.approaching(home, k), $0.zoom.approaching(zoom, k)) } ?? (home, zoom)
        shown = now
        var gathering = false
        if held, case .fist = frame.gesture?.kind { gathering = true }
        system.center = now.home
        system.radius = gathering ? 70 * u : cloud
        system.size = Self.size * u * now.zoom
        system.rotation = turning.rotation
        system.pointSize = 3 * Float(max(now.zoom, 1)).squareRoot()  // so the network still reads, zoomed in
        system.follow(time: frame.time, dt: frame.dt)

        // Labels and activated neurons once the particles have mostly landed; they go at once with a fist.
        let lit = formed.map { frame.time - $0 > 0.8 } ?? false
        network.alpha = network.alpha.approaching(lit ? 1 : 0, CGFloat(1 - exp(-frame.dt * (lit ? 3 : 14))))
        network.isHidden = network.alpha < 0.01
        if network.isHidden {
            title.update(beside: .zero, visible: false, frame: frame)
            system.highlight = nil
            return
        }
        title.update(beside: CGRect(enclosing: outline.map { system.shownPoint($0).point }), visible: now.zoom < 1.6, frame: frame)
        updateNetwork(frame)
    }

    private func updateNetwork(_ frame: StageFrame) {
        let u = frame.stage.unit
        let size = CGFloat(Self.neuronSize) * system.size
        onStage = neurons.map { neuron in
            let (point, depth) = system.shownPoint(neuron.point)
            return (point, depth, size * neuron.item.scale)
        }

        // Action mode: per fingertip, the nearest neuron its touch circle reaches, else the nearest synapse it reaches.
        let acting = frame.keys.held.contains("space")
        let reach = Pointer.reach * u
        var pointedNeurons = Set<Int>()
        var pointedSynapse: Int?
        if acting || frame.keys.released.contains("space") {
            for pointer in frame.pointers {
                let gap = { (i: Int) in self.onStage[i].point.distance(to: pointer.location) }
                if let i = neurons.indices.filter({ gap($0) < onStage[$0].radius + reach }).min(by: { gap($0) < gap($1) }) {
                    pointedNeurons.insert(i)
                } else if let s = synapses.indices.min(by: { distance(pointer.location, $0) < distance(pointer.location, $1) }),
                    distance(pointer.location, s) < reach {
                    pointedSynapse = s
                    frame.pointing.mark(pointer.hand)
                }
            }
        }

        for i in neurons.indices {
            let (point, depth, radius) = onStage[i]
            let isOn: ((CGPoint) -> Bool)? = pointedNeurons.contains(i) ? { $0.distance(to: point) < radius + reach } : nil
            if neurons[i].item.update(frame, isOn: isOn) { neurons[i].gold.toggle() }
            let disc = neurons[i].disc
            disc.isHidden = !neurons[i].gold
            if neurons[i].gold {
                disc.position = point
                disc.setScale(2 * (radius + 2 * u) / 64)
                disc.zPosition = CGFloat(depth)
                disc.alpha = CGFloat(0.7 + 0.3 * (depth + 1) / 2)
            }
        }
        // The neuron grown most (one at a time) grows its particles.
        let grown = neurons.indices.max { neurons[$0].item.scale < neurons[$1].item.scale }!
        system.highlight = neurons[grown].item.scale > 1.001
            ? (grown + 1, neurons[grown].point, Float(neurons[grown].item.scale)) : nil

        // The neuron's description beside it; the touched synapse lit, its weight over its middle.
        if let i = pointedNeurons.min() {
            described.neuron = i
            neuronInfo.setText(String(format: "neuron - bias %+.2f", neurons[i].bias), at: 0)
        }
        // The touched neuron as a disc, popping in as it grows (and out as it shrinks back), at least `focusRadius`.
        var around = CGRect.zero
        if let i = described.neuron {
            let item = neurons[i].item
            let shown = min(max((item.scale - 1) / (item.grown - 1), 0), 1)
            let radius = max(onStage[i].radius + 2 * u, Self.focusRadius * u) * shown
            focus.isHidden = shown < 0.01
            focus.position = onStage[i].point
            focus.setScale(radius / 32)
            focus.texture = neurons[i].gold ? Self.goldDisc : Self.whiteDisc
            focusValue.set(\.text, String(format: "%.2f", neurons[i].activation))
            around = CGRect(x: onStage[i].point.x - radius, y: onStage[i].point.y - radius, width: 2 * radius, height: 2 * radius)
        }
        // Its description on the right, the line ending at the disc's edge.
        neuronInfo.update(
            anchors: [described.neuron.map { _ in CGPoint(x: around.maxX, y: around.midY) }], around: around,
            visible: !pointedNeurons.isEmpty, frame: frame)

        if let s = pointedSynapse {
            described.synapse = s
            weight.label.set(\.text, String(format: "weight %+.2f", synapses[s].weight))
        }
        if let s = described.synapse {
            let (a, b) = (onStage[synapses[s].a].point, onStage[synapses[s].b].point)
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
        let (a, b) = (onStage[synapses[s].a].point, onStage[synapses[s].b].point)
        let (dx, dy) = (b.x - a.x, b.y - a.y)
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / max(dx * dx + dy * dy, 1e-6)))
        return p.distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    private func randomDirection() -> SIMD3<Float> {
        while true {
            let v = SIMD3<Float>(.random(in: -1...1), .random(in: -1...1), .random(in: -1...1))
            let l = simd_length(v)
            if l > 0.01, l <= 1 { return v / l }
        }
    }

    /// An activated neuron's look: a filled disc with a ring, 64 points across.
    private static func disc(fill: NSColor, ring: NSColor, width: CGFloat) -> SKTexture {
        let size = 128
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rect = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: width / 2 + 2, dy: width / 2 + 2)
        context.setFillColor(fill.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(ring.cgColor)
        context.setLineWidth(width)
        context.strokeEllipse(in: rect)
        return SKTexture(cgImage: context.makeImage()!)
    }
}
