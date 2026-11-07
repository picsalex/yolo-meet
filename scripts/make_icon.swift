// Renders the app icon to Support/AppIcon.icns: the Ultralytics logomark (white, the official reverse variant) detected
// YOLO-style on a brand-gradient tile. Run from the repo root: swift scripts/make_icon.swift [preview.png]
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

let (darkBlue, brightBlue, aqua, pink, yellow) = (
    0x111F68 as UInt32, 0x042AFF as UInt32, 0x00FFFF as UInt32, 0xFF64DA as UInt32, 0xE1FF25 as UInt32
)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// The logomark's two paths from ultralytics/assets logo/Ultralytics_Logotype_Original.svg (107 x 92 units, y down).
let logomark = [
    "M56.7478 25.1939L56.7365 38.0286C56.7824 55.5439 42.5251 69.8368 25.1086 69.8148C18.1905 69.8036 11.8932 67.6925 6.78925 63.9998C15.9461 80.5019 33.5065 91.6475 53.471 91.6608C82.4752 91.6378 106.447 67.9677 106.902 38.8701L106.895 38.7488C106.922 38.0783 106.894 25.6714 106.927 25.1223C106.889 11.317 95.6288 -0.0290768 81.8562 0.00597989C68.0198 -0.0165355 56.7033 11.2672 56.7478 25.1939Z",
    "M25.0789 12.9165C11.2511 12.9165 0.000768562 24.1938 0.000768562 38.0553C0.000768562 51.9154 11.2511 63.1926 25.0789 63.1926C38.9075 63.1926 50.157 51.9154 50.157 38.0553C50.157 24.1938 38.9075 12.9165 25.0789 12.9165Z",
]

/// Builds a CGPath from the absolute M/L/C/Z commands these paths use.
func path(_ svg: String, _ transform: CGAffineTransform) -> CGPath {
    let tokens = svg.matches(of: #/[MLCZ]|-?\d*\.?\d+(?:e-?\d+)?/#).map { String($0.output) }
    let path = CGMutablePath()
    var (i, command) = (0, "")
    func point() -> CGPoint {
        defer { i += 2 }
        return CGPoint(x: Double(tokens[i])!, y: Double(tokens[i + 1])!).applying(transform)
    }
    while i < tokens.count {
        if Double(tokens[i]) == nil {
            command = tokens[i]
            i += 1
        }
        switch command {
        case "M": path.move(to: point())
        case "L": path.addLine(to: point())
        case "C":
            let (c1, c2) = (point(), point())
            path.addCurve(to: point(), control1: c1, control2: c2)
        case "Z": path.closeSubpath()
        default: fatalError("unsupported path command \(command)")
        }
    }
    return path
}

func render(_ size: Int) -> Data {
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    // Tile on the macOS icon grid (824 pt body on a 1024 canvas) with a soft shadow.
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0, 0.35))
    ctx.addPath(tile)
    ctx.setFillColor(color(darkBlue))
    ctx.fillPath()
    ctx.restoreGState()

    // Brand gradient, Bright Blue to Dark Blue, lit by an Aqua and a Neon Pink glow.
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let base = CGGradient(colorsSpace: sRGB, colors: [color(brightBlue), color(darkBlue)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
    for (hex, center, radius) in [(aqua, CGPoint(x: 180, y: 860), 520.0), (pink, CGPoint(x: 900, y: 140), 560.0)] {
        let glow = CGGradient(colorsSpace: sRGB, colors: [color(hex, hex == pink ? 0.8 : 0.55), color(hex, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }
    ctx.restoreGState()

    // The logomark, white, centered in the detection box below.
    let box = CGRect(x: 232, y: 228, width: 560, height: 500)
    let scale = 4.1
    let mark = CGSize(width: 107 * scale, height: 92 * scale)
    let flip = CGAffineTransform(translationX: box.midX - mark.width / 2, y: box.midY + mark.height / 2)
        .scaledBy(x: scale, y: -scale)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: color(aqua, 0.6))
    for d in logomark { ctx.addPath(path(d, flip)) }
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // Detection: Neon Yellow corner brackets and an Ultralytics-style label chip.
    let arm: CGFloat = 110
    ctx.setStrokeColor(color(yellow))
    ctx.setLineWidth(20)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for (corner, dx, dy) in [
        (CGPoint(x: box.minX, y: box.maxY), arm, -arm), (CGPoint(x: box.maxX, y: box.maxY), -arm, -arm),
        (CGPoint(x: box.minX, y: box.minY), arm, arm), (CGPoint(x: box.maxX, y: box.minY), -arm, arm),
    ] {
        ctx.move(to: CGPoint(x: corner.x + dx, y: corner.y))
        ctx.addLine(to: corner)
        ctx.addLine(to: CGPoint(x: corner.x, y: corner.y + dy))
    }
    ctx.strokePath()
    let label = NSAttributedString(string: "ultralytics 99%", attributes: [
        .font: NSFont(name: "Arial-BoldMT", size: 50)!, .foregroundColor: NSColor(cgColor: color(darkBlue))!,
    ])
    let text = label.size()
    let chip = CGRect(x: box.minX - 10, y: box.maxY + 24, width: text.width + 48, height: text.height + 22)
    ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.setFillColor(color(yellow))
    ctx.fillPath()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    label.draw(at: CGPoint(x: chip.minX + 24, y: chip.minY + 11))
    NSGraphicsContext.current = nil

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let iconset = URL(filePath: NSTemporaryDirectory()).appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try render(points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try render(points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
if let preview = CommandLine.arguments.dropFirst().first { try render(1024).write(to: URL(filePath: preview)) }
let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Support/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote Support/AppIcon.icns" : "iconutil failed")
