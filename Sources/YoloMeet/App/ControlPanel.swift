import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import YoloMeetCore

/// Private controls. Only the Stage window is meant to be shared in Meet.
struct ControlPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
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

            if model.source == .camera {
                Section {
                    Picker("Mode", selection: $model.mode) {
                        ForEach(AppModel.Mode.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    switch model.mode {
                    case .display:
                        Text(model.store.downloaded.isEmpty
                            ? "Download a model below to start."
                            : "Click a downloaded model below to show or hide it on stage.")
                            .foregroundStyle(.secondary)
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
            }

            Section("Models") { ModelBrowser() }

            Section("Inference") { InferenceSettingsView() }

            Section("Status") {
                Toggle("Stats for nerds (on stage)", isOn: $model.showStats)
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    LabeledContent("Stage", value: "\(model.renderFPS) fps")
                    ForEach(model.pipeline.latestOutputs.values.sorted { $0.modelID < $1.modelID }, id: \.modelID) {
                        LabeledContent($0.modelID, value: String(format: "%.1f ms", $0.latency * 1000))
                    }
                    ForEach(model.pipeline.errors.sorted { $0.key < $1.key }, id: \.key) {
                        Text("\($0.key): \($0.value)").foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.store.downloaded) { model.applyScene() }
    }

    @ViewBuilder private var storyControls: some View {
        @Bindable var model = model
        Picker("Story", selection: $model.storyID) {
            ForEach(Story.all) { Text($0.title).tag($0.id) }
        }
        ForEach(Array(model.story.steps.enumerated()), id: \.offset) { index, step in
            Button { model.stepIndex = index } label: {
                HStack {
                    Image(systemName: index == model.stepIndex ? "play.fill" : "circle").frame(width: 16)
                    Text("\(index + 1). \(step.title)")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fontWeight(index == model.stepIndex ? .semibold : .regular)
        }
        HStack {
            Button("Previous", systemImage: "chevron.left") { model.previous() }.disabled(model.stepIndex == 0)
            Spacer()
            Button("Next", systemImage: "chevron.right") { model.next() }
                .disabled(model.stepIndex == model.story.steps.count - 1)
        }
        Toggle("Clicker keys (←/→, Page Up/Down) in any app", isOn: $model.clickerKeys)
        if model.clickerKeys && !ClickerKeys.hasPermission {
            Text("Allow YOLO-meet in System Settings › Privacy & Security › Accessibility, then toggle again.")
                .foregroundStyle(.secondary)
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
