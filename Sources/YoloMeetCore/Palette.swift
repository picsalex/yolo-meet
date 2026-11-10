import CoreGraphics
import Foundation

/// Brand colors shared by decoders (overlay images) and effects (strokes, labels), as RGB bytes.
public nonisolated enum Palette {
    /// Ultralytics annotation palette (https://www.ultralytics.com/brand).
    public static let ultralytics: [(UInt8, UInt8, UInt8)] = [
        "042AFF", "0BDBEB", "F3F3F3", "00DFB7", "111F68", "FF6FDD", "FF444F", "CCED00", "00F344", "BD00FF",
        "00B4FF", "DD00BA", "00FFFF", "26C000", "01FFB3", "7D24FF", "7B0068", "FF1B6C", "FC6D2F", "A2FF0B",
    ].map(rgb)

    /// Roboflow's annotation palette: supervision's `ColorPalette.DEFAULT` (supervision 0.31).
    public static let roboflow: [(UInt8, UInt8, UInt8)] = [
        "A351FB", "FF4040", "FFA1A0", "FF7633", "FFB633", "D1D435", "4CFB12", "94CF1A", "40DE8A", "1B9640", "00D6C1",
        "2E9CAA", "00C4FF", "364797", "6675FF", "0019EF", "863AFF", "530087", "CD3AFF", "FF97CA", "FF39C9",
    ].map(rgb)

    /// Cityscapes palette for the 19 semantic classes.
    public static let cityscapes: [(UInt8, UInt8, UInt8)] = [
        (128, 64, 128), (244, 35, 232), (70, 70, 70), (102, 102, 156), (190, 153, 153), (153, 153, 153),
        (250, 170, 30), (220, 220, 0), (107, 142, 35), (152, 251, 152), (70, 130, 180), (220, 20, 60),
        (255, 0, 0), (0, 0, 142), (0, 0, 70), (0, 60, 100), (0, 80, 100), (0, 0, 230), (119, 11, 32),
    ]

    /// The Ultralytics gradient (Aqua Blue → Bright Blue → Neon Pink) in 256 steps.
    static let ultralyticsGradient: [(UInt8, UInt8, UInt8)] = (0..<256).map { step in
        let stops: [(Float, Float, Float)] = [(0, 255, 255), (4, 42, 255), (255, 100, 218)]
        let x = Float(step) / 255 * Float(stops.count - 1)
        let i = min(Int(x), stops.count - 2)
        let f = x - Float(i)
        let (a, b) = (stops[i], stops[i + 1])
        return (UInt8(a.0 + (b.0 - a.0) * f), UInt8(a.1 + (b.1 - a.1) * f), UInt8(a.2 + (b.2 - a.2) * f))
    }

    /// Inferno, the depth colormap: dark purple (far, 0) through red and orange to pale yellow (near, 1), rgb 0...1.
    public static func inferno(_ t: Float) -> SIMD3<Float> {
        let stops: [SIMD3<Float>] = [[0.08, 0.03, 0.22], [0.34, 0.06, 0.42], [0.73, 0.21, 0.33], [0.98, 0.55, 0.04], [0.99, 1, 0.64]]
        let x = min(max(t, 0), 1) * Float(stops.count - 1)
        let i = min(Int(x), stops.count - 2)
        return stops[i] + (stops[i + 1] - stops[i]) * (x - Float(i))
    }

    /// Inferno in 256 steps (far to near), as bytes.
    public static let infernoGradient: [(UInt8, UInt8, UInt8)] = (0..<256).map { step in
        let c = inferno(Float(step) / 255) * 255
        return (UInt8(c.x.rounded()), UInt8(c.y.rounded()), UInt8(c.z.rounded()))
    }

    public static func rgb(_ hex: String) -> (UInt8, UInt8, UInt8) {
        let v = UInt32(hex, radix: 16)!
        return (UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
    }
}

/// Wraps premultiplied RGBA bytes in a `CGImage`.
nonisolated func makeImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
    guard width > 0, height > 0, let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}
