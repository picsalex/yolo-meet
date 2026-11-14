import CoreGraphics

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
