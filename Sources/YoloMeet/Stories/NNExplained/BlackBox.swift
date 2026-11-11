import SpriteKit
import simd

extension NetworkLayout {
    /// The cube's half side, in the shape's units.
    static let blackBoxSide: Float = 0.62

    /// A neural network seen from outside: a black box, its edges drawn by all the particles (dark gray), turning
    /// slowly. A fist releases the particles, and letting go moves on to the next step (`releases`), the brain.
    static func blackBox() -> NetworkLayout {
        let layout = NetworkLayout(
            title: "Black box", subtitle: "a neural network, seen from outside", neurons: [], synapses: [], neuronSize: 0.02,
            restingTilt: 0.42)
        (layout.restingTurn, layout.spins, layout.releases) = (0.6, true, true)
        let s = blackBoxSide
        layout.outline = blackBoxCorners
        // The 12 edges: along each axis, at each sign of the other two.
        let edges: [(SIMD3<Float>, SIMD3<Float>)] = (0..<3).flatMap { axis in
            [(-1, -1), (-1, 1), (1, -1), (1, 1)].map { (a: Float, b: Float) -> (SIMD3<Float>, SIMD3<Float>) in
                var from = SIMD3<Float>.zero, along = SIMD3<Float>.zero
                along[axis] = 2 * s
                from[axis] = -s
                (from[(axis + 1) % 3], from[(axis + 2) % 3]) = (a * s, b * s)
                return (from, along)
            }
        }
        let n = NeuralNetwork.particles
        let gray = SIMD3<Float>(repeating: 0.03)
        let points = (0..<n).map { i -> SIMD3<Float> in
            let (from, along) = edges[i % edges.count]
            return from + along * Float.random(in: 0...1) + SIMD3<Float>.random(in: -0.007...0.007)
        }
        layout.shape = ParticleShape(
            points: points, offsets: Array(repeating: .zero, count: n), parts: Array(repeating: 0, count: n),
            colors: Array(repeating: gray, count: n))
        return layout
    }

    /// The black box's 8 corners.
    static var blackBoxCorners: [SIMD3<Float>] {
        let s = blackBoxSide
        return [-1, 1].flatMap { x in [-1, 1].flatMap { y in [-1, 1].map { z in SIMD3<Float>(x, y, z) * s } } }
    }
}

/// The black box's faces, filled black under the particles (`behind`, over the camera), so it reads as a solid box with
/// the particles as its edges. They follow the particles (`shownPoint`) and go at once when a fist releases them.
final class BlackBoxEffect: Effect {
    private let network: NeuralNetwork
    private let layout: NetworkLayout
    /// One shape per face: overlapping in one path, they could cut holes in each other.
    private let faces = (0..<6).map { _ in SKShapeNode() }
    private let box = SKNode()

    init(_ network: NeuralNetwork, _ layout: NetworkLayout) {
        (self.network, self.layout) = (network, layout)
        super.init()
        behind = true
        box.alpha = 0
        node.addChild(box)
        for face in faces {
            (face.fillColor, face.strokeColor) = (.black, .clear)
            box.addChild(face)
        }
    }

    override func update(_ frame: StageFrame) {
        let system = network.system
        let shown = network.formed === layout && system.mode == .form
        box.alpha = box.alpha.approaching(shown ? 1 : 0, CGFloat(1 - exp(-frame.dt * (shown ? 2 : 14))))
        box.isHidden = box.alpha < 0.01
        guard !box.isHidden else { return }
        let c = NetworkLayout.blackBoxCorners.map { system.shownPoint($0).point }
        // Corners: index x * 4 + y * 2 + z (0: -, 1: +); each face, its four corners in order.
        let quads = [[0, 1, 3, 2], [4, 5, 7, 6], [0, 1, 5, 4], [2, 3, 7, 6], [0, 2, 6, 4], [1, 3, 7, 5]]
        for (face, quad) in zip(faces, quads) {
            let path = CGMutablePath()
            path.addLines(between: quad.map { c[$0] })
            path.closeSubpath()
            face.path = path
        }
    }
}
