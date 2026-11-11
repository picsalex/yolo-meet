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
    /// The same, with arrows into its input and out of its output.
    let inputOutput: NetworkLayout
    /// The same, its dust gathered into a picture at the input: what the model looks at.
    let picture: NetworkLayout
    /// The picture zoomed in: all the particles become its pixels, squares of one color each.
    let pixels: NetworkLayout
    /// Its pixels split into three layers back to back, red, green and blue.
    let channels: NetworkLayout
    /// The same picture as one gray layer.
    let grayscale: NetworkLayout
    /// The same picture as five bands back to back (blue, green, red, red edge, near-infrared).
    let multispectral: NetworkLayout
    /// How far a splitting layout's parts have come apart (0...1, linear), shared so it goes back smoothly too.
    var split: Float = 0
    /// The picture at the model's input again, the bands gliding back into it.
    let pictureAgain: NetworkLayout
    /// The same, its pixels flowing through the model as pulses of light (`NetworkLayout.flow`), over and over.
    let inference: NetworkLayout
    /// The inference's output on its input: a large picture, then each task's output on it.
    let results: NetworkLayout
    let tasks: TaskLayouts
    /// The recap: the picture, YOLO, and the seven tasks' outputs.
    let recap: NetworkLayout
    /// The rotation the particles last showed, so the next step's view turns from it instead of jumping.
    var rotation: simd_quatf?

    init() {
        system.brightness = 0.45 / Float(Self.scale).squareRoot()  // points add light: about the same look, denser
        brain = .brain()
        perceptron = .perceptron(layers: [10, 5, 8], from: brain)
        architecture = .architecture()
        inputOutput = .inputOutput(of: architecture)
        picture = .picture(of: inputOutput)
        pixels = .pixels(of: picture)
        channels = .channels(of: pixels)
        grayscale = .grayscale(of: pixels, after: channels)
        multispectral = .multispectral(of: pixels, after: grayscale)
        pictureAgain = .returning(to: picture, from: multispectral, through: pixels)
        inference = .flow(of: picture, through: architecture)
        results = .results(after: inference, picture: picture)
        tasks = NetworkLayout.tasks(results)
        recap = .recap(tasks, architecture: architecture)
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
    var restingTurn: Float = 0
    /// How much a touched neuron or block grows.
    private(set) var grown: CGFloat = 1.8
    /// Labels under parts of the layout (e.g. its columns), at points of it, with the neurons or blocks they name
    /// (outlined when a header is touched in action mode).
    var headers: [(text: String, point: SIMD3<Float>, members: [Int])] = []
    /// The headers' text size at 720 px of stage height.
    var headerSize: CGFloat = 24
    /// Measurements along the layout's sides (`Dimension`: its size, from, to), e.g. a picture's width and height.
    private(set) var dimensions: [(text: String, from: SIMD3<Float>, to: SIMD3<Float>)] = []
    /// Drawn arrows, labelled, between points of the layout (e.g. into its input).
    var arrows: [(text: String, tail: SIMD3<Float>, tip: SIMD3<Float>)] = []
    /// Lines joining into an arrow's tail, by its text (points of the layout, each line ending at the tail).
    var arrowFeeds: [String: [[SIMD3<Float>]]] = [:]
    /// Whether its particles move on after it forms, eased (`ParticleShape.offsets`, `ParticleSystem.explode`), when
    /// it follows `splitsFrom`: they start where that layout has them and glide to their place, e.g. a picture
    /// growing or coming apart in layers. From any other layout they go straight to their place. Its headers and
    /// outline are where they end up.
    var splits = false
    weak var splitsFrom: NetworkLayout?
    /// A layout formed first when coming from the one it `splitsFrom`, this one then gliding on from it: e.g. the
    /// perceptron's neurons leaving the brain before the rest of the brain becomes its connections.
    var prelude: NetworkLayout?
    /// `shape` once it has fully moved on (`splits`): each point where its offset takes it, no offsets left, so a
    /// part grown around its center (`ParticleSystem.highlight`) grows where it is.
    var settled: ParticleShape? {
        if settledShape == nil, let shape {
            var settled = shape
            settled.points = zip(shape.points, shape.offsets).map { $0 + $1 }
            settled.offsets = Array(repeating: .zero, count: shape.points.count)
            if let arrivedColors { settled.colors = arrivedColors }
            settledShape = settled
        }
        return settledShape
    }
    private var settledShape: ParticleShape?
    /// The particles' colors once `settled`, faded to as they arrive, if not their colors on the way (e.g. particles
    /// that glide black, unseen, and light up once there).
    var arrivedColors: [SIMD3<Float>?]?
    /// Particles moving through the layout over time, animated by the effect every frame; nil: it stands still.
    private(set) var flow: Flow?
    /// What the flow's output shows once its particles are through (e.g. "Cat"), beside the output arrow's tip.
    private(set) var flowResult: String?
    /// The particles' points; nil until ready (the brain's surface is built in the background).
    var shape: ParticleShape?
    /// Some points around the layout, to place its title.
    var outline: [SIMD3<Float>] = []
    /// The layout this one is a variant of (same blocks, some particles moved), if any.
    weak var base: NetworkLayout?
    /// Done once `shape` is set.
    private var ready: Task<Void, Never>?

    init(title: String, subtitle: String, neurons: [Neuron], synapses: [Synapse], neuronSize: Float, restingTilt: Float) {
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
            var shape = layout.particles(around: dust, perNeuron: Array(repeating: 800 * NeuralNetwork.scale, count: neurons.count))
                .following(previous, parts: parts)
            // From the brain: first only the picked neurons glide out of it to their place here (each the same ball of
            // particles), the rest of the brain still; then everything glides on into the perceptron.
            let moved = previous.points.indices.map { k -> SIMD3<Float> in
                let part = previous.parts[k]
                guard let mine = parts[part] else { return previous.points[k] }
                return neurons[mine - 1].point + (previous.points[k] - brain.neurons[part - 1].point)
            }
            let prelude = NetworkLayout(
                title: layout.title, subtitle: layout.subtitle, neurons: [], synapses: [], neuronSize: brain.neuronSize, restingTilt: 0)
            (prelude.base, prelude.splits, prelude.splitsFrom) = (brain, true, brain)
            prelude.shape = ParticleShape(
                points: previous.points, offsets: zip(moved, previous.points).map { $0 - $1 }, parts: previous.parts)
            shape.offsets = zip(shape.points, moved).map { $0 - $1 }
            shape.points = moved
            (layout.prelude, layout.splits, layout.splitsFrom) = (prelude, true, prelude)
            layout.shape = shape
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
    static let dustPart = 1_000_000

    /// `architecture` with two drawn arrows, into its input (the image) and out of its output (the middle Detect block);
    /// its particles are the same.
    static func inputOutput(of architecture: NetworkLayout) -> NetworkLayout {
        let layout = variant(of: architecture)
        let n = architecture.neurons
        // Into the image's left face, along x; out of the head: a line from each Detect block's right face, joining
        // level with the middle one, then the arrow along x.
        let inTip = n[0].point - [n[0].box!.x + 0.06, 0, 0]
        let heads = [10, 11, 12]
        let join = heads.map { n[$0].point.x + n[$0].box!.x }.max()! + 0.14
        let outTail = SIMD3<Float>(join, n[11].point.y, n[11].point.z)
        layout.arrows = [("Input", inTip - [0.42, 0, 0], inTip), ("Output", outTail, outTail + [0.42, 0, 0])]
        layout.arrowFeeds["Output"] = heads.map { h in
            let face = n[h].point + [n[h].box!.x + 0.03, 0, 0]
            return [face, [join, face.y, face.z], outTail]
        }
        layout.outline = architecture.outline + layout.arrows.flatMap { [$0.tail, $0.tip] }
        layout.shape = architecture.shape
        return layout
    }

    /// `inputOutput` with its dust gathered into a picture at the input arrow's tail (what the model looks at): a
    /// cat, a pixel per particle, in color; every other particle stays where it is.
    static func picture(of inputOutput: NetworkLayout) -> NetworkLayout {
        let layout = variant(of: inputOutput)
        (layout.arrows, layout.arrowFeeds) = (inputOutput.arrows, inputOutput.arrowFeeds)
        // A square picture, its right edge just before the input arrow.
        let side: Float = 1
        let center = inputOutput.arrows[0].tail - [0.06 + side / 2, 0, 0]
        layout.outline = inputOutput.outline + [center - [side / 2, side / 2, 0], center + [side / 2, side / 2, 0]]
        guard var shape = inputOutput.shape else { return layout }
        let dust = shape.parts.indices.filter { shape.parts[$0] == dustPart }
        let cells = Int(Float(dust.count).squareRoot())
        let pixels = catPicture(cells)
        shape.colors = Array(repeating: nil, count: shape.points.count)
        for (k, i) in dust.enumerated() {
            // A pixel each (row by row, from the top); the few left over on random pixels.
            let p = k < cells * cells ? k : Int.random(in: 0..<cells * cells)
            let (x, y) = (Float(p % cells) + 0.5, Float(p / cells) + 0.5)
            shape.points[i] = center + [(x / Float(cells) - 0.5) * side, (0.5 - y / Float(cells)) * side, .random(in: -0.004...0.004)]
            shape.colors[i] = pixels[p] * 2  // brighter than full: particles are light added over the camera image
        }
        layout.shape = shape
        return layout
    }

    /// Pixels on a side in `pixels`.
    nonisolated static let pixelCells = 32
    /// The picture's side in `pixels` and `channels`, in the shape's units.
    private static let pixelSide: Float = 2.6

    /// `picture` zoomed in: every particle becomes part of a pixel, a square of one color (the same share of particles
    /// each); the picture's particles keep their place in it, the architecture's fill in. It splits from `picture`:
    /// every particle starts where it is there and glides in, so the picture grows rather than forming anew.
    static func pixels(of picture: NetworkLayout) -> NetworkLayout {
        let (cells, side) = (pixelCells, pixelSide)
        let layout = NetworkLayout(
            title: "Pixels", subtitle: "\(cells) × \(cells) pixels · each a red, a green and a blue value",
            neurons: [], synapses: [], neuronSize: 0.02, restingTilt: 0)
        (layout.base, layout.splits, layout.splitsFrom) = (picture.base ?? picture, true, picture)
        layout.outline = [[-side / 2, -side / 2, 0], [side / 2, side / 2, 0], [-side / 2, side / 2, 0], [side / 2, -side / 2, 0]]
        // Its width under it, its height on its left.
        let (h, g) = (side / 2, Float(0.08))
        layout.dimensions = [("\(cells) px", [-h, -h - g, 0], [h, -h - g, 0]), ("\(cells) px", [-h - g, h, 0], [-h - g, -h, 0])]
        guard let previous = picture.shape else { return layout }
        let n = previous.points.count
        let (lo, hi) = (picture.outline[picture.outline.count - 2], picture.outline[picture.outline.count - 1])
        let quota = (n + cells * cells - 1) / (cells * cells)
        var cellOf = [Int](repeating: -1, count: n)
        var counts = [Int](repeating: 0, count: cells * cells)
        for i in 0..<n where previous.parts[i] == dustPart {
            let p = previous.points[i]
            let (fx, fy) = ((p.x - lo.x) / (hi.x - lo.x), (hi.y - p.y) / (hi.y - lo.y))
            let c = min(max(Int(fy * Float(cells)), 0), cells - 1) * cells + min(max(Int(fx * Float(cells)), 0), cells - 1)
            if counts[c] < quota { (cellOf[i], counts[c]) = (c, counts[c] + 1) }
        }
        var open = counts.indices.flatMap { Array(repeating: $0, count: quota - counts[$0]) }.shuffled()
        for i in 0..<n where cellOf[i] < 0 { cellOf[i] = open.popLast()! }
        let colors = catPicture(cells)
        // Each pixel's particles on an even grid (a few slots spare), so it reads as a solid square.
        let fill: Float = 0.84  // of a pixel's side: the gaps show the grid
        let slots = Int(Float(quota).squareRoot().rounded(.up))
        var used = [Int](repeating: 0, count: cells * cells)
        let order = (0..<cells * cells).map { _ in (0..<slots * slots).shuffled() }
        let points = cellOf.map { c -> SIMD3<Float> in
            let slot = order[c][used[c]]
            used[c] += 1
            let (sx, sy) = ((Float(slot % slots) + 0.5) / Float(slots) - 0.5, (Float(slot / slots) + 0.5) / Float(slots) - 0.5)
            let x = (Float(c % cells) + 0.5 + sx * fill) / Float(cells)
            let y = (Float(c / cells) + 0.5 + sy * fill) / Float(cells)
            return [(x - 0.5) * side, (0.5 - y) * side, .random(in: -0.004...0.004)]
        }
        layout.shape = ParticleShape(
            points: previous.points, offsets: zip(points, previous.points).map { $0 - $1 }, parts: Array(repeating: 0, count: n),
            colors: cellOf.map { colors[$0] * 1.1 })  // dense: dimmer than the picture's single particles
        return layout
    }

    /// `pixels` split into its red, green and blue layers back to back (red in front), each a third of every pixel's
    /// particles in that color alone: from the front they add up to the picture, turned they come apart.
    static func channels(of pixels: NetworkLayout) -> NetworkLayout {
        layers(
            "RGB channels", "\(pixelCells) × \(pixelCells) × 3 values · red, green, blue", of: pixels, after: pixels,
            bands: [("Red", [1, 0, 0]), ("Green", [0, 1, 0]), ("Blue", [0, 0, 1])], values: { [$0.x, $0.y, $0.z] },
            scale: 0.75, depth: 1.2, aside: 0.35)
    }

    /// `channels` down to one layer of brightness: the red layer turns gray where it is, and the green and blue ones
    /// fade away (their particles go black, adding no light, and stay there).
    static func grayscale(of pixels: NetworkLayout, after channels: NetworkLayout) -> NetworkLayout {
        let layout = NetworkLayout(
            title: "Grayscale", subtitle: "\(pixelCells) × \(pixelCells) × 1 value · a brightness per pixel",
            neurons: [], synapses: [], neuronSize: 0.02, restingTilt: channels.restingTilt)
        (layout.restingTurn, layout.base) = (channels.restingTurn, channels.base)
        layout.headers = channels.headers.prefix(1).map { ("Gray", $0.point, $0.members) }
        layout.outline = Array(channels.outline.prefix(4))  // the first layer's corners
        guard let picture = pixels.shape, let from = channels.shape else { return layout }
        let colors = picture.points.indices.map { i -> SIMD3<Float>? in
            guard i % 3 == 0 else { return .zero }
            let c = picture.colors[i] ?? .one
            // Brightness, with some contrast (white particles add up fast), for a third of the particles.
            return .one * 1.8 * pow(min(0.299 * c.x + 0.587 * c.y + 0.114 * c.z, 1), 1.6)
        }
        layout.shape = ParticleShape(
            points: zip(from.points, from.offsets).map { $0 + $1 }, offsets: Array(repeating: .zero, count: from.points.count),
            parts: Array(repeating: 0, count: from.points.count), colors: colors)
        return layout
    }

    /// The single gray layer fanned out into five bands back to back, as a multispectral camera sees them: blue,
    /// green, red, red edge and near-infrared (the last two made up from the picture: high on the grass, as
    /// vegetation is in near-infrared).
    static func multispectral(of pixels: NetworkLayout, after grayscale: NetworkLayout) -> NetworkLayout {
        layers(
            "Multispectral", "\(pixelCells) × \(pixelCells) × 5 values · beyond what the eye sees", of: pixels, after: grayscale,
            bands: [
                ("Blue", [0.25, 0.45, 1]), ("Green", [0.2, 1, 0.3]), ("Red", [1, 0.2, 0.15]),
                ("Red edge", [1, 0.35, 0.6]), ("Near-IR", [0.75, 0.4, 1]),
            ],
            values: { c in
                let nir = min(max(0.15 + 1.1 * c.y - 0.6 * c.z, 0), 1)
                return [c.z, c.y, c.x, (c.x + nir) / 2, nir]
            },
            scale: 0.6, depth: 0.8, aside: 0.25)
    }

    /// `pixels` as layers back to back (the first in front), each a band (name, tint) holding a share of every
    /// pixel's particles in its tint times the band's value there (`values` of the pixel's color, one per band), so
    /// that from the front they add up. Turned, a little apart sideways too, each shows beside the next. Its particles
    /// start where `previous` leaves them and glide to their layer (`splits`).
    private static func layers(
        _ title: String, _ subtitle: String, of pixels: NetworkLayout, after previous: NetworkLayout,
        bands: [(name: String, tint: SIMD3<Float>)], values: (SIMD3<Float>) -> [Float],
        scale: Float, depth: Float, aside: Float
    ) -> NetworkLayout {
        let layout = NetworkLayout(title: title, subtitle: subtitle, neurons: [], synapses: [], neuronSize: 0.02, restingTilt: 0.12)
        (layout.restingTurn, layout.base, layout.splits, layout.splitsFrom) = (-0.9, pixels.base ?? pixels, true, previous)
        let n = bands.count
        let middle = Float(n - 1) / 2
        let offset = { (c: Int) in SIMD3<Float>(aside * (Float(c) - middle), 0, depth * (middle - Float(c))) }
        layout.headers = bands.indices.map { c in
            (bands[c].name, SIMD3<Float>(0, -pixelSide * scale / 2 - 0.06, 0) + offset(c), [Int]())
        }
        layout.outline = bands.indices.flatMap { c in pixels.outline.map { $0 * scale + offset(c) } }
        guard let picture = pixels.shape, let from = previous.shape else { return layout }
        let start = zip(from.points, from.offsets).map { $0 + $1 }
        var points = [SIMD3<Float>](), colors = [SIMD3<Float>?]()
        for i in picture.points.indices {
            let c = i % n
            points.append((picture.points[i] + picture.offsets[i]) * scale + offset(c))
            let color = picture.colors[i] ?? .one
            colors.append(bands[c].tint * values(color)[c] * Float(n))  // a share of the particles: they add up
        }
        layout.shape = ParticleShape(
            points: start, offsets: zip(points, start).map { $0 - $1 }, parts: Array(repeating: 0, count: start.count), colors: colors)
        return layout
    }

    /// `target` again, its particles gliding to it from where `previous` leaves them (`splits`); with `through`, they
    /// first glide to that layout, in its colors (its `prelude`: e.g. layers merging back into the picture), then on.
    static func returning(to target: NetworkLayout, from previous: NetworkLayout, through stop: NetworkLayout? = nil) -> NetworkLayout {
        let layout = variant(of: target)
        (layout.arrows, layout.outline, layout.splits, layout.splitsFrom) = (target.arrows, target.outline, true, previous)
        layout.arrowFeeds = target.arrowFeeds
        guard var shape = target.shape, var from = previous.shape else { return layout }
        if let stop, let there = stop.shape {
            let prelude = variant(of: target)
            (prelude.splits, prelude.splitsFrom) = (true, previous)
            var first = there
            let start = zip(from.points, from.offsets).map { $0 + $1 }
            first.offsets = zip(zip(there.points, there.offsets), start).map { $0.0 + $0.1 - $1 }
            first.points = start
            prelude.shape = first
            (layout.prelude, layout.splitsFrom, from) = (prelude, prelude, first)
        }
        let start = zip(from.points, from.offsets).map { $0 + $1 }
        shape.offsets = zip(zip(shape.points, shape.offsets), start).map { $0.0 + $0.1 - $1 }
        shape.points = start
        layout.shape = shape
        return layout
    }

    /// `picture`, its pixels flowing through `architecture` (the rest standing still): each pixel's particle goes in
    /// along the input arrow, then through the blocks along a random path of their connections, from the backbone to
    /// a Detect block of the head and out of it. They leave in pulses, the column nearest the arrow first.
    static func flow(of picture: NetworkLayout, through architecture: NetworkLayout) -> NetworkLayout {
        let layout = variant(of: picture, title: "Inference", subtitle: "also called prediction or forward propagation")
        (layout.arrows, layout.outline, layout.shape) = (picture.arrows, picture.outline, picture.shape)
        layout.arrowFeeds = picture.arrowFeeds
        guard let shape = picture.shape else { return layout }
        let blocks = architecture.neurons
        var next: [Int: [Int]] = [:]
        for s in architecture.synapses { next[s.a, default: []].append(s.b) }
        let (tail, tip) = (picture.arrows[0].tail, picture.arrows[0].tip)
        let (lo, hi) = (picture.outline[picture.outline.count - 2], picture.outline[picture.outline.count - 1])
        var particles: [Int] = [], routes: [[SIMD3<Float>]] = [], colors: [SIMD3<Float>] = [], departures: [Float] = []
        var visits: [[Int]] = []
        for i in shape.points.indices where shape.parts[i] == dustPart {
            let start = shape.points[i]
            let spread = SIMD3<Float>(0, .random(in: -0.025...0.025), .random(in: -0.025...0.025))
            var route = [start, tail + spread, tip + spread]
            var visit = [-1, -1, -1]
            var block = 0
            while true {
                let box = blocks[block].box!
                route.append(blocks[block].point + box * SIMD3(.random(in: -0.7...0.7), .random(in: -0.7...0.7), .random(in: -0.7...0.7)))
                visit.append(block)
                guard let pick = next[block]?.randomElement() else { break }
                block = pick
            }
            // Out of the head: along its line into the output arrow, and along it.
            if let output = picture.arrows.last, let feed = picture.arrowFeeds[output.text]?.first(where: {
                simd_distance($0[0], blocks[block].point) < blocks[block].box!.x + 0.1
            }) {
                let jitter = SIMD3<Float>(0, .random(in: -0.015...0.015), .random(in: -0.015...0.015))
                route += feed.dropFirst().map { $0 + jitter } + [output.tip - [0.04, 0, 0] + jitter]
                visit += Array(repeating: -1, count: feed.count)
            } else {
                route.append(blocks[block].point + [blocks[block].box!.x + 0.45, .random(in: -0.02...0.02), 0])
                visit.append(-1)
            }
            visits.append(visit)
            let column = (start.x - lo.x) / (hi.x - lo.x)
            particles.append(i)
            routes.append(route)
            colors.append(shape.colors.isEmpty ? .one : shape.colors[i] ?? .one)
            departures.append(Flow.fadeIn + Float(Int((1 - column) * 6)) * 0.4 + .random(in: 0...0.12))
        }
        let members = blocks.indices.map { b in shape.parts.indices.filter { shape.parts[$0] == b + 1 } }
        layout.flow = Flow(
            particles: particles, routes: routes, colors: colors, departures: departures, visits: visits, blocks: members)
        layout.flowResult = "Cat"
        return layout
    }

    /// Particles of a layout travelling along routes (its points) over a step's timeline, glowing as pulses of light:
    /// each waits at the route's start in its own color, leaves at its departure, turning gold, and fades out at the
    /// end. Looping, they fade back in at their start first.
    struct Flow {
        /// Seconds the particles take to fade back in at their start when the timeline starts over, and to travel.
        static let fadeIn: Float = 0.8, travel: Float = 3
        let particles: [Int]
        let routes: [[SIMD3<Float>]]
        let colors: [SIMD3<Float>]
        let departures: [Float]
        /// The block (index in `blocks`) at each point of each route, -1 for none.
        let visits: [[Int]]
        /// The particles of each block the routes go through, to light up as they pass.
        let blocks: [[Int]]
        /// When nearly all the particles are through (seconds into the timeline).
        var end: Float { (departures.max() ?? 0) + Self.travel * 0.9 }
        /// Each route's distance from its start at each of its points.
        private let distances: [[Float]]
        private let seeds: [Float]

        init(
            particles: [Int], routes: [[SIMD3<Float>]], colors: [SIMD3<Float>], departures: [Float], visits: [[Int]], blocks: [[Int]]
        ) {
            (self.particles, self.routes, self.colors, self.departures) = (particles, routes, colors, departures)
            (self.visits, self.blocks) = (visits, blocks)
            distances = routes.map { route in
                var total: Float = 0
                return route.indices.map { j in
                    if j > 0 { total += simd_distance(route[j - 1], route[j]) }
                    return total
                }
            }
            seeds = particles.map { _ in .random(in: 0...100) }
        }

        /// The particles' points and colors `time` seconds into the timeline (`again`: it started over, so they fade
        /// in at their start), and how many are in each block.
        func frame(at time: Float, again: Bool) -> (points: [SIMD3<Float>], colors: [SIMD3<Float>], inside: [Int]) {
            var inside = [Int](repeating: 0, count: blocks.count)
            let gold = SIMD3<Float>(1, 0.78, 0.22) * 3.5
            var points = [SIMD3<Float>](), colors = [SIMD3<Float>]()
            points.reserveCapacity(particles.count)
            colors.reserveCapacity(particles.count)
            let shown = again ? min(time / Self.fadeIn, 1) : 1
            for k in particles.indices {
                let t = time - departures[k]
                let route = routes[k]
                guard t > 0 else {
                    points.append(route[0])
                    colors.append(self.colors[k] * shown * shown * (3 - 2 * shown))
                    continue
                }
                let s = t / Self.travel
                guard s < 1 else {  // arrived: unseen (black) back at the start, for the next time
                    points.append(route[0])
                    colors.append(.zero)
                    continue
                }
                let along = distances[k], d = s * along.last!
                var j = 1
                while j < along.count - 1, along[j] < d { j += 1 }
                let f = (d - along[j - 1]) / max(along[j] - along[j - 1], 1e-5)
                let at = visits[k][f < 0.5 ? j - 1 : j]
                if at >= 0 { inside[at] += 1 }
                // A crackle around the path, and bands of light running along it.
                let seed = seeds[k]
                let crackle = SIMD3<Float>(sin(time * 37 + seed), cos(time * 31 + seed * 1.7), sin(time * 23 + seed * 2.3)) * 0.012
                points.append(route[j - 1] + (route[j] - route[j - 1]) * min(f, 1) + crackle)
                let wave = 0.5 + 0.5 * sin(2 * .pi * (s * 5 - time * 2))
                let toGold = min(t / 0.3, 1), fade = s > 0.85 ? 1 - (s - 0.85) / 0.15 : 1
                colors.append((self.colors[k] + (gold * (0.5 + wave * wave) - self.colors[k]) * toGold) * fade)
            }
            return (points, colors, inside)
        }
    }

    /// A new layout with `base`'s blocks, synapses, title (or its own), view and headers (its particles to set).
    static func variant(of base: NetworkLayout, title: String? = nil, subtitle: String? = nil) -> NetworkLayout {
        let layout = NetworkLayout(
            title: title ?? base.title, subtitle: subtitle ?? base.subtitle, neurons: base.neurons, synapses: base.synapses,
            neuronSize: base.neuronSize, restingTilt: base.restingTilt)
        (layout.restingTurn, layout.grown, layout.base, layout.headers) = (base.restingTurn, base.grown, base.base ?? base, base.headers)
        return layout
    }

    /// A cat's face on a sky over grass, `size` pixels square, row by row from the top (rgb 0...1).
    static func catPicture(_ size: Int) -> [SIMD3<Float>] { catDrawing(size) }

    /// What each pixel of the cat picture shows (`size` square, row by row from the top), as `Scene` raw values.
    static func catClasses(_ size: Int, tilt: CGFloat = 0) -> [Int] {
        catDrawing(size, classes: true, tilt: tilt).map { Int(($0.x * 255 / 60).rounded()) }
    }

    /// The parts of the cat picture, for its class map.
    enum Scene: Int { case sky, sun, grass, cat }

    /// The cat's center on the 100 × 100 canvas, which it tilts around.
    static let catCenter = CGPoint(x: 50, y: 45)

    /// The cat picture (rgb 0...1), or its class map (`classes`: each part a flat red of 60 × its `Scene`, no
    /// antialiasing, no whiskers), the cat tilted by `tilt` radians (counterclockwise) around `catCenter`.
    static func catDrawing(_ size: Int, classes: Bool = false, tilt: CGFloat = 0) -> [SIMD3<Float>] {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setShouldAntialias(!classes)
        context.scaleBy(x: CGFloat(size) / 100, y: CGFloat(size) / 100)  // drawn on a 100 × 100 canvas, y up
        func fill(_ part: Scene, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ path: () -> Void) {
            if classes {
                context.setFillColor(red: CGFloat(part.rawValue * 60) / 255, green: 0, blue: 0, alpha: 1)
            } else {
                context.setFillColor(red: r, green: g, blue: b, alpha: 1)
            }
            path()
            context.fillPath()
        }
        fill(.sky, 0.45, 0.75, 1) { context.addRect(CGRect(x: 0, y: 0, width: 100, height: 100)) }
        fill(.sun, 1, 0.9, 0.35) { context.addEllipse(in: CGRect(x: 76, y: 76, width: 16, height: 16)) }
        fill(.grass, 0.3, 0.8, 0.3) { context.addRect(CGRect(x: 0, y: 0, width: 100, height: 22)) }
        // The cat, tilted around its center.
        context.translateBy(x: catCenter.x, y: catCenter.y)
        context.rotate(by: tilt)
        context.translateBy(x: -catCenter.x, y: -catCenter.y)
        // Ears, then the head over them.
        for (x, flip) in [(28.0, 1.0), (72.0, -1.0)] {
            fill(.cat, 1, 0.55, 0.15) { context.addLines(between: [CGPoint(x: x - 12 * flip, y: 62), CGPoint(x: x - 4 * flip, y: 88), CGPoint(x: x + 12 * flip, y: 66)]) }
            fill(.cat, 1, 0.6, 0.7) { context.addLines(between: [CGPoint(x: x - 7 * flip, y: 64), CGPoint(x: x - 3 * flip, y: 80), CGPoint(x: x + 6 * flip, y: 66)]) }
        }
        fill(.cat, 1, 0.55, 0.15) { context.addEllipse(in: CGRect(x: 20, y: 14, width: 60, height: 56)) }  // head
        fill(.cat, 1, 0.85, 0.6) { context.addEllipse(in: CGRect(x: 36, y: 16, width: 28, height: 24)) }  // muzzle
        for x in [33.0, 55.0] {
            fill(.cat, 0.4, 1, 0.35) { context.addEllipse(in: CGRect(x: x, y: 42, width: 12, height: 13)) }  // eyes
            fill(.cat, 0, 0, 0) { context.addEllipse(in: CGRect(x: x + 4.5, y: 43, width: 3, height: 11)) }  // pupils
        }
        fill(.cat, 1, 0.45, 0.6) { context.addLines(between: [CGPoint(x: 45, y: 36), CGPoint(x: 55, y: 36), CGPoint(x: 50, y: 30)]) }  // nose
        if !classes {
            // Whiskers.
            context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.setLineWidth(1.2)
            for (side, y) in [(-1.0, 30.0), (-1.0, 26.0), (1.0, 30.0), (1.0, 26.0)] {
                context.move(to: CGPoint(x: 50 + side * 10, y: 29))
                context.addLine(to: CGPoint(x: 50 + side * 34, y: y + (y - 28) * 2))
            }
            context.strokePath()
        }
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<size * size).map { i in
            SIMD3(Float(bytes[i * 4]), Float(bytes[i * 4 + 1]), Float(bytes[i * 4 + 2])) / 255
        }
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
