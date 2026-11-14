import AVFoundation
import PenLink
import SwiftUI
import UniformTypeIdentifiers
import YoloMeetCore

/// Private controls. Only the Stage window is meant to be shared in Meet.
///
/// Laid out to fit without scrolling: what is switched mid-talk is in the toolbar (drawing, hiding the camera,
/// debug) and the bottom bar (the story's steps, the stage's speed); the rest is split into tabs, one-time setup
/// (pen pairing, clicker keys, storage) in Settings.
struct ControlPanel: View {
    enum Tab: String, CaseIterable { case stage = "Stage", models = "Models", settings = "Settings" }

    @Environment(AppModel.self) private var model
    @AppStorage("panelTab") private var tab = Tab.stage

    var body: some View {
        @Bindable var model = model
        @Bindable var drawing = model.drawing
        Form {
            switch tab {
            case .stage: StageTab(tab: $tab)
            case .models: ModelsTab()
            case .settings: SettingsTab()
            }
        }
        .formStyle(.grouped)
        .id(tab)  // each tab opens at its top
        .safeAreaBar(edge: .top) {
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .safeAreaBar(edge: .bottom) { BottomBar() }
        .toolbar {
            ToolbarItemGroup {
                Toggle("Draw on Stage", systemImage: "pencil.tip", isOn: $drawing.isOn)
                    .help("Draw on the stage with the mouse (P on stage)")
                Toggle("Hide Camera", systemImage: "video.slash", isOn: $model.cameraHidden)
                    .help("Show black instead of the camera; the models keep running (H on stage)")
                Toggle("Debug Mode", systemImage: "ladybug", isOn: $model.debugMode)
                    .help("Show stats and the recognized hand gesture on the stage")
            }
        }
        .onChange(of: model.store.downloaded) { model.modelsChanged() }
    }
}

/// Where the picture comes from, what is shown on it (models, or a story), and ink drawn over it.
private struct StageTab: View {
    @Binding var tab: ControlPanel.Tab
    @Environment(AppModel.self) private var model
    /// Whether the story's step list is shown (remembered across launches).
    @AppStorage("storyStepsExpanded") private var stepsExpanded = false

    var body: some View {
        @Bindable var model = model
        Section("Source") {
            Picker("Source", selection: $model.source) {
                ForEach(AppModel.Source.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch model.source {
            case .camera:
                Toggle("Camera", isOn: $model.cameraOn)
                if model.cameraOn {
                    Picker("Device", selection: $model.camera.selectedID) {
                        ForEach(model.camera.devices, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                    }
                    Toggle("Mirror", isOn: $model.mirror)
                }
                if !model.camera.authorized {
                    Text("Camera access is off. Enable it in System Settings › Privacy & Security › Camera.")
                        .foregroundStyle(.secondary)
                }
            case .media: MediaSourceView()
            }
        }

        if model.source == .camera {
            Section("Background") { LibraryStrip(library: model.backgrounds, types: [.image], none: true) }
        }

        Section {
            Picker("Mode", selection: $model.mode) {
                ForEach(AppModel.Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            switch model.mode {
            case .display:
                LabeledContent {
                    Button("Choose…") { tab = .models }
                } label: {
                    Text("Models on stage")
                    Text(model.displayModels.isEmpty ? "None: click a downloaded model in Models" : model.displayModels.joined(separator: ", "))
                }
            case .story: storyControls
            }
            if !model.missingModels.isEmpty {
                HStack {
                    Text("Missing: \(model.missingModels.joined(separator: ", "))").foregroundStyle(.orange)
                    Spacer()
                    Button("Download") { model.downloadMissing() }
                }
            }
        }

        DrawControls()
    }

    @ViewBuilder private var storyControls: some View {
        @Bindable var model = model
        Picker("Story", selection: $model.storyID) {
            ForEach(Story.all) { Text($0.title).tag($0.id) }
        }
        if model.preparingStory == model.storyID {
            LabeledContent("Preparing \(model.story.title)…") { ProgressView().controlSize(.small) }
        }
        // The steps, collapsed by default (a story can have dozens); the bottom bar shows where the story is and
        // steps through it either way.
        // A step's branches (`Story.Step.branches`) are indented under it, their steps unnumbered.
        DisclosureGroup(isExpanded: $stepsExpanded) {
            ForEach(model.story.places, id: \.self) { place in
                let current = place == model.place
                Button { model.place = place } label: {
                    HStack {
                        Text(place.branch == nil ? "\(place.step + 1)" : "").monospacedDigit().foregroundStyle(.secondary)
                            .frame(minWidth: 20, alignment: .trailing)
                        Text(model.story.step(at: place).title)
                            .padding(.leading, place.branch == nil ? 0 : 16)
                            .foregroundStyle(place.branch == nil ? .primary : .secondary)
                        Spacer()
                        if current {
                            Image(systemName: "play.fill").foregroundStyle(.tint).accessibilityLabel("Current step")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fontWeight(current ? .semibold : .regular)
            }
        } label: {
            LabeledContent("Steps", value: "\(model.story.steps.count)")
        }
    }
}

/// The story's Previous/Next and the stage's speed, always in view.
private struct BottomBar: View {
    @Environment(AppModel.self) private var model
    @State private var showsErrors = false

    var body: some View {
        HStack(spacing: 6) {
            if model.mode == .story {
                let (story, place) = (model.story, model.place)
                // A branch's step after the step it branches from: "13 of 14 · Task quiz › Detect".
                let title = place.branch == nil ? story.steps[place.step].title
                    : "\(story.steps[place.step].title) › \(story.step(at: place).title)"
                Button("Previous Step", systemImage: "chevron.left") { model.previous() }
                    .disabled(story.place(before: place) == nil)
                    .help("Previous step (←)")
                Text("\(place.step + 1) of \(story.steps.count) · \(title)")
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button("Next Step", systemImage: "chevron.right") { model.next() }
                    .disabled(story.place(after: place) == nil)
                    .help("Next step (→)")
            }
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in status }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// The stage's frame rate and the slowest model's latency (each model's in the tooltip); a warning for errors.
    @ViewBuilder private var status: some View {
        let outputs = model.pipeline.latestOutputs.values.sorted { $0.modelID < $1.modelID }
        let errors = model.pipeline.errors.sorted { $0.key < $1.key }
        HStack(spacing: 6) {
            Text((["\(model.renderFPS) fps"] + (outputs.map(\.latency).max().map { [String(format: "%.0f ms", $0 * 1000)] } ?? []))
                .joined(separator: " · "))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help((["Stage: \(model.renderFPS) fps"] + outputs.map { String(format: "%@: %.1f ms", $0.modelID, $0.latency * 1000) })
                    .joined(separator: "\n"))
            if !errors.isEmpty {
                Button("Errors", systemImage: "exclamationmark.triangle.fill") { showsErrors.toggle() }
                    .foregroundStyle(.red)
                    .help("Model errors")
                    .popover(isPresented: $showsErrors) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(errors, id: \.key) { Text("\($0.key): \($0.value)") }
                        }
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: 360)
                    }
            }
        }
    }
}

/// The model browser, and the settings for every model on stage, collapsed to a summary.
private struct ModelsTab: View {
    @Environment(AppModel.self) private var model
    @AppStorage("inferenceExpanded") private var inferenceExpanded = false

    var body: some View {
        if model.mode == .story {
            // In Story mode clicks don't change the stage: say so before one seems to fail.
            Section {
                LabeledContent {
                    Button("Switch to Display") { model.mode = .display }
                } label: {
                    Label("Story mode", systemImage: "info.circle")
                    Text("You're in Story mode, where each step picks its models. To choose which models to show, switch back to Display mode.")
                }
            }
        }
        Section { ModelBrowser() }
        Section {
            DisclosureGroup(isExpanded: $inferenceExpanded) {
                InferenceSettingsView()
            } label: {
                let settings = model.inference
                LabeledContent("Inference") {
                    Text(
                        [settings.imgsz.map { "\($0) px" }, "Conf \(settings.confidence.formatted(.number.precision(.fractionLength(2))))",
                         "IoU \(settings.iou.formatted(.number.precision(.fractionLength(2))))"]
                            .compactMap(\.self).joined(separator: " · "))
                        .monospacedDigit()
                }
            }
        }
    }
}

/// The iPad pen's switch, with whether a pad is connected. Its pairing code is in the Settings tab.
struct PenToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var pen = model.pen
        Toggle(isOn: $pen.isOn) {
            Text("iPad pen")
            Text(!pen.isOn
                ? "Draw with an Apple Pencil, from the yolo-meet pen app"
                : pen.pad.map { "Connected to \($0)" } ?? "Waiting for the yolo-meet pen app · pairing code in Settings")
        }
    }
}

/// Ink on the stage (`Drawing`): the mouse and the iPad's pen, the ink's look, and removing strokes.
private struct DrawControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var drawing = model.drawing
        let pen = model.pen
        Section("Draw") {
            Toggle("Draw on stage (P)", isOn: $drawing.isOn)
            PenToggle()
        }
        if drawing.isOn || pen.isOn || drawing.strokeCount > 0 {
            Section {
                if drawing.isOn || pen.isOn {
                    // The tool and the color on one row: picking a color also picks the pencil.
                    HStack {
                        Picker("Tool", selection: $drawing.erases) {
                            Label("Pencil", systemImage: "pencil.tip").tag(false)
                            Label("Eraser", systemImage: "eraser").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                        HStack(spacing: 6) {
                            ForEach(Drawing.colors, id: \.1) { name, hex in
                                Button { (drawing.color, drawing.erases) = (hex, false) } label: {
                                    Circle().fill(Color(nsColor: .hex(hex))).frame(width: 18, height: 18)
                                        .overlay(Circle().stroke(.secondary.opacity(0.5), lineWidth: 1))
                                        .padding(3)
                                        .overlay(Circle().stroke(Color.accentColor, lineWidth: drawing.color == hex && !drawing.erases ? 2 : 0))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(name)
                                .help(name)
                            }
                        }
                    }
                    LabeledContent {
                        Slider(value: $drawing.width, in: InkSettings.widths, step: 1)
                    } label: {
                        Text("Width")
                        Text("\(Int(drawing.width)) px")
                    }
                    // One row: the switch, and the delay it reveals.
                    LabeledContent {
                        HStack {
                            if drawing.fades { Slider(value: $drawing.fadeAfter, in: InkSettings.stays, step: 1) }
                            Toggle("Fading ink", isOn: $drawing.fades).labelsHidden().toggleStyle(.switch).fixedSize()
                        }
                    } label: {
                        Text("Fading ink")
                        Text(drawing.fades ? "Fades after \(Int(drawing.fadeAfter)) s" : "Strokes stay until undone, erased or cleared")
                    }
                }
            } header: {
                HStack {
                    Text("Ink")
                    Spacer()
                    Group {
                        Button("Undo", systemImage: "arrow.uturn.backward") { drawing.undo() }.help("Undo the last stroke (⌫ on stage)")
                        Button("Clear", systemImage: "trash") { drawing.clear() }.help("Clear all strokes (C on stage)")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(drawing.strokeCount == 0)
                }
            }
        }
    }
}

/// A library's files as thumbnails: click to select, right-click to remove, "+" to add.
private struct LibraryStrip: View {
    let library: FileLibrary
    let types: [UTType]
    /// Offers a "None" tile that clears the selection.
    var none = false
    @State private var importing = false

    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                if none { tile(nil) }
                ForEach(library.items, id: \.self, content: tile)
                Button { importing = true } label: { Image(systemName: "plus").frame(width: 80, height: 45) }
            }
            .padding(.vertical, 4)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: types, allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { library.add(urls) }
        }
    }

    private func tile(_ url: URL?) -> some View {
        let selected = library.selected == url
        return Button { library.selected = url } label: {
            Group {
                if let url, let image = library.thumbnails[url] {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Text(url?.deletingPathExtension().lastPathComponent ?? "None").font(.caption).lineLimit(2).padding(4)
                }
            }
            .frame(width: 80, height: 45)
            .overlay(alignment: .bottomTrailing) {
                if let url, FileLibrary.isVideo(url) {
                    Image(systemName: "play.fill").font(.caption2).foregroundStyle(.white).shadow(radius: 2).padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .secondary.opacity(0.3), lineWidth: selected ? 3 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 6))  // a plain button only hits its drawn pixels, e.g. "None"'s text
        }
        .buttonStyle(.plain)
        .help(url?.lastPathComponent ?? "No background")
        .contextMenu {
            if let url { Button("Remove", role: .destructive) { library.remove(url) } }
        }
    }
}

/// Images, videos and downloaded links to run the models on, with playback controls for videos.
private struct MediaSourceView: View {
    @Environment(AppModel.self) private var model
    @State private var link = ""
    @State private var error: String?
    /// The scrubber position while it is dragged.
    @State private var scrub: Double?

    var body: some View {
        LibraryStrip(library: model.media, types: [.image, .movie])
        HStack {
            TextField("Video link", text: $link, prompt: Text("Paste a YouTube or video link"))
                .labelsHidden()
                .onSubmit(download)
            if let progress = model.links.progress {
                if let progress {
                    ProgressView(value: progress).frame(width: 60)
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                } else {
                    ProgressView().controlSize(.small)  // getting yt-dlp, or waiting for the first progress line
                }
                Button("Cancel Download", systemImage: "xmark.circle.fill") { model.links.cancel(in: model.media.directory) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Cancel the download")
            } else {
                Button("Download", action: download).disabled(link.isEmpty)
            }
        }
        if let status = model.links.status { Text(status).font(.caption).foregroundStyle(.secondary) }
        if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        if model.player.isVideo {
            HStack {
                Button(model.player.isPlaying ? "Pause" : "Play", systemImage: model.player.isPlaying ? "pause.fill" : "play.fill") {
                    model.player.isPlaying.toggle()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                Slider(value: Binding { scrub ?? model.player.time } set: { scrub = $0 }, in: 0...max(model.player.duration, 1)) {
                    EmptyView()
                } onEditingChanged: { editing in
                    guard !editing, let scrub else { return }
                    model.player.seek(to: scrub)
                    self.scrub = nil
                }
                Text(Duration.seconds(scrub ?? model.player.time).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func download() {
        guard !link.isEmpty, model.links.progress == nil else { return }
        error = nil
        Task {
            do {
                try await model.addLink(link)
                link = ""
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Settings for every model on stage.
private struct InferenceSettingsView: View {
    @Environment(AppModel.self) private var model
    /// The image size while its slider is dragged: each new size is compiled once, so it is applied on release.
    @State private var imgsz: Double?

    var body: some View {
        @Bindable var model = model
        // One row: the models' training size, or an override set with the slider the switch reveals.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let training = model.pipeline.trainingSizes
            let size = Binding { imgsz ?? Double(model.inference.imgsz ?? training.first ?? 640) } set: { imgsz = $0 }
            LabeledContent {
                HStack {
                    if model.inference.imgsz != nil {
                        Slider(value: size, in: 160...1280, step: 32) {
                            EmptyView()
                        } onEditingChanged: { editing in
                            guard !editing, let imgsz else { return }
                            model.inference.imgsz = Int(imgsz)
                            self.imgsz = nil
                        }
                    }
                    Toggle("Override", isOn: Binding { model.inference.imgsz != nil } set: {
                        model.inference.imgsz = $0 ? training.first ?? 640 : nil
                    })
                    .toggleStyle(.checkbox)  // HIG: a checkbox for a setting that adjusts another; box before label
                    .fixedSize()
                    .help("Override the training image size")
                }
            } label: {
                Text("Image size")
                Text(model.inference.imgsz == nil
                    ? "Training · " + (training.isEmpty ? "per model" : training.map { "\($0) px" }.joined(separator: " / "))
                    : "\(Int(size.wrappedValue)) px")
            }
        }
        LabeledContent {
            Slider(value: $model.inference.confidence, in: 0.05...0.95, step: 0.05)
        } label: {
            Text("Confidence")
            Text(model.inference.confidence.formatted(.number.precision(.fractionLength(2))))
        }
        LabeledContent {
            Slider(value: $model.inference.iou, in: 0.1...0.95, step: 0.05)
        } label: {
            Text("IoU (NMS)")
            Text(model.inference.iou.formatted(.number.precision(.fractionLength(2))))
        }
        Toggle(isOn: $model.smoothing) {
            Text("Smoothing")
            Text("Predicts motion between model runs and fades out vanished objects")
        }
        if model.inference != InferenceSettings() {
            Button("Reset to Defaults") { model.inference = InferenceSettings() }
        }
    }
}
