import AppKit
import CoreImage
import Observation
import PenLink
import YoloMeetCore

/// App state shared by the control panel and the stage.
@Observable
final class AppModel {
    enum Mode: String, CaseIterable {
        case display = "Display"
        case story = "Story"
    }
    /// What the stage shows under the effects.
    enum Source: String, CaseIterable {
        case camera = "Camera"
        case media = "Media"
    }

    let pipeline = Pipeline()
    let store = ModelStore()
    let custom = CustomModels()
    let converter = PTConverter(script: Bundle.main.url(forResource: "export_models", withExtension: "py"))
    let backgrounds = FileLibrary(folder: "Backgrounds", key: "background")
    /// Images and videos to run models on instead of the camera.
    let media = FileLibrary(folder: "Media", key: "media")
    let links = LinkDownloader()
    @ObservationIgnored lazy var player = MediaPlayer { [pipeline] in pipeline.show($0, isNew: $1) }
    @ObservationIgnored lazy var camera = Camera { [pipeline] in pipeline.handle($0) }
    @ObservationIgnored private lazy var keys = ClickerKeys { [weak self] forward in
        forward ? self?.next() : self?.previous()
    }
    /// Keys for the stage's effects (`frame.keys`).
    @ObservationIgnored let stageKeys = StageKeys()
    /// Ink drawn on the stage with the mouse, or with the iPad pen app's Apple Pencil; both observe their own settings.
    @ObservationIgnored let drawing = Drawing()
    @ObservationIgnored private(set) lazy var pen = PenInput(
        drawing: drawing, stories: Story.all.map { StoryInfo(id: $0.id, title: $0.title) }, story: storyID,
        onStep: { [weak self] forward in forward ? self?.next() : self?.previous() },
        onShow: { [weak self] show in
            guard let self else { return }
            switch show {
            case .story: showStory()
            case .whiteboard: whiteboard.toggle()  // its key again: back to what was under it
            case .display: (whiteboard, mode) = (false, .display)
            }
        },
        onStory: { [weak self] in self?.showStory($0) },
        onRestart: { [weak self] in self?.restartStory() },
        onHide: { [weak self] in self?.cameraHidden = $0 })

    var mode: Mode = .display { didSet { applyScene() } }
    /// The stage shows a whiteboard over everything: white, with its own ink (`Drawing.page`), and no models or effects.
    /// The mode and the story's place stay as they were underneath, and show again when it's off.
    var whiteboard = false {
        didSet {
            guard whiteboard != oldValue else { return }
            drawing.page = whiteboard ? .whiteboard : .stage
            applyScene()
        }
    }
    /// What the stage shows, for the pen app's deck.
    var shows: StageShow { whiteboard ? .whiteboard : mode == .story ? .story : .display }
    /// Models drawn in Display mode, in drawing order.
    var displayModels: [String] = [] { didSet { applyScene() } }
    /// The models on stage now: the Display picks, or the story step's; none on the whiteboard.
    var stageModels: [String] { whiteboard ? [] : mode == .display ? displayModels : step.models }
    var storyID = Story.all[0].id {
        didSet {
            pen.story = storyID
            (visited, revealed) = ([:], [:])
            place = Story.Place()
        }
    }
    /// Where the story is: a step, or a step of one of its branches.
    var place = Story.Place() {
        didSet {
            // The branches entered from a step stay visited until the story changes or the step is reset.
            if let branch = place.branch {
                visited[place.step, default: []].insert(branch)
                revealed[place.step, default: []].insert(branch)
            }
            let left = oldValue.branch != nil && place.branch == nil && oldValue.step == place.step
            returnedBranch = left ? oldValue.branch : nil
            applyScene(transition: sceneStory == storyID ? story.transition(from: oldValue, to: place) : .fade)
        }
    }
    /// The story's step on stage.
    var step: Story.Step { story.step(at: place) }
    /// The branches entered from each step (index in `story.steps`), for its effects (`StageFrame.branches`).
    private(set) var visited: [Int: Set<Int>] = [:]
    /// The branches shown on each step (e.g. a quiz's items clicked clear), entered or not: kept like `visited`.
    private(set) var revealed: [Int: Set<Int>] = [:]
    /// The branch the story just came back from to its step, if it did.
    @ObservationIgnored private(set) var returnedBranch: Int?
    var mirror = true { didSet { pipeline.setMirror(mirror) } }
    /// The stage's input, in either mode: a story keeps its step when it changes.
    var source = Source.camera { didSet { applyInput() } }
    /// Off: no capture; the stage shows the background, or black.
    var cameraOn = true { didSet { applyInput() } }
    var inference = InferenceSettings.saved {
        didSet {
            inference.save()
            pipeline.setSettings(inference)
        }
    }
    /// The stage shows black instead of the camera (H on stage); the camera keeps running for the models.
    var cameraHidden = false {
        didSet {
            restoreHidden = false  // set by hand: no longer ours to restore
            pen.cameraHidden = cameraHidden
        }
    }
    /// The camera was hidden when a live step showed it: hide it again on the next step that doesn't.
    private var restoreHidden = false
    /// ←/→ and Page Up/Down step the story while other apps are in front (a setting: remembered across launches).
    var clickerKeys = UserDefaults.standard.bool(forKey: "clickerKeys") {
        didSet {
            UserDefaults.standard.set(clickerKeys, forKey: "clickerKeys")
            keys.isEnabled = clickerKeys
        }
    }
    /// Debug mode: stats and the recognized hand gesture on the stage.
    var debugMode = UserDefaults.standard.bool(forKey: "debugMode") {
        didSet { UserDefaults.standard.set(debugMode, forKey: "debugMode") }
    }
    /// Prediction between model runs, smoothing, and fading out vanished objects. Off: each model's latest raw result.
    var smoothing = UserDefaults.standard.object(forKey: "smoothing") as? Bool ?? true {
        didSet { UserDefaults.standard.set(smoothing, forKey: "smoothing") }
    }

    /// Bumped whenever the effects on stage must be rebuilt.
    private(set) var sceneVersion = 0
    /// How the stage swaps to the new scene.
    private(set) var transition = Story.Transition.fade
    /// The story on stage, to tell a step change within it from a new story.
    private var sceneStory: String?
    /// Models the current scene needs that are not downloaded.
    private(set) var missingModels: [String] = []
    /// Active models still loading or waiting for their first result.
    private(set) var pendingModels: Set<String> = []
    /// Written by the renderer every frame; read periodically by the panel, so not observed.
    @ObservationIgnored var renderFPS = 0
    /// Stories whose `prepare` has finished.
    @ObservationIgnored private var prepared: Set<String> = []
    /// The story whose `prepare` is running: the stage shows a loading card and the panel a spinner meanwhile.
    private(set) var preparingStory: String?
    /// Whether the story on stage still has to be prepared before its steps can show.
    private var storyNeedsPreparing: Bool { mode == .story && story.prepare != nil && !prepared.contains(storyID) }

    var story: Story { Story.all.first { $0.id == storyID } ?? Story.all[0] }

    init() {
        keys.isEnabled = clickerKeys  // ←/→ step the story while yolo-meet is active, and in other apps when set
        _ = pen  // the iPad pen app finds yolo-meet from launch, when the pen is on
        pipeline.onPendingChange = { [weak self] in
            Task { @MainActor in self.map { $0.pendingModels = $0.pipeline.pending } }
        }
        Task { await start() }
        Task { await refreshNumbers() }
    }

    private func start() async {
        pipeline.setSettings(inference)
        backgrounds.onChange = { [pipeline] url in
            pipeline.setBackground(url.flatMap { FileLibrary.image(at: $0, covering: Pipeline.workingSize) })
        }
        media.onChange = { [player] in player.load($0) }
        await camera.start()
        applyScene()
    }

    /// Only one input runs: the camera (when on) or the media player.
    private func applyInput() {
        camera.isOn = source == .camera && cameraOn
        pipeline.setInput(source == .media ? .media : cameraOn ? .camera : .off)
        player.isActive = source == .media
    }

    /// Downloads a video link into the media library and shows it.
    func addLink(_ link: String) async throws {
        media.adopt(try await links.download(link, into: media.directory))
    }

    /// The story's next step, or the one before; not while the whiteboard hides it.
    func next() { if mode == .story, !whiteboard, let next = story.place(after: place) { place = next } }
    func previous() { if mode == .story, !whiteboard, let previous = story.place(before: place) { place = previous } }
    /// Back to the story, at the step it was on: from the whiteboard or from Display mode (the pen app's Story).
    func showStory() { (whiteboard, mode) = (false, .story) }
    /// The story `id` on stage (the pen app's deck): where it was if it is the one open, else from its start.
    func showStory(_ id: String) {
        guard Story.all.contains(where: { $0.id == id }) else { return }
        if storyID != id { storyID = id }
        showStory()
    }
    /// The story on stage starts over (the pen app's deck): its first step, its branches unvisited and its quiz blurred
    /// again, as when it was opened. Not while the whiteboard hides it.
    func restartStory() {
        guard mode == .story, !whiteboard else { return }
        (visited, revealed) = ([:], [:])
        place = Story.Place()
    }
    /// Enters a branch of the step on stage (`Story.Step.branches`), at its first step: only from the step itself,
    /// not from its substeps or from inside a branch.
    func enter(branch: Int) {
        guard mode == .story, place.isStep, story.steps[place.step].branches.indices.contains(branch) else {
            return
        }
        place = Story.Place(step: place.step, branch: branch)
    }

    /// Marks a branch of the step on stage as shown (`StageFrame.Branches.reveal`), without entering it.
    func reveal(branch: Int) {
        guard mode == .story, place.isStep, story.steps[place.step].branches.indices.contains(branch) else {
            return
        }
        revealed[place.step, default: []].insert(branch)
    }

    /// Whether a story shows live numbers (`Story.refresh`), for Settings › Refresh.
    var hasLiveNumbers: Bool { Story.all.contains { $0.refresh != nil } }
    /// Fetching the stories' live numbers now.
    private(set) var refreshingNumbers = false
    /// The last fetch's outcome: when, and whether every source answered (else the last numbers fetched stay).
    private(set) var numbersRefreshed: (at: Date, complete: Bool)?

    /// Fetches the live numbers the stories show (GitHub's stars, PyPI's release…): at launch, and from Settings.
    func refreshNumbers() async {
        guard !refreshingNumbers, hasLiveNumbers else { return }
        refreshingNumbers = true
        var complete = true
        for story in Story.all {
            if let refresh = story.refresh, await !refresh() { complete = false }
        }
        (numbersRefreshed, refreshingNumbers) = ((Date(), complete), false)
    }

    /// Forgets the branches entered from a step and shown on it (e.g. a quiz's revealed items blur again).
    func reset(step: Int) { (visited[step], revealed[step]) = (nil, nil) }

    /// Recomputes the active models and asks the stage to rebuild its effects, with `transition`.
    func applyScene(transition: Story.Transition = .fade) {
        (self.transition, sceneStory) = (transition, mode == .story ? storyID : nil)
        if storyNeedsPreparing, preparingStory == nil, let prepare = story.prepare {
            // Once per story: its steps show when it's ready (the stage shows a loading card until then).
            let id = storyID
            preparingStory = id
            Task {
                await prepare()
                prepared.insert(id)
                preparingStory = nil
                applyScene()
            }
        }
        // A live step shows the camera even when it's hidden (H); the next step that doesn't hides it again.
        let live = mode == .story && !whiteboard && step.showsCamera
        if live, cameraHidden {
            cameraHidden = false
            restoreHidden = true
        } else if !live, restoreHidden {
            cameraHidden = true
        }
        let models = stageModels
        missingModels = models.filter { !isAvailable($0) }
        if mode == .story, !whiteboard {
            // A story's models download on their own: this step's, and the next one's so it's ready when it comes.
            let next = story.place(after: place).map { story.step(at: $0).models } ?? []
            for id in missingModels + next where !isAvailable(id) { ModelCatalog.entry(id).map(store.download) }
        }
        pipeline.setModels(models.filter(isAvailable).map { ($0, url(for: $0)) })
        sceneVersion += 1
        pen.shows = (shows, mode == .story ? .story : .display)
    }

    /// How long the step on stage plays before starting over (`Story.Step.loop`), if it loops.
    var stepLoop: TimeInterval? { mode == .story && !whiteboard ? step.loop : nil }

    /// Called by the stage renderer when `sceneVersion` changes.
    func makeEffects() -> [Effect] {
        if whiteboard { return [] }
        return switch mode {
        case .display:
            displayModels.flatMap { id in
                task(of: id).map { displayEffects(for: $0, model: id, custom: custom.model(id) != nil) } ?? []
            }
        case .story:
            storyNeedsPreparing ? [loadingCard(story.title)] : step.effects()
        }
    }

    func toggleDisplay(_ id: String) {
        if displayModels.contains(id) {
            displayModels.removeAll { $0 == id }
        } else {
            // One size per task: showing a model replaces any other size of the same task.
            let task = task(of: id)
            displayModels.removeAll { self.task(of: $0) == task }
            displayModels.append(id)
        }
    }

    func deleteModel(_ id: String) {
        displayModels.removeAll { $0 == id }
        store.delete(id)
    }

    /// Deletes every downloaded catalog model; imported custom models are kept.
    func deleteAllModels() {
        displayModels.removeAll { ModelCatalog.entry($0) != nil }
        store.deleteAll()
    }

    /// Imports a Core AI model, converting PyTorch checkpoints (`.pt`/`.pth`) first.
    func importModel(from url: URL) async throws {
        guard ["pt", "pth"].contains(url.pathExtension.lowercased()) else {
            return try await custom.importModel(from: url)
        }
        let zip = try await converter.convert(url)
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        try await custom.importModel(from: zip)
    }

    func deleteCustom(_ id: String) {
        displayModels.removeAll { $0 == id }
        custom.delete(id)
    }

    /// Catalog and custom models share ids' namespace: custom ids start with `custom-`.
    func task(of id: String) -> YOLOTask? { ModelCatalog.entry(id)?.task ?? custom.model(id)?.task }
    func isAvailable(_ id: String) -> Bool {
        store.downloaded.contains(id) || custom.model(id) != nil || ModelCatalog.entry(id)?.family.isBuiltIn == true
    }
    func url(for id: String) -> URL { custom.model(id) != nil ? custom.url(for: id) : store.url(for: id) }

    /// After a download or deletion: the scene again when it shows downloaded models (Display mode) or was waiting for
    /// one, not when a story's next step's model arrives meanwhile.
    func modelsChanged() {
        if mode == .display || !missingModels.isEmpty { applyScene() }
    }

    func downloadMissing() {
        for id in missingModels { ModelCatalog.entry(id).map(store.download) }
    }
}
