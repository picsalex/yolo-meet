import Foundation

/// A sequence of steps you move through with the panel or a clicker. Each step names the models it needs (catalog ids,
/// downloaded on demand) and builds the effects it draws. Each story lives in its own folder under `Stories/`; see
/// `Stories/README.md` to add one.
struct Story: Identifiable {
    let id: String
    let title: String
    let steps: [Step]
    /// Work done once before the story's first step shows (e.g. building its shared state): the stage shows a loading
    /// card meanwhile, and the panel a spinner. Nil: the steps show at once.
    var prepare: (() async -> Void)? = nil

    struct Step {
        let title: String
        let models: [String]
        /// How the stage moves between this step and the previous one, both ways.
        var transition = Transition.fade
        /// Seconds after which the step starts over, again and again (`StageFrame.stepTime`, `loopCount`): its effects
        /// play their timeline from the start, fading back in; nil: it plays once.
        var loop: TimeInterval? = nil
        /// A live demo on the camera: shown even when the camera is hidden (H), which comes back on the next step
        /// that doesn't show it.
        var showsCamera = false
        /// Branches: sequences of steps entered from this one by an effect (`StageFrame.branches.enter`, e.g. clicking
        /// an item), shown indented under it in the panel. Inside one, → and ← move through its steps, and past
        /// either end back to this step; → and ← on this step skip them.
        var branches: [[Step]] = []
        let effects: () -> [Effect]
    }

    /// Where a story is: one of its steps, or a step of one of that step's branches.
    struct Place: Hashable {
        var step = 0
        /// The branch of `step` (index in its `branches`), nil on the step itself.
        var branch: Int? = nil
        /// The step in the branch.
        var substep = 0
    }

    func step(at place: Place) -> Step {
        let step = steps[place.step]
        return place.branch.map { step.branches[$0][place.substep] } ?? step
    }

    /// The place → goes to: the branch's next step, or back to the step it branches from after its last; nil at the end.
    func place(after place: Place) -> Place? {
        guard let branch = place.branch else { return place.step + 1 < steps.count ? Place(step: place.step + 1) : nil }
        return place.substep + 1 < steps[place.step].branches[branch].count
            ? Place(step: place.step, branch: branch, substep: place.substep + 1) : Place(step: place.step)
    }

    /// The place ← goes to: the branch's previous step, or back to the step it branches from before its first.
    func place(before place: Place) -> Place? {
        guard let branch = place.branch else { return place.step > 0 ? Place(step: place.step - 1) : nil }
        return place.substep > 0 ? Place(step: place.step, branch: branch, substep: place.substep - 1) : Place(step: place.step)
    }

    /// Every place in order, each step's branches right after it (the panel's list).
    var places: [Place] {
        steps.indices.flatMap { s in
            [Place(step: s)] + steps[s].branches.indices.flatMap { b in
                steps[s].branches[b].indices.map { Place(step: s, branch: b, substep: $0) }
            }
        }
    }

    /// How the stage moves between two places: neighbouring steps (of the story, or of one branch) take the later
    /// one's transition, both ways; entering a branch takes its first step's; anything else (leaving a branch,
    /// jumping) fades.
    func transition(from a: Place, to b: Place) -> Transition {
        let (first, second) = a.step < b.step || (a.step == b.step && (a.branch ?? -1, a.substep) < (b.branch ?? -1, b.substep)) ? (a, b) : (b, a)
        switch (first.branch, second.branch) {
        case (nil, nil) where second.step == first.step + 1:
            return steps[second.step].transition
        case let (x?, y?) where x == y && first.step == second.step && second.substep == first.substep + 1:
            return step(at: second).transition
        case (nil, _?) where a == first && first.step == second.step && second.substep == 0:
            return step(at: second).transition
        default:
            return .fade
        }
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
