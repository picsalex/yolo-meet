import CoreGraphics
import Foundation
import simd

nonisolated extension CGPath {
    /// A closed polygon through `points`.
    static func closed(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }
}

nonisolated extension CGContext {
    /// A bitmap to draw in: sRGB, premultiplied RGBA, 4 bytes a pixel row after row (`data`), origin at the bottom left.
    static func bitmap(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
}

/// Smoothstep: `t` clamped to 0...1, eased at both ends (3t² − 2t³).
nonisolated func smoothstep<T: BinaryFloatingPoint>(_ t: T) -> T {
    let t = min(max(t, 0), 1)
    return t * t * (3 - 2 * t)
}

/// A value a spring can move: added, subtracted and scaled.
nonisolated protocol SpringValue {
    static func + (a: Self, b: Self) -> Self
    static func - (a: Self, b: Self) -> Self
    static func * (a: Self, k: Float) -> Self
    static var zero: Self { get }
}

nonisolated extension SIMD2: SpringValue where Scalar == Float {}
nonisolated extension SIMD3: SpringValue where Scalar == Float {}
nonisolated extension simd_float3x3: SpringValue {
    static var zero: simd_float3x3 { simd_float3x3(0) }
}

/// A value moving toward a target on a critically damped spring, as the particles do in the shader
/// (`ParticleSystem.formStiffness`): e.g. 2D content drawn on the particles that has to move with them.
nonisolated struct Spring<Value: SpringValue> {
    var value: Value
    var speed: Value = .zero

    init(_ value: Value) { self.value = value }

    /// Moves `dt` seconds on toward `target`, in substeps as the shader (at most 0.1 s, so a long frame doesn't jump).
    mutating func step(toward target: Value, dt: TimeInterval, stiffness k: Float = ParticleSystem.formStiffness) {
        let dt = Float(min(dt, 0.1))
        let steps = min(max(Int((dt * 120).rounded(.up)), 1), 8)
        let h = dt / Float(steps)
        for _ in 0..<steps {
            speed = speed + ((target - value) * k - speed * (2 * k.squareRoot())) * h
            value = value + speed * h
        }
    }
}
