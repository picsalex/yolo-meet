import Observation
import PenLink
import SwiftUI

/// The pad's state: the link to yolo-meet, the ink's settings (the same as in yolo-meet's panel, and changed from
/// either), the stage's picture, and the pad's own copy of the strokes it drew, which stays as it is on stage: a
/// stroke leaves the pad when yolo-meet says it left the stage.
///
/// The picture is a moment behind the pen, so the pad draws its own copy of a stroke over it until a picture shows the
/// stroke whole. Without pictures (the stage isn't being drawn), it draws them all.
@Observable
final class PadModel {
    struct Stroke {
        let id: Int
        let color: String
        /// In ink points, each with the line's width there.
        var points: [(at: CGPoint, width: CGFloat)]
        /// The stage's picture shows the stroke whole: the pad no longer draws its copy.
        var isPictured = false
    }

    private(set) var link = PenClient.State.unpaired
    /// The Mac's name, once connected (it says it inside the link; Bonjour only shows the app's name).
    private(set) var hostName: String?
    /// yolo-meet's pairing code, typed once and kept in the keychain: the link is encrypted with it (`PenCode`).
    private(set) var code = Keychain.read("pairing code")
    /// The ink's settings, and the colors to pick from (hex).
    private(set) var settings = InkSettings(color: "E1FF25", width: 6, fades: false, fadeAfter: 4, erases: false)
    private(set) var colors: [String] = []
    /// What the stage shows: Display mode's models, a story, or the whiteboard (`StageShow`).
    private(set) var shows = StageShow.display
    /// The mode under the whiteboard: Display mode or the story, what the whiteboard's key goes back to.
    private(set) var mode = StageShow.display
    /// The stage hides the camera image (H on the Mac).
    private(set) var cameraHidden = false
    /// The stories yolo-meet can show, and the one open.
    private(set) var stories: [StoryInfo] = []
    private(set) var currentStory: String?
    /// The stickers yolo-meet can place on the whiteboard (none from an older yolo-meet).
    private(set) var stickers: [StickerInfo] = []
    /// The stickers on the whiteboard, where they are on stage (ink points), as yolo-meet last said; one being dragged
    /// is moved here at once.
    private(set) var placed: [PlacedSticker] = []
    /// The sticker selected with a tap: its toolbar shows over it.
    private(set) var selected: Int?
    /// When a sticker was asked for (placed or duplicated): the next new one is selected, if it comes soon (yolo-meet
    /// ignores the ask when the whiteboard has just gone).
    @ObservationIgnored private var addingSince: Date?
    /// The sticker being dragged or resized here, where and as large as the finger has made it (ink points on stage),
    /// and once the finger has lifted, until when it waits: yolo-meet's answers lag the finger, so until one has caught
    /// up with it (or that time has passed) the sticker stays here rather than jumping back to what yolo-meet had.
    @ObservationIgnored private var held: (sticker: PlacedSticker, until: Date?)?
    /// The story's keys held down on the deck (the space bar's and Command's on the Mac): lit while held.
    private(set) var heldKeys: Set<StoryKey> = []
    /// Whether the story on stage has a step before the one it is on, and one after (both, until yolo-meet says).
    private(set) var steps = (hasPrevious: true, hasNext: true)
    /// How far the whiteboard is zoomed in (1 as it started), and whether its view is where it started.
    private(set) var board = (zoom: 1.0, isHome: true)
    /// Where the eraser is over the pad (ink points), while the pen erases or hovers with it.
    @ObservationIgnored private(set) var eraser: CGPoint? {
        didSet {
            let reach = settings.eraserRadius + 2
            for point in [oldValue, eraser] {
                if let point { redraw?(CGRect(origin: point, size: .zero).insetBy(dx: -reach, dy: -reach)) }
            }
        }
    }
    @ObservationIgnored private(set) var strokes: [Stroke] = []
    /// The stage's latest picture from yolo-meet, if any.
    @ObservationIgnored private(set) var picture: UIImage? { didSet { show?(picture) } }
    /// Asks the canvas to draw its ink again: all of it (nil), or around a rectangle in ink points.
    @ObservationIgnored var redraw: ((CGRect?) -> Void)?
    /// Asks the canvas to show the stage's picture, or none (nil).
    @ObservationIgnored var show: ((UIImage?) -> Void)?
    /// Pictures received and the last one shown, by number: one that is ready after a later one isn't shown.
    @ObservationIgnored private var pictures = (received: 0, shown: 0)
    @ObservationIgnored private let client = PenClient()
    /// The pen is on the pad: drawing a stroke, or erasing.
    @ObservationIgnored private var isDrawing = false
    @ObservationIgnored private var isErasing = false

    init() {
        client.changed = { [weak self] state in
            guard let self else { return }
            self.link = state
            if case .connected = state {
                self.client.send(.hello(name: UIDevice.current.name))
            } else {
                (self.hostName, self.shows, self.mode, self.cameraHidden) = (nil, .display, .display, false)
                (self.board, self.steps) = ((1, true), (true, true))
                (self.placed, self.selected, self.held, self.addingSince) = ([], nil, nil, nil)
                self.heldKeys = []
                self.end()
                self.forgetPicture()
            }
        }
        client.received = { [weak self] in self?.handle($0) }
    }

    func start() { if let code { client.start(code: code) } }
    func stop() { client.stop() }

    /// Takes yolo-meet's pairing code as it was typed, if that is a whole code, and connects with it.
    func pair(_ typed: String) -> Bool {
        guard let code = PenCode.read(typed) else { return false }
        self.code = code
        Keychain.save(code, as: "pairing code")
        client.stop()
        client.start(code: code)
        return true
    }

    private func handle(_ message: HostMessage) {
        switch message {
        case .hello(let name):
            hostName = String(name.prefix(40))
        case .settings(let settings, let colors):
            if settings.erases != self.settings.erases { end() }  // the pen's touch was for the other tool
            (self.settings, self.colors) = (settings, colors)
            if !settings.erases { eraser = nil }
        case .cameraHidden(let hidden): cameraHidden = hidden
        case .board(let zoom, let isHome): board = (zoom, isHome)
        case .steps(let hasPrevious, let hasNext): steps = (hasPrevious, hasNext)
        case .stickers(let stickers): self.stickers = Array(stickers.prefix(48))
        case .placed(let placed):
            // A sticker placed or duplicated from here is selected when it comes, so it can be moved at once.
            let new = placed.map(\.id).filter { id in !self.placed.contains { $0.id == id } }
            self.placed = holding(Array(placed.prefix(200)))
            if let since = addingSince, Date().timeIntervalSince(since) > 2 { addingSince = nil }
            if addingSince != nil, let newest = new.max() {
                (selected, addingSince) = (newest, nil)
            } else if let selected, !placed.contains(where: { $0.id == selected }) {
                self.selected = nil
            }
        case .stories(let stories, let current): (self.stories, currentStory) = (Array(stories.prefix(24)), current)
        case .shows(let shows, let mode):
            (self.shows, self.mode) = (shows, mode)
            redraw?(nil)  // white ink is drawn another color on the whiteboard
            if shows != .story { for key in heldKeys { hold(key, false) } }
        case .ink(let ids): keep { ids.contains($0.id) }
        case .removed(let ids): keep { !ids.contains($0.id) }
        case .picture(let jpeg, let through):
            pictures.received += 1
            let number = pictures.received
            Task {
                // Decoded off the main thread: the pen is read on it.
                guard let image = await UIImage(data: jpeg)?.byPreparingForDisplay(), number > pictures.shown else {
                    return
                }
                (pictures.shown, picture) = (number, image)
                guard let through, let last = strokes.firstIndex(where: { $0.id == through }),
                    strokes[...last].contains(where: { !$0.isPictured })
                else { return }
                for index in 0...last { strokes[index].isPictured = true }
                redraw?(nil)
            }
        }
    }

    /// The link dropped: the pad draws all its strokes itself again.
    private func forgetPicture() {
        (pictures.shown, picture) = (pictures.received, nil)  // nor is a picture still being decoded shown
        for index in strokes.indices { strokes[index].isPictured = false }
        redraw?(nil)
    }

    private func keep(_ isKept: (Stroke) -> Bool) {
        if isDrawing, let current = strokes.last, !isKept(current) { isDrawing = false }
        strokes.removeAll { !isKept($0) }
        redraw?(nil)
    }

    // The pen, in ink points. `force` is 1 for an average press.

    func begin(at point: CGPoint, force: Double) {
        guard case .connected = link else { return }
        let id = Int.random(in: 1...Int(Int32.max))  // unlike any stroke still on stage from an earlier launch
        if settings.erases {
            // Erasing happens on stage: the pad only shows where the eraser is.
            (isErasing, eraser) = (true, point)
        } else {
            strokes.append(
                Stroke(id: id, color: settings.color, points: [(point, settings.width * PenLink.press(force: force))]))
            isDrawing = true
            redraw?(CGRect(origin: point, size: .zero))
        }
        client.send(.down(id: id, x: rounded(point.x), y: rounded(point.y), force: rounded(force, to: 100)))
    }

    func move(to point: CGPoint, force: Double) {
        if isErasing {
            eraser = point
        } else if isDrawing, let last = strokes.last?.points.last {
            strokes[strokes.count - 1].points.append((point, settings.width * PenLink.press(force: force)))
            redraw?(CGRect(origin: last.at, size: .zero).union(CGRect(origin: point, size: .zero)))
        } else {
            return
        }
        client.send(.move(x: rounded(point.x), y: rounded(point.y), force: rounded(force, to: 100)))
    }

    func end() {
        guard isDrawing || isErasing else { return }
        if isErasing { eraser = nil }
        (isDrawing, isErasing) = (false, false)
        client.send(.up)
    }

    /// The pen is over the pad at `point` (`height` from 0 at the glass to 1), or left it (nil).
    func hover(at point: CGPoint?, height: Double = 0) {
        if settings.erases, !isErasing { eraser = point }
        if let point {
            client.send(.hover(x: rounded(point.x), y: rounded(point.y), height: rounded(height, to: 100)))
        } else {
            client.send(.hoverEnded)
        }
    }

    // Actions: yolo-meet does them and tells the pad what changed.

    func undo() { client.send(.undo) }
    func clear() { client.send(.clear) }
    /// The story's next step on stage, or the one before: what the Mac's arrow keys do.
    func step(forward: Bool) { client.send(.step(forward: forward)) }
    /// The story on stage starts over, at its first step.
    func restartStory() { client.send(.restartStory) }
    /// The story (where it was) or the whiteboard on stage. The deck's keys light when yolo-meet says it did it
    /// (`shows`), not before: a key that stays dark means it didn't (e.g. an older yolo-meet).
    func show(_ show: StageShow) { client.send(.show(show)) }
    /// The story `id` on stage: where it was if it is the one open, else from its start; lit when yolo-meet says so.
    func open(story id: String) { client.send(.story(id: id)) }
    /// Hides the stage's camera image, or shows it again, as H does on the Mac; lit when yolo-meet says so.
    func toggleCamera() { client.send(.hideCamera(!cameraHidden)) }
    /// Fingers zoom the whiteboard by `scale` around `point` and slide it by `offset` (ink points).
    func moveBoard(zoom scale: Double = 1, around point: CGPoint = .zero, by offset: CGVector = .zero) {
        guard shows == .whiteboard, scale != 1 || offset != .zero else { return }
        client.send(
            .moveBoard(
                scale: rounded(scale, to: 10_000), x: rounded(point.x), y: rounded(point.y), dx: rounded(offset.dx),
                dy: rounded(offset.dy)))
    }
    /// The whiteboard's view goes back to where it started.
    func resetBoard() { client.send(.resetBoard) }
    /// A finger on the story, as the mouse on the Mac's stage (points in ink points).
    func touch(_ touch: StoryTouch) {
        guard shows == .story else { return }
        switch touch {
        case .down(let x, let y): client.send(.touch(.down(x: rounded(x), y: rounded(y))))
        case .move(let x, let y): client.send(.touch(.move(x: rounded(x), y: rounded(y))))
        case .zoom(let scale, let x, let y):
            guard scale != 1 else { return }
            client.send(.touch(.zoom(scale: rounded(scale, to: 10_000), x: rounded(x), y: rounded(y))))
        case .up, .zoomEnded: client.send(.touch(touch))
        }
    }
    /// A story key held down on the deck, or let go: the Mac's space bar or Command, for the fingers.
    func hold(_ key: StoryKey, _ down: Bool) {
        guard down != heldKeys.contains(key) else { return }
        if down { heldKeys.insert(key) } else { heldKeys.remove(key) }
        client.send(.hold(key, down))
    }
    /// The sticker `id` is placed in the middle of the whiteboard's view.
    func place(sticker id: String) {
        addingSince = Date()
        client.send(.sticker(id: id))
    }

    /// The topmost sticker at `point` (ink points), if any.
    func sticker(at point: CGPoint) -> PlacedSticker? {
        placed.last { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(point) }
    }

    /// Selects the sticker `id` (its toolbar shows over it), or none.
    func select(_ id: Int?) { selected = id }

    /// Drags the sticker `id` by `offset` (ink points): its frame here follows at once, the stage's picture a moment
    /// later. It moves here by what is sent, so it ends where yolo-meet puts it.
    func moveSticker(_ id: Int, by offset: CGVector) {
        let (dx, dy) = (rounded(offset.dx), rounded(offset.dy))
        guard let index = placed.firstIndex(where: { $0.id == id }), !placed[index].isLocked, dx != 0 || dy != 0 else {
            return
        }
        placed[index].x += dx
        placed[index].y += dy
        held = (placed[index], nil)
        client.send(.moveSticker(id: id, dx: dx, dy: dy))
    }

    /// A handle of the sticker `id` is dragged: its frame becomes `frame` (ink points, its height kept to its shape by
    /// yolo-meet), here at once, the stage's picture a moment later.
    func resizeSticker(_ id: Int, to frame: CGRect) {
        guard let index = placed.firstIndex(where: { $0.id == id }), !placed[index].isLocked else { return }
        let (x, y, width) = (rounded(frame.minX), rounded(frame.minY), rounded(frame.width))
        let height = rounded(width * placed[index].height / max(placed[index].width, 1))
        guard x != placed[index].x || y != placed[index].y || width != placed[index].width else { return }
        (placed[index].x, placed[index].y, placed[index].width, placed[index].height) = (x, y, width, height)
        held = (placed[index], nil)
        client.send(.resizeSticker(id: id, x: x, y: y, width: width))
    }

    /// The finger dragging the sticker `id` or one of its handles lifted: it stays where it was put until yolo-meet
    /// catches up.
    func endDrag(_ id: Int) {
        if held?.sticker.id == id { held?.until = Date().addingTimeInterval(1) }
    }

    /// yolo-meet's stickers, with the one being dragged where the finger put it (`held`) until yolo-meet has caught up
    /// with the finger, once it has lifted.
    private func holding(_ placed: [PlacedSticker]) -> [PlacedSticker] {
        guard let held else { return placed }
        let kept = held.sticker
        guard let index = placed.firstIndex(where: { $0.id == kept.id }) else {
            self.held = nil  // deleted meanwhile
            return placed
        }
        let caughtUp = [
            (placed[index].x, kept.x), (placed[index].y, kept.y), (placed[index].width, kept.width),
            (placed[index].height, kept.height),
        ].allSatisfy { abs($0 - $1) < 0.5 }
        if let until = held.until, caughtUp || Date() > until {
            self.held = nil
            return placed
        }
        var placed = placed
        (placed[index].x, placed[index].y, placed[index].width, placed[index].height) = (
            kept.x, kept.y, kept.width, kept.height
        )
        return placed
    }

    /// Changes the selected sticker from its toolbar.
    func edit(_ edit: StickerEdit) {
        guard let selected else { return }
        if edit == .duplicate { addingSince = Date() }
        client.send(.editSticker(id: selected, edit))
    }

    // Settings: the pad changes them at once, and yolo-meet answers only when it keeps something else.

    func change(_ edit: (inout InkSettings) -> Void) {
        var changed = settings
        edit(&changed)
        guard changed != settings else { return }
        if changed.erases != settings.erases { end() }
        settings = changed
        if !settings.erases { eraser = nil }
        client.send(.set(settings))
    }

    /// One of the settings, for a control.
    func setting<Value>(_ path: WritableKeyPath<InkSettings, Value>) -> Binding<Value> {
        Binding {
            self.settings[keyPath: path]
        } set: { value in
            self.change { $0[keyPath: path] = value }
        }
    }

    /// Picking a color takes the pencil back.
    func pick(_ color: String) { change { ($0.color, $0.erases) = (color, false) } }

    /// The color after the ink's among the colors to pick from.
    func pickNext() {
        guard let index = colors.firstIndex(of: settings.color) else { return }
        pick(colors[(index + 1) % colors.count])
    }

    /// From the pencil to the eraser, and back.
    func switchTool() { change { $0.erases.toggle() } }

    /// Short numbers make short messages: tenths of an ink point are finer than the stage shows.
    private func rounded(_ value: Double, to parts: Double = 10) -> Double { (value * parts).rounded() / parts }
}
