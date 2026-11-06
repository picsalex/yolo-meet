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
            .contentShape(RoundedRectangle(cornerRadius: 6))  // a plain button only hits its drawn pixels, e.g. "None"'s text
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let url { Button("Remove", role: .destructive) { model.backgrounds.remove(url) } }
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
        let size = Binding { imgsz ?? Double(model.inference.imgsz) } set: { imgsz = $0 }
        LabeledContent {
            Slider(value: size, in: 160...1280, step: 32) {
                EmptyView()
            } onEditingChanged: { editing in
                guard !editing, let imgsz else { return }
                model.inference.imgsz = Int(imgsz)
                self.imgsz = nil
            }
        } label: {
            Text("Image size")
            Text("\(Int(size.wrappedValue)) px")
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
        Text("Image size sets the frame's long side; RF-DETR and YOLO26 depth keep their fixed export size. RF-DETR has no NMS, so IoU applies to YOLO only.")
            .font(.caption).foregroundStyle(.secondary)
        if model.inference != InferenceSettings() {
            Button("Reset to Defaults") { model.inference = InferenceSettings() }
        }
    }
}
