import CoreGraphics
import Foundation

/// A grayscale picture drawn in code (the story's examples of client pictures: drawn after them, no files), as
/// brightness.
struct GrayPicture {
    let width, height: Int
    /// 0...1, row by row from the top.
    let values: [Float]

    /// `draw`'s picture, `width` × `height`: it draws on a canvas `canvas` in size with its origin at the top left
    /// (y down), black at first.
    init(width: Int, height: Int, canvas: CGSize, draw: (CGContext) -> Void) {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / canvas.width, y: -CGFloat(height) / canvas.height)
        draw(context)
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let row = context.bytesPerRow
        (self.width, self.height) = (width, height)
        values = (0..<height).flatMap { y in (0..<width).map { Float(bytes[y * row + $0]) / 255 } }
    }

    /// Its brightness at a point in pixels (between pixels: bilinear), its edges repeated beyond them.
    func at(_ x: Float, _ y: Float) -> Float {
        let (fx, fy) = (min(max(x - 0.5, 0), Float(width - 1)), min(max(y - 0.5, 0), Float(height - 1)))
        let (x0, y0) = (Int(fx), Int(fy))
        let (x1, y1) = (min(x0 + 1, width - 1), min(y0 + 1, height - 1))
        let (tx, ty) = (fx - Float(x0), fy - Float(y0))
        let top = values[y0 * width + x0] * (1 - tx) + values[y0 * width + x1] * tx
        let bottom = values[y1 * width + x0] * (1 - tx) + values[y1 * width + x1] * tx
        return top * (1 - ty) + bottom * ty
    }
}

/// Random numbers that come out the same every run (SplitMix64), so a drawing is always the same picture.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension CGContext {
    fileprivate func fill(_ gray: CGFloat, alpha: CGFloat = 1, _ points: [(CGFloat, CGFloat)]) {
        setFillColor(gray: gray, alpha: alpha)
        addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
        fillPath()
    }

    fileprivate func stroke(_ gray: CGFloat, alpha: CGFloat = 1, width: CGFloat, _ path: (CGContext) -> Void) {
        setStrokeColor(gray: gray, alpha: alpha)
        setLineWidth(width)
        path(self)
        strokePath()
    }

    /// A soft spot of light: brightest in the middle, gone at `radius`.
    fileprivate func glint(_ x: CGFloat, _ y: CGFloat, radius: CGFloat, gray: CGFloat = 1) {
        for k in 1...6 {
            let r = radius * CGFloat(7 - k) / 6
            setFillColor(gray: gray, alpha: 0.22)
            fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
    }
}

extension GrayPicture {
    /// The size of the golf club picture this one is drawn after.
    static let golfClubSize = (width: 1280, height: 1024)

    /// A golf club head on grass at night, lit from the front, as a grayscale camera sees it: the iron's bright face
    /// between its darker toe and heel, its shaft leaving to the top right, tall grass and dark trees behind, mown
    /// grass in front with a dark line on it.
    static func golfClub(width: Int, height: Int) -> GrayPicture {
        let canvas = CGSize(width: golfClubSize.width, height: golfClubSize.height)
        return GrayPicture(width: width, height: height, canvas: canvas) { c in
            var random = SeededRandom(7)
            let rand = { (range: ClosedRange<CGFloat>) in CGFloat.random(in: range, using: &random) }
            // The trees: almost black, with faint leaves, more of them lower down.
            c.fill(0.02, [(0, 0), (1280, 0), (1280, 1024), (0, 1024)])
            for _ in 0..<700 {
                let (x, y, r) = (rand(0...1280), 60 + 205 * rand(0...1).squareRoot(), rand(1.5...5))
                c.setFillColor(gray: rand(0.03...0.09), alpha: 0.9)
                c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            }
            // The ground, far to near: a strip of fairway, the dark foot of the tall grass, mown grass, the rough.
            c.fill(0.15, [(0, 260), (1280, 296), (1280, 345), (0, 302)])
            c.fill(0.06, [(0, 302), (1280, 345), (1280, 450), (0, 400)])
            c.fill(0.26, [(0, 400), (1280, 450), (1280, 566), (1080, 532), (520, 478), (0, 492)])
            c.fill(0.15, [(0, 492), (520, 478), (1080, 532), (1280, 566), (1280, 1024), (0, 1024)])
            for _ in 0..<2600 {  // its blades, lighter and darker
                let (x, y) = (rand(0...1280), rand(480...1024))
                guard y > 492 + (x > 520 ? (x - 520) * 0.1 : 0) else { continue }
                let (lean, length) = (rand(-5...5), rand(8...16))
                c.stroke(rand(0.1...0.23), width: 3) {
                    $0.move(to: CGPoint(x: x, y: y))
                    $0.addLine(to: CGPoint(x: x + lean, y: y - length))
                }
            }
            // Tall grass in tufts along the mown grass's far edge, and a bush on the left.
            for tuft in 0..<30 {
                let center = CGFloat(tuft) * 45 + rand(-12...12)
                let foot = 402 + 50 * center / 1280
                for _ in 0..<46 {
                    let (x, lean, tall) = (center + rand(-34...34), rand(-30...30), rand(60...112))
                    c.fill(
                        rand(0.2...0.52),
                        [(x - 3.5, foot + rand(-4...10)), (x + 3.5, foot + 8), (x + lean, foot - tall)])
                }
            }
            for _ in 0..<150 {
                let (x, y, r) = (rand(-14...88), rand(404...498), rand(7...15))
                c.setFillColor(gray: rand(0.14...0.46), alpha: 1)
                c.fillEllipse(in: CGRect(x: x - r, y: y - r * 0.5, width: 2 * r, height: r))
            }
            // The dark line on the grass, from under the club toward the camera.
            c.fill(0.03, [(738, 625), (757, 625), (697, 1024), (650, 1024)])

            // The shaft, from the hosel up to the top right: dark edges, light along its middle.
            c.fill(0.26, [(1036, 505), (1136, 300), (1212, 100), (1247, 0), (1320, 0), (1213, 300), (1108, 522)])
            c.fill(0.1, [(1036, 505), (1136, 300), (1247, 0), (1258, 0), (1148, 300), (1050, 508)])
            c.fill(0.5, [(1058, 505), (1154, 300), (1262, 0), (1300, 0), (1192, 300), (1092, 512)])
            c.fill(0.76, [(1066, 503), (1162, 300), (1268, 0), (1284, 0), (1178, 300), (1084, 508)])
            c.fill(0.12, [(1138, 297), (1212, 304), (1217, 288), (1144, 282)])  // where the hosel ends
            // The head: the toe (rounded, left), the face, the heel (right) into the hosel.
            c.setFillColor(gray: 0.43, alpha: 1)
            c.move(to: CGPoint(x: 594, y: 264))
            c.addQuadCurve(to: CGPoint(x: 504, y: 410), control: CGPoint(x: 508, y: 282))
            c.addQuadCurve(to: CGPoint(x: 566, y: 594), control: CGPoint(x: 502, y: 530))
            c.addLine(to: CGPoint(x: 636, y: 615))
            c.fillPath()
            c.stroke(0.8, alpha: 0.6, width: 8) {  // light along the toe's edge
                $0.move(to: CGPoint(x: 590, y: 270))
                $0.addQuadCurve(to: CGPoint(x: 509, y: 410), control: CGPoint(x: 514, y: 288))
            }
            c.fill(
                0.45,
                [(936, 420), (990, 462), (1022, 482), (1076, 470), (1102, 502), (1072, 556), (1020, 590), (964, 592)])
            // The face: the brightest thing in the picture, a little darker toward the sole, with its grooves.
            c.saveGState()
            c.addLines(
                between: [(594, 264), (700, 302), (938, 421), (966, 591), (800, 625), (700, 629), (634, 614)].map {
                    CGPoint(x: $0.0, y: $0.1)
                })
            c.clip()
            let shades = [CGFloat(0.92), 1, 0.8, 1]
            let gradient = CGGradient(
                colorSpace: CGColorSpaceCreateDeviceGray(), colorComponents: shades, locations: [0, 1], count: 2)!
            c.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 264), end: CGPoint(x: 0, y: 629), options: [])
            for y in [CGFloat(548), 566, 584] {
                c.stroke(0.7, alpha: 0.4, width: 3) {
                    $0.move(to: CGPoint(x: 620, y: y + 18))
                    $0.addLine(to: CGPoint(x: 980, y: y))
                }
            }
            c.restoreGState()
            // Glints where the light catches its edges.
            c.glint(554, 578, radius: 12)
            c.glint(1000, 488, radius: 24)
            c.glint(1042, 572, radius: 22)
        }
    }

    /// One layer of a wafer under an electron microscope: bright vertical bars in pairs, each pair half a period
    /// down from its neighbours (as bricks are laid), with thin lines around and between them: rings around a
    /// pair's middle, straight or wavy links to the next pairs, and curves around the gaps between a pair's bars.
    /// `size` square; the pattern goes on past its edges.
    static func wafer(size: Int = 390) -> GrayPicture {
        GrayPicture(width: size, height: size, canvas: CGSize(width: 390, height: 390)) { c in
            var random = SeededRandom(11)
            // The dark between the lines, a little uneven.
            c.setFillColor(gray: 0.24, alpha: 1)
            c.fill(CGRect(x: 0, y: 0, width: 390, height: 390))
            for _ in 0..<500 {
                let (x, y) = (CGFloat.random(in: 0...390, using: &random), CGFloat.random(in: 0...390, using: &random))
                c.setFillColor(gray: .random(in: 0.16...0.33, using: &random), alpha: 0.5)
                c.fillEllipse(in: CGRect(x: x - 9, y: y - 5, width: 18, height: 10))
            }
            // Pairs of bars: `pitch` from pair to pair, a pair's bars `apart`, each bar `long` in every `period`.
            let (pitch, apart, period, long) = (CGFloat(55.7), CGFloat(27), CGFloat(94), CGFloat(76))
            let (thin, faint) = (CGFloat(2), CGFloat(0.66))
            c.setLineCap(.round)
            for pair in -1...8 {
                let x = 12 + CGFloat(pair) * pitch
                let (left, right) = (x - apart / 2, x + apart / 2)
                let low = pair % 2 == 0  // every other pair half a period down
                for k in -1...5 {
                    let top = (low ? 74 : 23) + CGFloat(k) * period
                    let (middle, gap) = (top + long / 2, top + long + (period - long) / 2)
                    // Around the gap under the bars: out and back in (low pairs), or in toward each other.
                    for (bar, side) in [(left, CGFloat(-1)), (right, 1)] {
                        c.stroke(faint, width: thin) {
                            $0.move(to: CGPoint(x: bar, y: gap - 12))
                            $0.addQuadCurve(
                                to: CGPoint(x: bar, y: gap + 12),
                                control: CGPoint(x: bar + side * (low ? 15 : -9), y: gap))
                        }
                    }
                    if low && k % 2 == 0 {
                        // Two straight lines across, to the pairs on either side.
                        for y in [middle - 18, middle + 18] {
                            c.stroke(faint, width: thin) {
                                $0.move(to: CGPoint(x: right - pitch, y: y))
                                $0.addLine(to: CGPoint(x: left + pitch, y: y))
                            }
                        }
                    } else {
                        // Two rings around the pair's middle.
                        for (rx, ry) in [(CGFloat(25), CGFloat(11)), (19, 6.5)] {
                            c.stroke(faint, width: thin) {
                                $0.addEllipse(in: CGRect(x: x - rx, y: middle - ry, width: 2 * rx, height: 2 * ry))
                            }
                        }
                    }
                    if low && k % 2 != 0 {
                        // Three wavy lines to the pair on either side, above and below the rings.
                        for (from, to) in [(right, left + pitch), (left, right - pitch)] {
                            for y in [middle - 21, middle + 21] {
                                for line in -1...1 {
                                    let at = y + CGFloat(line) * 7
                                    c.stroke(faint, alpha: 0.85, width: thin) {
                                        $0.move(to: CGPoint(x: from, y: at - 2))
                                        $0.addQuadCurve(
                                            to: CGPoint(x: to, y: at + 3),
                                            control: CGPoint(x: (from + to) / 2, y: at + CGFloat(line) * 3 + 4))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // The bars over the lines: a soft edge, then their bright middle.
            for (gray, width) in [(CGFloat(0.6), CGFloat(7.5)), (0.95, 4.4)] {
                for pair in -1...8 {
                    let x = 12 + CGFloat(pair) * pitch
                    for k in -1...5 {
                        let top = (pair % 2 == 0 ? 74 : 23) + CGFloat(k) * period
                        for (bar, bow) in [(x - apart / 2, CGFloat(-0.8)), (x + apart / 2, 0.8)] {
                            // Not quite straight: bowed out a little in the middle.
                            c.stroke(gray, width: width) {
                                $0.move(to: CGPoint(x: bar, y: top + 4))
                                $0.addQuadCurve(
                                    to: CGPoint(x: bar, y: top + long - 4),
                                    control: CGPoint(x: bar + bow * 2, y: top + long / 2))
                            }
                        }
                    }
                }
            }
        }
    }
}
