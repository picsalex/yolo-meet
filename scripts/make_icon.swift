// Renders the app icon to Support/AppIcon.icns: a person framed by a detection box with pose keypoints, in Ultralytics
// brand colors. Run from the repo root: swift scripts/make_icon.swift
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

let (darkBlue, brightBlue, aqua, pink, yellow) = (0x111F68 as UInt32, 0x042AFF as UInt32, 0x00FFFF as UInt32, 0xFF64DA as UInt32, 0xE1FF25 as UInt32)

func render(_ size: Int) -> Data {
    let s = CGFloat(size) / 1024
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    // macOS icon grid: 824 pt body centered on a 1024 canvas, with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(darkBlue))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let background = CGGradient(colorsSpace: space, colors: [color(0x1A2C8F), color(darkBlue), color(0x0A1240)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [color(brightBlue, 0.55), color(brightBlue, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 470), startRadius: 0, endCenter: CGPoint(x: 512, y: 470), endRadius: 420, options: [])

    // Person: head and shoulders, in the brand gradient (Aqua -> Bright Blue -> Neon Pink).
    let person = CGMutablePath()
    person.addEllipse(in: CGRect(x: 397, y: 470, width: 230, height: 230))
    // Shoulders: rounded on top, running off the bottom edge of the icon.
    person.move(to: CGPoint(x: 272, y: 60))
    person.addLine(to: CGPoint(x: 272, y: 280))
    person.addCurve(to: CGPoint(x: 512, y: 445), control1: CGPoint(x: 272, y: 400), control2: CGPoint(x: 380, y: 445))
    person.addCurve(to: CGPoint(x: 752, y: 280), control1: CGPoint(x: 644, y: 445), control2: CGPoint(x: 752, y: 400))
    person.addLine(to: CGPoint(x: 752, y: 60))
    person.closeSubpath()
    ctx.saveGState()
    ctx.addPath(person)
    ctx.clip()
    let brand = CGGradient(colorsSpace: space, colors: [color(aqua), color(brightBlue), color(pink)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(brand, start: CGPoint(x: 360, y: 720), end: CGPoint(x: 680, y: 120), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
    ctx.restoreGState()

    // Detection box: corner brackets around the person, with a label chip.
    let box = CGRect(x: 250, y: 205, width: 524, height: 545)
    let arm: CGFloat = 120
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineWidth(22)
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
    let chip = CGPath(roundedRect: CGRect(x: box.minX - 11, y: box.maxY + 26, width: 230, height: 62), cornerWidth: 16, cornerHeight: 16, transform: nil)
    ctx.addPath(chip)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    for (i, w) in [CGFloat(70), 104].enumerated() {  // abstract "label" text
        let bar = CGRect(x: box.minX + 14 + CGFloat(i) * 88, y: box.maxY + 47, width: w - (i == 0 ? 0 : 30), height: 20)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 10, cornerHeight: 10, transform: nil))
    }
    ctx.setFillColor(color(darkBlue))
    ctx.fillPath()

    // Pose keypoints in the app's pose colors: Aqua left, Neon Pink right, Light Blue center; Neon Yellow joints.
    let (nose, neck) = (CGPoint(x: 512, y: 575), CGPoint(x: 512, y: 380))
    let (left, right) = (CGPoint(x: 362, y: 360), CGPoint(x: 662, y: 360))  // the person's left is on our right
    ctx.setLineWidth(14)
    for (a, b, c) in [(nose, neck, 0xACF9FF as UInt32), (neck, right, aqua), (neck, left, pink)] {
        ctx.setStrokeColor(color(c))
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
    }
    for p in [nose, left, right] {
        let dot = CGRect(x: p.x - 28, y: p.y - 28, width: 56, height: 56)
        ctx.setFillColor(color(yellow))
        ctx.fillEllipse(in: dot)
        ctx.setStrokeColor(color(darkBlue))
        ctx.setLineWidth(8)
        ctx.strokeEllipse(in: dot)
    }

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
