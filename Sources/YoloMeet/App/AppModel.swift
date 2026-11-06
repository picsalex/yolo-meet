import AppKit
import CoreImage
import Observation
import YoloMeetCore

/// App state shared by the control panel and the stage.
@Observable
final class AppModel {
    enum Mode: String, CaseIterable { case display = "Display", story = "Story" }

    let pipeline = Pipeline()
    let store = ModelStore()
    let custom = CustomModels()
    let converter = PTConverter(script: Bundle.main.url(forResource: "export_models", withExtension: "py"))
    let backgrounds = BackgroundLibrary()
    @ObservationIgnored lazy var camera = Camera { [pipeline] in pipeline.handle($0) }
    @ObservationIgnored private lazy var keys = ClickerKeys { [weak self] forward in forward ? self?.next() : self?.previous() }

    var mode: Mode = .display { didSet { applyScene() } }
    /// Models drawn in Display mode, in drawing order.
    var displayModels: [String] = [] { didSet { applyScene() } }
    var storyID = Story.all[0].id { didSet { stepIndex = 0 } }
    var stepIndex = 0 { didSet { applyScene() } }
    var mirror = true { didSet { pipeline.setMirror(mirror) } }
    var clickerKeys = false { didSet { keys.isEnabled = clickerKeys } }
    /// "Stats for nerds" overlay on the stage.
    var showStats = UserDefaults.standard.bool(forKey: "showStats") {
        didSet { UserDefaults.standard.set(showStats, forKey: "showStats") }
    }

    /// Bumped whenever the effects on stage must be rebuilt.
    private(set) var sceneVersion = 0
    /// Models the current scene needs that are not downloaded.
    private(set) var missingModels: [String] = []
    /// Written by the renderer every frame; read periodically by the panel, so not observed.
    @ObservationIgnored var renderFPS = 0

    var story: Story { Story.all.first { $0.id == storyID } ?? Story.all[0] }

    init() {
        Task { await start() }
    }

    private func start() async {
        backgrounds.onChange = { [pipeline] url in
            pipeline.setBackground(url.flatMap { CIImage(contentsOf: $0, options: [.applyOrientationProperty: true]) })
        }
        await camera.start()
        applyScene()
    }

    func next() { if mode == .story, stepIndex < story.steps.count - 1 { stepIndex += 1 } }
    func previous() { if mode == .story, stepIndex > 0 { stepIndex -= 1 } }

    /// Recomputes the active models and asks the stage to rebuild its effects.
    func applyScene() {
        let models = mode == .display ? displayModels : story.steps[stepIndex].models
        missingModels = models.filter { !isAvailable($0) }
        pipeline.setModels(models.filter(isAvailable).map { ($0, url(for: $0)) })
        sceneVersion += 1
    }

    /// Called by the stage renderer when `sceneVersion` changes.
    func makeEffects() -> [Effect] {
        switch mode {
        case .display:
            displayModels.flatMap { id in task(of: id).map { displayEffects(for: $0, model: id) } ?? [] }
        case .story:
            story.steps[stepIndex].effects()
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
    func isAvailable(_ id: String) -> Bool { store.downloaded.contains(id) || custom.model(id) != nil }
    func url(for id: String) -> URL { custom.model(id) != nil ? custom.url(for: id) : store.url(for: id) }

    func downloadMissing() {
        for id in missingModels { ModelCatalog.entry(id).map(store.download) }
    }
}
