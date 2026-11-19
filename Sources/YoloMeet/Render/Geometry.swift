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

nonisolated extension CGPath {
    /// A path from SVG path data (`d`), y down as in SVG: moves, lines, curves (cubic, smooth) and circular arcs, absolute
    /// or relative. Enough for an icon (e.g. a logo filled
    /// with particles).
    static func svg(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var numbers: [CGFloat] = []
        var tokens: [(Character, [CGFloat])] = []
        var command: Character?
        var number = ""
        func flush() {
            if let value = Double(number) { numbers.append(CGFloat(value)) }
            number = ""
        }
        for ch in d {
            if ch.isLetter && ch != "e" {
                flush()
                if let command { tokens.append((command, numbers)) }
                (command, numbers) = (ch, [])
            } else if ch == " " || ch == "," {
                flush()
            } else {
                // A sign starts a new number, and so does a second decimal point (".55.38": 0.55, 0.38).
                if ch == "-" && !number.isEmpty && !number.hasSuffix("e") { flush() }
                if ch == "." && number.contains(".") { flush() }
                number.append(ch)
            }
        }
        flush()
        if let command { tokens.append((command, numbers)) }

        var current = CGPoint.zero
        var start = CGPoint.zero
        var control: CGPoint?
        for (command, args) in tokens {
            let relative = command.isLowercase
            let at = { (x: CGFloat, y: CGFloat) in
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch command.uppercased() {
            case "M":
                for k in stride(from: 0, to: args.count - 1, by: 2) {
                    current = at(args[k], args[k + 1])
                    if k == 0 {
                        path.move(to: current)
                        start = current
                    } else {
                        path.addLine(to: current)
                    }
                }
                control = nil
            case "L":
                for k in stride(from: 0, to: args.count - 1, by: 2) {
                    current = at(args[k], args[k + 1])
                    path.addLine(to: current)
                }
                control = nil
            case "H":
                for x in args {
                    current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                    path.addLine(to: current)
                }
                control = nil
            case "V":
                for y in args {
                    current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                    path.addLine(to: current)
                }
                control = nil
            case "C":
                for k in stride(from: 0, to: args.count - 5, by: 6) {
                    let (c1, c2) = (at(args[k], args[k + 1]), at(args[k + 2], args[k + 3]))
                    let end = at(args[k + 4], args[k + 5])
                    path.addCurve(to: end, control1: c1, control2: c2)
                    (current, control) = (end, c2)
                }
            case "S":
                for k in stride(from: 0, to: args.count - 3, by: 4) {
                    let c1 = control.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                    let (c2, end) = (at(args[k], args[k + 1]), at(args[k + 2], args[k + 3]))
                    path.addCurve(to: end, control1: c1, control2: c2)
                    (current, control) = (end, c2)
                }
            case "A":
                for k in stride(from: 0, to: args.count - 6, by: 7) {
                    let end = at(args[k + 5], args[k + 6])
                    arc(path, from: current, to: end, radius: args[k], large: args[k + 3] != 0, sweep: args[k + 4] != 0)
                    current = end
                }
                control = nil
            case "Z":
                path.closeSubpath()
                current = start
                control = nil
            default: break
            }
        }
        return path
    }

    /// A circular arc from `p0` to `p1` as SVG draws it (its center from the flags), in short lines.
    private static func arc(
        _ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, radius: CGFloat, large: Bool, sweep: Bool
    ) {
        let (dx, dy) = ((p0.x - p1.x) / 2, (p0.y - p1.y) / 2)
        let r = max(radius, (dx * dx + dy * dy).squareRoot())
        let k = ((r * r - dx * dx - dy * dy) / (dx * dx + dy * dy)).squareRoot() * (large == sweep ? -1 : 1)
        let center = CGPoint(x: k * dy + (p0.x + p1.x) / 2, y: -k * dx + (p0.y + p1.y) / 2)
        let a0 = atan2(p0.y - center.y, p0.x - center.x)
        var delta = atan2(p1.y - center.y, p1.x - center.x) - a0
        if sweep, delta < 0 { delta += 2 * .pi }
        if !sweep, delta > 0 { delta -= 2 * .pi }
        let steps = 24
        for s in 1...steps {
            let a = a0 + delta * CGFloat(s) / CGFloat(steps)
            path.addLine(to: CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a)))
        }
    }
}

/// The convex outline around points, in order (Andrew's monotone chain).
nonisolated func convexHull(_ points: [CGPoint]) -> [CGPoint] {
    let sorted = points.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
    let cross = { (o: CGPoint, a: CGPoint, b: CGPoint) in (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
    var lower: [CGPoint] = []
    var upper: [CGPoint] = []
    for p in sorted {
        while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
        lower.append(p)
    }
    for p in sorted.reversed() {
        while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
        upper.append(p)
    }
    return lower.dropLast() + upper.dropLast()
}
