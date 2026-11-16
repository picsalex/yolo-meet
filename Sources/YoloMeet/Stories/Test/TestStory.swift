import AppKit
import YoloMeetCore

extension Story {
    /// Prototype of the story foundation: MediaPipe hand gestures driving the 3D layer and the particles.
    static let test = Story(
        id: "test", title: "Test",
        steps: [
            Step(title: "Hand gestures", models: ["mediapipe-hand"]) {
                // Pinch to drag, pinch both hands to zoom, cmd + fist to grab; hold space, point at it and release.
                [ManipulationEffect(), handSkeleton()]
            },
            Step(title: "Particles", models: ["mediapipe-hand"]) {
                // Cmd + fist on the particles, open to form a cube; pinch and pull to explode, two hands to zoom; hold
                // space, point at the top and release.
                [ParticleMorphEffect(), handSkeleton()]
            },
        ])
}
