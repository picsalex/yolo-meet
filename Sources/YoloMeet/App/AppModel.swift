import AppKit
import CoreImage
import Observation
import YoloMeetCore

/// App state shared by the control panel and the stage.
@Observable
final class AppModel {
    enum Mode: String, CaseIterable { case display = "Display", story = "Story" }
    /// What the stage shows under the effects.
    enum Source: String, CaseIterable { case camera = "Camera", media = "Media" }

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
    @ObservationIgnored private lazy var keys = ClickerKeys { [weak self] forward in forward ? self?.next() : self?.previous() }
    /// Keys for the stage's effects (`frame.keys`).
    @ObservationIgnored let stageKeys = StageKeys()

    var mode: Mode = .display { didSet { applyScene() } }
    /// Models drawn in Display mode, in drawing order.
    var displayModels: [String] = [] { didSet { applyScene() } }
    var storyID = Story.all[0].id { didSet { stepIndex = 0 } }
    var stepIndex = 0 {
        didSet {
            // Between neighbouring steps of the story on stage: the later step's transition, both ways.
            let neighbours = sceneStory == storyID && abs(stepIndex - oldValue) == 1
            applyScene(transition: neighbours ? story.steps[max(stepIndex, oldValue)].transition : .fade)
        }
    }
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
    var cameraHidden = false { didSet { restoreHidden = false } }  // set by hand: no longer ours to restore
    /// The camera was hidden when a live step showed it: hide it again on the next step that doesn't.
    private var restoreHidden = false
    var clickerKeys = false { didSet { keys.isEnabled = clickerKeys } }
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
        _ = keys  // ←/→ step the story while yolo-meet is active
        pipeline.onPendingChange = { [weak self] in
            Task { @MainActor in self.map { $0.pendingModels = $0.pipeline.pending } }
        }
        Task { await start() }
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

    func next() { if mode == .story, stepIndex < story.steps.count - 1 { stepIndex += 1 } }
    func previous() { if mode == .story, stepIndex > 0 { stepIndex -= 1 } }

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
        let live = mode == .story && story.steps[stepIndex].showsCamera
        if live, cameraHidden {
            cameraHidden = false
            restoreHidden = true
        } else if !live, restoreHidden {
            cameraHidden = true
        }
        let models = mode == .display ? displayModels : story.steps[stepIndex].models
        missingModels = models.filter { !isAvailable($0) }
        if mode == .story {
            // A story's models download on their own: this step's, and the next one's so it's ready when it comes.
            let next = stepIndex + 1 < story.steps.count ? story.steps[stepIndex + 1].models : []
            for id in missingModels + next where !isAvailable(id) { ModelCatalog.entry(id).map(store.download) }
        }
        pipeline.setModels(models.filter(isAvailable).map { ($0, url(for: $0)) })
        sceneVersion += 1
    }

    /// How long the step on stage plays before starting over (`Story.Step.loop`), if it loops.
    var stepLoop: TimeInterval? { mode == .story ? story.steps[stepIndex].loop : nil }

    /// Called by the stage renderer when `sceneVersion` changes.
    func makeEffects() -> [Effect] {
        switch mode {
        case .display:
            displayModels.flatMap { id in task(of: id).map { displayEffects(for: $0, model: id, custom: custom.model(id) != nil) } ?? [] }
        case .story:
            storyNeedsPreparing ? [loadingCard(story.title)] : story.steps[stepIndex].effects()
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
        guard ["pt", "pth"].contains(url.pathExtension.lowercased()) else { return try await custom.importModel(from: url) }
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
