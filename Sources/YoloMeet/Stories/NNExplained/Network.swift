import CoreGraphics
import simd

/// The NN explained story's network, shared by its steps (created in the story file) so the particles fly from one
/// layout to the next instead of starting over: one particle system, and the layouts it forms.
final class NeuralNetwork {
    /// Particles per 60,000 of the layouts' budgets below: more is denser (the GPU simulates 60,000 in about 0.2 ms).
    nonisolated static let scale = 2
    static let particles = 60_000 * scale
    let system = ParticleSystem(count: particles)
    /// The layout the particles formed last: a variant of it (`NetworkLayout.base`) forms without restarting their flight.
    var formed: NetworkLayout?
    /// Where the particles are centered (stage points), kept from step to step so the next layout forms there; nil
    /// until the first step places it on the right third of the stage (0 brings it back there).
    var home: CGPoint?
    /// 300 neurons inside a brain, each joined to its three nearest.
    let brain: NetworkLayout
    /// 23 of the brain's neurons (with their biases) in three fully connected layers.
    let perceptron: NetworkLayout
    /// YOLO's convolutional architecture: backbone, neck and head.
    let architecture: NetworkLayout
    /// The same, its dust gathered into two yellow arrows: into the input, out of the output.
    let inputOutput: NetworkLayout

    init() {
        system.brightness = 0.45 / Float(Self.scale).squareRoot()  // points add light: about the same look, denser
        brain = .brain()
        perceptron = .perceptron(layers: [10, 5, 8], from: brain)
        architecture = .architecture()
        inputOutput = .inputOutput(of: architecture)
    }
}

/// Neurons and synapses placed in a particle shape's -1...1 space, and the shape they form: each neuron a ball of
/// particles (neuron `i` is part `i + 1`), or a box for a block of layers, each synapse a line of particles, with other
/// particles around them.
final class NetworkLayout {
    struct Neuron {
        let point: SIMD3<Float>
        var bias: Float = 0
        /// A block's half size (a feature map: width, height, channels), drawn as a box; nil: a neuron, a ball.
        var box: SIMD3<Float>? = nil
        /// What a block is, shown when touched in action mode (a neuron shows its bias).
        var info: String? = nil
        /// A block's neurons, drawn inside its box: slices (channels) of square grids (`cells` × `cells`), fewer than
        /// the real ones so they read.
        var grid: (cells: Int, slices: Int)? = nil
    }
    struct Synapse {
        let a, b: Int
        /// Shown when touched in action mode; nil: a connection that can't be touched.
        var weight: Float? = nil
    }

    let title, subtitle: String
    let neurons: [Neuron]
    let synapses: [Synapse]
    /// A neuron's radius in the shape's units.
    let neuronSize: Float
    /// Tilt toward the viewer and turn at rest (`KeyTurn`).
    let restingTilt: Float
    private(set) var restingTurn: Float = 0
    /// How much a touched neuron or block grows.
    private(set) var grown: CGFloat = 1.8
    /// Labels under parts of the layout (e.g. its columns), at points of it, with the neurons or blocks they name
    /// (outlined when a header is touched in action mode).
    private(set) var headers: [(text: String, point: SIMD3<Float>, members: [Int])] = []
    /// The particles' points; nil until ready (the brain's surface is built in the background).
    private(set) var shape: ParticleShape?
    /// Some points around the layout, to place its title.
    private(set) var outline: [SIMD3<Float>] = []
    /// The layout this one is a variant of (same blocks, some particles moved), if any.
    private(set) weak var base: NetworkLayout?
    /// Done once `shape` is set.
    private var ready: Task<Void, Never>?

    private init(title: String, subtitle: String, neurons: [Neuron], synapses: [Synapse], neuronSize: Float, restingTilt: Float) {
        (self.title, self.subtitle, self.neurons, self.synapses) = (title, subtitle, neurons, synapses)
        (self.neuronSize, self.restingTilt) = (neuronSize, restingTilt)
    }

    /// The brain's surface, built once per run in the background (it takes most of a second).
    private static let surface = Task.detached(priority: .userInitiated) { Brain.shape(30_000 * NeuralNetwork.scale) }

    static func brain() -> NetworkLayout {
        let neurons = (0..<300).map { _ in Neuron(point: Brain.inside(), bias: .random(in: -1...1)) }
        let points = neurons.map(\.point)
        var pairs = Set<[Int]>()
        for (i, point) in points.enumerated() {
            let nearest = points.indices.filter { $0 != i }.sorted {
                simd_distance(points[$0], point) < simd_distance(points[$1], point)
            }
            for j in nearest.prefix(3) { pairs.insert([min(i, j), max(i, j)]) }
        }
        let synapses = pairs.map { Synapse(a: $0[0], b: $0[1], weight: .random(in: -1...1)) }
        let layout = NetworkLayout(
            title: "Neural network", subtitle: "\(neurons.count) neurons · \(synapses.count) synapses · zoom in",
            neurons: neurons, synapses: synapses, neuronSize: 0.022, restingTilt: 0.2)
        layout.ready = Task {
            let surface = await surface.value
            layout.outline = stride(from: 0, to: surface.points.count, by: 200).map { surface.points[$0] }
            layout.shape = layout.particles(around: surface.points, perNeuron: Array(repeating: 60 * NeuralNetwork.scale, count: neurons.count))
        }
        return layout
    }

    /// Layers side by side (inputs on the left), each layer's neurons in a column, every neuron joined to every neuron of
    /// the next layer. Its neurons are some of `brain`'s, keeping their biases, and each one's particles in the brain fly
    /// into it; the brain's other particles become the rest of the neurons, the connections and a faint dust around them.
    static func perceptron(layers: [Int], from brain: NetworkLayout) -> NetworkLayout {
        let picked = brain.neurons.indices.shuffled()
        var neurons: [Neuron] = []
        var columns: [[Int]] = []
        for (l, count) in layers.enumerated() {
            let x = Float(l) / Float(layers.count - 1) * 2.6 - 1.3
            columns.append(Array(neurons.count..<neurons.count + count))
            for k in 0..<count {
                let y = (Float(count - 1) / 2 - Float(k)) * 0.24
                neurons.append(Neuron(point: [x, y, 0], bias: brain.neurons[picked[neurons.count]].bias))
            }
        }
        var synapses: [Synapse] = []
        for (from, to) in zip(columns, columns.dropFirst()) {
            for a in from { for b in to { synapses.append(Synapse(a: a, b: b, weight: .random(in: -1...1))) } }
        }
        let layout = NetworkLayout(
            title: "Multilayer perceptron",
            subtitle: layers.map(String.init).joined(separator: " → ") + " neurons · \(synapses.count) weights",
            neurons: neurons, synapses: synapses, neuronSize: 0.06, restingTilt: 0)
        let dust = dust(11_600 * NeuralNetwork.scale, core: [1.3, 1, 0.4])
        layout.outline = neurons.map(\.point)
        // Brain part (its neuron + 1) to this layout's part.
        let parts = Dictionary(uniqueKeysWithValues: neurons.indices.map { (picked[$0] + 1, $0 + 1) })
        layout.ready = Task {
            await brain.ready?.value
            guard let previous = brain.shape else { return }
            layout.shape = layout.particles(around: dust, perNeuron: Array(repeating: 800 * NeuralNetwork.scale, count: neurons.count))
                .following(previous, parts: parts)
        }
        return layout
    }

    /// YOLO's architecture as Ultralytics draws it, in three columns. The backbone turns the image into feature maps,
    /// smaller and deeper going down (boxes: width and height by size, depth by channels); the neck mixes them back up
    /// (upsampling) then down again (strided convolutions), joining the backbone's maps at each scale; the head detects
    /// at three scales (small, medium, large objects). Each block holds its neurons: one per cell of each channel's map,
    /// in grids, larger and fewer going down.
    static func architecture() -> NetworkLayout {
        let (backbone, up, down, head): (Float, Float, Float, Float) = (-1.15, -0.25, 0.3, 1.15)
        let (p3, p4, p5): (Float, Float, Float) = (-0.05, -0.4, -0.75)
        func block(_ name: String, _ size: Int, _ channels: Int, _ x: Float, _ y: Float) -> Neuron {
            let side = 0.04 + 0.1 * log2(Float(size) / 20) / 5
            let depth = 0.02 * log2(Float(channels))
            let count = size * size * channels
            let amount = count >= 1_000_000 ? String(format: "%.1fM", Float(count) / 1e6) : "\(count / 1000)K"
            let what = channels == 3 ? "values" : "neurons"
            // Grids: 4 cells across at 20×20 up to 12 at 640×640; a slice per RGB channel, else 2 to 6 by depth.
            let grid = (cells: min(4 + 2 * Int(log2(Float(size) / 20)), 12), slices: channels == 3 ? 3 : Int(log2(Float(channels))) - 4)
            return Neuron(
                point: [x, y, 0], box: [side, side, depth], info: "\(name) · \(size)×\(size)×\(channels) · \(amount) \(what)",
                grid: grid)
        }
        let neurons = [
            block("Input image", 640, 3, backbone, 0.95),  // 0
            block("Conv", 320, 64, backbone, 0.6),  // 1
            block("C3k2", 160, 128, backbone, 0.28),  // 2
            block("C3k2 · P3", 80, 256, backbone, p3),  // 3
            block("C3k2 · P4", 40, 512, backbone, p4),  // 4
            block("SPPF · P5", 20, 1024, backbone, p5),  // 5
            block("Upsample + C3k2", 40, 512, up, p4),  // 6
            block("Upsample + C3k2", 80, 256, up, p3),  // 7
            block("Conv stride 2 + C3k2", 40, 512, down, p4),  // 8
            block("Conv stride 2 + C3k2", 20, 1024, down, p5),  // 9
            block("Detect · small objects", 80, 64, head, p3),  // 10
            block("Detect · medium objects", 40, 64, head, p4),  // 11
            block("Detect · large objects", 20, 64, head, p5),  // 12
        ]
        let edges = [(0, 1), (1, 2), (2, 3), (3, 4), (4, 5), (5, 6), (4, 6), (6, 7), (3, 7), (7, 8), (6, 8), (8, 9), (5, 9),
                     (7, 10), (8, 11), (9, 12)]
        let layout = NetworkLayout(
            title: "YOLO architecture", subtitle: "CNN · image → backbone → neck → head → boxes",
            neurons: neurons, synapses: edges.map { Synapse(a: $0.0, b: $0.1) }, neuronSize: 0, restingTilt: 0.15)
        (layout.restingTurn, layout.grown) = (-0.35, 1.15)
        layout.headers = [
            ("Backbone", [backbone, -1.0, 0], Array(0...5)), ("Neck", [(up + down) / 2, -1.0, 0], Array(6...9)),
            ("Head", [head, -1.0, 0], Array(10...12)),
        ]
        layout.outline = neurons.flatMap { n in [n.point - n.box!, n.point + n.box!] }
        // Each box: its edges (10,000 particles over all boxes, by edge length), then 12 particles per neuron of its grids
        // (per 60,000: × `scale`).
        let lengths = neurons.map { n in n.box!.x + n.box!.y + n.box!.z }
        let outlines = lengths.map { Int(Float(10_000 * NeuralNetwork.scale) * $0 / lengths.reduce(0, +)) }
        let dots = neurons.map { n in n.grid!.cells * n.grid!.cells * n.grid!.slices }
        let dust = dust(8_000 * NeuralNetwork.scale, core: [1.3, 0.9, 0.3])
        layout.shape = layout.particles(
            around: dust, part: dustPart, perNeuron: zip(outlines, dots).map { $0 + 12 * NeuralNetwork.scale * $1 }
        ) { i, k in
            let (box, grid) = (neurons[i].box!, neurons[i].grid!)
            guard k >= outlines[i] else { return layout.boxPoint(box, onEdge: true) }
            // Neuron d of the grids: its slice along the depth, its cell in the slice, a little jitter.
            let d = (k - outlines[i]) % dots[i]
            let (slice, cell, cells) = (d / (grid.cells * grid.cells), d % (grid.cells * grid.cells), grid.cells)
            let at = { (index: Int, count: Int) in -1 + (2 * Float(index) + 1) / Float(count) }
            let jitter = SIMD3<Float>(.random(in: -1...1), .random(in: -1...1), .random(in: -1...1)) * 0.0025
            return SIMD3(box.x * 0.85 * at(cell % cells, cells), box.y * 0.85 * at(cell / cells, cells), box.z * at(slice, grid.slices)) + jitter
        }
        return layout
    }

    /// `others` (as `part`) plus each neuron as a ball of its `perNeuron` particles (or at `point(neuron, k)` from its
    /// center) and the synapses as lines of the rest (part 0), spread by length; in random order, so each particle flies
    /// to a random point.
    private func particles(
        around others: [SIMD3<Float>], part: Int = 0, perNeuron: [Int], point: ((Int, Int) -> SIMD3<Float>)? = nil
    ) -> ParticleShape {
        var points = others
        var parts = [Int](repeating: part, count: points.count)
        for (i, neuron) in neurons.enumerated() {
            for k in 0..<perNeuron[i] {
                points.append(neuron.point + (point?(i, k) ?? randomDirection() * neuronSize))
                parts.append(i + 1)
            }
        }
        let forSynapses = NeuralNetwork.particles - points.count
        let lengths = synapses.map { simd_distance(neurons[$0.a].point, neurons[$0.b].point) }
        let total = lengths.reduce(0, +)
        var (s, start) = (0, Float(0))
        for k in 0..<forSynapses {
            let at = (Float(k) + .random(in: 0..<1)) / Float(forSynapses) * total
            while s < synapses.count - 1, start + lengths[s] < at { (start, s) = (start + lengths[s], s + 1) }
            let (a, b) = (neurons[synapses[s].a].point, neurons[synapses[s].b].point)
            points.append(a + (b - a) * min(max((at - start) / lengths[s], 0), 1))
            parts.append(0)
        }
        let order = points.indices.shuffled()
        return ParticleShape(
            points: order.map { points[$0] }, offsets: Array(repeating: .zero, count: points.count), parts: order.map { parts[$0] })
    }

    /// The part of the architecture's dust, so the next step can gather it (no neuron has it).
    private static let dustPart = 1_000_000

    /// `architecture` with its dust gathered into two yellow arrows, into its input (the image) and out of its output
    /// (the middle Detect block), labelled; every other particle stays where it is.
    static func inputOutput(of architecture: NetworkLayout) -> NetworkLayout {
        let n = architecture.neurons
        let layout = NetworkLayout(
            title: architecture.title, subtitle: architecture.subtitle, neurons: n, synapses: architecture.synapses,
            neuronSize: architecture.neuronSize, restingTilt: architecture.restingTilt)
        (layout.restingTurn, layout.grown, layout.base) = (architecture.restingTurn, architecture.grown, architecture)
        // Into the image's left face, out of the middle Detect block's right face, both along x.
        let inTip = n[0].point - [n[0].box!.x + 0.05, 0, 0]
        let outStart = n[11].point + [n[11].box!.x + 0.05, 0, 0]
        let arrows: [(tail: SIMD3<Float>, tip: SIMD3<Float>)] = [(inTip - [0.7, 0, 0], inTip), (outStart, outStart + [0.7, 0, 0])]
        layout.headers = architecture.headers + [
            ("Input", (arrows[0].tail + arrows[0].tip) / 2 + [0, 0.3, 0], [0]),
            ("Output", (arrows[1].tail + arrows[1].tip) / 2 + [0, 0.3, 0], [10, 11, 12]),
        ]
        layout.outline = architecture.outline + arrows.flatMap { [$0.tail, $0.tip] }
        guard var shape = architecture.shape else { return layout }
        let dust = shape.parts.indices.filter { shape.parts[$0] == dustPart }.shuffled()
        let yellow = SIMD3<Float>(0.8, 0.55, 0.08)  // deep: dense points add up to yellow, not white
        shape.colors = Array(repeating: nil, count: shape.points.count)
        for (k, i) in dust.enumerated() {
            let arrow = arrows[k % 2]
            shape.points[i] = arrowPoint(from: arrow.tail, to: arrow.tip)
            shape.colors[i] = yellow
        }
        layout.shape = shape
        return layout
    }

    /// A random point in an arrow from `tail` to `tip`: a round shaft, then a cone (the head), both filled, a little
    /// denser on their surface so they read.
    private static func arrowPoint(from tail: SIMD3<Float>, to tip: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_distance(tail, tip)
        let along = (tip - tail) / length
        let side = simd_normalize(simd_cross(along, abs(along.z) < 0.9 ? [0, 0, 1] : [0, 1, 0]))
        let up = simd_cross(along, side)
        let (shaft, shaftRadius, headRadius): (Float, Float, Float) = (length * 0.72, 0.025, 0.07)
        let angle = Float.random(in: 0..<(2 * .pi))
        let surface = Bool.random()
        var (t, radius): (Float, Float)
        if Float.random(in: 0...1) < 0.6 {
            (t, radius) = (.random(in: 0...shaft), shaftRadius)
        } else {
            // The cone: more points near its base, where it's wider.
            let f = 1 - Float.random(in: 0...1).squareRoot()
            (t, radius) = (shaft + f * (length - shaft), headRadius * (1 - f))
        }
        if !surface { radius *= Float.random(in: 0...1).squareRoot() }
        return tail + along * t + (side * cos(angle) + up * sin(angle)) * radius
    }

    /// Faint particles around a layout: even within `core` (half sizes), thinning out gradually beyond it (Gaussian,
    /// `softness` wide), so they have no hard edge.
    private static func dust(_ count: Int, core: SIMD3<Float>, softness: Float = 0.3) -> [SIMD3<Float>] {
        (0..<count).map { _ in
            let even = SIMD3<Float>(.random(in: -1...1), .random(in: -1...1), .random(in: -1...1)) * core
            // Box–Muller: three normal draws.
            let normal = SIMD3<Float>((0..<3).map { _ in
                (-2 * log(Float.random(in: Float.ulpOfOne...1))).squareRoot() * cos(2 * .pi * Float.random(in: 0...1))
            })
            return even + normal * softness
        }
    }

    /// A random point on the surface of a box (half size `half`), or on one of its 12 edges.
    fileprivate func boxPoint(_ half: SIMD3<Float>, onEdge: Bool) -> SIMD3<Float> {
        // A face by its area.
        let areas = [half.y * half.z, half.x * half.z, half.x * half.y]
        let pick = Float.random(in: 0..<areas.reduce(0, +))
        let axis = pick < areas[0] ? 0 : pick < areas[0] + areas[1] ? 1 : 2
        var p = SIMD3<Float>(.random(in: -1...1), .random(in: -1...1), .random(in: -1...1))
        p[axis] = Bool.random() ? 1 : -1
        if onEdge { p[(axis + Int.random(in: 1...2)) % 3] = Bool.random() ? 1 : -1 }
        return p * half
    }

    /// Where a neuron or block reaches from its center (its radius, or the larger side of its box face), in the shape's
    /// units.
    /// Whether one of the two is a variant of the other (or they're the same).
    func isVariant(of other: NetworkLayout) -> Bool { (base ?? self) === (other.base ?? other) }

    func reach(_ neuron: Neuron) -> Float { neuron.box.map { max($0.x, $0.y) } ?? neuronSize }

    private func randomDirection() -> SIMD3<Float> {
        while true {
            let v = SIMD3<Float>(.random(in: -1...1), .random(in: -1...1), .random(in: -1...1))
            let l = simd_length(v)
            if l > 0.01, l <= 1 { return v / l }
        }
    }
}

extension ParticleShape {
    /// The same points, reordered so that the particles of `previous`'s parts in `parts` (its part to this shape's) fly
    /// to their part here: a neuron of one layout becomes a neuron of the next. The others go anywhere.
    func following(_ previous: ParticleShape, parts map: [Int: Int]) -> ParticleShape {
        var pools = Dictionary(grouping: points.indices, by: { parts[$0] })
        var order = [Int?](repeating: nil, count: points.count)
        for k in order.indices {
            if let part = map[previous.parts[k]], let i = pools[part]?.popLast() { order[k] = i }
        }
        var rest = pools.values.flatMap { $0 }.shuffled()
        let indices = order.map { $0 ?? rest.popLast()! }
        return ParticleShape(
            points: indices.map { points[$0] }, offsets: indices.map { offsets[$0] }, parts: indices.map { parts[$0] },
            colors: colors.isEmpty ? [] : indices.map { colors[$0] })
    }
}
