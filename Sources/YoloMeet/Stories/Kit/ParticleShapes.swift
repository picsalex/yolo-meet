import simd

/// A shape for `ParticleSystem.form(_:)`: one point per particle, and where each point goes when it's exploded.
struct ParticleShape {
    /// In -1...1 (x right, y up, z toward the viewer), in random order, so each particle flies to a random point.
    var points: [SIMD3<Float>]
    /// How far and which way each point moves at `ParticleSystem.explode` 1, in the shape's units (its part's
    /// direction; zero stays put).
    var offsets: [SIMD3<Float>]
}

enum ParticleShapes {
    /// The surface of a cube, a quarter of the points on its 12 edges so its outline reads. Exploded, each face moves
    /// out along its normal, taking its border with it (an edge's points go with either of its two faces).
    static func cube(_ count: Int, explodedBy distance: Float = 0.8) -> ParticleShape {
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
        }
        return shape
    }
}
