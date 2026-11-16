import AppKit

/// The hands' skeletons from MediaPipe's hand model, see-through so they guide the gestures without hiding the scene:
/// MediaPipe's light gray lines with white joints, drawn behind the 3D objects and particles. The index fingertip's
/// joint grows to its touch circle while it points at an actionable item (`StageFrame.pointer(on:)`). They fade out
/// while the camera image is hidden (H), with it, as the hands' gestures stop (`HandGestures`): the stage is then the
/// scene alone. The step must list `mediapipe-hand`.
func handSkeleton(opacity: CGFloat = 0.15) -> Effect {
    let pose = PoseEffect(model: "mediapipe-hand", opacity: opacity, theme: .hands)
    // The pointing fingertip's joint grows to its touch circle.
    let grown = Pointer.reach / Theme.hands.jointRadius
    pose.grownJoints = { frame, hand in frame.pointing.isPointing(hand) ? [8: grown] : [:] }
    return HandSkeleton(pose)
}

/// The skeletons, faded out while the camera is hidden.
private final class HandSkeleton: Effect {
    /// As long as the camera image takes to fade (`StageRenderer`).
    private static let fadeTime = 0.6
    private let pose: PoseEffect
    private var last: TimeInterval?

    init(_ pose: PoseEffect) {
        self.pose = pose
        super.init()
        behind = true
        node.addChild(pose.node)
    }

    override func update(_ frame: StageFrame) {
        let dt = last.map { frame.time - $0 } ?? .infinity  // the first frame: at once
        last = frame.time
        let step = CGFloat(min(max(dt, 0), Self.fadeTime) / Self.fadeTime)
        node.set(\.alpha, frame.cameraHidden ? max(node.alpha - step, 0) : min(node.alpha + step, 1))
        pose.update(frame)  // hidden too: the hands are where they are when they show again
    }
}

extension Theme {
    /// MediaPipe's look with white joints, quieter than its red.
    static let hands = Theme(
        classes: mediapipe.classes, labelFont: mediapipe.labelFont, lineWidth: mediapipe.lineWidth, darkText: .black,
        leftLimb: mediapipe.leftLimb, rightLimb: mediapipe.rightLimb, centerLimb: mediapipe.centerLimb,
        joint: .white, jointOutline: .white, limbWidth: mediapipe.limbWidth, jointRadius: mediapipe.jointRadius)
}
