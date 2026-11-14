import SpriteKit
import simd

/// The task quiz's particles: the head's three Detect blocks, twice as large, on the left of the stage, with the lines
/// from each joining into the output arrow, and the rest of the particles in a small ball on the right, a few of them
/// lit and swirling (`TaskQuizEffect`). The blocks glide from the inference (`splitsFrom`, so without stagger).
/// Formed by `NetworkEffect(_:_:at:)` centered on the stage, where the fractions below put things.
struct TaskQuiz {
    /// The blocks (neurons 0...2, parts 1...3) and the ball.
    let layout: NetworkLayout
    /// The output arrow out of the blocks (points of the layout), drawn by `TaskQuizEffect`.
    let tail, tip: SIMD3<Float>
    /// The lines from each block's right face joining into the arrow's tail.
    let feeds: [[SIMD3<Float>]]
    /// The ball's center (shape units).
    let ball: SIMD3<Float>
    /// The particles of the ball (all but the blocks'), the lit ones first.
    let rest: [Int]
    /// How each lit particle swirls: its point around the ball's center at first, turning about `axis` at `speed`
    /// (radians per second), and breathing in and out from the center (`phase`, radians).
    let swirl: [(offset: SIMD3<Float>, axis: SIMD3<Float>, speed: Float, phase: Float)]

    /// Where the middle block and the ball go, in fractions of the stage, the layout centered on it at zoom 1.
    static let blocksAt = CGPoint(x: 0.05, y: 0.5), ballAt = CGPoint(x: 0.8, y: 0.5)
    /// How much larger the blocks are than in the architecture; the ball's radius (shape units); its lit particles, and
    /// their brightness (of the system's color).
    static let grow: Float = 2, ballRadius: Float = 0.6, lit = 8_000 * NeuralNetwork.scale, litBrightness: Float = 0.6
    /// How far each lit particle breathes in and out (a fraction of its distance to the center), and how fast.
    static let breath: Float = 0.18, breathSpeed: Float = 1.6

    init(after inference: NetworkLayout, architecture: NetworkLayout) {
        let n = architecture.neurons
        let heads = [10, 11, 12]
        // The view the layout rests at (the architecture's), to find where stage points are in the shape.
        let view = KeyTurn(restingTilt: architecture.restingTilt, restingTurn: architecture.restingTurn, spinning: false).rotation
        let inShape = { (at: CGPoint) -> SIMD3<Float> in
            let size = Float(NetworkEffect.size)
            return view.inverse.act([Float(at.x - 0.5) * 1280 / size, Float(at.y - 0.5) * 720 / size, 0])
        }
        let middle = n[11].point, center = inShape(Self.blocksAt)
        let place = { (p: SIMD3<Float>) in center + (p - middle) * Self.grow }

        let neurons = heads.map { h in
            NetworkLayout.Neuron(point: place(n[h].point), box: n[h].box.map { $0 * Self.grow }, info: n[h].info, grid: n[h].grid)
        }
        layout = NetworkLayout(
            title: "", subtitle: "", neurons: neurons, synapses: [], neuronSize: 0, restingTilt: architecture.restingTilt)
        (layout.restingTurn, layout.grown, layout.splitsFrom) = (architecture.restingTurn, 1.15, inference)
        layout.outline = neurons.flatMap { Box.corners($0.point, half: $0.box!) }

        let output = inference.arrows.last
        tail = place(output?.tail ?? middle)
        tip = tail + [0.5, 0, 0]
        feeds = (inference.arrowFeeds[output?.text ?? ""] ?? []).map { $0.map(place) }
        ball = inShape(Self.ballAt)

        guard let from = inference.shape else {
            (rest, swirl) = ([], [])
            return
        }
        let part = Dictionary(uniqueKeysWithValues: heads.enumerated().map { ($1 + 1, $0 + 1) })  // architecture's → ours
        var (points, parts, colors) = ([SIMD3<Float>](), [Int](), [SIMD3<Float>?]())
        var (rest, swirl) = ([Int](), [(offset: SIMD3<Float>, axis: SIMD3<Float>, speed: Float, phase: Float)]())
        for i in from.points.indices {
            if let p = part[from.parts.isEmpty ? 0 : from.parts[i]] {
                points.append(place(from.points[i]))
                parts.append(p)
                colors.append(from.colors.isEmpty ? nil : from.colors[i])
            } else {
                // Uniform in the ball; the shape's random order makes the first ones a random few to light.
                let offset = SIMD3<Float>.randomDirection() * Self.ballRadius * pow(Float.random(in: 0...1), 1 / 3)
                let lit = rest.count < Self.lit
                if lit {
                    let speed = Float.random(in: 0.6...1.5) * (Bool.random() ? 1 : -1)
                    let axis = simd_normalize(SIMD3<Float>(.random(in: -0.6...0.6), 1, .random(in: -0.6...0.6)))
                    swirl.append((offset, axis, speed, .random(in: 0...2 * .pi)))
                }
                rest.append(i)
                points.append(ball + offset)
                parts.append(0)
                colors.append(lit ? nil : .zero)  // black: unseen
            }
        }
        (self.rest, self.swirl) = (rest, swirl)
        layout.shape = ParticleShape(
            points: points, offsets: Array(repeating: .zero, count: points.count), parts: parts, colors: colors)
    }

    /// The `k`th lit particle's point at `time` (seconds), swirling in the ball and breathing in and out.
    func swirling(_ k: Int, at time: Float) -> SIMD3<Float> {
        let s = swirl[k]
        let breathing = 1 + Self.breath * sin(Self.breathSpeed * time * abs(s.speed) + s.phase)
        return ball + simd_quatf(angle: s.speed * time, axis: s.axis).act(s.offset * breathing)
    }
}

/// The task quiz's own motion and drawing, around its `NetworkEffect` (list it after that one): the output arrow out of
/// the Detect blocks (`TaskQuiz`) and its result ("Cat") past it, and the ball's lit particles swirling. Coming from
/// the inference, the arrow moves with the blocks (on the particles' spring, from where the inference showed it), and
/// every other particle, in its color, slides off the stage's left edge with them (one `form`: all on the same spring,
/// so they start and settle together), as a slide leaves; the lit ones cross back unseen past the right edge, then
/// stream in from there and gather into the swirling ball. Otherwise the arrow fades in as the blocks arrive, and the ball forms. It all fades out with the
/// quiz's labels as a title flies to the top (`quiz`).
final class TaskQuizEffect: Effect {
    private let network: NeuralNetwork
    private let arrow: Arrow
    private let result: ShadowedLabel
    /// Holds the arrow and result, fading with the quiz (the effect's node fades in and out with the step).
    private let content = SKNode()
    /// The quiz beside it, whose leaving fades it out.
    weak var quiz: QuizEffect?
    /// The arrow's tail, tip and feeds' points on stage, and their speeds, on the particles' spring (`ParticleSystem.
    /// formStiffness`) toward where the layout puts them; nil until the first frame (from the inference's arrow, or at
    /// their place).
    private var arrowPoints: [CGPoint]?
    private var arrowSpeeds: [CGVector] = []
    /// Whether the arrow glides from the inference's (else it fades in as the blocks arrive).
    private let glides: Bool
    /// The ball's particles as the inference left them, on stage (x, y, depth, stage points), with their colors (in
    /// `rest`'s order); nil: no slide.
    private let leaving: (points: [SIMD3<Float>], colors: [SIMD3<Float>?])?
    /// When each lit particle comes back in (seconds into the step), and from where past the right edge (a height
    /// around the ball's, -1...1, and how far past it, 0...1).
    private let comeback: [(at: Float, y: Float, past: Float)]
    private var start: TimeInterval?

    /// Seconds: when the lit ones, gone, cross back unseen past the right edge; when they start coming back in, and over
    /// how long they all do.
    static let away: Float = 0.7, back: Float = 1.15, stream: Float = 0.8

    /// Built as the step starts, before its effects update: the particles are still as the previous step left them.
    init(_ network: NeuralNetwork) {
        self.network = network
        arrow = Arrow(network.inference.arrows.last?.text ?? "Output", color: NNColors.gold)
        result = ShadowedLabel(network.inference.flowResult ?? "", font: "Archivo-SemiBold")
        let (system, inference, quiz) = (network.system, network.inference, network.taskQuiz)
        var arrowPoints: [CGPoint]?
        if network.formed === inference, let output = inference.arrows.last, let points = system.points(quiz.rest),
            let colors = system.colors(quiz.rest) {
            let shown = { (p: SIMD3<Float>) in system.shownPoint(p).point }
            arrowPoints = [shown(output.tail), shown(output.tip)] + (inference.arrowFeeds[output.text] ?? []).flatMap { $0.map(shown) }
            let (center, size) = (system.center, Float(system.size))
            let onStage = points.map { p -> SIMD3<Float> in
                let p = system.rotation.act(p) * size
                return [Float(center.x) + p.x, Float(center.y) + p.y, p.z]
            }
            leaving = (onStage, colors)
        } else {
            leaving = nil
        }
        glides = arrowPoints?.count == 2 + network.taskQuiz.feeds.reduce(0) { $0 + $1.count }
        self.arrowPoints = glides ? arrowPoints : nil
        comeback = quiz.swirl.indices.map { _ in (Self.back + .random(in: 0...Self.stream), .random(in: -1...1), .random(in: 0...1)) }
        super.init()
        (result.label.horizontalAlignmentMode, result.label.verticalAlignmentMode) = (.left, .center)
        content.addChild(arrow)
        content.addChild(result)
        node.addChild(content)
    }

    /// Where the branches' objects will be (stage points): where the particles were centered before the quiz (its
    /// layout, placed for this step alone, leaves `network.home` there), else where a network starts (the right third).
    func objectCenter(_ frame: StageFrame) -> CGPoint {
        network.home ?? CGPoint(x: frame.stage.viewSize.width * 2 / 3, y: frame.stage.viewSize.height / 2)
    }

    override func update(_ frame: StageFrame) {
        let first = start == nil
        if first { start = frame.time }
        let t = frame.time - start!
        moveParticles(Float(t), first: first, frame)
        drawArrow(t, frame)
    }

    private func moveParticles(_ t: Float, first: Bool, _ frame: StageFrame) {
        let (system, quiz) = (network.system, network.taskQuiz)
        guard network.formed === quiz.layout, !quiz.rest.isEmpty else { return }
        let u = Float(frame.stage.unit)
        // A stage point (x, y, depth) in the shape, as the system is placed now.
        let (center, size, turn) = (system.center, Float(max(system.size, 1)), system.rotation.inverse)
        let inShape = { (s: SIMD3<Float>) in turn.act([(s.x - Float(center.x)) / size, (s.y - Float(center.y)) / size, s.z / size]) }
        if first, let leaving, var shape = quiz.layout.shape {
            // All together, in their colors, as the blocks glide to their place: the whole picture shifted left until its
            // right end is well past the edge (the spring slows near its end, which should be out of sight).
            let by = (leaving.points.map(\.x).max() ?? 0) + 250 * u
            for (k, i) in quiz.rest.enumerated() {
                shape.points[i] = inShape(leaving.points[k] - [by, 0, 0])
                shape.colors[i] = leaving.colors[k]
            }
            system.form(shape, staggered: false)
            return
        }
        guard leaving == nil || t >= Self.away else { return }
        let lit = Array(quiz.rest.prefix(quiz.swirl.count))
        var (points, colors) = ([SIMD3<Float>](), [SIMD3<Float>]())
        points.reserveCapacity(lit.count)
        colors.reserveCapacity(lit.count)
        let ball = system.stagePoint(quiz.ball)
        for k in lit.indices {
            if leaving != nil, t < comeback[k].at {
                // Unseen, past the right edge, at about the ball's height.
                let c = comeback[k]
                let edge = Float(frame.stage.viewSize.width) + (80 + 160 * c.past) * u
                points.append(inShape([edge, Float(ball.y) + c.y * 160 * u, 0]))
                colors.append(.zero)
            } else {
                points.append(quiz.swirling(k, at: t))
                colors.append(system.color * TaskQuiz.litBrightness)
            }
        }
        system.place(lit, at: points, colors: colors)
    }

    private func drawArrow(_ t: TimeInterval, _ frame: StageFrame) {
        let u = frame.stage.unit
        let (system, quiz) = (network.system, network.taskQuiz)
        // Where the layout puts them now; the arrow springs there as the blocks' particles do.
        let targets = ([quiz.tail, quiz.tip] + quiz.feeds.flatMap { $0 }).map(system.stagePoint)
        var points = arrowPoints ?? targets
        if arrowSpeeds.count != points.count { arrowSpeeds = Array(repeating: .zero, count: points.count) }
        let k = CGFloat(ParticleSystem.formStiffness), dt = min(frame.dt, 0.1)
        let steps = min(max(Int((dt * 120).rounded(.up)), 1), 8)
        let h = CGFloat(dt) / CGFloat(steps)
        for _ in 0..<steps {
            for i in points.indices {
                let (gap, v) = (CGVector(dx: targets[i].x - points[i].x, dy: targets[i].y - points[i].y), arrowSpeeds[i])
                arrowSpeeds[i] = CGVector(dx: v.dx + (k * gap.dx - 2 * k.squareRoot() * v.dx) * h, dy: v.dy + (k * gap.dy - 2 * k.squareRoot() * v.dy) * h)
                points[i] = CGPoint(x: points[i].x + arrowSpeeds[i].dx * h, y: points[i].y + arrowSpeeds[i].dy * h)
            }
        }
        arrowPoints = points
        let appear = glides ? 1 : QuizEffect.eased((t - 1) / 0.5)  // without a glide: once the blocks are about there
        content.alpha = appear * (1 - (self.quiz?.leaving ?? 0))
        var rest = points.dropFirst(2)
        let feeds = quiz.feeds.map { feed -> [CGPoint] in
            defer { rest = rest.dropFirst(feed.count) }
            return Array(rest.prefix(feed.count))
        }
        arrow.update(from: points[0], to: points[1], feeds: feeds, frame: frame)
        result.label.set(\.fontSize, 30 * u)
        result.label.set(\.fontColor, NNColors.gold)
        result.position = CGPoint(x: points[1].x + 14 * u, y: points[1].y)
        result.sync(unit: u)
    }
}
