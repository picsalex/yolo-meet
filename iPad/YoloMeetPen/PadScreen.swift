import PenLink
import SwiftUI

/// The pad, with the link's state and pairing over it and a bar under it. On the bar's left, a deck of large keys, as
/// on a Stream Deck: Display mode, a story (its key opens a page of the stories to pick from) or the whiteboard on
/// stage, hiding the camera, the story's steps while it shows, and the whiteboard's zoom while it shows (tapped, its
/// view goes back to where it started); on its right, the pencil or the eraser, ink that
/// stays or fades, the ink's color (the others show over it when it is tapped), the whiteboard's stickers while it
/// shows (a list over their button), the ink's settings, undo and clear. Until
/// yolo-meet's pairing code has been typed, it asks for it.
struct PadScreen: View {
    @Environment(PadModel.self) private var model
    /// The deck shows the stories to pick from instead of its keys.
    @State private var picksStory = false
    @State private var showsInk = false
    /// The colors to pick from show over the ink's.
    @State private var showsColors = false
    /// The stickers to place show over their button.
    @State private var showsStickers = false
    /// Clear asks first: it can't be undone.
    @State private var confirmsClear = false
    @State private var showsPairing = false

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { space in
                // As large as fits under the link's line. The room it leaves is shared above and under it, so it sits
                // in the middle; the line is centered in the room above, between the screen's top and the pad.
                let width = min(space.size.width, (space.size.height - 32) * PenLink.size.width / PenLink.size.height)
                let height = width * PenLink.size.height / PenLink.size.width
                VStack(spacing: 0) {
                    link.frame(maxWidth: .infinity).frame(height: max(32, (space.size.height - height) / 2))
                    PadView(model: model)
                        .frame(width: width, height: height)
                        .overlay { StickerSelection(model: model, size: CGSize(width: width, height: height)) }
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(.white.opacity(0.25), lineWidth: 1))
                    Spacer(minLength: 0)
                }
                .frame(width: space.size.width, height: space.size.height)
            }
            bar
        }
        .padding([.horizontal, .bottom], 12)
        .background(Color(white: 0.08))
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)  // a stroke that starts at the screen's edge is a stroke
        .sheet(
            isPresented: Binding {
                model.code == nil || showsPairing
            } set: {
                showsPairing = $0
            }
        ) {
            PairingSheet(model: model).interactiveDismissDisabled(model.code == nil)
        }
    }

    /// The link's state, and the pairing code, in a line centered over the pad.
    private var link: some View {
        HStack(spacing: 10) {
            Circle().fill(isConnected ? .green : .orange).frame(width: 8, height: 8)
            Text(status).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            Button("Pairing code", systemImage: "key") { showsPairing = true }
                .labelStyle(.iconOnly)
                .font(.footnote)
                .tint(model.link == .refused ? .orange : nil)
        }
    }

    private var bar: some View {
        HStack(spacing: 20) {
            deck.disabled(!isConnected)
            Spacer(minLength: 0)
            ink.disabled(!isConnected)
        }
        .labelStyle(.iconOnly)
        .font(.title2)
        .frame(height: 64)
        .animation(.snappy(duration: 0.2), value: model.shows)
        .animation(.snappy(duration: 0.2), value: picksStory)
        .onChange(of: isConnected) { if !isConnected { picksStory = false } }
    }

    /// The deck: Display mode, the story and the whiteboard, lit while on stage (Story opens the stories' page; Whiteboard
    /// again goes back to what was under it); hiding
    /// the camera (H), lit while it is hidden, off on the whiteboard, where there's no camera to hide; and while the
    /// story shows, a restart from its first step and its steps as the Mac's arrow keys. Keys large enough for a finger that isn't looked at.
    @ViewBuilder private var deck: some View {
        if picksStory {
            stories
        } else {
            HStack(spacing: 10) {
                DeckKey(
                    "Display", symbol: "camera.viewfinder", isLit: model.shows == .display, isMarked: isUnder(.display)
                ) {
                    model.show(.display)
                }
                DeckKey("Story", symbol: "play.rectangle.fill", isLit: model.shows == .story, isMarked: isUnder(.story))
                {
                    picksStory = true
                }
                DeckKey("Whiteboard", symbol: "rectangle.and.pencil.and.ellipsis", isLit: model.shows == .whiteboard) {
                    model.show(.whiteboard)
                }
                DeckKey("Hide", symbol: "video.slash.fill", isLit: model.cameraHidden) { model.toggleCamera() }
                    .disabled(model.shows == .whiteboard)
                if model.shows == .whiteboard {
                    // How far it is zoomed; tapped, the view goes back to where it started.
                    DeckKey(
                        "\(Int((model.board.zoom * 100).rounded()))%",
                        symbol: "arrow.up.left.and.down.right.magnifyingglass"
                    ) {
                        model.resetBoard()
                    }
                    .disabled(model.board.isHome)
                    .padding(.leading, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                if model.shows == .story {
                    DeckKey("Restart", symbol: "backward.end.fill") { model.restartStory() }
                        .padding(.leading, 8)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    // Off at the story's first step and at its last.
                    DeckKey("Previous", symbol: "chevron.left") { model.step(forward: false) }
                        .disabled(!model.steps.hasPrevious)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    DeckKey("Next", symbol: "chevron.right") { model.step(forward: true) }
                        .disabled(!model.steps.hasNext)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .transition(.opacity)
        }
    }

    /// Whether `mode` is under the whiteboard: its key stays yellow but is off, as what the whiteboard's key goes back
    /// to.
    private func isUnder(_ mode: StageShow) -> Bool { model.shows == .whiteboard && model.mode == mode }

    /// The deck's page of stories, as a Stream Deck folder: Back to the keys, then a key per story, the one open lit
    /// while a story shows. Picking one shows it (where it was if it is the one open) and goes back to the keys.
    private var stories: some View {
        HStack(spacing: 10) {
            DeckKey("Back", symbol: "arrow.backward") { picksStory = false }
            HStack(spacing: 10) {
                ForEach(model.stories, id: \.self) { story in
                    DeckKey(
                        story.title, symbol: "play.rectangle.fill",
                        isLit: model.shows == .story && model.currentStory == story.id,
                        isMarked: isUnder(.story) && model.currentStory == story.id
                    ) {
                        model.open(story: story.id)
                        picksStory = false
                    }
                }
            }
            .padding(.leading, 8)
        }
        .transition(.opacity)
    }

    /// The ink's controls.
    @ViewBuilder private var ink: some View {
        Picker("Tool", selection: model.setting(\.erases)) {
            Image(systemName: "pencil.tip").accessibilityLabel("Pencil").tag(false)
            Image(systemName: "eraser").accessibilityLabel("Eraser").tag(true)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        Toggle(isOn: model.setting(\.fades)) {
            // A pencil whose ink sparkles away.
            Image(systemName: "pencil.tip").padding(.trailing, 8)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "sparkles").font(.caption.weight(.bold)).offset(x: 4, y: -4)
                }
        }
        .toggleStyle(.button)
        .accessibilityLabel("Fading ink")
        // The ink's color alone: the others show over it when it is tapped, so the bar stays as it is.
        Button {
            showsColors = true
        } label: {
            swatch(model.settings.color, size: 30)
        }
        .accessibilityLabel("Colors")
        .popover(isPresented: $showsColors, arrowEdge: .bottom) {
            HStack(spacing: 14) {
                ForEach(model.colors, id: \.self) { color in
                    Button {
                        model.pick(color)
                        showsColors = false
                    } label: {
                        swatch(color, size: 40)
                    }
                    .accessibilityLabel("Color \(color)")
                }
            }
            .padding(16)
            .preferredColorScheme(.dark)
            .presentationCompactAdaptation(.popover)
        }
        if model.shows == .whiteboard, !model.stickers.isEmpty {
            Button("Stickers", systemImage: "face.smiling") { showsStickers = true }
                .popover(isPresented: $showsStickers, arrowEdge: .bottom) { stickerList }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
        Button("Ink", systemImage: "slider.horizontal.3") {
            showsInk = true
        }
        .popover(isPresented: $showsInk) { InkPanel(model: model) }
        Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
        Button("Clear", systemImage: "trash") { confirmsClear = true }
            .confirmationDialog(
                model.shows == .whiteboard ? "Clear the whiteboard?" : "Clear the ink?", isPresented: $confirmsClear,
                titleVisibility: .visible
            ) {
                Button("Clear", role: .destructive) { model.clear() }
            } message: {
                Text(
                    model.shows == .whiteboard
                        ? "All its ink and its unlocked stickers leave. This can't be undone."
                        : "All the ink on stage leaves. This can't be undone.")
            }
    }

    /// The stickers to place on the whiteboard, as keys: one tapped is placed in the middle of its view.
    private var stickerList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stickers").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                ForEach(model.stickers, id: \.self) { sticker in
                    Button {
                        model.place(sticker: sticker.id)
                        showsStickers = false
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: sticker.symbol).font(.title2)
                            Text(sticker.title).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        .frame(width: 96, height: 80)
                    }
                    .buttonStyle(DeckPress(isLit: false))
                    .accessibilityLabel(sticker.title)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
        .preferredColorScheme(.dark)
        .presentationCompactAdaptation(.popover)
    }

    /// A color to pick, as it draws on stage now (white is near-black on the whiteboard), ringed when it is the ink's
    /// and the pencil has it.
    private func swatch(_ color: String, size: CGFloat) -> some View {
        Circle().fill(Color(uiColor: UIColor(hex: PenLink.ink(color, onWhiteboard: model.shows == .whiteboard))))
            .frame(width: size, height: size)
            .padding(4)
            .overlay(
                Circle().stroke(.white, lineWidth: model.settings.color == color && !model.settings.erases ? 2 : 0))
    }

    private var isConnected: Bool { if case .connected = model.link { true } else { false } }

    private var status: String {
        switch model.link {
        case .unpaired: "Type yolo-meet's pairing code to connect"
        case .refused: "yolo-meet has another pairing code: tap the key"
        case .searching: "Looking for yolo-meet: turn on iPad pen in its Draw section"
        case .blocked: "Allow Local Network for yolo-meet pen in Settings"
        case .outdated: "yolo-meet on the Mac and this app are different versions: update both"
        case .connected(let name): "Drawing on \(model.hostName ?? name)"
        }
    }
}

/// The selected sticker, as on Miro: a frame around it with handles at its corners (none while it is locked), and over
/// it (under it when there's no room above) its toolbar: its kind's actions, the lock, and a menu with Duplicate and
/// Delete. Only the toolbar takes touches: the pad under it still draws and drags.
private struct StickerSelection: View {
    let model: PadModel
    /// The pad's size.
    let size: CGSize

    var body: some View {
        if model.shows == .whiteboard, let sticker = model.placed.first(where: { $0.id == model.selected }) {
            let scale = size.width / PenLink.size.width
            let frame = CGRect(
                x: sticker.x * scale, y: size.height - (sticker.y + sticker.height) * scale,
                width: sticker.width * scale, height: sticker.height * scale)
            ZStack {
                Rectangle().stroke(Self.blue, lineWidth: 1.5)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                if !sticker.isLocked {
                    ForEach(0..<4, id: \.self) { corner in
                        Circle().fill(.white).stroke(.gray, lineWidth: 1.5).frame(width: 12, height: 12)
                            .position(
                                x: corner % 2 == 0 ? frame.minX : frame.maxX, y: corner < 2 ? frame.minY : frame.maxY)
                    }
                }
            }
            .allowsHitTesting(false)
            .overlay {
                toolbar(sticker)
                    .fixedSize()
                    .position(
                        x: min(max(frame.midX, 170), size.width - 170),
                        y: frame.minY > 70 ? frame.minY - 38 : frame.maxY + 38)
            }
            .frame(width: size.width, height: size.height)
        }
    }

    /// Miro's selection blue.
    private static let blue = Color(red: 0.26, green: 0.38, blue: 1)

    private func toolbar(_ sticker: PlacedSticker) -> some View {
        HStack(spacing: 0) {
            ForEach(sticker.actions, id: \.self) { action in
                Button {
                    model.edit(.action(action.id))
                } label: {
                    Label(action.title, systemImage: action.symbol).padding(.horizontal, 16).frame(maxHeight: .infinity)
                }
                Divider()
            }
            Button {
                model.edit(.lock(!sticker.isLocked))
            } label: {
                Image(systemName: sticker.isLocked ? "lock.fill" : "lock.open")
                    .frame(width: 52).frame(maxHeight: .infinity)
            }
            .accessibilityLabel(sticker.isLocked ? "Unlock" : "Lock")
            Divider()
            Menu {
                Button("Duplicate", systemImage: "plus.square.on.square") { model.edit(.duplicate) }
                Button("Delete", systemImage: "trash", role: .destructive) { model.edit(.delete) }
                    .disabled(sticker.isLocked)
            } label: {
                Image(systemName: "ellipsis").rotationEffect(.degrees(90))
                    .frame(width: 52).frame(maxHeight: .infinity)
            }
            .accessibilityLabel("More")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.plain)
        .font(.body.weight(.medium))
        .foregroundStyle(.black)
        .frame(height: 52)
        .background(Capsule().fill(.white).shadow(color: .black.opacity(0.25), radius: 10, y: 3))
        .environment(\.colorScheme, .light)
    }
}

/// A key of the deck, as on a Stream Deck: a symbol over its name on a square-ish key, in Ultralytics' yellow while
/// what it shows is on stage. A marked key (the mode under the whiteboard) stays yellow but is off, dimmed like any
/// key that is: the whiteboard's key goes back to it.
private struct DeckKey: View {
    let title: String
    let symbol: String
    let isLit: Bool
    let isMarked: Bool
    let action: () -> Void

    init(
        _ title: String, symbol: String, isLit: Bool = false, isMarked: Bool = false, action: @escaping () -> Void
    ) {
        (self.title, self.symbol, self.isLit, self.isMarked, self.action) = (title, symbol, isLit, isMarked, action)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3.weight(.semibold))
                Text(title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 4)
            .frame(width: 92, height: 60)
        }
        .buttonStyle(DeckPress(isLit: isLit || isMarked))
        .disabled(isMarked)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isLit ? .isSelected : [])
    }
}

/// A deck key's face: dark, lit yellow, dimmed while off, and pressed in while touched.
private struct DeckPress: ButtonStyle {
    let isLit: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isLit ? Color.black : Color.white)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isLit ? Color(uiColor: UIColor(hex: "E1FF25")) : Color(white: 0.2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.white.opacity(configuration.isPressed ? 0.6 : 0.12), lineWidth: 1))
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// The ink's settings that don't fit the bar: the line's width, and how long fading ink stays (the bar switches it).
private struct InkPanel: View {
    let model: PadModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("Width") { Text("\(Int(model.settings.width)) px") }
            Slider(value: model.setting(\.width), in: InkSettings.widths, step: 1)
            Divider()
            LabeledContent("Fading ink fades after") { Text("\(Int(model.settings.fadeAfter)) s") }
            Slider(value: model.setting(\.fadeAfter), in: InkSettings.stays, step: 1)
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
            Text(
                "On the Mac, turn on iPad pen in yolo-meet's Draw section and press Show next to Pairing code. Type the code here once. The link is encrypted with it: without the code, nobody nearby can connect, see the stage or draw on it."
            )
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
