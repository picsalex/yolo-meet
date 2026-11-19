import SpriteKit
import YoloMeetCore
import simd

/// After the recap, YOLO leaves the lab: the model goes back into its black box (step 1's), the box's code is on
/// GitHub, each release is published to PyPI, and an end user's `pip install ultralytics` brings a copy of it to their
/// laptop. A small YOLO stays lit inside each box. Two steps, each with a substep, then the command alone: the box, then its repository (GitHub on the left, the box on the right, the
/// code flowing into it); then the box moving left under the GitHub mark and a copy flying to PyPI's shelf in the
/// middle, then to a laptop on the right. Each part keeps its particles from step to step (`Shipping`'s groups), so the
/// box is the recap's pictures, shrunk, and the copies leave from the box they're copied from.
final class Shipping {
    /// The model gone back into the black box: the recap's pictures fly to its edges (but the GitHub mark's, which
    /// fade out where they are), then the model shrinks into it and goes dark as the box closes.
    let packaged: NetworkLayout
    /// The box on the right, and its repository on the left (a card under the GitHub mark, `ShippingEffect`), its code
    /// flowing into the box.
    let repository: NetworkLayout
    /// The box, smaller, on the left under the GitHub mark; PyPI's shelf of packages in the middle, and the box's copy
    /// published there (flown by `ShippingEffect`).
    let pypi: NetworkLayout
    /// A laptop and its user on the right, and the copy `pip install` brings there from PyPI (flown by
    /// `ShippingEffect`).
    let install: NetworkLayout
    /// The end: everything fades out but the command, which eases to the middle of the stage (`ClosingEffect`).
    let closing: NetworkLayout

    /// Each part's particles, the same in every step: the box, the GitHub mark, the code flowing into the box, the
    /// shelf's packages (a box each), the box's copy on PyPI, its copy on the laptop, the laptop, its user; and the
    /// small YOLO inside each box (the recap's model, shrunk, in the box; its copies in theirs).
    let boxA, mark, stream, boxB, boxC, laptop, user: [Int]
    let modelA, modelB, modelC: [Int]
    let shelf: [[Int]]
    /// Each box particle's place on its box (`Spot`), so a box keeps its look as it moves and shrinks.
    private let spots: [Spot]
    /// Each small YOLO's particle: its point in YOLO's architecture (`NetworkLayout.architecture`), centered.
    private let local: [SIMD3<Float>]

    /// A box particle's place on its box: the edge (`Box.edges`), how far along it, and a little jitter (in half
    /// sides).
    struct Spot {
        var edge = 0
        var along: Float = 0
        var jitter = SIMD3<Float>.zero

        /// Where it is on `cube` (its `corners`).
        func on(_ cube: Cube, _ corners: [SIMD3<Float>]) -> SIMD3<Float> {
            let (a, b) = Box.edges[edge]
            return corners[a] + (corners[b] - corners[a]) * along + jitter * cube.half
        }
    }

    // Where things stand, in the shape's units: the layouts are centered on the stage (x within ±3.7, y within ±2.1).
    /// The repository: its card's top left corner (`ShippingEffect`), the GitHub mark over it, the box on the right,
    /// centered on the stage together (from the card's left edge to the box's right one).
    static let cardCorner = SIMD3<Float>(-3.08, 0.62, 0)
    static let repositoryMark = (center: SIMD3<Float>(-1.49, 1.0, 0), radius: Float(0.3))
    /// Level with the card's middle (`ShippingEffect.Card`: 364 points high at unit 1, 170 points a shape unit).
    static let inRepository = Cube(center: [2.49, -0.45, 0], half: 0.42)
    /// Then GitHub on the left, the box under the mark, and PyPI on its right, the two centered on the stage together
    /// (from the mark's left edge to the published version's right end).
    static let onGitHub = Cube(center: [-1.44, -0.42, 0], half: 0.24)
    static let markSpot = (center: SIMD3<Float>(-1.44, 0.6, 0), radius: Float(0.44))
    /// PyPI's other packages, two rows of boxes, and the slot left for the box (top right).
    static let shelfBoxes = [(0.11, 0.25), (0.81, 0.25), (0.11, -0.5), (0.81, -0.5), (1.51, -0.5)].map {
        Cube(center: [Float($0.0), Float($0.1), 0], half: 0.19)
    }
    static let shelfNames = ["numpy", "torch", "opencv-python", "pillow", "matplotlib"]
    static let onPyPI = Cube(center: [1.51, 0.25, 0], half: 0.19)
    /// The copy as it lands there: turned a quarter by its flight (`Cube.flight`), so the next step keeps each of its
    /// particles where it is.
    static var published: Cube {
        var cube = onPyPI
        cube.spin = .pi / 2
        return cube
    }
    /// In pip install, GitHub gone, PyPI moves this far so that it and the laptop are centered on the stage.
    static let installShift = SIMD3<Float>(-2.31, 0, 0)
    /// The laptop's screen (its terminal inside), and where the installed copy lands on it, right of the text: the
    /// laptop shows only in pip install, so it's placed there already (`installShift`).
    static let screen = (center: SIMD3<Float>(1.35, 0.3, 0), half: SIMD2<Float>(0.95, 0.6))
    static let onLaptop = Cube(center: [1.95, 0.06, 0], half: 0.13)
    /// Under the stations: their names.
    static let headerY: Float = -1.02

    /// The latest release and its wheel (PyPI), the repository's stars and forks (GitHub): fetched at launch
    /// (`ProjectStats.ultralytics`, the story's `refresh`), else the last ones fetched or those of November 2026.
    /// Each step reads them once, as it starts (`ShippingEffect.numbers`), so a refresh never changes half a step.
    static var numbers: ProjectStats.Snapshot { ProjectStats.ultralytics.current }

    /// Builds the layouts in order, `pause` after each (`NeuralNetwork.breathe`), so the app keeps drawing meanwhile.
    init(after recap: NetworkLayout, architecture: NetworkLayout, between pause: () async -> Void) async {
        let n = NeuralNetwork.particles
        guard let from = recap.settled, let fromColors = recap.arrivedColors else {
            preconditionFailure("Shipping: the recap has no particles")
        }
        let inModel = Set(recap.modelParticles)
        let pictures = (0..<n).filter { !inModel.contains($0) }.shuffled()
        let model = recap.modelParticles.shuffled()
        // The pictures' particles become the boxes, the mark and the code's flow, the model's the laptop and its user.
        var rest = pictures[...]
        func take(_ share: Float) -> [Int] {
            let part = Array(rest.prefix(Int(Float(pictures.count) * share)))
            rest = rest.dropFirst(part.count)
            return part
        }
        let boxA = take(0.15)
        let mark = take(0.18)
        let stream = take(0.08)
        let shelf = (0..<5).map { _ in take(0.056) }
        let boxB = take(0.11)
        let modelB = take(0.06)
        let modelC = take(0.06)
        let boxC = Array(rest)
        // The model: a quarter stays the small YOLO in the box, the rest becomes the laptop and its user.
        let modelA = Array(model.prefix(model.count / 4))
        let laptop = Array(model.dropFirst(modelA.count).prefix(model.count * 45 / 100))
        let user = Array(model.dropFirst(modelA.count + laptop.count))
        (self.boxA, self.mark, self.stream, self.shelf, self.boxB, self.boxC, self.laptop, self.user) =
            (boxA, mark, stream, shelf, boxB, boxC, laptop, user)
        (self.modelA, self.modelB, self.modelC) = (modelA, modelB, modelC)
        let inMark = Set(mark)
        let inModelA = Set(modelA)

        // The small YOLOs' points in the architecture: the model's where they were in the recap's (shrunk there), the
        // copies' at random points of its blocks and connections.
        var local = [SIMD3<Float>](repeating: .zero, count: n)
        let recapModel = NetworkLayout.recapModel
        for i in modelA { local[i] = (from.points[i] - recapModel.center) / recapModel.scale - Self.modelCenter }
        if let blocks = architecture.shape {
            let solid = blocks.parts.indices.filter { blocks.parts[$0] != NetworkLayout.dustPart }
            for i in modelB + modelC { local[i] = blocks.points[solid.randomElement()!] - Self.modelCenter }
        }
        self.local = local
        func inBox(_ i: Int, _ cube: Cube) -> SIMD3<Float> { Self.place(local[i], in: cube) }

        var spots = [Spot](repeating: Spot(), count: n)
        for (k, i) in pictures.enumerated() {
            spots[i] = Spot(edge: k % Box.edges.count, along: .random(in: 0...1), jitter: .random(in: -0.011...0.011))
        }
        self.spots = spots
        func point(_ i: Int, on cube: Cube, _ corners: [SIMD3<Float>]) -> SIMD3<Float> { spots[i].on(cube, corners) }
        func gray(_ count: Int, _ cube: Cube) -> SIMD3<Float> {
            SIMD3(repeating: Self.edgeGray(count, half: cube.half))
        }

        // 16 · GitHub: step 1's box, around the model (the view turns it, as in step 1). The mark's particles stay
        // out of it: they fade out where they are, for the mark to form from outside the box.
        let big = Cube(center: .zero, half: NetworkLayout.blackBoxSide, turned: false)
        let start = from.points
        var walls = start
        let bigCorners = big.corners
        for i in pictures where !inMark.contains(i) { walls[i] = point(i, on: big, bigCorners) }
        let packaged = NetworkLayout(
            title: "Back in the black box", subtitle: "YOLO, packaged as code", neurons: [], synapses: [],
            neuronSize: 0.02, restingTilt: 0.42)
        (packaged.restingTurn, packaged.spins, packaged.splits) = (0.6, true, true)
        packaged.outline = bigCorners
        // First the pictures fly to the box's edges around the model, in their colors.
        let prelude = NetworkLayout(
            title: packaged.title, subtitle: packaged.subtitle, neurons: [], synapses: [], neuronSize: 0.02,
            restingTilt: 0.42)
        (prelude.splits, prelude.splitsFrom, prelude.outline) = (true, recap, bigCorners)
        prelude.shape = ParticleShape(
            points: start, offsets: zip(walls, start).map { $0 - $1 }, parts: [],
            colors: (0..<n).map { i in
                inModel.contains(i) ? nil : inMark.contains(i) ? .zero : fromColors[i].map { $0 * 0.45 }
            })
        (packaged.prelude, packaged.splitsFrom) = (prelude, prelude)
        // Then the model shrinks into the box's middle: a quarter of it stays lit there, a small YOLO in the box; the
        // rest, dimmed on the way (denser), goes dark there.
        let wallGray = gray(pictures.count - mark.count, big)
        var inside = walls
        for i in model { inside[i] = (start[i] - recapModel.center) * 0.45 }
        for i in modelA { inside[i] = inBox(i, big) }
        let blue = Self.modelColor
        let bigModel = blue * Self.modelLight(modelA.count, in: big)
        let dark = { (i: Int) in inModel.contains(i) || inMark.contains(i) }
        packaged.shape = ParticleShape(
            points: walls, offsets: zip(inside, walls).map { $0 - $1 }, parts: [],
            colors: (0..<n).map {
                inMark.contains($0)
                    ? .zero : inModelA.contains($0) ? bigModel : inModel.contains($0) ? blue * 0.28 : wallGray
            })
        packaged.arrivedColors = ParticleColors(
            (0..<n).map { inModelA.contains($0) ? bigModel : dark($0) ? .zero : wallGray })
        self.packaged = packaged
        await pause()

        // The stations stay in place on the stage from here on; their title stays centered over all of them.
        let stations: [SIMD3<Float>] = [[-3.2, 1.1, 0], [3.5, 1.1, 0], [3.5, -1.0, 0], [-3.2, -1.0, 0]]
        func station(_ title: String, _ subtitle: String, after previous: NetworkLayout) -> NetworkLayout {
            let layout = NetworkLayout(
                title: title, subtitle: subtitle, neurons: [], synapses: [], neuronSize: 0.02, restingTilt: 0)
            (layout.splits, layout.splitsFrom, layout.outline, layout.headerSize) = (true, previous, stations, 22)
            return layout
        }
        let mark01 = Self.markPoints(mark.count)
        func markOn(_ spot: (center: SIMD3<Float>, radius: Float)) -> (points: [SIMD3<Float>], light: SIMD3<Float>) {
            let side = 2 * spot.radius
            let light = Self.fillLight(mark.count, area: mark01.area * side * side) * 1.1
            return (mark01.points.map { spot.center + $0 * side }, SIMD3(repeating: light))
        }

        // 16 › Repository: the box moves to the right; the GitHub mark forms over the repository's card on the left
        // (unseen on the way, lit once there); the rest waits out of sight, black, inside the box (`ShippingEffect`
        // flows the code's particles into it).
        let hero = Self.inRepository
        let heroCorners = hero.corners
        let repository = station(
            "On GitHub", "github.com/ultralytics/ultralytics · open source", after: packaged)
        var points = (0..<n).map { _ in hero.center + SIMD3<Float>.random(in: -0.12...0.12) }
        var travel = [SIMD3<Float>?](repeating: .zero, count: n)
        var arrived = [SIMD3<Float>?](repeating: .zero, count: n)
        let heroGray = gray(boxA.count, hero)
        for i in boxA { (points[i], travel[i], arrived[i]) = (point(i, on: hero, heroCorners), heroGray, heroGray) }
        let heroModel = blue * Self.modelLight(modelA.count, in: hero)
        for i in modelA { (points[i], travel[i], arrived[i]) = (inBox(i, hero), heroModel, heroModel) }
        let repositoryMark = markOn(Self.repositoryMark)
        for (k, i) in mark.enumerated() { (points[i], arrived[i]) = (repositoryMark.points[k], repositoryMark.light) }
        repository.shape = ParticleShape(
            points: inside, offsets: zip(points, inside).map { $0 - $1 }, parts: [], colors: travel)
        repository.arrivedColors = ParticleColors(arrived)
        self.repository = repository
        await pause()

        // 17 · PyPI: the box moves to the left, under the GitHub mark (which shrinks there from the card's); the
        // shelf's packages appear in the middle (unseen on the way, lit once there); the box's copy waits, unseen, in
        // the box (`ShippingEffect` flies it), and the laptop's copy, unseen, in its slot. The rest waits in the box.
        let a = Self.onGitHub
        let aCorners = a.corners
        let pypi = station("On PyPI", "pypi.org/project/ultralytics · published with every release", after: repository)
        pypi.headers = [
            ("GitHub", [a.center.x, Self.headerY, 0], []),
            ("PyPI", [Self.shelfBoxes[1].center.x, Self.headerY, 0], []),
        ]
        pypi.arrows = [Self.publishArrow]
        let before = points
        points = (0..<n).map { _ in a.center + SIMD3<Float>.random(in: -0.08...0.08) }
        let aGray = gray(boxA.count, a)
        for i in boxA { (points[i], arrived[i]) = (point(i, on: a, aCorners), aGray) }
        for i in modelA { (points[i], arrived[i]) = (inBox(i, a), blue * Self.modelLight(modelA.count, in: a)) }
        let leftMark = markOn(Self.markSpot)
        for (k, i) in mark.enumerated() { (points[i], arrived[i]) = (leftMark.points[k], leftMark.light) }
        for i in stream { arrived[i] = .zero }
        let slot = Self.onPyPI
        let slotCorners = slot.corners
        for i in boxB { points[i] = point(i, on: a, aCorners) }
        for i in modelB { points[i] = inBox(i, a) }
        for i in boxC { points[i] = point(i, on: slot, slotCorners) }
        for i in modelC { points[i] = inBox(i, slot) }
        var onTheWay = arrived
        for (k, cube) in Self.shelfBoxes.enumerated() {
            let corners = cube.corners
            let color = Self.shelfColor(k) * Self.edgeGray(shelf[k].count, half: cube.half) * 1.6
            for i in shelf[k] { (points[i], arrived[i]) = (point(i, on: cube, corners), color) }
        }
        pypi.shape = ParticleShape(
            points: before, offsets: zip(points, before).map { $0 - $1 }, parts: [], colors: onTheWay)
        pypi.arrivedColors = ParticleColors(arrived)
        self.pypi = pypi
        await pause()

        // 17 › pip install: GitHub goes (its mark and box fade out where they are); the copy is in its slot on PyPI,
        // as it landed; a laptop and its user appear on the right (unseen on the way), and the laptop's copy waits,
        // unseen, in the slot (`ShippingEffect` flies it during the download).
        let install = station("pip install ultralytics", "from PyPI to any laptop, in one line", after: pypi)
        install.headers = []  // PyPI's name slides with its shelf (`ShippingEffect`)
        install.arrows = [Self.installArrow]
        for i in boxA + mark + modelA { arrived[i] = .zero }
        let landed = Self.published
        let landedCorners = landed.corners
        let bGray = gray(boxB.count, landed)
        for i in boxB { (points[i], arrived[i]) = (point(i, on: landed, landedCorners), bGray) }
        for i in modelB {
            (points[i], arrived[i]) = (inBox(i, landed), blue * Self.modelLight(modelB.count, in: landed))
        }
        let startInstall = points
        // PyPI (its shelf, the copy, the laptop's copy unseen in it) slides left, now that GitHub has gone.
        for i in shelf.joined() + boxB + boxC + modelB + modelC { points[i] += Self.installShift }
        onTheWay = arrived
        let laptopLines = Self.laptopPoints(laptop.count)
        let laptopGray = SIMD3<Float>(repeating: Self.lineGray(laptop.count, length: laptopLines.length))
        for (k, i) in laptop.enumerated() { (points[i], arrived[i]) = (laptopLines.points[k], laptopGray) }
        let userPoints = Self.userPoints(user.count)
        let userLight = blue * Self.fillLight(user.count, area: userPoints.area) * 1.6
        for (k, i) in user.enumerated() { (points[i], arrived[i]) = (userPoints.points[k], userLight) }
        install.shape = ParticleShape(
            points: startInstall, offsets: zip(points, startInstall).map { $0 - $1 }, parts: [], colors: onTheWay)
        install.arrivedColors = ParticleColors(arrived)
        self.install = install
        await pause()

        // 18 · The end: everything fades out where it is, but the command (no title: `ClosingEffect` draws it). Where
        // pip install left it: the laptop's copy landed (`ClosingEffect` reads where all the particles are, in case the
        // step changed before then).
        let closing = station("", "", after: install)
        closing.splits = false
        var installed = Self.onLaptop
        installed.spin = .pi / 2  // turned a quarter by its flight (`Cube.flight`)
        let installedCorners = installed.corners
        for i in boxC { points[i] = point(i, on: installed, installedCorners) }
        for i in modelC { points[i] = inBox(i, installed) }
        closing.shape = ParticleShape(
            points: points, offsets: Array(repeating: .zero, count: n), parts: [],
            colors: Array(repeating: .zero, count: n))
        self.closing = closing
    }

    /// Keeps `particles` in `layout` where they are now (`ParticleSystem.points`), so they fade out there, as in
    /// PowerPoint's morph: what the next step has glides there, what it doesn't fades out in place, rather than going
    /// somewhere else unseen. For particles a step moved itself (`ParticleSystem.place`, e.g. the code's flow, the
    /// copies), whose place no layout knows; called when the next step starts (its effect's `init`, before it forms).
    func fadeInPlace(_ particles: [Int], in layout: NetworkLayout, system: ParticleSystem) {
        guard var shape = layout.shape, let now = system.points(particles) else { return }
        for (k, i) in particles.enumerated() { (shape.points[i], shape.offsets[i]) = (now[k], .zero) }
        layout.shape = shape
    }

    /// Where small YOLO particle `i` is in `cube`.
    func inside(_ i: Int, _ cube: Cube) -> SIMD3<Float> { Self.place(local[i], in: cube) }

    /// Where a small YOLO's point (`local`) is in `cube`.
    private static func place(_ point: SIMD3<Float>, in cube: Cube) -> SIMD3<Float> {
        cube.center + cube.rotation.act(point * (modelScale * cube.half))
    }

    /// The architecture's middle (its blocks span about ±1.3 across, -0.8...1.1 up), and how large it is in a box, by
    /// the box's half side.
    static let modelCenter = SIMD3<Float>(0, 0.15, 0)
    static let modelScale: Float = 0.5
    /// The model's blue (the particles' own, `ParticleSystem.color`).
    static let modelColor = SIMD3<Float>(0.3, 0.75, 1)

    /// How bright each of `count` particles of a small YOLO in `cube` should be to look like the recap's model (all
    /// its particles at `recapModel.scale`, in the system's color): smaller and denser, dimmer.
    static func modelLight(_ count: Int, in cube: Cube) -> Float {
        let recap = Float(NetworkLayout.recapModel.scale)
        let scale = modelScale * cube.half
        let reference = Float(NeuralNetwork.particles - 8 * NetworkLayout.recapCopy) / (recap * recap)
        return min(reference / (Float(count) / (scale * scale)), 1)
    }

    /// Where box particle `i` is on `cube` (its `corners`).
    func point(_ i: Int, on cube: Cube, _ corners: [SIMD3<Float>]) -> SIMD3<Float> { spots[i].on(cube, corners) }

    /// The gray of a box's edges drawn by `count` particles, as bright as step 1's (all the particles on its edges,
    /// 0.03 each): light adds up, so fewer particles on as long an edge are brighter each.
    static func edgeGray(_ count: Int, half: Float) -> Float { lineGray(count, length: 24 * half) }

    /// The same for lines of any `length` in all (shape units).
    static func lineGray(_ count: Int, length: Float) -> Float {
        0.03 * Float(NeuralNetwork.particles) / (24 * NetworkLayout.blackBoxSide) / (Float(count) / length)
    }

    /// How bright each of `count` particles filling `area` (shape units²) should be to look like the large pictures.
    static func fillLight(_ count: Int, area: Float) -> Float {
        let reference = Float(NeuralNetwork.particles) / (NetworkLayout.resultSide * NetworkLayout.resultSide)
        return min(reference / (Float(count) / area), 1)
    }

    /// PyPI's packages in Python's blue and yellow, alternating.
    static func shelfColor(_ k: Int) -> SIMD3<Float> {
        [0, 3].contains(k) ? NSColor.hex("4B8BBE").rgb : NSColor.hex("FFD43B").rgb
    }

    /// From the box on GitHub to the shelf's bottom row (under the copy's flight); from the shelf to the laptop's
    /// screen, in pip install (`installShift`).
    static let publishArrow: (text: String, tail: SIMD3<Float>, tip: SIMD3<Float>) =
        ("publish", [-1.04, -0.55, 0], [-0.29, -0.5, 0])
    static let installArrow: (text: String, tail: SIMD3<Float>, tip: SIMD3<Float>) =
        ("pip install", [-0.33, -0.14, 0], [0.32, -0.14, 0])

    /// The GitHub mark (Octicons' `mark-github`, 16 × 16) filled with `count` points, in a unit square around 0, and
    /// the share of it the mark fills.
    private static func markPoints(_ count: Int) -> (points: [SIMD3<Float>], area: Float) {
        let path = CGPath.svg(
            "M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z"
        )
        let picture = GrayPicture(width: 256, height: 256, canvas: CGSize(width: 16, height: 16)) { context in
            context.setFillColor(gray: 1, alpha: 1)
            context.addPath(path)
            context.fillPath()
        }
        return filling(picture, count: count, center: .zero, size: [1, 1])
    }

    /// A user seen from behind, sitting at the laptop: head and shoulders, in front of its base (the laptop's lines
    /// behind them are left out, `laptopPoints`), down to the stage's bottom.
    private static let seated = (
        center: SIMD3<Float>(screen.center.x, -1.35, 0.01), size: SIMD2<Float>(1.3, 1.6),
        picture: GrayPicture(width: 260, height: 320, canvas: CGSize(width: 130, height: 160)) { context in
            context.setFillColor(gray: 1, alpha: 1)
            context.fillEllipse(in: CGRect(x: 46, y: 0, width: 38, height: 46))  // head
            context.fill(CGRect(x: 56, y: 40, width: 18, height: 18))  // neck
            let shoulders = CGMutablePath()
            shoulders.move(to: CGPoint(x: 4, y: 160))
            shoulders.addCurve(
                to: CGPoint(x: 65, y: 54), control1: CGPoint(x: 6, y: 80), control2: CGPoint(x: 28, y: 58))
            shoulders.addCurve(
                to: CGPoint(x: 126, y: 160), control1: CGPoint(x: 102, y: 58), control2: CGPoint(x: 124, y: 80))
            shoulders.closeSubpath()
            context.addPath(shoulders)
            context.fillPath()
        }
    )

    private static func userPoints(_ count: Int) -> (points: [SIMD3<Float>], area: Float) {
        filling(seated.picture, count: count, center: seated.center, size: seated.size)
    }

    /// Whether the user hides a point (in front of it).
    private static func userHides(_ p: SIMD3<Float>) -> Bool {
        let (x, y) = ((p.x - seated.center.x) / seated.size.x + 0.5, 0.5 - (p.y - seated.center.y) / seated.size.y)
        guard (0...1).contains(x), (0...1).contains(y) else { return false }
        return seated.picture.at(x * Float(seated.picture.width), y * Float(seated.picture.height)) > 0.5
    }

    /// `count` random points where `picture` is bright, in a rectangle of `size` around `center` (the picture's top
    /// at the top), and the area they fill.
    private static func filling(_ picture: GrayPicture, count: Int, center: SIMD3<Float>, size: SIMD2<Float>)
        -> (points: [SIMD3<Float>], area: Float)
    {
        var random = SeededRandom(UInt64(count))
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(count)
        while points.count < count {
            let (x, y) = (Float.random(in: 0..<1, using: &random), Float.random(in: 0..<1, using: &random))
            guard picture.at(x * Float(picture.width), y * Float(picture.height)) > 0.5 else { continue }
            let z = Float.random(in: -0.004...0.004, using: &random)
            points.append(center + [(x - 0.5) * size.x, (0.5 - y) * size.y, z])
        }
        let filled = Float(picture.values.filter { $0 > 0.5 }.count) / Float(picture.values.count)
        return (points, filled * size.x * size.y)
    }

    /// A laptop facing the viewer: the screen's frame, and below it the base seen from above (a trapezoid) with
    /// rows of keys and a trackpad; `count` points along their lines, the keys' denser (`keyDensity`, so their short
    /// dashes read), and the lines' length in all as seen by `lineGray` (the keys' counted that many times).
    private static let keyDensity: Float = 2

    private static func laptopPoints(_ count: Int) -> (points: [SIMD3<Float>], length: Float) {
        let (c, h) = (screen.center, screen.half)
        func rect(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> [(SIMD3<Float>, SIMD3<Float>)] {
            let p = [SIMD3<Float>(x0, y0, 0), [x1, y0, 0], [x1, y1, 0], [x0, y1, 0]]
            return (0..<4).map { (p[$0], p[($0 + 1) % 4]) }
        }
        var lines = rect(c.x - h.x, c.y - h.y, c.x + h.x, c.y + h.y)
        var weights: [Float] = []
        let (top, bottom): (Float, Float) = (c.y - h.y - 0.04, -0.8)
        let (topHalf, bottomHalf): (Float, Float) = (h.x + 0.02, h.x + 0.2)
        let corners: [SIMD3<Float>] = [
            [c.x - topHalf, top, 0], [c.x + topHalf, top, 0], [c.x + bottomHalf, bottom, 0],
            [c.x - bottomHalf, bottom, 0],
        ]
        lines += (0..<4).map { (corners[$0], corners[($0 + 1) % 4]) }
        weights = Array(repeating: 1, count: lines.count)
        // Keys: three rows of short dashes, wider going down (the base's perspective); the trackpad under them.
        for row in 0..<3 {
            let y = top - 0.07 - Float(row) * 0.075
            let half = topHalf + (bottomHalf - topHalf) * (top - y) / (top - bottom) - 0.12
            let keys = 13
            let pitch = 2 * half / Float(keys)
            for k in 0..<keys {
                let x = c.x - half + pitch * (Float(k) + 0.2)
                lines.append(([x, y, 0], [x + pitch * 0.6, y, 0]))
                weights.append(keyDensity)
            }
        }
        lines += rect(c.x - 0.28, bottom + 0.05, c.x + 0.28, top - 0.3)
        weights += Array(repeating: 1, count: lines.count - weights.count)
        let lengths = zip(lines, weights).map { simd_distance($0.0.0, $0.0.1) * $0.1 }
        let total = lengths.reduce(0, +)
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(count)
        for (line, length) in zip(lines, lengths) {
            let share = Int((Float(count) * length / total).rounded())
            var placed = 0
            while placed < share, points.count < count {
                let p = line.0 + (line.1 - line.0) * .random(in: 0...1) + SIMD3<Float>.random(in: -0.005...0.005)
                placed += 1
                if !userHides(p) { points.append(p) }
            }
        }
        while points.count < count { points.append(lines[0].0 + (lines[0].1 - lines[0].0) * .random(in: 0...1)) }
        return (points.shuffled(), total)
    }
}

/// A box in a layout's space at the story's angle (step 1's view, so it reads as a box while the layout faces the
/// viewer), with an extra turn around the vertical (a box spinning as it flies).
struct Cube {
    var center: SIMD3<Float>
    var half: Float
    /// False: as it is, the view turning it (step 1's box, and the box the model goes back into).
    var turned = true
    var spin: Float = 0

    static let view = KeyTurn.rotation(tilt: 0.42, turn: 0.6)

    /// How it's turned: the story's view (if `turned`), after its `spin`.
    var rotation: simd_quatf {
        let spun = simd_quatf(angle: spin, axis: [0, 1, 0])
        return turned ? Cube.view * spun : spun
    }

    var corners: [SIMD3<Float>] {
        let rotation = rotation
        return Box.corners(half: SIMD3(repeating: half)).map { center + rotation.act($0) }
    }
    /// Its lowest point (to put a label under it).
    var bottom: Float { corners.map(\.y).min()! }

    /// The same box, moved.
    func moved(by offset: SIMD3<Float>) -> Cube {
        var cube = self
        cube.center += offset
        return cube
    }

    /// Between `a` and `b` (0...1): along an arc `height` above the straight line (below it if negative), highest
    /// `peak` of the way along (later than halfway: it leaves nearly level), a quarter turn on the way.
    static func flight(from a: Cube, to b: Cube, at s: Float, height: Float, peak: Float = 0.5) -> Cube {
        var cube = a
        let arc = sin(.pi * pow(s, log(0.5) / log(peak)))
        cube.center = a.center + (b.center - a.center) * s + [0, height * arc, 0]
        cube.half = a.half + (b.half - a.half) * s
        cube.spin = .pi / 2 * s
        return cube
    }
}

/// The end: the command (pip install's title) eases from the top of the stage, where that title stood, to the middle,
/// slightly larger, as everything else fades out (`Shipping.closing`).
final class ClosingEffect: Effect {
    private let command = ShadowedLabel(ShippingEffect.command, font: Theme.titleFont)
    /// How much larger it ends, and when it moves (step time).
    static let grown: CGFloat = 1.3
    static let ease = (start: Float(0.3), duration: Float(1.4))

    init(_ network: NeuralNetwork, _ shipping: Shipping) {
        // Nothing stays: every particle fades out where it is.
        shipping.fadeInPlace(Array(0..<NeuralNetwork.particles), in: shipping.closing, system: network.system)
        super.init()
        (command.label.horizontalAlignmentMode, command.label.verticalAlignmentMode) = (.center, .top)
        node.addChild(command)
    }

    override func update(_ frame: StageFrame) {
        let u = frame.stage.unit
        let s = CGFloat(smoothstep((Float(frame.stepTime) - Self.ease.start) / Self.ease.duration))
        command.label.set(\.fontSize, ObjectTitle.titleSize * u * (1 + (Self.grown - 1) * s))
        // Its top: from where the title stood (centered on the stage, as over the stations) to where it's centered on
        // the stage.
        let size = frame.stage.viewSize
        let from = ObjectTitle.top(over: size.width / 2, width: command.label.frame.width, frame: frame)
        let to = CGPoint(x: size.width / 2, y: size.height / 2 + command.label.frame.height / 2)
        command.set(\.position, CGPoint(x: from.x + (to.x - from.x) * s, y: from.y + (to.y - from.y) * s))
        command.sync(unit: u)
    }
}

/// The 2D of the shipping steps, behind the particles: each box's faces filled black (so it reads as a solid box over
/// the camera, as `BlackBoxEffect` does), and per step: the repository on GitHub (a card, its `ultralytics` folder
/// outlined in gold, its code flowing into the box as gold particles); the shelf's package names and the published
/// version; the laptop's terminal, where `pip install ultralytics` types itself and the download brings the copy over.
/// It moves those particles itself, every frame (`ParticleSystem.place`): the code's flow, and the copies' flights
/// from the box on GitHub to its slot on PyPI, from there to the laptop.
final class ShippingEffect: Effect {
    enum Scene { case repository, pypi, install }

    private let network: NeuralNetwork
    private let shipping: Shipping
    private let scene: Scene
    private var layout: NetworkLayout {
        switch scene {
        case .repository: shipping.repository
        case .pypi: shipping.pypi
        case .install: shipping.install
        }
    }

    /// The copies' flights: when they leave (step time), and how long they take.
    /// The copy leaves once the box has moved to the left.
    static let publish = (start: Float(1.9), duration: Float(1.8))
    static let typing = (start: Float(1.7), perKey: Float(0.075))
    static let command = "pip install ultralytics"
    /// After the command is typed: Enter, then pip's lines, the download (the copy's flight) and the result.
    static var entered: Float { typing.start + Float(command.count) * typing.perKey + 0.25 }
    static var download: (start: Float, duration: Float) { (entered + 0.8, 1.8) }

    private let content = SKNode()
    /// One shape per box: overlapping in one path, they could cut holes in each other.
    private var faces: [SKShapeNode] = []
    private let card = SKNode()
    private var cardUnit: CGFloat = 0
    /// Each of the code's particles: its place along the flow (0...1 at time 0) and across it (-1...1).
    private var phase: [Float] = [], side: [Float] = []
    /// The flying copies' corners as their particles show them (`sprung`).
    private var springs: [Int: [Spring<SIMD3<Float>>]] = [:]
    /// PyPI's name under its shelf in pip install, where it slides with it (elsewhere it's the layout's header).
    private let pypiName = ShadowedLabel("PyPI", font: Theme.titleFont)
    /// How far along the flow the code's particles go per second (a whole flow is 1).
    static let flowSpeed: Float = 0.22
    private var names: [ShadowedLabel] = []
    /// The numbers shown, as they were when the step started (`Shipping.numbers`).
    private let numbers = Shipping.numbers
    private lazy var release = ShadowedLabel(
        "ultralytics \(numbers.version)", font: "Archivo-SemiBold", color: NNColors.gold)
    private let terminal = SKNode()
    private let panel = SKShapeNode()
    private var lines: [SKLabelNode] = []
    private let cursor = SKShapeNode()
    private let bar = (track: SKShapeNode(), fill: SKShapeNode())

    init(_ network: NeuralNetwork, _ shipping: Shipping, _ scene: Scene) {
        (self.network, self.shipping, self.scene) = (network, shipping, scene)
        // The code's flow isn't on PyPI's step: it fades out where it is.
        if scene == .pypi { shipping.fadeInPlace(shipping.stream, in: shipping.pypi, system: network.system) }
        super.init()
        behind = true
        content.alpha = 0
        node.addChild(content)
        switch scene {
        case .repository:
            content.addChild(card)
        case .pypi, .install:
            names = Shipping.shelfNames.map {
                ShadowedLabel($0, font: "Archivo-SemiBold", color: NSColor(white: 0.88, alpha: 1))
            }
            // Over the boxes' faces (`zPosition` 5), so a copy flying past never hides one.
            for label in names + [release] {
                label.zPosition = 6
                content.addChild(label)
            }
            release.alpha = 0
        }
        if scene == .install {
            // PyPI as step 17 left it, sliding from there: shown at once (the step's fade covers the change).
            (content.alpha, release.alpha, terminal.alpha) = (1, 1, 0)
            content.addChild(pypiName)
            (panel.fillColor, panel.strokeColor) = (NSColor.hex("0B0F14"), .clear)
            terminal.addChild(panel)
            lines = (0..<8).map { _ in
                let line = SKLabelNode(fontNamed: "GeistMono-Medium")
                (line.horizontalAlignmentMode, line.verticalAlignmentMode) = (.left, .baseline)
                terminal.addChild(line)
                return line
            }
            (bar.track.fillColor, bar.track.strokeColor) = (NSColor(white: 1, alpha: 0.12), .clear)
            (bar.fill.fillColor, bar.fill.strokeColor) = (NSColor.hex("72B01D"), .clear)
            (cursor.fillColor, cursor.strokeColor) = (NSColor(white: 0.85, alpha: 1), .clear)
            for child in [bar.track, bar.fill, cursor] { terminal.addChild(child) }
            content.addChild(terminal)
        }
        let boxes = scene == .repository ? 1 : 7
        faces = (0..<boxes).map { _ in
            let face = SKShapeNode()
            (face.fillColor, face.strokeColor, face.zPosition) = (.black, .clear, 5)
            content.addChild(face)
            return face
        }
    }

    override func update(_ frame: StageFrame) {
        let system = network.system
        let current = network.formed === layout && system.mode == .form
        let arrived = current && network.split >= 1
        // In pip install, PyPI shows as it slides (its labels with it), the terminal once the laptop is there.
        let shown = arrived || (scene == .install && current)
        content.alpha = content.alpha.approaching(shown ? 1 : 0, CGFloat(1 - exp(-frame.dt * (shown ? 3 : 14))))
        terminal.alpha = terminal.alpha.approaching(arrived ? 1 : 0, CGFloat(1 - exp(-frame.dt * 3)))
        let t = Float(frame.stepTime)

        // The code flows and the copies fly while this step's layout is formed (its own particles); the copies stay
        // where they landed. In pip install GitHub is gone and PyPI slides left (`installShift`) as the layout glides.
        let glide = scene == .install && current ? smoothstep(network.split) : 0
        let shift = Shipping.installShift * (scene == .install ? glide : 0)
        var boxes: [[SIMD3<Float>]] = []
        switch scene {
        case .repository: boxes = [Shipping.inRepository.corners]
        case .pypi: boxes = [Shipping.onGitHub.corners]
        case .install: break
        }
        if scene == .repository, current { flow(frame, t: t) }
        // The shelf's boxes and the published copy, with a name under each.
        var labelled: [[SIMD3<Float>]] = []
        if scene != .repository {
            labelled = Shipping.shelfBoxes.enumerated().map { k, cube in
                sprung(2 + k, cube.moved(by: shift).corners, dt: frame.dt)
            }
            let s = scene == .pypi ? smoothstep((t - Self.publish.start) / Self.publish.duration) : 1
            let b = Cube.flight(from: Shipping.onGitHub, to: Shipping.onPyPI, at: s, height: 1.0).moved(by: shift)
            labelled.append(sprung(0, b.corners, dt: frame.dt))
            boxes += labelled
            if current, scene == .pypi {
                fly(shipping.boxB, model: shipping.modelB, on: b, shown: t >= Self.publish.start)
            }
            release.alpha = release.alpha.approaching(s >= 1 ? 1 : 0, CGFloat(1 - exp(-frame.dt * 4)))
        }
        var progress: Float = 0
        if scene == .install {
            progress = smoothstep((t - Self.download.start) / Self.download.duration)
            // Leaving nearly level (PyPI's labels draw over it), then dipping along the arrow and under the
            // terminal's text, into the screen's lower right.
            let c = Cube.flight(
                from: Shipping.onPyPI.moved(by: shift), to: Shipping.onLaptop, at: progress, height: -0.3, peak: 0.6)
            boxes.append(sprung(1, c.corners, dt: frame.dt))
            if current { fly(shipping.boxC, model: shipping.modelC, on: c, shown: t >= Self.download.start) }
        }
        guard content.alpha > 0.01 else {
            content.isHidden = true
            return
        }
        content.isHidden = false
        for (face, corners) in zip(faces, boxes) {
            face.set(\.path, CGPath.closed(convexHull(corners.map { system.shownPoint($0).point })))
        }
        switch scene {
        case .repository: repository(frame)
        case .pypi, .install: shelfNames(frame, boxes: labelled)
        }
        if scene == .install { console(frame, t: t, progress: progress) }
    }

    /// A moving box's corners (its `k`: 0 the copy published to PyPI, 1 the one installed on the laptop, 2... the
    /// shelf's boxes) on the particles' spring (`Spring`), so its faces and label stay on its particles, which trail
    /// the points they're placed at.
    private func sprung(_ k: Int, _ corners: [SIMD3<Float>], dt: TimeInterval) -> [SIMD3<Float>] {
        var corner = springs[k] ?? corners.map { Spring($0) }
        for c in corners.indices { corner[c].step(toward: corners[c], dt: dt) }
        springs[k] = corner
        return corner.map(\.value)
    }

    /// A copy's particles on `cube` and its small YOLO in it, lit once it has left (black, unseen, in the box it leaves
    /// from before).
    private func fly(_ particles: [Int], model: [Int], on cube: Cube, shown: Bool) {
        let corners = cube.corners
        let gray = SIMD3<Float>(repeating: shown ? Shipping.edgeGray(particles.count, half: cube.half) : 0)
        let blue = shown ? Shipping.modelColor * Shipping.modelLight(model.count, in: cube) : .zero
        network.system.place(
            particles + model,
            at: particles.map { shipping.point($0, on: cube, corners) } + model.map { shipping.inside($0, cube) },
            colors: Array(repeating: gray, count: particles.count) + Array(repeating: blue, count: model.count))
    }

    // MARK: GitHub

    /// The repository's card on the left, under the GitHub mark, its `ultralytics` folder outlined in gold.
    private func repository(_ frame: StageFrame) {
        let u = frame.stage.unit
        if cardUnit != u { buildCard(u) }
        card.set(\.position, network.system.shownPoint(Shipping.cardCorner).point)
    }

    /// A channel between the card and the box, its particles flowing both ways: gold along its top half, the code going
    /// into the box, and blue along its bottom half, coming back out of it. Wide where it meets the card and the box, narrow in the middle (an hourglass on
    /// its side); each particle goes on from its own place along it, at its own place across it, lit but at the ends,
    /// where they come out of one side and vanish into the other. They come in once the box has arrived.
    private func flow(_ frame: StageFrame, t: Float) {
        let system = network.system
        let particles = shipping.stream
        if phase.count != particles.count {
            phase = particles.map { _ in .random(in: 0..<1) }
            side = particles.map { _ in .random(in: -1...1) }
        }
        // From under the card's right edge to inside the box's left side, level with both (in the shape's units: the
        // card is drawn at the stage's unit, not with the particles): their ends there are unseen (`light`), so they
        // come out of the card and the box, and vanish into them.
        let perUnit = Float(frame.stage.unit / system.size)
        let box = Shipping.inRepository
        let y = Shipping.cardCorner.y - Float(Card.height / 2) * perUnit
        let (left, right) = (
            Shipping.cardCorner.x + Float(Card.width) * perUnit - 0.25, box.corners.map(\.x).min()! + 0.28
        )
        let (ends, waist): (Float, Float) = (0.5, 0.07)
        let ramp = smoothstep((t - 1.2) / 1.0)
        let gold = NNColors.goldLight * ramp
        let blue = Shipping.modelColor * ramp
        var points: [SIMD3<Float>] = []
        var colors: [SIMD3<Float>] = []
        points.reserveCapacity(particles.count)
        colors.reserveCapacity(particles.count)
        for k in particles.indices {
            // Every other particle goes back: from the box (s 0) to the card (s 1).
            let back = k % 2 == 1
            let s = (phase[k] + t * Self.flowSpeed).truncatingRemainder(dividingBy: 1)
            let along = back ? 1 - s : s
            let across = 2 * along - 1
            let half = waist + (ends - waist) * across * across
            // Its lane: the top half going in, the bottom half coming out, a little apart in the middle.
            let lane = (0.08 + 0.92 * abs(side[k])) * (back ? -1 : 1)
            let drift = lane + 0.1 * sin(along * 9 + phase[k] * 40)
            points.append([left + (right - left) * along, y + max(min(drift, 1), -1) * half, 0])
            // Unseen at first, while they spring back to the start in a straight line (`place`), lit from there, out
            // at the far end; dimmer where they crowd (the waist), so it doesn't burn white.
            let light = smoothstep((s - 0.11) / 0.02) * min((1 - s) / 0.12, 1) * pow(half / ends, 0.35)
            colors.append((back ? blue : gold) * light)
        }
        system.place(particles, at: points, colors: colors)
    }

    /// The card's look: GitHub's dark theme.
    private enum Card {
        static let width: CGFloat = 540
        static let background = NSColor.hex("0D1117"), border = NSColor.hex("3D444D"), separator = NSColor.hex("21262D")
        static let text = NSColor.hex("E6EDF3"), muted = NSColor.hex("9198A1"), link = NSColor.hex("4493F8")
        static let rows: [(name: String, folder: Bool, note: String)] = [
            (".github", true, ""), ("docker", true, ""), ("docs", true, ""), ("examples", true, ""),
            ("tests", true, ""), ("ultralytics", true, "cfg · data · engine · models · nn · utils …"),
            ("LICENSE", false, ""), ("README.md", false, ""), ("pyproject.toml", false, ""),
        ]
        static let highlighted = 5
        /// The repository's description (GitHub, November 2026).
        static let description = """
            Ultralytics YOLO27, YOLO26, YOLO11, YOLOv8 — object detection, instance segmentation, semantic \
            segmentation, image classification, pose estimation, object tracking
            """

        static let tableTop: CGFloat = 82, rowHeight: CGFloat = 26
        /// A row's middle, down from the card's top (at unit 1).
        static func row(_ k: Int) -> CGFloat { tableTop + rowHeight * (CGFloat(k) + 0.5) }
        static var height: CGFloat { tableTop + rowHeight * CGFloat(rows.count) + 48 }
    }

    /// Lays the card out at the stage's unit: its top left at the node's origin.
    private func buildCard(_ u: CGFloat) {
        cardUnit = u
        card.removeAllChildren()
        @discardableResult func label(
            _ text: String, _ size: CGFloat, _ color: NSColor, x: CGFloat, y: CGFloat, font: String = "Archivo-SemiBold"
        )
            -> SKLabelNode
        {
            let label = SKLabelNode(fontNamed: font)
            (label.text, label.fontSize, label.fontColor) = (text, size * u, color)
            (label.horizontalAlignmentMode, label.verticalAlignmentMode) = (.left, .center)
            label.position = CGPoint(x: x * u, y: -y * u)
            card.addChild(label)
            return label
        }
        func shape(_ path: CGPath, fill: NSColor = .clear, stroke: NSColor = .clear, width: CGFloat = 1) {
            let node = SKShapeNode(path: path)
            (node.fillColor, node.strokeColor, node.lineWidth) = (fill, stroke, width * u)
            card.addChild(node)
        }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat = 0) -> CGPath {
            CGPath(
                roundedRect: CGRect(x: x * u, y: -(y + h) * u, width: w * u, height: h * u), cornerWidth: radius * u,
                cornerHeight: radius * u, transform: nil)
        }
        let (w, h) = (Card.width, Card.height)
        shape(rect(0, 0, w, h, radius: 10), fill: Card.background, stroke: Card.border)
        // The repository: its icon (a book), name and visibility, its stars and forks.
        shape(rect(20, 20, 12, 16, radius: 2), stroke: Card.muted, width: 1.5)
        let name = label("ultralytics / ultralytics", 20, Card.link, x: 42, y: 28)
        let pillX = 42 + name.frame.width / u + 10
        shape(rect(pillX, 18, 50, 21, radius: 10.5), stroke: Card.border)
        label("Public", 12, Card.muted, x: pillX + 9, y: 28.5)
        let counts = label("★ \(numbers.starsText)   ⑂ \(numbers.forksText)", 14, Card.text, x: w - 20, y: 28)
        counts.horizontalAlignmentMode = .right
        // The description, cut at a word with "…" to fit inside the card, as GitHub cuts it.
        let about = label("", 13.5, Card.muted, x: 20, y: 58)
        var words = Card.description.split(separator: " ").map(String.init)
        about.text = Card.description
        while about.frame.width > (w - 40) * u, words.count > 1 {
            words.removeLast()
            about.text = words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters) + " …"
        }
        // Its files, folders first, as GitHub lists them; the package's folder (the box's code) outlined in gold.
        let table = Card.tableTop
        shape(rect(20, table, w - 40, Card.rowHeight * CGFloat(Card.rows.count), radius: 6), stroke: Card.border)
        for (k, row) in Card.rows.enumerated() {
            let y = Card.row(k)
            let gold = k == Card.highlighted
            if gold {
                shape(
                    rect(20, y - Card.rowHeight / 2, w - 40, Card.rowHeight, radius: 4),
                    fill: NNColors.gold.withAlphaComponent(0.14), stroke: NNColors.gold, width: 1.5)
            } else if k > 0 {
                let line = CGMutablePath()
                line.move(to: CGPoint(x: 21 * u, y: -(y - Card.rowHeight / 2) * u))
                line.addLine(to: CGPoint(x: (w - 21) * u, y: -(y - Card.rowHeight / 2) * u))
                if k != Card.highlighted + 1 { shape(line, stroke: Card.separator) }
            }
            let color = gold ? NNColors.gold : Card.muted
            if row.folder {
                let folder = CGMutablePath()
                let (x, top) = (34 * u, -(y - 6) * u)
                folder.addLines(between: [
                    CGPoint(x: x, y: top), CGPoint(x: x + 6 * u, y: top), CGPoint(x: x + 8 * u, y: top - 2 * u),
                    CGPoint(x: x + 16 * u, y: top - 2 * u), CGPoint(x: x + 16 * u, y: top - 12 * u),
                    CGPoint(x: x, y: top - 12 * u),
                ])
                folder.closeSubpath()
                shape(folder, fill: color)
            } else {
                shape(rect(36, y - 7, 12, 15, radius: 1.5), stroke: color, width: 1.3)
            }
            label(row.name, 14.5, gold ? NNColors.gold : Card.text, x: 60, y: y)
            if !row.note.isEmpty { label(row.note, 13, Card.muted, x: 175, y: y, font: "GeistMono-Medium") }
        }
        // Its language and license.
        let footer = Card.tableTop + Card.rowHeight * CGFloat(Card.rows.count) + 25
        let dot = CGPath(
            ellipseIn: CGRect(x: 21 * u, y: -(footer + 5) * u, width: 10 * u, height: 10 * u), transform: nil)
        shape(dot, fill: NSColor.hex("3572A5"))
        label("Python", 13.5, Card.muted, x: 38, y: footer)
        label("AGPL-3.0 license", 13.5, Card.muted, x: 112, y: footer)
    }

    // MARK: PyPI

    /// The shelf's package names under their boxes, and the published version under the copy once it has landed.
    private func shelfNames(_ frame: StageFrame, boxes: [[SIMD3<Float>]]) {
        let u = frame.stage.unit
        let system = network.system
        // Under each box as it shows (`boxes`: the shelf's, then the published copy), so they move with it.
        let under = { (corners: [SIMD3<Float>]) -> CGPoint in
            let x = corners.map(\.x).reduce(0, +) / Float(corners.count)
            return system.shownPoint([x, corners.map(\.y).min()! - 0.03, 0]).point
        }
        for (label, corners) in zip(names + [release], boxes) {
            label.label.set(\.fontSize, (label === release ? 15 : 13) * u)
            label.label.set(\.verticalAlignmentMode, .top)
            label.set(\.position, under(corners))
            label.sync(unit: u)
        }
        guard scene == .install else { return }
        pypiName.label.set(\.fontSize, 22 * u)
        pypiName.label.set(\.verticalAlignmentMode, .top)
        pypiName.set(\.position, CGPoint(x: under(boxes[1]).x, y: system.shownPoint([0, Shipping.headerY, 0]).point.y))
        pypiName.sync(unit: u)
    }

    // MARK: pip install

    /// The terminal on the laptop's screen: the command typed key by key, then pip's output, its progress bar filling
    /// as the copy flies over, and a new prompt.
    private func console(_ frame: StageFrame, t: Float, progress: Float) {
        let u = frame.stage.unit
        let system = network.system
        let (c, h) = (Shipping.screen.center, Shipping.screen.half)
        let lo = system.shownPoint([c.x - h.x + 0.03, c.y - h.y + 0.03, 0]).point
        let hi = system.shownPoint([c.x + h.x - 0.03, c.y + h.y - 0.03, 0]).point
        let screen = CGRect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y)
        panel.set(\.path, CGPath(rect: screen, transform: nil))

        let typed = min(max(Int((t - Self.typing.start) / Self.typing.perKey), 0), Self.command.count)
        let entered = Self.entered
        let download = Self.download
        let done = download.start + download.duration
        let text = NSColor(white: 0.82, alpha: 1)
        // pip's lines, as it prints them (indented as it does), the long ones wrapped to fit the screen.
        let rows: [(text: String, indent: CGFloat, color: NSColor, at: Float)] = [
            ("$ " + Self.command.prefix(typed), 0, .white, 0),
            ("Collecting ultralytics", 0, text, entered + 0.3),
            ("Downloading ultralytics-", 2, text, download.start),
            ("\(numbers.version)-py3-none-any.whl", 2, text, download.start),
            ("", 0, text, download.start),  // the bar's size
            ("Successfully installed", 0, .white, done + 0.3),
            ("ultralytics-\(numbers.version)", 2, .white, done + 0.3),
            ("$", 0, .white, done + 0.6),
        ]
        let (size, pitch) = (12.5 * u, 19 * u)
        let left = lo.x + 12 * u
        let top = hi.y - 22 * u
        for (k, (line, row)) in zip(lines, rows).enumerated() {
            line.set(\.fontSize, size)
            if k != 4 { line.set(\.text, row.text) }
            line.set(\.fontColor, row.color)
            line.set(\.isHidden, t < row.at)
            line.set(\.position, CGPoint(x: left + row.indent * 0.6 * size, y: top - CGFloat(k) * pitch))
        }
        // The bar: as wide as the wheel's name, filled with the copy's flight, its size after it.
        let barY = top - 4 * pitch + 3 * u
        let width = 150 * u
        let track = CGRect(x: left + 16 * u, y: barY, width: width, height: 6 * u)
        bar.track.set(\.path, CGPath(rect: track, transform: nil))
        let filled = CGRect(x: track.minX, y: track.minY, width: width * CGFloat(progress), height: track.height)
        bar.fill.set(\.path, CGPath(rect: filled, transform: nil))
        bar.track.set(\.isHidden, t < download.start)
        bar.fill.set(\.isHidden, bar.track.isHidden)
        lines[4].set(\.text, String(format: "%.1f/%@", numbers.wheelMB * progress, numbers.wheelText))
        lines[4].set(\.position, CGPoint(x: track.maxX + 8 * u, y: barY - 1 * u))
        lines[4].set(\.fontSize, 11 * u)
        // The cursor: after what's typed, then on the new prompt; blinking while it waits.
        let waiting = t < Self.typing.start || t > done + 0.6
        let row = t > done + 0.6 ? 7 : 0
        let blink = !waiting || Int(frame.time * 2) % 2 == 0
        let x = left + lines[row].frame.width + (row == 7 ? 0.6 * size : 2 * u)
        let y = top - CGFloat(row) * pitch - 3 * u
        cursor.set(\.path, CGPath(rect: CGRect(x: x, y: y, width: 7 * u, height: 14 * u), transform: nil))
        cursor.set(\.isHidden, !blink || (t > entered && t <= done + 0.6))
    }
}

extension ProjectStats {
    /// Ultralytics' numbers for the shipping steps (`Shipping.numbers`), fetched at launch: until then, and offline,
    /// the last ones fetched, or these (November 2026).
    static let ultralytics = ProjectStats(
        repository: "ultralytics/ultralytics", package: "ultralytics",
        fallback: .init(stars: 63_600, forks: 12_000, version: "8.4.215", wheelBytes: 1_500_000))
}
