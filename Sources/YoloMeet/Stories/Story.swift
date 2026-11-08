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
        let effects: () -> [Effect]
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
