import simd

/// A shape for `ParticleSystem.form(_:)`: one point per particle, and where each point goes when it's exploded.
nonisolated struct ParticleShape {
    /// In -1...1 (x right, y up, z toward the viewer), in random order, so each particle flies to a random point.
    var points: [SIMD3<Float>]
    /// How far and which way each point moves at `ParticleSystem.explode` 1, in the shape's units (its part's
    /// direction; zero stays put).
    var offsets: [SIMD3<Float>]
    /// The part each point belongs to (e.g. a cube's face), for `ParticleSystem.highlight`; empty: all part 0.
    var parts: [Int] = []
    /// Each point's color (rgb 0...1), nil for the system's `color`; empty: all the system's.
    var colors = ParticleColors()

    init(points: [SIMD3<Float>], offsets: [SIMD3<Float>], parts: [Int] = [], colors: [SIMD3<Float>?] = []) {
        (self.points, self.offsets, self.parts, self.colors) = (points, offsets, parts, ParticleColors(colors))
    }
}

/// The particles' colors (rgb 0...1, nil for the system's `color`), kept as the GPU reads them: rgb then 1, or all 0
/// for none. Half the memory of optional colors (16 bytes each, not 32), and handed to the GPU as they are.
nonisolated struct ParticleColors: RandomAccessCollection, MutableCollection, Sendable {
    private(set) var gpu: [SIMD4<Float>]

    init() { gpu = [] }
    init(_ colors: some Sequence<SIMD3<Float>?>) { gpu = colors.map(Self.gpu) }
    init(repeating color: SIMD3<Float>?, count: Int) { gpu = Array(repeating: Self.gpu(color), count: count) }

    var startIndex: Int { 0 }
    var endIndex: Int { gpu.count }

    subscript(index: Int) -> SIMD3<Float>? {
        get {
            let color = gpu[index]
            return color.w > 0.5 ? SIMD3(color.x, color.y, color.z) : nil
        }
        set { gpu[index] = Self.gpu(newValue) }
    }

    private static func gpu(_ color: SIMD3<Float>?) -> SIMD4<Float> { color.map { SIMD4($0, 1) } ?? .zero }
}

enum ParticleShapes {
    /// How far a cube's faces move out when it's exploded, by default (in half-sizes).
    static let cubeExplode: Float = 0.8

    /// A cube's faces as `ParticleShape.parts`, and each face's center (its outward normal).
    enum CubeFace: Int, CaseIterable {
        case left, right, bottom, top, back, front

        var center: SIMD3<Float> {
            var c = SIMD3<Float>(repeating: 0)
            c[rawValue / 2] = rawValue % 2 == 0 ? -1 : 1
            return c
        }

        /// The face's four corners in order around it, grown by `scale` in its plane and moved out as the cube is
        /// exploded (`ParticleSystem.explode`, at `cubeExplode`): map them through `ParticleSystem.stagePoint` to
        /// hit-test the face.
        func corners(grownBy scale: Float = 1, exploded explode: Float = 0) -> [SIMD3<Float>] {
            let axis = rawValue / 2
            var (u, v) = (SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 0))
            u[(axis + 1) % 3] = scale
            v[(axis + 2) % 3] = scale
            let middle = center * (1 + ParticleShapes.cubeExplode * explode)
            return [middle - u - v, middle + u - v, middle + u + v, middle - u + v]
        }
    }

    /// The surface of a cube, a quarter of the points on its 12 edges so its outline reads. Exploded, each face moves
    /// out along its normal, taking its border with it (an edge's points go with either of its two faces). Parts are
    /// the faces (`CubeFace`).
    static func cube(_ count: Int, explodedBy distance: Float = cubeExplode) -> ParticleShape {
        var shape = ParticleShape(points: [], offsets: [])
        for i in 0..<count {
            // The face: ±1 on one axis.
            let axis = Int.random(in: 0..<3)
            let side: Float = Bool.random() ? 1 : -1
            var p = SIMD3<Float>(repeating: 0)
            p[axis] = side
            p[(axis + 1) % 3] = .random(in: -1...1)
            p[(axis + 2) % 3] = .random(in: -1...1)
            if i % 4 == 0 {
                // On one of the face's four border edges.
                p[(axis + Int.random(in: 1...2)) % 3] = Bool.random() ? 1 : -1
            }
            var normal = SIMD3<Float>(repeating: 0)
            normal[axis] = side
            shape.points.append(p)
            shape.offsets.append(normal * distance)
            shape.parts.append(axis * 2 + (side > 0 ? 1 : 0))
        }
        return shape
    }
}

/// A box in a shape's space: its 8 corners (corner `k` on the + side of x when `k & 1`, of y when `k & 2`, of z when
/// `k & 4`), and its 12 edges and 6 faces as corner indices.
nonisolated enum Box {
    static func corners(_ center: SIMD3<Float> = .zero, half: SIMD3<Float>) -> [SIMD3<Float>] {
        (0..<8).map { k in center + half * SIMD3(k & 1 == 0 ? -1 : 1, k & 2 == 0 ? -1 : 1, k & 4 == 0 ? -1 : 1) }
    }

    /// The corners that differ on one axis.
    static let edges: [(Int, Int)] = (0..<8).flatMap { k in [1, 2, 4].filter { k & $0 == 0 }.map { (k, k | $0) } }

    /// Each face's corners in order around it: left, right, bottom, top, back, front.
    static let faces = [[0, 4, 6, 2], [1, 5, 7, 3], [0, 4, 5, 1], [2, 6, 7, 3], [0, 2, 3, 1], [4, 6, 7, 5]]
}
