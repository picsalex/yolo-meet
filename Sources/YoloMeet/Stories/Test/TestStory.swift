import AppKit
import YoloMeetCore

extension Story {
    /// Prototype of the story foundation: MediaPipe hand gestures driving the 3D layer.
    static let test = Story(
        id: "test", title: "Test",
        steps: [
            Step(title: "Hand gestures", models: ["mediapipe-hand"]) {
                [ManipulationEffect(), titleCard("Pinch to drag, pinch both hands to zoom, fist to grab")]
            },
        ])
}
