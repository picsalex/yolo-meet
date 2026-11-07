import AppKit
import YoloMeetCore

extension Story {
    /// Prototype of the story foundation: MediaPipe hand tracking driving the 3D layer.
    static let test = Story(
        id: "test", title: "Test",
        steps: [
            Step(title: "Glowing fingertips", models: ["mediapipe-hand"]) {
                [FingertipGlowEffect(model: "mediapipe-hand"), titleCard("Glowing fingertips")]
            },
        ])
}
