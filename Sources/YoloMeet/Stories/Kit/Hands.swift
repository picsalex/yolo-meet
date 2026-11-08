import AppKit

/// The hands' skeletons from MediaPipe's hand model, see-through so they guide the gestures without hiding the scene:
/// MediaPipe's light gray lines with white joints, drawn behind the 3D objects and particles. The step must list
/// `mediapipe-hand`.
func handSkeleton(opacity: CGFloat = 0.15) -> Effect {
    let effect = PoseEffect(model: "mediapipe-hand", opacity: opacity, theme: .hands)
    effect.behind = true
    return effect
}

extension Theme {
    /// MediaPipe's look with white joints, quieter than its red.
    static let hands = Theme(
        classes: mediapipe.classes, labelFont: mediapipe.labelFont, lineWidth: mediapipe.lineWidth, darkText: .black,
        leftLimb: mediapipe.leftLimb, rightLimb: mediapipe.rightLimb, centerLimb: mediapipe.centerLimb,
        joint: .white, jointOutline: .white, limbWidth: mediapipe.limbWidth, jointRadius: mediapipe.jointRadius)
}
