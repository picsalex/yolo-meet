import CoreGraphics

/// The hands' skeletons from MediaPipe's hand model, see-through so they guide the gestures without hiding the scene.
/// The step must list `mediapipe-hand`.
func handSkeleton(opacity: CGFloat = 0.5) -> Effect {
    PoseEffect(model: "mediapipe-hand", opacity: opacity)
}
