import Foundation

/// A sequence of steps you move through with the panel or a clicker. Each step names the models it needs (catalog ids,
/// downloaded on demand) and builds the effects it draws. Each story lives in its own folder under `Stories/`; see
/// `Stories/README.md` to add one.
struct Story: Identifiable {
    let id: String
    let title: String
    let steps: [Step]

    struct Step {
        let title: String
        let models: [String]
        /// How the stage moves between this step and the previous one, both ways.
        var transition = Transition.fade
        /// Seconds after which the step starts over, again and again (`StageFrame.stepTime`, `loopCount`): its effects
        /// play their timeline from the start, fading back in; nil: it plays once.
        var loop: TimeInterval? = nil
        let effects: () -> [Effect]
    }

    enum Transition {
        /// The previous step's 2D content fades out and this one's fades in.
        case fade
        /// None, as in a slide deck: the swap is instant, and effects that continue the previous step's
        /// (`Effect.continuing`) show at once, so only what's new appears (e.g. an arrow added to the same object).
        case none
    }

    static let all: [Story] = [.nnExplained, .test]

    /// A story's file (`Stories/Assets/<story>/<name>`): in the app's resources, or in the source tree when running
    /// from `swift run`.
    static func asset(_ name: String, in story: String) -> URL? {
        let bundled = Bundle.main.resourceURL?.appending(path: "Stories/\(story)/\(name)")
        let source = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Assets/\(story)/\(name)")
        return [bundled, source].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
