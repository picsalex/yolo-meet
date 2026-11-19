import SpriteKit
import simd

/// One pixel of the zoomed-in picture and the three numbers it is (`NetworkLayout.onePixel`): outlined in gold on the
/// grid, it flies out of it as a large swatch of its color beside the picture, then its red, green and blue values show
/// one after the other, each a bar out of 255 that fills as its number counts up, and last the three together, the
/// pixel's value. Space + point at another pixel shows its values instead (they stay once Space is released).
final class PixelValuesEffect: Effect {
    /// The pixel shown first (column, row from the top): the cat's cheek, its orange fur.
    static let first = (column: 23, row: 20)
    /// When each part shows, in seconds once the picture is in place: the outline, the swatch's flight, the values
    /// (one after the other), the three together.
    private static let outlineAt = 0.3, flight = (at: 0.9, duration: 0.9), valuesAt = 2.1, valueGap = 0.9, totalAt = 5.0
    /// How long a value's bar takes to fill as its number counts up.
    private static let fill = 0.7

    private let network: NeuralNetwork
    private let layout: NetworkLayout
    /// The picture's pixels, 0...255 per channel, row by row from the top.
    private let values: [SIMD3<Int>]
    private var pixel: Int
    /// The bars' lengths (0...1 of 255), easing toward the pixel's values when another is pointed at.
    private var bars: SIMD3<Float>
    /// When the picture was in place here; nil until then.
    private var since: TimeInterval?

    private let content = SKNode()
    private let outline = SKShapeNode()
    /// Lines from the pixel to its swatch, as through a magnifier.
    private let rays = SKShapeNode()
    private let swatch = SKShapeNode()
    private let place = ShadowedLabel("", font: ObjectTitle.subtitleFont)
    private let rows: [(name: ShadowedLabel, track: SKShapeNode, bar: SKShapeNode, value: ShadowedLabel)]
    private let total = ShadowedLabel("", font: ObjectTitle.subtitleFont, color: NNColors.gold)
    private static let gold = NNColors.gold
    /// Each channel's name and its color on stage (lighter than pure, so the blue reads on black).
    private static let channels: [(name: String, color: NSColor)] = [
        ("R", NSColor(red: 1, green: 0.3, blue: 0.3, alpha: 1)),
        ("G", NSColor(red: 0.3, green: 1, blue: 0.4, alpha: 1)),
        ("B", NSColor(red: 0.35, green: 0.55, blue: 1, alpha: 1)),
    ]

    init(_ network: NeuralNetwork, _ layout: NetworkLayout) {
        (self.network, self.layout) = (network, layout)
        let cells = layout.pixelGrid?.cells ?? NetworkLayout.pixelCells
        values = NetworkLayout.catDrawing(cells).map { SIMD3<Int>(($0 * 255).rounded(.toNearestOrEven)) }
        pixel = Self.first.row * cells + Self.first.column
        bars = SIMD3<Float>(values[pixel]) / 255
        rows = Self.channels.map { channel in
            let name = ShadowedLabel(channel.name, font: "Archivo-SemiBold", color: channel.color)
            let (track, bar) = (SKShapeNode(), SKShapeNode())
            (track.fillColor, track.strokeColor) = (NSColor(white: 1, alpha: 0.14), .clear)
            (bar.fillColor, bar.strokeColor) = (channel.color, .clear)
            return (name, track, bar, ShadowedLabel("", font: ObjectTitle.subtitleFont))
        }
        super.init()
        (outline.strokeColor, outline.fillColor, outline.lineJoin) = (Self.gold, .clear, .miter)
        (rays.strokeColor, rays.lineCap) = (Self.gold.withAlphaComponent(0.7), .round)
        swatch.strokeColor = Self.gold
        (place.label.horizontalAlignmentMode, place.label.verticalAlignmentMode) = (.left, .center)
        (total.label.horizontalAlignmentMode, total.label.verticalAlignmentMode) = (.left, .center)
        for child in [rays, outline, swatch, place, total] as [SKNode] { content.addChild(child) }
        for row in rows {
            (row.name.label.horizontalAlignmentMode, row.name.label.verticalAlignmentMode) = (.left, .center)
            (row.value.label.horizontalAlignmentMode, row.value.label.verticalAlignmentMode) = (.left, .center)
            for child in [row.track, row.bar, row.name, row.value] as [SKNode] { content.addChild(child) }
        }
        content.alpha = 0
        node.addChild(content)
    }

    override func update(_ frame: StageFrame) {
        let u = frame.stage.unit
        let system = network.system
        guard let grid = layout.pixelGrid else { return }
        // Once the picture is in place (it slides aside first), not while a fist scatters it.
        let here = network.formed === layout && system.mode == .form
        if here, since == nil { since = frame.time + 0.5 }
        if !here { since = nil }
        let t = since.map { frame.time - $0 } ?? -1
        let ease = CGFloat(1 - exp(-frame.dt * (here ? 6 : 14)))
        content.set(\.alpha, content.alpha.approaching(here && t >= 0 ? 1 : 0, ease))
        content.set(\.isHidden, content.alpha < 0.01)
        guard !content.isHidden else { return }

        // The grid on stage: a pixel's corners from its column and row (the picture faces the viewer).
        let n = grid.cells
        let pitch = grid.side / Float(n)
        let corner = { (x: Float, y: Float) -> CGPoint in
            system.shownPoint(grid.center + SIMD3(-grid.side / 2 + x * pitch, grid.side / 2 - y * pitch, 0)).point
        }
        let picture = CGRect(enclosing: [corner(0, 0), corner(Float(n), Float(n))])

        // Space + point: the pixel under the fingertip.
        if frame.keys.held.contains("space") {
            for pointer in frame.pointers where picture.contains(pointer.location) {
                let fx = (pointer.location.x - picture.minX) / picture.width
                let fy = (picture.maxY - pointer.location.y) / picture.height
                pixel = min(Int(fy * CGFloat(n)), n - 1) * n + min(Int(fx * CGFloat(n)), n - 1)
                frame.pointing.mark(pointer.hand)
                break
            }
        }
        let (column, row) = (pixel % n, pixel / n)
        let value = values[pixel]
        bars += (SIMD3<Float>(value) / 255 - bars) * Float(1 - exp(-frame.dt * 10))

        // The pixel outlined in gold, closing in on it from four times its size.
        let cell = CGRect(enclosing: [corner(Float(column), Float(row)), corner(Float(column + 1), Float(row + 1))])
        let close = CGFloat(smoothstep((t - Self.outlineAt) / 0.6))
        let grow = 1 + 3 * (1 - close)
        let ring = cell.insetBy(dx: -cell.width * (grow - 1) / 2, dy: -cell.height * (grow - 1) / 2)
        outline.set(\.path, CGPath(rect: ring, transform: nil))
        outline.set(\.lineWidth, 2.5 * u)
        outline.set(\.alpha, close)

        // The panel beside the picture, on the right if it fits, else on the left (clear of the height's label).
        let (side, width) = (120 * u, 250 * u)
        let view = frame.stage.viewSize
        var x = picture.maxX + 56 * u
        if x + width > view.width - 24 * u { x = picture.minX - 100 * u - width }
        x = min(max(x, 24 * u), view.width - 24 * u - width)
        let (rowsTop, rowHeight) = (side + 48 * u, 44 * u)  // from the panel's top
        let height = rowsTop + 3 * rowHeight + 54 * u
        let top = min(picture.midY + height / 2, view.height - 130 * u)
        let target = CGRect(x: x, y: top - side, width: side, height: side)

        // The swatch flies out of the pixel, growing, to its place; the rays follow it.
        let flown = CGFloat(smoothstep((t - Self.flight.at) / Self.flight.duration))
        let box = CGRect(
            x: cell.minX + (target.minX - cell.minX) * flown, y: cell.minY + (target.minY - cell.minY) * flown,
            width: cell.width + (target.width - cell.width) * flown,
            height: cell.height + (target.height - cell.height) * flown)
        swatch.set(\.isHidden, t < Self.flight.at)
        swatch.set(\.path, CGPath(rect: box, transform: nil))
        swatch.set(
            \.fillColor,
            NSColor(
                srgbRed: CGFloat(value.x) / 255, green: CGFloat(value.y) / 255, blue: CGFloat(value.z) / 255, alpha: 1))
        swatch.set(\.lineWidth, 2 * u)
        // From the pixel's side facing the swatch to the swatch's near side.
        let right = box.midX > cell.midX
        let (near, far) = (right ? cell.maxX : cell.minX, right ? box.minX : box.maxX)
        let rayPath = CGMutablePath()
        rayPath.move(to: CGPoint(x: near, y: cell.maxY))
        rayPath.addLine(to: CGPoint(x: far, y: box.maxY))
        rayPath.move(to: CGPoint(x: near, y: cell.minY))
        rayPath.addLine(to: CGPoint(x: far, y: box.minY))
        rays.set(\.path, rayPath)
        rays.set(\.lineWidth, 1.5 * u)
        rays.set(\.alpha, flown)

        // Where it is in the picture, under the swatch.
        place.label.set(\.text, "pixel (\(column), \(row))")
        place.label.set(\.fontSize, 18 * u)
        place.set(\.position, CGPoint(x: x, y: target.minY - 22 * u))
        place.set(\.alpha, CGFloat(smoothstep((t - Self.flight.at - Self.flight.duration) / 0.4)))
        place.sync(unit: u)

        // Its values, one after the other: the bar fills as the number counts up to it.
        let track = (x: x + 34 * u, width: 150 * u, height: 14 * u)
        for (c, row) in rows.enumerated() {
            let at = Self.valuesAt + Double(c) * Self.valueGap
            let shown = CGFloat(smoothstep((t - at) / 0.3))
            let filled = Float(smoothstep((t - at) / Self.fill))
            let y = top - rowsTop - (CGFloat(c) + 0.5) * rowHeight
            for part in [row.name, row.track, row.bar, row.value] as [SKNode] { part.set(\.alpha, shown) }
            row.name.label.set(\.fontSize, 24 * u)
            row.name.set(\.position, CGPoint(x: x, y: y))
            row.name.sync(unit: u)
            let r = track.height / 2
            row.track.set(
                \.path,
                CGPath(
                    roundedRect: CGRect(x: track.x, y: y - r, width: track.width, height: track.height),
                    cornerWidth: r, cornerHeight: r, transform: nil))
            let length = max(CGFloat(bars[c] * filled) * track.width, 0)
            row.bar.set(
                \.path,
                length < 1
                    ? nil
                    : CGPath(
                        roundedRect: CGRect(x: track.x, y: y - r, width: length, height: track.height),
                        cornerWidth: min(r, length / 2), cornerHeight: r, transform: nil))
            row.value.label.set(\.text, "\(Int((bars[c] * 255 * filled).rounded()))")
            row.value.label.set(\.fontSize, 24 * u)
            row.value.set(\.position, CGPoint(x: track.x + track.width + 14 * u, y: y))
            row.value.sync(unit: u)
        }

        // The three together: the pixel's value.
        total.label.set(\.text, "= (\(value.x), \(value.y), \(value.z))")
        total.label.set(\.fontSize, 26 * u)
        total.set(\.position, CGPoint(x: x, y: top - rowsTop - 3 * rowHeight - 30 * u))
        total.set(\.alpha, CGFloat(smoothstep((t - Self.totalAt) / 0.5)))
        total.sync(unit: u)
    }
}
