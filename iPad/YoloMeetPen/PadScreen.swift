import PenLink
import SwiftUI

/// The pad, with a bar under it: the link's state and pairing, the pencil or the eraser, the ink's colors and
/// settings, undo and clear. Until yolo-meet's pairing code has been typed, it asks for it.
struct PadScreen: View {
    @Environment(PadModel.self) private var model
    @State private var showsInk = false
    @State private var showsPairing = false

    var body: some View {
        VStack(spacing: 0) {
            PadView(model: model)
                .aspectRatio(PenLink.size.width / PenLink.size.height, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(.white.opacity(0.25), lineWidth: 1))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            bar
        }
        .padding(12)
        .background(Color(white: 0.08))
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)  // a stroke that starts at the screen's edge is a stroke
        .sheet(isPresented: Binding { model.code == nil || showsPairing } set: { showsPairing = $0 }) {
            PairingSheet(model: model).interactiveDismissDisabled(model.code == nil)
        }
    }

    private var bar: some View {
        HStack(spacing: 20) {
            Circle().fill(isConnected ? .green : .orange).frame(width: 10, height: 10)
            Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Button("Pairing code", systemImage: "key") { showsPairing = true }
                .tint(model.link == .refused ? .orange : nil)
            Spacer()
            ink.disabled(!isConnected)
        }
        .labelStyle(.iconOnly)
        .font(.title2)
        .frame(height: 56)
    }

    /// The ink's controls.
    @ViewBuilder private var ink: some View {
        Picker("Tool", selection: model.setting(\.erases)) {
            Image(systemName: "pencil.tip").accessibilityLabel("Pencil").tag(false)
            Image(systemName: "eraser").accessibilityLabel("Eraser").tag(true)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        ForEach(model.colors, id: \.self) { color in
            Button { model.pick(color) } label: {
                Circle().fill(Color(uiColor: UIColor(hex: color))).frame(width: 30, height: 30)
                    .padding(4)
                    .overlay(Circle().stroke(.white, lineWidth: model.settings.color == color && !model.settings.erases ? 2 : 0))
            }
            .accessibilityLabel("Color \(color)")
        }
        Button("Ink", systemImage: "slider.horizontal.3") { showsInk = true }
            .popover(isPresented: $showsInk) { InkPanel(model: model) }
        Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
        Button("Clear", systemImage: "trash") { model.clear() }
    }

    private var isConnected: Bool { if case .connected = model.link { true } else { false } }

    private var status: String {
        switch model.link {
        case .unpaired: "Type yolo-meet's pairing code to connect"
        case .refused: "yolo-meet has another pairing code: tap the key"
        case .searching: "Looking for yolo-meet: turn on iPad pen in its Draw section"
        case .blocked: "Allow Local Network for yolo-meet pen in Settings"
        case .connected(let name): "Drawing on \(name)"
        }
    }
}

/// The ink's settings that don't fit the bar: the line's width, and whether and when strokes fade.
private struct InkPanel: View {
    let model: PadModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("Width") { Text("\(Int(model.settings.width)) px") }
            Slider(value: model.setting(\.width), in: InkSettings.widths, step: 1)
            Divider()
            Toggle("Fading ink", isOn: model.setting(\.fades))
            if model.settings.fades {
                LabeledContent("Fades after") { Text("\(Int(model.settings.fadeAfter)) s") }
                Slider(value: model.setting(\.fadeAfter), in: InkSettings.stays, step: 1)
            } else {
                Text("Strokes stay until they are undone, erased or cleared").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .font(.body)
        .padding(20)
        .frame(width: 340)
        .preferredColorScheme(.dark)
        .presentationCompactAdaptation(.popover)
    }
}

/// Asks for yolo-meet's pairing code: once, and again if yolo-meet made another.
private struct PairingSheet: View {
    let model: PadModel
    @State private var typed = ""
    @FocusState private var isTyping: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Pair with yolo-meet").font(.title2.bold())
            Text("On the Mac, turn on iPad pen in yolo-meet's Draw section and press Show next to Pairing code. Type the code here once. The link is encrypted with it: without the code, nobody nearby can connect, see the stage or draw on it.")
                .foregroundStyle(.secondary)
            TextField("XXXX-XXXX-XXXX-XXXX-XXXX", text: $typed)
                .font(.system(.title3, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .focused($isTyping)
                .onSubmit(pair)
            if model.link == .refused {
                Text("yolo-meet has another code than the one this iPad has.").foregroundStyle(.orange)
            }
            HStack {
                if model.code != nil { Button("Cancel") { dismiss() } }
                Spacer()
                Button("Pair", action: pair).buttonStyle(.borderedProminent).disabled(PenCode.read(typed) == nil)
            }
        }
        .padding(28)
        .preferredColorScheme(.dark)
        .onAppear { isTyping = true }
    }

    private func pair() {
        if model.pair(typed) { dismiss() }
    }
}
