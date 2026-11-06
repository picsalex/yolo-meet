import CoreGraphics
import Foundation

/// Colors shared by decoders (overlay images) and effects (strokes, labels), as RGB bytes.
public nonisolated enum Palette {
    /// Ultralytics default class palette.
    public static let classes: [(UInt8, UInt8, UInt8)] = [
        "042AFF", "0BDBEB", "F3F3F3", "00DFB7", "111F68", "FF6FDD", "FF444F", "CCED00", "00F344", "BD00FF",
        "00B4FF", "DD00BA", "00FFFF", "26C000", "01FFB3", "7D24FF", "7B0068", "FF1B6C", "FC6D2F", "A2FF0B",
    ].map(rgb)

    /// Cityscapes palette for the 19 semantic classes.
    public static let cityscapes: [(UInt8, UInt8, UInt8)] = [
        (128, 64, 128), (244, 35, 232), (70, 70, 70), (102, 102, 156), (190, 153, 153), (153, 153, 153),
        (250, 170, 30), (220, 220, 0), (107, 142, 35), (152, 251, 152), (70, 130, 180), (220, 20, 60),
        (255, 0, 0), (0, 0, 142), (0, 0, 70), (0, 60, 100), (0, 80, 100), (0, 0, 230), (119, 11, 32),
    ]

    public static func color(for index: Int) -> CGColor {
        let (r, g, b) = classes[abs(index) % classes.count]
        return CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// Turbo colormap (Google's polynomial approximation), `t` in 0...1.
    static func turbo(_ t: Float) -> (UInt8, UInt8, UInt8) {
        let x = min(max(t, 0), 1)
        let r = 0.13572138 + x * (4.61539260 + x * (-42.66032258 + x * (132.13108234 + x * (-152.94239396 + x * 59.28637943))))
        let g = 0.09140261 + x * (2.19418839 + x * (4.84296658 + x * (-14.18503333 + x * (4.27729857 + x * 2.82956604))))
        let b = 0.10667330 + x * (12.64194608 + x * (-60.58204836 + x * (110.36276771 + x * (-89.90310912 + x * 27.34824973))))
        func byte(_ v: Float) -> UInt8 { UInt8(min(max(v, 0), 1) * 255) }
        return (byte(r), byte(g), byte(b))
    }

    private static func rgb(_ hex: String) -> (UInt8, UInt8, UInt8) {
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
