import SwiftUI
import YoloMeetCore

/// Models by source: Ultralytics' families, other vendors' families, and user-imported models.
struct ModelBrowser: View {
    enum Source: String, CaseIterable { case ultralytics = "Ultralytics", other = "Other", custom = "Custom" }

    @Environment(AppModel.self) private var model
    @AppStorage("modelSource") private var source = Source.ultralytics

    var body: some View {
        Picker("Source", selection: $source) {
            ForEach(Source.allCases, id: \.self) { source in
                Text(onStage(source) ? "\(source.rawValue) •" : source.rawValue)  // a dot marks models on stage
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        switch source {
        case .ultralytics: ModelGrid(families: ModelFamily.allCases.filter(\.isUltralytics))
        case .other: ModelGrid(families: ModelFamily.allCases.filter { !$0.isUltralytics })
        case .custom: CustomModelList()
        }
        if source != .custom, let error = model.store.lastError {
            Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
        }
    }

    private func onStage(_ source: Source) -> Bool {
        model.stageModels.contains { id in
            switch source {
            case .ultralytics: ModelCatalog.entry(id)?.family.isUltralytics == true
            case .other: ModelCatalog.entry(id)?.family.isUltralytics == false
            case .custom: model.custom.model(id) != nil
            }
        }
    }
}

/// One family at a time as a compact grid: tasks are rows, sizes are columns.
private struct ModelGrid: View {
    let families: [ModelFamily]
    @Environment(AppModel.self) private var model
    @AppStorage private var selected: ModelFamily

    /// Each source remembers its own family, defaulting to its newest.
    init(families: [ModelFamily]) {
        self.families = families
        _selected = AppStorage(wrappedValue: families[families.count - 1], "gridFamily.\(families[0].rawValue)")
    }

    var body: some View {
        let family = families.contains(selected) ? selected : families[families.count - 1]
        if families.count > 1 {
            Picker("Family", selection: $selected) {
                ForEach(families, id: \.self) { family in
                    let onStage = model.stageModels.contains { ModelCatalog.entry($0)?.family == family }
                    Text(onStage ? "\(family.title) •" : family.title)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        if let credit = family.credit {
            Text("\(family.title) \(credit)").font(.caption).foregroundStyle(.secondary)
        }
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
///
/// Filled: on stage now (a Display pick, or used by the story's step). Outlined: a Display pick, kept for when
/// Display mode is back.
private struct ModelCell: View {
    @Environment(AppModel.self) private var model
    let entry: CatalogEntry

    var body: some View {
        let progress = model.store.progress[entry.id]
        let downloaded = model.store.downloaded.contains(entry.id) || entry.family.isBuiltIn
        let shown = model.stageModels.contains(entry.id)
        let kept = !shown && model.mode == .story && model.displayModels.contains(entry.id)
        Button {
            if !downloaded { model.store.download(entry) } else if model.mode == .display { model.toggleDisplay(entry.id) }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(shown ? Color.accentColor : downloaded ? Color.secondary.opacity(0.2) : .clear)
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(kept ? Color.accentColor : .secondary.opacity(downloaded ? 0 : 0.4), lineWidth: kept ? 1.5 : 1)
                if let progress {
                    ProgressView(value: progress).progressViewStyle(.circular).controlSize(.mini)
                } else if shown && model.pendingModels.contains(entry.id) {
                    ProgressView().controlSize(.mini).tint(.white)  // loading until its first result
                } else {
                    Image(systemName: shown ? "eye.fill" : kept ? "eye" : downloaded ? "checkmark" : "arrow.down")
                        .foregroundStyle(shown ? Color.white : kept ? Color.accentColor.opacity(0.7) : .secondary)
                }
            }
            .frame(width: 40, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(progress != nil)
        .help(help(downloaded: downloaded, shown: shown, kept: kept))
        .contextMenu {
            if downloaded && !entry.family.isBuiltIn {
                Button("Delete \(entry.title)", role: .destructive) { model.deleteModel(entry.id) }
            }
        }
    }

    private func help(downloaded: Bool, shown: Bool, kept: Bool) -> String {
        guard downloaded else { return "Download \(entry.title)" }
        let state =
            model.mode == .story
            ? shown ? " — used by this story step" : kept ? " — kept for Display mode" : ""
            : ""
        return entry.title + state + (entry.family.isBuiltIn ? "" : " (right-click to delete)")
    }
}

/// Imported models: show/hide on stage, rename, delete, and import more.
private struct CustomModelList: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var error: String?
    @State private var renaming: CustomModel?
    @State private var newName = ""

    var body: some View {
        if model.custom.models.isEmpty {
            Text("Import an Ultralytics or RF-DETR model: PyTorch weights (.pt, .pth) are converted to Core AI, or pick an .aimodel (.zip). The family and task are detected automatically.")
                .font(.callout).foregroundStyle(.secondary)
        }
        ForEach(model.custom.models) { custom in
            HStack {
                VStack(alignment: .leading) {
                    Text(custom.name)
                    Text("\(custom.family) · \(custom.task.title) · \(model.custom.size(of: custom.id).formatted(.byteCount(style: .file)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Rename", systemImage: "pencil") { newName = custom.name; renaming = custom }
                Button("Delete", systemImage: "trash", role: .destructive) { model.deleteCustom(custom.id) }
                if model.pendingModels.contains(custom.id) { ProgressView().controlSize(.small) }
                if model.mode == .display {
                    Toggle("Show on stage", isOn: Binding(
                        get: { model.displayModels.contains(custom.id) }, set: { _ in model.toggleDisplay(custom.id) }))
                        .labelsHidden()
                        .help("Show on stage")
                } else if model.stageModels.contains(custom.id) {
                    Image(systemName: "eye.fill").foregroundStyle(.tint).help("Used by this story step")
                } else if model.displayModels.contains(custom.id) {
                    Image(systemName: "eye").foregroundStyle(Color.accentColor.opacity(0.7)).help("Kept for Display mode")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .toggleStyle(.switch)
        }
        HStack {
            Button("Import Model…", systemImage: "square.and.arrow.down") { importing = true }
            if model.custom.isImporting || model.converter.status != nil { ProgressView().controlSize(.small) }
        }
        .disabled(model.custom.isImporting || model.converter.status != nil)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item, .folder]) { result in
            guard case .success(let url) = result else { return }
            error = nil
            Task {
                do { try await model.importModel(from: url) } catch { self.error = error.localizedDescription }
            }
        }
        .alert("Rename Model", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { renaming.map { model.custom.rename($0.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        if let status = model.converter.status {
            VStack(alignment: .leading) {
                Text(status)
                Text(model.converter.lastLine).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        if model.converter.isInstalled && model.converter.status == nil { ConverterRow() }
    }
}

/// The PyTorch converter's environment: its size, and a way to delete it.
private struct ConverterRow: View {
    @Environment(AppModel.self) private var model
    @State private var size: Int?
    @State private var confirming = false

    var body: some View {
        HStack {
            Text("PyTorch converter")
            Text(size.map { $0.formatted(.byteCount(style: .file)) } ?? "…").foregroundStyle(.secondary)
            Spacer()
            Group {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.converter.directory])
                }
                .help("Show the converter's folder in Finder")
                Button("Remove…", systemImage: "trash", role: .destructive) { confirming = true }
                    .help("Remove the converter's Python environment")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .font(.callout)
        .task { size = await model.converter.environmentSize() }
        .confirmationDialog("Remove the PyTorch converter?", isPresented: $confirming) {
            Button("Remove", role: .destructive) { model.converter.removeEnvironment() }
        } message: {
            Text("Deletes its Python environment. Imported models are kept; the next .pt import sets it up again.")
        }
    }
}
