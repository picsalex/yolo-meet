import AppKit

/// The hand gestures made with the mouse or trackpad on the stage, in stage points, so every scene can be driven
/// without a camera: the cursor points (a `Pointer`, hand `Pointer.mouse`), pressing and moving drags, and a trackpad
/// pinch or Command + scroll wheel zooms around the cursor. The stage view feeds it its events; the stage reads it once
/// per frame (`update`), and while it makes a gesture that gesture wins over the hands'.
final class MouseGestures {
    /// How long a scroll-wheel zoom lasts after its last wheel event (a wheel has no end of its own).
    static let wheelIdle: TimeInterval = 0.25
    /// Zoom per point of scroll: a trackpad's precise deltas, or a wheel's lines.
    static let wheelZoom = (precise: 0.005, lines: 0.1)

    /// The cursor, while it's over the stage.
    private(set) var hover: CGPoint?
    private var current: (kind: HandGesture.Kind, announced: Bool, ending: Bool)?
    /// The scroll-wheel zoom in progress ends once its wheel has been idle for `wheelIdle`.
    private var wheelAt: TimeInterval?
    private var click: CGPoint?

    /// The cursor as a pointer for actionable items (`frame.pointers`), while it's over the stage.
    var pointer: Pointer? { hover.map { Pointer(hand: Pointer.mouse, location: $0) } }

    /// The gesture for this frame: `.began` once, `.changed` every frame, `.ended` once (the frame after `.began` at
    /// the earliest, for a click).
    func update(time: TimeInterval) -> HandGesture? {
        if let at = wheelAt, time - at > Self.wheelIdle { finish() }
        guard let gesture = current else { return nil }
        let phase: HandGesture.Phase = !gesture.announced ? .began : gesture.ending ? .ended : .changed
        if phase == .ended { current = nil } else { current?.announced = true }
        let hands = if case .zoom = gesture.kind { 2 } else { 1 }
        return HandGesture(kind: gesture.kind, phase: phase, hands: hands)
    }

    // Events, at stage points.

    func moved(to point: CGPoint?) {
        hover = point
        if let point, case let .drag(start, _) = current?.kind, current?.ending == false {
            current?.kind = .drag(start: start, location: point)
        }
    }

    func pressed(at point: CGPoint) {
        hover = point
        guard current == nil else { return }
        current = (.drag(start: point, location: point), false, false)
    }

    /// A press while the space bar is held (action mode): a click for this frame's effects, not a drag.
    func clicked(at point: CGPoint) {
        hover = point
        click = point
    }

    /// The click since the last frame, if any (`StageFrame.click`).
    func takeClick() -> CGPoint? {
        defer { click = nil }
        return click
    }

    func released() {
        if case .drag = current?.kind { finish() }
    }

    /// A trackpad pinch: `magnification` since the last event (0 at rest).
    func magnified(by magnification: CGFloat, phase: NSEvent.Phase, at point: CGPoint) {
        if phase.contains(.began) { zoom(at: point) }
        scale(by: 1 + magnification)
        if !phase.intersection([.ended, .cancelled]).isEmpty, wheelAt == nil, case .zoom = current?.kind { finish() }
    }

    /// Command + scroll: up (or away) zooms in.
    func scrolled(by delta: CGFloat, precise: Bool, at point: CGPoint, time: TimeInterval) {
        if wheelAt == nil { zoom(at: point) }
        guard case .zoom = current?.kind else { return }
        wheelAt = time
        scale(by: exp(delta * (precise ? Self.wheelZoom.precise : Self.wheelZoom.lines)))
    }

    private func zoom(at point: CGPoint) {
        guard current == nil else { return }
        current = (.zoom(scale: 1, center: hover ?? point), false, false)
    }

    private func scale(by factor: CGFloat) {
        guard case let .zoom(scale, center) = current?.kind, current?.ending == false else { return }
        current?.kind = .zoom(scale: scale * factor, center: center)
    }

    private func finish() {
        wheelAt = nil
        current?.ending = true
    }
}
