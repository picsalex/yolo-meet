import AVFoundation
import SwiftUI
import YoloMeetCore

/// Private controls. Only the Stage window is meant to be shared in Meet.
struct ControlPanel: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var confirmingDeleteAll = false

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

            Section("Models") {
                ModelGrid()
                Button("Delete All Models…", role: .destructive) { confirmingDeleteAll = true }
                    .disabled(model.store.downloaded.isEmpty)
                    .confirmationDialog("Delete all downloaded models?", isPresented: $confirmingDeleteAll) {
                        Button("Delete All", role: .destructive) { model.deleteAllModels() }
                    } message: {
                        Text("Removes \(model.store.downloaded.count) models and their compiled copies. You can download them again.")
                    }
            }

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
                if let error = model.store.lastError { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { model.backgrounds.add(urls) }
        }
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

/// One family at a time as a compact grid: tasks are rows, sizes are columns.
private struct ModelGrid: View {
    @Environment(AppModel.self) private var model
    @AppStorage("gridFamily") private var family = ModelFamily.yolo26

    var body: some View {
        Picker("Family", selection: $family) {
            ForEach(ModelFamily.allCases, id: \.self) { family in
                // A dot marks families with a model on stage.
                let onStage = model.displayModels.contains { ModelCatalog.entry($0)?.family == family }
                Text(onStage ? "\(family.title) •" : family.title)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                Text("")
                ForEach(family.sizes, id: \.self) {
                    Text($0).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 40)
                }
            }
            ForEach(family.tasks, id: \.self) { ModelGridRow(family: family, task: $0) }
        }
        .padding(.vertical, 4)
    }
}

/// One task's sizes; an empty slot where the family has no checkpoint for that size.
private struct ModelGridRow: View {
    let family: ModelFamily
    let task: YOLOTask

    var body: some View {
        let entries = ModelCatalog.entries.filter { $0.family == family && $0.task == task }
        GridRow {
            Text(task.title)
            ForEach(family.sizes, id: \.self) { size in
                if let entry = entries.first(where: { $0.size == size }) {
                    ModelCell(entry: entry)
                } else {
                    Color.clear.frame(width: 40, height: 26)
                }
            }
        }
    }
}

/// Click to download; once downloaded, click to show/hide in Display mode, right-click to delete.
private struct ModelCell: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        let progress = model.store.progress[entry.id]
        let downloaded = model.store.downloaded.contains(entry.id)
        let shown = model.mode == .display && model.displayModels.contains(entry.id)
        Button {
            if !downloaded { model.store.download(entry) } else if model.mode == .display { model.toggleDisplay(entry.id) }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(shown ? Color.accentColor : downloaded ? Color.secondary.opacity(0.2) : .clear)
                RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(downloaded ? 0 : 0.4))
                if let progress {
                    ProgressView(value: progress).progressViewStyle(.circular).controlSize(.mini)
                } else {
                    Image(systemName: shown ? "eye.fill" : downloaded ? "checkmark" : "arrow.down")
                        .foregroundStyle(shown ? Color.white : .secondary)
                }
            }
            .frame(width: 40, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(progress != nil)
        .help(downloaded ? "\(entry.title) — right-click to delete" : "Download \(entry.title)")
        .contextMenu {
            if downloaded { Button("Delete \(entry.title)", role: .destructive) { model.deleteModel(entry.id) } }
        }
    }
}
