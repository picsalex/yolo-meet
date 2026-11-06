import AVFoundation
import SwiftUI
import YoloMeetCore

/// Private controls. Only the Stage window is meant to be shared in Meet.
struct ControlPanel: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Camera") {
                Picker("Camera", selection: $model.camera.selectedID) {
                    ForEach(model.camera.devices, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                }
                Toggle("Mirror", isOn: $model.mirror)
                if !model.camera.authorized {
                    Text("Camera access is off. Enable it in System Settings › Privacy & Security › Camera.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Background") {
                ScrollView(.horizontal) {
                    HStack {
                        thumbnail(nil)
                        ForEach(model.backgrounds.items, id: \.self, content: thumbnail)
                        Button { importing = true } label: {
                            Image(systemName: "plus").frame(width: 80, height: 45)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                Picker("Mode", selection: $model.mode) {
                    ForEach(AppModel.Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                switch model.mode {
                case .display: displayControls
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

            Section("Models") { ModelList() }

            Section("Status") {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    LabeledContent("Stage", value: "\(model.renderFPS) fps")
                    ForEach(model.pipeline.latestOutputs.values.sorted { $0.modelID < $1.modelID }, id: \.modelID) {
                        LabeledContent($0.modelID, value: String(format: "%.1f ms", $0.latency * 1000))
                    }
                    ForEach(model.pipeline.errors.sorted { $0.key < $1.key }, id: \.key) {
                        Text("\($0.key): \($0.value)").foregroundStyle(.red)
                    }
                }
                if let error = model.store.lastError { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { model.backgrounds.add(urls) }
        }
        .onChange(of: model.store.downloaded) { model.applyScene() }
    }

    private var displayControls: some View {
        let downloaded = ModelCatalog.entries.filter { model.store.downloaded.contains($0.id) }
        return Group {
            if downloaded.isEmpty { Text("Download a model below to start.").foregroundStyle(.secondary) }
            ForEach(downloaded) { entry in
                Toggle(entry.title, isOn: Binding(
                    get: { model.displayModels.contains(entry.id) }, set: { _ in model.toggleDisplay(entry.id) }))
            }
        }
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

    private func thumbnail(_ url: URL?) -> some View {
        let selected = model.backgrounds.selected == url
        return Button { model.backgrounds.selected = url } label: {
            Group {
                if let url, let image = model.backgrounds.thumbnails[url] {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Text("None").font(.caption)
                }
            }
            .frame(width: 80, height: 45)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .secondary.opacity(0.3), lineWidth: selected ? 3 : 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let url { Button("Remove", role: .destructive) { model.backgrounds.remove(url) } }
        }
    }
}

/// Catalog grouped by task, with download / delete per model.
private struct ModelList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(YOLOTask.allCases, id: \.self) { task in
            DisclosureGroup(task.title) {
                ForEach(ModelCatalog.entries.filter { $0.task == task }) { entry in
                    HStack {
                        Text(entry.title)
                        Spacer()
                        if let progress = model.store.progress[entry.id] {
                            ProgressView(value: progress).frame(width: 80)
                        } else if model.store.downloaded.contains(entry.id) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                model.displayModels.removeAll { $0 == entry.id }
                                model.store.delete(entry.id)
                            }
                            .labelStyle(.iconOnly)
                        } else {
                            Button("Download", systemImage: "arrow.down.circle") { model.store.download(entry) }
                                .labelStyle(.iconOnly)
                        }
                    }
                }
            }
        }
    }
}
