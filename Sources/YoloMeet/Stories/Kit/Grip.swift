import CoreGraphics

/// Whether the hand gestures hold an object: a gesture holds it when it begins on it (`isOn`), so hands elsewhere never
/// move it. The object swells while a pinch charges on it (`frame.charge`) and stays a little larger while held
/// (`scale`), so the presenter sees it's taken before it moves. One per object; call `update` every frame.
final class Grip {
    /// The object's size while held (1 at rest).
    let grown: CGFloat
    /// Whether the current gesture began on the object.
    private(set) var held = false
    /// The object's size now, eased toward 1, `grown` while held, and in between while a gesture charges on it: draw the
    /// object at it.
    private(set) var scale: CGFloat = 1

    init(grown: CGFloat = 1.06) { self.grown = grown }

    /// `isOn` tells whether a stage point takes hold of the object (e.g. within reach of its center). Returns the frame's
    /// gesture while it holds the object, nil otherwise; on `.began`, store the values the gesture acts from.
    func update(_ frame: StageFrame, isOn: (CGPoint) -> Bool) -> HandGesture? {
        var holding: HandGesture?
        if let gesture = frame.gesture {
            if gesture.phase == .began { held = isOn(gesture.location) }
            if held { holding = gesture }
            if gesture.phase == .ended { held = false }
        } else {
            held = false
        }
        let charging = frame.charge.flatMap { isOn($0.location) ? $0.progress : nil }
        let target = held ? grown : 1 + (grown - 1) * (charging ?? 0)
        scale = scale.approaching(target, frame.smoothing)
        return holding
    }
}
