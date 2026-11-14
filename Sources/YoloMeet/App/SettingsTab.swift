import PenLink
import SwiftUI

/// The panel's Settings tab, for setup: pairing the iPad pen, clicker keys, and the downloaded models' storage.
struct SettingsTab: View {
    @Environment(AppModel.self) private var model
    /// The pairing code is only readable while asked for: the panel may be on a shared screen.
    @State private var showsCode = false
    @State private var confirmingDeleteAll = false

    var body: some View {
        @Bindable var model = model
        let pen = model.pen
        Section("iPad Pen") {
            PenToggle()
            LabeledContent {
                Text(showsCode ? PenCode.shown(pen.code) : "••••-••••-••••-••••-••••").monospaced().textSelection(.enabled)
                Button(showsCode ? "Hide" : "Show") { showsCode.toggle() }
                Button("New") { pen.renewCode() }
                    .help("Makes another code: every iPad has to be given it")
            } label: {
                Text("Pairing code")
                Text("Typed once in the pen app. The link is encrypted with it")
            }
        }

        Section("Clicker") {
            Toggle(isOn: $model.clickerKeys) {
                Text("Clicker keys in other apps")
                Text("←/→ and Page Up/Down step the story while Meet is in front")
            }
            if model.clickerKeys && !ClickerKeys.hasPermission {
                Text(
                    "macOS needs yolo-meet allowed in System Settings › Privacy & Security › Accessibility (again after a rebuild). Then turn this off and on."
                )
                .foregroundStyle(.secondary)
            }
        }

        Section("Storage") {
            LabeledContent {
                Button("Delete All…", role: .destructive) { confirmingDeleteAll = true }
                    .disabled(model.store.downloaded.isEmpty)
            } label: {
                Text("Downloaded models")
                Text(model.store.downloaded.isEmpty ? "None" : "\(model.store.downloaded.count) models and their compiled copies")
            }
            .confirmationDialog("Delete all downloaded models?", isPresented: $confirmingDeleteAll) {
                Button("Delete All", role: .destructive) { model.deleteAllModels() }
            } message: {
                Text("Removes \(model.store.downloaded.count) models and their compiled copies. Imported models are kept.")
            }
        }
    }
}
