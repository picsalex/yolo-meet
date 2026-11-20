import PenLink
import SwiftUI
import UIKit

/// The pad, as a SwiftUI view: it stands for the stage, so it is laid out 16:9.
struct PadView: UIViewRepresentable {
    let model: PadModel

    func makeUIView(context: Context) -> PadCanvas { PadCanvas(model: model) }
    func updateUIView(_ view: PadCanvas, context: Context) {}
}

/// Takes the Apple Pencil: touching draws or erases, hovering shows the nib on stage, a double tap on the pencil
/// switches between the pencil and the eraser, and a squeeze (Apple Pencil Pro) picks the next color. It shows the stage's picture, and over it the pad's strokes the
/// picture doesn't have yet (`InkView`).
///
/// Only the pencil draws: a resting hand or a finger leaves no ink. On the whiteboard, fingers pinch to zoom it and drag
/// to slide it; a tap on a sticker selects it (its toolbar shows over it, `PadScreen`), elsewhere unselects it, one
/// finger dragging a sticker that isn't locked moves it, and one dragging a handle of the selected one resizes it.
final class PadCanvas: UIView, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
    private let model: PadModel
    private let picture = UIImageView()
    private let ink: InkView
    /// The touch that draws: others that land meanwhile are ignored.
    private var drawing: UITouch?
    /// Taps on the pencil's barrel, for an Apple Pencil Pro.
    private lazy var feedback = UICanvasFeedbackGenerator(view: self)
    /// Fingers on the whiteboard: pinching zooms it, dragging slides it. The pencil never moves it.
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
    private lazy var drag = UIPanGestureRecognizer(target: self, action: #selector(dragged))
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
    /// The sticker one finger is dragging, if the drag started on one that isn't locked; else the drag slides the
    /// whiteboard.
    private var dragging: Int?
    /// The handle one finger is dragging, on the selected sticker: the sticker, its corner that stays put (ink points),
    /// which way the dragged corner lies from it (±1 each), and how far that corner was from the finger.
    private var resizing: (sticker: PlacedSticker, anchor: CGPoint, sx: CGFloat, sy: CGFloat, grab: CGVector)?
    /// How far from a handle's middle a finger still takes it, in view points.
    private static let handleReach: CGFloat = 30

    init(model: PadModel) {
        self.model = model
        ink = InkView(model: model)
        super.init(frame: .zero)
        backgroundColor = .black
        for view in [picture, ink] {
            (view.frame, view.autoresizingMask, view.isUserInteractionEnabled) = (
                bounds, [.flexibleWidth, .flexibleHeight], false
            )
            addSubview(view)
        }
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
        for fingers in [pinch, drag, tap] as [UIGestureRecognizer] {
            fingers.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
            fingers.delegate = self
            addGestureRecognizer(fingers)
        }
        addInteraction(UIPencilInteraction(delegate: self))
        model.redraw = { [weak ink] in ink?.changed(around: $0) }
        model.show = { [weak picture] in picture?.image = $0 }
        picture.image = model.picture
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// A place on the pad in ink points: the stage's, with the origin at the bottom left.
    private func inkPoint(_ point: CGPoint) -> CGPoint {
        inkUnit > 0 ? CGPoint(x: point.x / inkUnit, y: (bounds.height - point.y) / inkUnit) : .zero
    }

    /// A finger presses as an average press: the iPad doesn't feel how hard.
    private func force(_ touch: UITouch) -> Double { touch.type == .pencil ? touch.force : 1 }

    // Touches.

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard drawing == nil, let touch = touches.first(where: { $0.type == .pencil }) else { return }
        drawing = touch
        // A hand resting on the glass while the pencil draws must not move the board or a sticker: fingers already
        // pinching or dragging stop, and none start until the pencil lifts (`gestureRecognizerShouldBegin`).
        for fingers in [pinch, drag, tap] as [UIGestureRecognizer] where fingers.state != .possible {
            fingers.isEnabled = false  // cancels it
            fingers.isEnabled = true
        }
        model.begin(at: inkPoint(touch.location(in: self)), force: force(touch))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let drawing, touches.contains(drawing) else { return }
        // Every sample since the last event: the pencil is read more often than the screen is drawn.
        for touch in event?.coalescedTouches(for: drawing) ?? [drawing] {
            model.move(to: inkPoint(touch.location(in: self)), force: force(touch))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { ended(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { ended(touches) }

    private func ended(_ touches: Set<UITouch>) {
        guard let drawing, touches.contains(drawing) else { return }
        self.drawing = nil
        model.end()
    }

    // Fingers on the whiteboard.

    /// Fingers act on the whiteboard only, and not while the pencil draws (also the delegate's question: the same
    /// method).
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        [pinch, drag, tap].contains { $0 === recognizer }
            ? model.shows == .whiteboard && drawing == nil : super.gestureRecognizerShouldBegin(recognizer)
    }

    /// Selects the sticker under the finger, or none.
    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        model.select(model.sticker(at: inkPoint(recognizer.location(in: self)))?.id)
    }

    func gestureRecognizer(
        _ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    )
        -> Bool
    { [recognizer, other].allSatisfy { $0 === pinch || $0 === drag } }

    /// Zooms around the fingers' middle, as far as they spread since the last change.
    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed, recognizer.numberOfTouches >= 2 else {
            return
        }
        model.moveBoard(zoom: recognizer.scale, around: inkPoint(recognizer.location(in: self)))
        recognizer.scale = 1
    }

    /// Moves the sticker the drag started on as far as the finger moved since the last change, or else slides the
    /// whiteboard: up on the pad is up on the stage.
    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began {
            // Where the finger came down: the drag begins once it has moved a little.
            let moved = recognizer.translation(in: self)
            let start = recognizer.location(in: self)
            let down = inkPoint(CGPoint(x: start.x - moved.x, y: start.y - moved.y))
            resizing = recognizer.numberOfTouches == 1 ? handle(at: down) : nil
            let sticker = recognizer.numberOfTouches == 1 && resizing == nil ? model.sticker(at: down) : nil
            dragging = sticker?.isLocked == false ? sticker?.id : nil
            if let dragging { model.select(dragging) }
        }
        guard recognizer.state == .began || recognizer.state == .changed, inkUnit > 0 else {
            if let id = dragging ?? resizing?.sticker.id { model.endDrag(id) }
            (dragging, resizing) = (nil, nil)
            return
        }
        if let resizing {
            return resize(resizing, to: inkPoint(recognizer.location(in: self)))
        }
        let moved = recognizer.translation(in: self)
        let offset = CGVector(dx: moved.x / inkUnit, dy: -moved.y / inkUnit)
        if let dragging { model.moveSticker(dragging, by: offset) } else { model.moveBoard(by: offset) }
        recognizer.setTranslation(.zero, in: self)
    }

    /// The handle of the selected sticker at `point` (ink points), if it isn't locked: the nearest corner in reach.
    private func handle(
        at point: CGPoint
    ) -> (sticker: PlacedSticker, anchor: CGPoint, sx: CGFloat, sy: CGFloat, grab: CGVector)? {
        guard let sticker = model.placed.first(where: { $0.id == model.selected }), !sticker.isLocked else {
            return nil
        }
        let frame = CGRect(x: sticker.x, y: sticker.y, width: sticker.width, height: sticker.height)
        let corners = [(-1, -1), (1, -1), (-1, 1), (1, 1)].map { (sx: CGFloat($0), sy: CGFloat($1)) }
        func corner(_ sx: CGFloat, _ sy: CGFloat) -> CGPoint {
            CGPoint(x: sx < 0 ? frame.minX : frame.maxX, y: sy < 0 ? frame.minY : frame.maxY)
        }
        func distance(_ sx: CGFloat, _ sy: CGFloat) -> CGFloat {
            let at = corner(sx, sy)
            return hypot(at.x - point.x, at.y - point.y)
        }
        guard let nearest = corners.min(by: { distance($0.sx, $0.sy) < distance($1.sx, $1.sy) }),
            distance(nearest.sx, nearest.sy) * inkUnit <= Self.handleReach
        else { return nil }
        let at = corner(nearest.sx, nearest.sy)
        return (
            sticker, corner(-nearest.sx, -nearest.sy), nearest.sx, nearest.sy,
            CGVector(dx: at.x - point.x, dy: at.y - point.y)
        )
    }

    /// Resizes the sticker of the handle being dragged so that its corner follows the finger at `point` (ink points),
    /// the opposite corner staying put and its shape kept.
    private func resize(
        _ handle: (sticker: PlacedSticker, anchor: CGPoint, sx: CGFloat, sy: CGFloat, grab: CGVector),
        to point: CGPoint
    ) {
        let (sticker, anchor) = (handle.sticker, handle.anchor)
        guard sticker.width > 0, sticker.height > 0 else { return }
        let aspect = sticker.height / sticker.width
        let corner = CGPoint(x: point.x + handle.grab.dx, y: point.y + handle.grab.dy)
        // As wide as the corner reaches across or up, whichever is further, within the widths yolo-meet allows.
        let reach = max((corner.x - anchor.x) * handle.sx, (corner.y - anchor.y) * handle.sy / aspect)
        let width = min(max(reach, PenLink.stickerWidths.lowerBound), PenLink.stickerWidths.upperBound)
        let height = width * aspect
        model.resizeSticker(
            sticker.id,
            to: CGRect(
                x: handle.sx > 0 ? anchor.x : anchor.x - width, y: handle.sy > 0 ? anchor.y : anchor.y - height,
                width: width, height: height))
    }

    // The pencil over the glass, and its barrel.

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed: model.hover(at: inkPoint(recognizer.location(in: self)), height: recognizer.zOffset)
        default: model.hover(at: nil)
        }
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        model.switchTool()
        feedback.pathCompleted(at: tap.hoverPose?.location ?? CGPoint(x: bounds.midX, y: bounds.midY))
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        model.pickNext()
        feedback.alignmentOccurred(at: squeeze.hoverPose?.location ?? CGPoint(x: bounds.midX, y: bounds.midY))
    }
}

/// The pad's own ink, over the stage's picture: its strokes that the picture doesn't show whole yet, so the line
/// follows the pen without waiting for the picture, and the eraser as a ring where it is.
private final class InkView: UIView {
    private let model: PadModel

    init(model: PadModel) {
        self.model = model
        super.init(frame: .zero)
        (backgroundColor, isOpaque, contentMode) = (.clear, false, .redraw)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The ink changed: all of it (nil), or around a rectangle in ink points.
    func changed(around rect: CGRect?) {
        guard let rect else { return setNeedsDisplay() }
        let place = CGRect(
            x: rect.minX * inkUnit, y: bounds.height - rect.maxY * inkUnit, width: rect.width * inkUnit,
            height: rect.height * inkUnit)
        setNeedsDisplay(place.insetBy(dx: -40, dy: -40))  // as far as the widest line and its round ends reach
    }

    private func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * inkUnit, y: bounds.height - point.y * inkUnit)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setLineCap(.round)
        for stroke in model.strokes where !stroke.isPictured {
            context.setStrokeColor(
                UIColor(hex: PenLink.ink(stroke.color, onWhiteboard: model.shows == .whiteboard)).cgColor)
            guard stroke.points.count > 1 else {
                // A dot: a line with no length and round ends.
                guard let dot = stroke.points.first else { continue }
                context.setLineWidth(dot.width * inkUnit)
                context.move(to: viewPoint(dot.at))
                context.addLine(to: viewPoint(dot.at))
                context.strokePath()
                continue
            }
            for (start, end) in zip(stroke.points, stroke.points.dropFirst()) {
                context.setLineWidth((start.width + end.width) / 2 * inkUnit)
                context.move(to: viewPoint(start.at))
                context.addLine(to: viewPoint(end.at))
                context.strokePath()
            }
        }
        if let eraser = model.eraser {
            let (middle, radius) = (viewPoint(eraser), model.settings.eraserRadius * inkUnit)
            let ring = CGRect(x: middle.x - radius, y: middle.y - radius, width: 2 * radius, height: 2 * radius)
            // White over the stage's picture, dark on the whiteboard.
            let shade = model.shows == .whiteboard ? UIColor(hex: "1A1A1A") : .white
            context.setFillColor(shade.withAlphaComponent(0.15).cgColor)
            context.fillEllipse(in: ring)
            context.setStrokeColor(shade.cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: ring)
        }
    }
}

extension UIView {
    /// View points per ink point, for a view that fills the pad.
    fileprivate var inkUnit: CGFloat { bounds.height / PenLink.size.height }
}

extension UIColor {
    /// A color from six hex digits; white for anything else.
    convenience init(hex: String) {
        let value = hex.count == 6 ? UInt32(hex, radix: 16) ?? 0xFFFFFF : 0xFFFFFF
        self.init(
            red: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }
}
