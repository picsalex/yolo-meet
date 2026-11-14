import simd

/// A brain seen from the side at rest (x front, y up, z toward the viewer: the left hemisphere), in -1...1: two folded
/// hemispheres, each its lobes blended smoothly (frontal, parietal, occipital) with the temporal lobe hanging under the
/// middle behind a crease (the lateral sulcus), the striped cerebellum under their back, and the brain stem.
/// Proportions follow a textbook side view.
nonisolated enum Brain {
    private struct Ellipsoid {
        let center, radii: SIMD3<Float>

        func contains(_ p: SIMD3<Float>, scale: Float = 1) -> Bool { simd_length((p - center) / radii) < scale }
        /// The point at a direction of its unit sphere, `r` along it.
        func point(_ direction: SIMD3<Float>, r: Float = 1) -> SIMD3<Float> { center + direction * r * radii }
        /// Roughly proportional to its surface, to spread points evenly over several.
        var area: Float { radii.x * radii.y + radii.y * radii.z + radii.x * radii.z }
        /// About how far a point is from its surface (negative inside).
        func distance(_ p: SIMD3<Float>) -> Float {
            let (k0, k1) = (simd_length((p - center) / radii), simd_length((p - center) / (radii * radii)))
            return k0 * (k0 - 1) / max(k1, 1e-5)
        }
    }

    /// Each hemisphere's lobes: frontal, parietal, occipital, temporal.
    private static let hemispheres = [-1, 1].map { (side: Float) in
        [
            Ellipsoid(center: [0.45, 0.32, 0.38 * side], radii: [0.57, 0.54, 0.38]),
            Ellipsoid(center: [-0.3, 0.42, 0.37 * side], radii: [0.55, 0.44, 0.37]),
            Ellipsoid(center: [-0.77, 0.14, 0.34 * side], radii: [0.25, 0.36, 0.32]),
            Ellipsoid(center: [0.02, -0.14, 0.42 * side], radii: [0.58, 0.28, 0.3]),
        ]
    }
    private static let lobes = hemispheres.flatMap { $0 }
    private static let cerebellum = Ellipsoid(center: [-0.48, -0.38, 0], radii: [0.36, 0.21, 0.5])
    private static let stem: (top: SIMD3<Float>, bottom: SIMD3<Float>, radius: Float) = ([-0.25, -0.28, 0], [-0.4, -0.72, 0], 0.09)

    /// The brain's surface as a particle shape (it doesn't explode).
    static func shape(_ count: Int) -> ParticleShape {
        let lobeArea = lobes.map(\.area).reduce(0, +)
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(count)
        while points.count < count {
            let pick = Float.random(in: 0...1)
            let d = SIMD3<Float>.randomDirection()
            if pick < 0.82 {
                // A lobe's point moved onto the blended surface, kept where that lobe is the nearest (so each part of
                // the surface is sampled once), its points crowding along winding lines (where a smooth wave pattern
                // crosses zero): the folds of the cortex.
                var a = Float.random(in: 0..<lobeArea)
                let lobe = lobes.first { a -= $0.area; return a < 0 } ?? lobes[0]
                let p = onCerebrum(lobe.point(d))
                let g = sin(6 * p.x + 2 * sin(5 * p.z) + 2.5 * sin(4 * p.y)) + 0.8 * sin(6 * p.y + 2.5 * sin(5 * p.x) + 2 * sin(6 * p.z))
                guard Float.random(in: 0...1) < 0.05 + 0.95 * exp(-g * g / 0.06), abs(cerebrum(p)) < 0.01,
                    lobes.min(by: { $0.distance(p) < $1.distance(p) })!.center == lobe.center, !cerebellum.contains(p)
                else { continue }
                points.append(p)
            } else if pick < 0.95 {
                // The cerebellum, in thin horizontal folds, where the hemispheres don't cover it.
                let p = cerebellum.point(d)
                guard Float.random(in: 0...1) < 0.2 + 0.8 * (sin(d.y * 40) * 0.5 + 0.5), cerebrum(p) > 0
                else { continue }
                points.append(p)
            } else {
                // The stem: a tube down from under the hemispheres, in front of the cerebellum.
                let t = Float.random(in: 0...1), angle = Float.random(in: 0...(2 * .pi))
                let p = stem.top + (stem.bottom - stem.top) * t + stem.radius * SIMD3(cos(angle), 0, sin(angle))
                guard cerebrum(p) > 0, !cerebellum.contains(p) else { continue }
                points.append(p)
            }
        }
        return ParticleShape(points: points, offsets: Array(repeating: .zero, count: count))
    }

    /// About how far a point is from the hemispheres' surface (negative inside): each hemisphere's upper lobes blended
    /// softly, the temporal lobe with a tight crease, and the two hemispheres apart (the fissure between them).
    private static func cerebrum(_ p: SIMD3<Float>) -> Float {
        hemispheres.map { l in
            let upper = smoothMin(smoothMin(l[0].distance(p), l[1].distance(p), 0.45), l[2].distance(p), 0.3)
            return smoothMin(upper, l[3].distance(p), 0.06)
        }.min()!
    }

    /// The point moved onto the hemispheres' surface, along the distance's slope (a few Newton steps).
    private static func onCerebrum(_ point: SIMD3<Float>) -> SIMD3<Float> {
        var p = point
        let e: Float = 0.002
        for _ in 0..<3 {
            let d = cerebrum(p)
            let g = SIMD3(cerebrum(p + [e, 0, 0]) - d, cerebrum(p + [0, e, 0]) - d, cerebrum(p + [0, 0, e]) - d) / e
            p -= d * g / max(simd_length_squared(g), 1e-6)
        }
        return p
    }

    private static func smoothMin(_ a: Float, _ b: Float, _ k: Float) -> Float {
        let h = max(k - abs(a - b), 0) / k
        return min(a, b) - h * h * k / 4
    }

    /// A random point well inside a lobe (nine in ten) or the cerebellum: where neurons go.
    static func inside() -> SIMD3<Float> {
        let region = Float.random(in: 0...1) < 0.9 ? lobes.randomElement()! : cerebellum
        while true {
            let d = SIMD3<Float>.random(in: -1...1)
            if simd_length(d) < 0.85 { return region.point(d) }
        }
    }
}
