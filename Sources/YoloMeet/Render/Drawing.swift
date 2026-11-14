import AppKit
import Observation
import PenLink
import SpriteKit

/// Freehand ink on the stage, over everything else, like Meet's annotations. While it's on, the mouse and trackpad draw
/// instead of making gestures (hands still do): press and move to draw a stroke. The iPad pen app's Apple Pencil draws
/// at any time (`PenInput`): a harder press makes a wider line, and its nib shows on stage while it hovers over the pad.
/// With the eraser, both remove the strokes they touch instead, whole.
///
/// Points are in ink points: stage points at unit 1 (a 1280 × 720 stage), so ink keeps its place when the stage resizes.
@Observable
final class Drawing {
    /// Who draws: each has its own stroke in progress.
    enum Source { case mouse, pen }
    /// What the pen's pad is told (`changed`): the ink's settings changed, or strokes it drew (their ids) left the
    /// stage.
    enum Change { case settings, removed([Int]) }

    /// Ink colors (Ultralytics' brand skeleton colors, white and the annotation palette's red), as names and hex.
    static let colors = [("Yellow", "E1FF25"), ("Aqua", "00FFFF"), ("Pink", "FF64DA"), ("White", "FFFFFF"), ("Red", "FF3838")]
    /// Fading ink fades out over this many seconds, once it has stayed `fadeAfter`.
    static let fadeTime = 1.0

    /// The mouse and trackpad draw.
    var isOn = false { didSet { if !isOn { released(.mouse, time: CACurrentMediaTime()) } } }
    /// The next strokes' color, as hex.
    var color = UserDefaults.standard.string(forKey: "drawColor") ?? colors[0].1 {
        didSet {
            UserDefaults.standard.set(color, forKey: "drawColor")
            changed?(.settings)
        }
    }
    /// The next strokes' width, in ink points.
    var width = UserDefaults.standard.object(forKey: "drawWidth") as? Double ?? 6 {
        didSet {
            UserDefaults.standard.set(width, forKey: "drawWidth")
            changed?(.settings)
        }
    }
    /// Strokes fade out once they have stayed `fadeAfter` seconds, so nothing has to be cleared by hand. Otherwise
    /// they stay until they are undone, erased or cleared.
    var fades = UserDefaults.standard.bool(forKey: "drawFades") {
        didSet {
            UserDefaults.standard.set(fades, forKey: "drawFades")
            changed?(.settings)
        }
    }
    var fadeAfter = UserDefaults.standard.object(forKey: "drawFadeAfter") as? Double ?? 4 {
        didSet {
            UserDefaults.standard.set(fadeAfter, forKey: "drawFadeAfter")
            changed?(.settings)
        }
    }
    /// The mouse and the pen erase instead of drawing: a stroke they touch leaves the stage.
    var erases = false {
        didSet {
            guard erases != oldValue else { return }
            for source in [Source.mouse, .pen] { released(source, time: CACurrentMediaTime()) }
            changed?(.settings)
        }
    }
    /// The ink's settings as the pen's pad has them.
    var settings: InkSettings { InkSettings(color: color, width: width, fades: fades, fadeAfter: fadeAfter, erases: erases) }
    /// Strokes on stage, for the panel's Undo and Clear.
    private(set) var strokeCount = 0

    /// The ink, for the stage's 2D layer.
    @ObservationIgnored let node = SKNode()
    @ObservationIgnored var changed: ((Change) -> Void)?
    @ObservationIgnored private var strokes: [Stroke] = []
    /// The strokes being drawn: the mouse's while its button is down, the pen's while it touches its pad.
    @ObservationIgnored private var current: [Source: Stroke] = [:]
    /// The pen's nib while it hovers over its pad: a dot the size of the line, in a ring that closes in as the pen
    /// comes down.
    @ObservationIgnored private let nib = (node: SKNode(), dot: SKShapeNode(circleOfRadius: 1), ring: SKShapeNode())
    @ObservationIgnored private var hovering: (point: CGPoint, height: CGFloat)?
    /// Where each eraser was last, while it is pressed.
    @ObservationIgnored private var erasing: [Source: CGPoint] = [:]
    /// The erasers on stage: a ring as large as each reaches.
    @ObservationIgnored private var rings: [Source: SKShapeNode] = [:]

    /// The ids of the pen's strokes on stage.
    var penStrokes: [Int] { strokes.compactMap(\.id) }
    /// The pen's latest finished stroke on stage, by its id.
    var penFinished: Int? { strokes.last { $0.id != nil && $0.endedAt != nil }?.id }

    init() {
        node.zPosition = 900  // over the effects, under the debug overlays
        nib.dot.lineWidth = 0
        (nib.ring.fillColor, nib.ring.lineWidth) = (.clear, 1.5)
        (nib.node.zPosition, nib.node.isHidden) = (1, true)
        nib.node.addChild(nib.dot)
        nib.node.addChild(nib.ring)
        node.addChild(nib.node)
    }

    // Events, in ink points. `press` is the line's width there, as a factor of `width`.

    /// A new stroke starts, or the eraser comes down; `id` names the pen's strokes for its pad.
    func pressed(at point: CGPoint, press: CGFloat = 1, from source: Source = .mouse, id: Int? = nil) {
        released(source, time: CACurrentMediaTime())
        guard !erases else {
            erasing[source] = point
            return erase(from: point, to: point)
        }
        let stroke = Stroke(color: .hex(color), id: id)
        node.addChild(stroke.node)
        strokes.append(stroke)
        (current[source], strokeCount) = (stroke, strokes.count)
        stroke.add(point, width: CGFloat(width) * press)
    }

    /// The cursor or the pen moved: it draws or erases while pressed.
    func moved(to point: CGPoint, press: CGFloat = 1, from source: Source = .mouse) {
        if let last = erasing[source] {
            erasing[source] = point
            erase(from: last, to: point)
        } else {
            current[source]?.add(point, width: CGFloat(width) * press)
        }
    }

    func released(_ source: Source = .mouse, time: TimeInterval) {
        current[source]?.endedAt = time
        (current[source], erasing[source]) = (nil, nil)
    }

    /// The strokes the eraser touches on its way from `start` to `end` leave the stage.
    private func erase(from start: CGPoint, to end: CGPoint) {
        let touched = strokes.filter { $0.isTouched(from: start, to: end, radius: settings.eraserRadius) }
        guard !touched.isEmpty else { return }
        strokes.removeAll { stroke in touched.contains { $0 === stroke } }
        remove(touched)
    }

    /// The pen is over its pad at `point` without touching it (`height` from 0 at the pad to 1), or left it (nil).
    func hover(at point: CGPoint?, height: CGFloat = 0) {
        hovering = point.map { ($0, min(max(height, 0), 1)) }
    }

    // The panel's, the stage keys' and the pad's actions.

    func undo() {
        guard let stroke = strokes.popLast() else { return }
        remove([stroke])
    }

    func clear() {
        let all = strokes
        strokes = []
        remove(all)
    }

    /// Every frame: strokes are redrawn and fade, and the node follows the stage's size.
    func update(_ frame: StageFrame) {
        node.setScale(frame.stage.unit)
        for stroke in strokes {
            stroke.redraw(unit: frame.stage.unit)
            let age = fades ? stroke.endedAt.map { frame.time - $0 - fadeAfter } : nil
            stroke.node.alpha = 1 - min(max((age ?? 0) / Self.fadeTime, 0), 1)  // opaque again when fading is turned off
            stroke.isFading = stroke.node.alpha < 1
        }
        let faded = strokes.filter { $0.node.alpha == 0 }
        if !faded.isEmpty {
            strokes.removeAll { $0.node.alpha == 0 }
            remove(faded)
        }
        // An eraser shows as a ring where it is: the pen's while it hovers or erases, the mouse's while it erases.
        for source in [Source.mouse, .pen] {
            guard let place = erasing[source] ?? (source == .pen && erases ? hovering?.point : nil) else {
                rings[source]?.isHidden = true
                continue
            }
            let ring = rings[source] ?? {
                let ring = SKShapeNode()
                (ring.strokeColor, ring.fillColor, ring.lineWidth, ring.zPosition) = (.white, .white.withAlphaComponent(0.15), 1.5, 1)
                node.addChild(ring)
                rings[source] = ring
                return ring
            }()
            let radius = settings.eraserRadius
            ring.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius), transform: nil)
            (ring.position, ring.isHidden) = (place, false)
        }
        // The nib hides while the pen draws: the line's end shows where it is.
        nib.node.isHidden = hovering == nil || current[.pen] != nil || erases
        if let hovering, !nib.node.isHidden {
            let (ink, radius) = (NSColor.hex(color), CGFloat(width) / 2 + 3 + 16 * hovering.height)
            nib.node.position = hovering.point
            nib.dot.setScale(CGFloat(width) / 2)
            nib.dot.fillColor = ink
            nib.ring.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius), transform: nil)
            nib.ring.strokeColor = ink.withAlphaComponent(0.9 - 0.5 * hovering.height)
        }
    }

    /// Strokes already taken out of `strokes` leave the stage; the pad hears about its own.
    private func remove(_ removed: [Stroke]) {
        for stroke in removed {
            if let source = current.first(where: { $0.value === stroke })?.key { current[source] = nil }
            stroke.isFading = true
            stroke.node.run(.sequence([.fadeOut(withDuration: 0.2), .removeFromParent()]))
        }
        strokeCount = strokes.count
        let ids = removed.compactMap(\.id)
        if !ids.isEmpty { changed?(.removed(ids)) }
    }
}

/// One stroke: a smooth line through its points, as wide as each was pressed, with a soft halo in its color.
///
/// It is drawn as images, a segment of the line each: SpriteKit's own shapes can't vary in width, fill overlapping
/// pieces with holes, and cost time on every frame for as long as they are on stage. A segment's image is drawn once,
/// when its pieces are all there; only the last one, which grows with the line, is drawn again. The translucent layers
/// of a segment's image leave out the area the segments before it already cover, so they never add up where segments
/// meet or where the line crosses itself; only the segments it overlaps are looked at, so a frame costs about the same
/// at the end of a long line as at its start (more only where the line crosses itself many times).
private final class Stroke {
    typealias Sample = (at: CGPoint, width: CGFloat)

    /// Points closer than this to the last one (ink points) are skipped, and the line is drawn in pieces this long at
    /// most.
    static let spacing: CGFloat = 3
    /// Where the line turns more than this (radians) between two pieces, a disc rounds the corner; a gentler turn's gap
    /// is filled flat.
    static let corner: CGFloat = 0.35
    /// The halo, then the line itself: how many times the line's width, and how opaque.
    static let look: [(scale: CGFloat, alpha: CGFloat)] = [(4, 0.1), (2.2, 0.2), (1, 1)]
    /// Pieces in a segment's image.
    static let segment = 32
    /// The most pixels for a stroke's area: a stroke across the whole stage is drawn a little softer, not larger.
    static let pixels: CGFloat = 2_500_000

    /// The segments' images, in order. While it fades, they are drawn as one picture first and that fades
    /// (`isFading`): where two images overlap (a piece of line both have), they would otherwise each show through.
    let node = SKEffectNode()
    /// Whether the stroke's alpha is below 1: its images fade together.
    var isFading = false {
        didSet { node.shouldEnableEffects = isFading }
    }
    /// The pad's name for the stroke, when the pen drew it.
    let id: Int?
    /// When the stroke was finished, for fading ink.
    var endedAt: TimeInterval?
    private let color: CGColor
    private var points: [Sample] = []
    /// The line's middle up to the midpoint between the last two points: it no longer changes.
    private var line: [Sample] = []
    /// The drawn segments, in order: for each layer of the `look`, the area each covers as one outline, and around it.
    private var drawn: [(areas: [CGPath], bounds: [CGRect])] = []
    /// For each layer, the pieces of the segment being drawn, which overlap and all wind the same way.
    private var growing = look.map { _ in CGMutablePath() }
    /// How much of `line` is in the areas, how many pieces the growing segment has, and the direction of the last piece.
    private var covered = (count: 1, pieces: 0, heading: CGFloat?.none)
    /// Around the points, and the widest of them.
    private var (box, widest) = (CGRect.null, CGFloat(0))
    private var changed = false
    /// The images' pixels per ink point.
    private var scale: CGFloat = 0
    /// The growing segment's image, over the drawn ones.
    private var growingImage: SKSpriteNode?

    init(color: NSColor, id: Int?) {
        (self.color, self.id) = (color.cgColor, id)
        (node.shouldRasterize, node.shouldEnableEffects) = (true, false)
    }

    /// Whether an eraser that reaches `radius` around itself touches the line on its way from `start` to `end`.
    func isTouched(from start: CGPoint, to end: CGPoint, radius: CGFloat) -> Bool {
        let reach = radius + widest / 2
        guard min(start.x, end.x) - reach <= box.maxX, max(start.x, end.x) + reach >= box.minX,
            min(start.y, end.y) - reach <= box.maxY, max(start.y, end.y) + reach >= box.minY
        else { return false }
        return zip(points, points.dropFirst(points.count > 1 ? 1 : 0)).contains { a, b in
            Self.distance(from: (start, end), to: (a.at, b.at)) <= radius + max(a.width, b.width) / 2
        }
    }

    /// The distance between two segments: none when they cross.
    private static func distance(from first: (CGPoint, CGPoint), to second: (CGPoint, CGPoint)) -> CGFloat {
        func side(_ point: CGPoint, of line: (CGPoint, CGPoint)) -> CGFloat {
            (line.1.x - line.0.x) * (point.y - line.0.y) - (line.1.y - line.0.y) * (point.x - line.0.x)
        }
        func distance(from point: CGPoint, to line: (CGPoint, CGPoint)) -> CGFloat {
            let (dx, dy) = (line.1.x - line.0.x, line.1.y - line.0.y)
            let along = dx * dx + dy * dy > 0 ? ((point.x - line.0.x) * dx + (point.y - line.0.y) * dy) / (dx * dx + dy * dy) : 0
            let nearest = min(max(along, 0), 1)
            return hypot(point.x - line.0.x - nearest * dx, point.y - line.0.y - nearest * dy)
        }
        if side(first.0, of: second) * side(first.1, of: second) < 0, side(second.0, of: first) * side(second.1, of: first) < 0 {
            return 0
        }
        return min(
            distance(from: first.0, to: second), distance(from: first.1, to: second), distance(from: second.0, to: first),
            distance(from: second.1, to: first))
    }

    func add(_ point: CGPoint, width: CGFloat) {
        guard let last = points.last else {
            (points, line) = ([(point, width)], [(point, width)])
            return grown(by: points[0])
        }
        guard hypot(point.x - last.at.x, point.y - last.at.y) >= Self.spacing else {
            // A dot is as wide as its hardest press: the pen lands lightly.
            if points.count == 1, width > last.width {
                (points[0].width, line[0].width) = (width, width)
                grown(by: points[0])
            }
            return
        }
        points.append((point, last.width + (width - last.width) * 0.5))  // the width eases, so it never jumps
        grown(by: points[points.count - 1])
        guard points.count > 2 else { return }
        // The curve around the point before, between the midpoints on either side of it: corners between points are
        // rounded.
        let (before, control, after) = (points[points.count - 3], points[points.count - 2], points[points.count - 1])
        func middle(_ a: Sample, _ b: Sample) -> Sample { (CGPoint(x: (a.at.x + b.at.x) / 2, y: (a.at.y + b.at.y) / 2), (a.width + b.width) / 2) }
        let (start, end) = (points.count == 3 ? before : middle(before, control), middle(control, after))
        let length = hypot(control.at.x - start.at.x, control.at.y - start.at.y) + hypot(end.at.x - control.at.x, end.at.y - control.at.y)
        let pieces = max(Int((length / Self.spacing).rounded(.up)), 1)
        for piece in 1...pieces {
            let t = CGFloat(piece) / CGFloat(pieces)
            let (a, b, c) = ((1 - t) * (1 - t), 2 * t * (1 - t), t * t)
            line.append((
                CGPoint(x: a * start.at.x + b * control.at.x + c * end.at.x, y: a * start.at.y + b * control.at.y + c * end.at.y),
                a * start.width + b * control.width + c * end.width))
        }
    }

    private func grown(by sample: Sample) {
        (box, widest, changed) = (box.union(CGRect(origin: sample.at, size: .zero)), max(widest, sample.width), true)
    }

    /// Draws the growing segment again when the line grew, or every segment when the stage's `unit` (pixels per ink
    /// point) changed enough to show.
    func redraw(unit: CGFloat) {
        guard let end = points.last, unit > 0 else { return }
        let margin = widest * Self.look[0].scale / 2 + 2
        let whole = box.insetBy(dx: -margin, dy: -margin)
        let wanted = min(unit, (Self.pixels / (whole.width * whole.height)).squareRoot())
        let rescaled = abs(wanted - scale) > 0.2 * scale
        guard changed || rescaled else { return }
        (changed, scale) = (false, rescaled ? wanted : scale)
        if rescaled, !drawn.isEmpty {
            // At the new scale, every segment is drawn again, as it was.
            node.removeAllChildren()
            growingImage = nil
            for index in drawn.indices { draw(drawn[index].areas, leavingOut: drawn[..<index]) }
        }
        // The line's new pieces join the growing segment; a segment that is whole is drawn one last time, and its area
        // joins the drawn area. The last piece, to the last point, is drawn apart: it changes with the next point.
        while covered.count < line.count {
            let before = covered.heading
            covered.heading = Self.cover(from: line[covered.count - 1], to: line[covered.count], after: before, in: growing)
            (covered.count, covered.pieces) = (covered.count + 1, covered.pieces + 1)
            if covered.pieces == Self.segment {
                growingImage?.removeFromParent()
                growingImage = nil
                draw(growing, leavingOut: drawn[...])
                let areas = growing.map { $0.normalized(using: .winding) }
                drawn.append((areas, areas.map(\.boundingBoxOfPath)))
                (growing, covered.pieces) = (Self.look.map { _ in CGMutablePath() }, 0)
                // The next segment starts with this one's last piece again: where two images meet edge to edge, their
                // smoothed edges would leave a faint seam across the line.
                _ = Self.cover(from: line[covered.count - 2], to: line[covered.count - 1], after: before, in: growing)
            }
        }
        let tail = Self.look.map { _ in CGMutablePath() }
        _ = Self.cover(from: line[line.count - 1], to: end, after: covered.heading, in: tail)
        Self.disc(end, in: tail)
        let areas = zip(growing, tail).map { pieces, tail in
            let area = CGMutablePath()
            area.addPath(pieces)
            area.addPath(tail)
            return area
        }
        growingImage?.removeFromParent()
        growingImage = draw(areas, leavingOut: drawn[...])
    }

    /// Adds an image of `areas` (one per layer of the `look`) to the node, over the others. The translucent layers
    /// leave out the area of the `drawn` segments it overlaps: only those near it cost anything.
    @discardableResult
    private func draw(_ areas: [CGPath], leavingOut drawn: ArraySlice<(areas: [CGPath], bounds: [CGRect])>) -> SKSpriteNode? {
        // Around the widest layer and its edge's smoothing, on whole pixels of the stroke's scale: the images line up.
        let bounds = areas[0].boundingBoxOfPath.insetBy(dx: -2, dy: -2)
        guard !bounds.isEmpty else { return nil }
        let (left, bottom) = ((bounds.minX * scale).rounded(.down), (bounds.minY * scale).rounded(.down))
        let (width, height) = (Int((bounds.maxX * scale).rounded(.up) - left), Int((bounds.maxY * scale).rounded(.up) - bottom))
        let frame = CGRect(x: left / scale, y: bottom / scale, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -frame.minX, y: -frame.minY)
        for (index, look) in Self.look.enumerated() {
            context.saveGState()
            if look.alpha < 1 {
                // Everywhere but each drawn segment it overlaps: around it, inside the frame (clips add up).
                for segment in drawn where segment.bounds[index].intersects(frame) {
                    context.addRect(frame)
                    context.addPath(segment.areas[index])
                    context.clip(using: .evenOdd)
                }
            }
            context.setFillColor(color.copy(alpha: look.alpha) ?? color)
            context.addPath(areas[index])
            context.fillPath(using: .winding)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { return nil }
        let sprite = SKSpriteNode(texture: SKTexture(cgImage: image), size: frame.size)
        sprite.position = CGPoint(x: frame.midX, y: frame.midY)
        node.addChild(sprite)
        return sprite
    }

    /// Adds the piece of line from `point` to `next` to each layer's area, closing the gap on the outside of the turn
    /// from the `heading` of the piece before, or with a disc on `point` where the line starts. Returns the piece's
    /// heading.
    private static func cover(from point: Sample, to next: Sample, after heading: CGFloat?, in areas: [CGMutablePath]) -> CGFloat? {
        let (dx, dy) = (next.at.x - point.at.x, next.at.y - point.at.y)
        let length = hypot(dx, dy)
        guard length > 0 else { return heading }
        let angle = atan2(dy, dx)
        let turn = heading.map { atan2(sin(angle - $0), cos(angle - $0)) }
        if turn.map({ abs($0) > corner }) ?? true { disc(point, in: areas) }
        for (area, look) in zip(areas, look) {
            // The piece's sides, to the left of its direction then back on the right: it winds as the discs do.
            let (nx, ny) = (-dy / length * look.scale / 2, dx / length * look.scale / 2)
            if let heading, let turn, abs(turn) <= corner {
                // The gap is on the right of a left turn, between the two pieces' corners there.
                let side = point.width * look.scale / 2 * (turn > 0 ? -1 : 1)
                let before = CGPoint(x: point.at.x - sin(heading) * side, y: point.at.y + cos(heading) * side)
                let after = CGPoint(x: point.at.x - sin(angle) * side, y: point.at.y + cos(angle) * side)
                area.addLines(between: turn > 0 ? [point.at, before, after] : [point.at, after, before])
                area.closeSubpath()
            }
            area.addLines(between: [
                CGPoint(x: point.at.x + nx * point.width, y: point.at.y + ny * point.width),
                CGPoint(x: point.at.x - nx * point.width, y: point.at.y - ny * point.width),
                CGPoint(x: next.at.x - nx * next.width, y: next.at.y - ny * next.width),
                CGPoint(x: next.at.x + nx * next.width, y: next.at.y + ny * next.width),
            ])
            area.closeSubpath()
        }
        return angle
    }

    private static func disc(_ point: Sample, in areas: [CGMutablePath]) {
        for (area, look) in zip(areas, look) {
            let radius = point.width * look.scale / 2
            area.addArc(center: point.at, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            area.closeSubpath()
        }
    }
}
