import AppKit
import Observation
import PenLink
import SystemConfiguration

/// The iPad pen app's Apple Pencil on the stage: while it's on, yolo-meet can be found by the app (the pad) on the
/// network they share, or straight from a nearby iPad when they share none, and the pad's strokes are drawn as ink
/// (`Drawing`). The pad shows the stage with its own ink over it, so it is told which of its strokes left the stage
/// and is sent the stage's picture (`StagePicture`). The ink's settings are the panel's, and the pad can change them
/// too. The pad also steps through the story, like the arrow keys, switches the stage between the story and the
/// whiteboard, and hides the camera image, as H does (its deck). Its fingers zoom and slide the whiteboard; on the
/// story they are a second mouse (`fingers`), and its deck holds the space bar and Command for them (`StageKeys`).
@Observable
final class PenInput {
    var isOn = UserDefaults.standard.bool(forKey: "penOn") {
        didSet {
            UserDefaults.standard.set(isOn, forKey: "penOn")
            if isOn { host.start(code: code) } else { host.stop() }
        }
    }
    /// The pairing code: the pen app is given it once, and the link is closed to whoever doesn't have it (`PenCode`).
    /// It is kept with the app's settings on this Mac.
    private(set) var code = UserDefaults.standard.string(forKey: "penCode").flatMap(PenCode.read) ?? PenCode.new() {
        didSet {
            UserDefaults.standard.set(code, forKey: "penCode")
            if isOn { host.start(code: code) }  // starts again: the pad that had the old code is let go
        }
    }
    /// The pad connected, by its name.
    private(set) var pad: String?
    /// When the pad last said anything (the pen hovering, drawing, or a change): the stage's pictures slow down
    /// while it has been quiet a while.
    @ObservationIgnored private(set) var lastHeard: TimeInterval = 0
    @ObservationIgnored private let host = PenHost()
    @ObservationIgnored private let drawing: Drawing
    @ObservationIgnored private let keys: StageKeys
    /// The pad's fingers on the story, as a mouse on the stage: the stage reads them every frame, after the mouse.
    @ObservationIgnored let fingers = MouseGestures(hand: Pointer.pad)
    /// Stage points per ink point, as the stage last drew: the pad's fingers are in ink points.
    @ObservationIgnored var stageUnit: CGFloat = 1
    /// The finger on the story: what it does (chosen by the key held when it touched down), and where it is (stage
    /// points).
    @ObservationIgnored private var finger: (kind: Finger, at: CGPoint)?
    private enum Finger { case drag, point, fist }
    /// Whether two fingers are zooming the story.
    @ObservationIgnored private var zooming = false
    /// What the stage shows, and the mode under the whiteboard (Display mode or the story): the pad is told when either
    /// changes.
    @ObservationIgnored var shows = (StageShow.display, mode: StageShow.display) {
        didSet {
            guard shows != oldValue else { return }
            host.send(.shows(shows.0, mode: shows.mode))
            if shows.0 != .story { letGo() }
        }
    }
    /// Whether the story has a step before the one on stage, and one after: the pad is told when either changes.
    @ObservationIgnored var steps = (hasPrevious: false, hasNext: true) {
        didSet { if steps != oldValue { host.send(.steps(hasPrevious: steps.hasPrevious, hasNext: steps.hasNext)) } }
    }
    /// Whether the camera image is hidden (H): the pad is told when it changes.
    @ObservationIgnored var cameraHidden = false {
        didSet { if cameraHidden != oldValue { host.send(.cameraHidden(cameraHidden)) } }
    }
    /// The story open: the pad's deck lights it among `stories`.
    @ObservationIgnored var story: String {
        didSet { if story != oldValue { host.send(.stories(stories, current: story)) } }
    }
    @ObservationIgnored private let stories: [StoryInfo]
    /// The pad asked for the story's next step (true) or the one before.
    @ObservationIgnored private let onStep: (Bool) -> Void
    /// The pad asked for the story or the whiteboard.
    @ObservationIgnored private let onShow: (StageShow) -> Void
    /// The pad asked for a story, by id.
    @ObservationIgnored private let onStory: (String) -> Void
    /// The pad asked for the story to start over.
    @ObservationIgnored private let onRestart: () -> Void
    /// The pad asked to hide the camera image (true) or show it.
    @ObservationIgnored private let onHide: (Bool) -> Void
    /// The pad's change to the settings is being made: it isn't sent back to it.
    @ObservationIgnored private var isApplying = false
    /// The whiteboard's view as the pad was last told it: its zoom (to the percent) and whether it is home.
    @ObservationIgnored private var toldBoard: HostMessage?
    /// The whiteboard's stickers as the pad was last told them.
    @ObservationIgnored private var toldStickers: [PlacedSticker]?

    init(
        drawing: Drawing, keys: StageKeys, stories: [StoryInfo], story: String, onStep: @escaping (Bool) -> Void,
        onShow: @escaping (StageShow) -> Void, onStory: @escaping (String) -> Void, onRestart: @escaping () -> Void,
        onHide: @escaping (Bool) -> Void
    ) {
        (self.drawing, self.keys, self.stories, self.story) = (drawing, keys, stories, story)
        (self.onStep, self.onShow, self.onStory, self.onRestart, self.onHide) = (
            onStep, onShow, onStory, onRestart, onHide
        )
        host.received = { [weak self] in self?.handle($0) }
        host.changed = { [weak self] connected in
            guard let self else { return }
            // Whichever way it changed, the pen isn't on the pad: a new pad says hello before it draws.
            (self.pad, self.lastHeard) = (nil, CACurrentMediaTime())
            self.drawing.released(.pen, time: CACurrentMediaTime())
            self.drawing.hover(at: nil)
            self.letGo()
            if connected {
                self.host.send(.hello(name: Self.macName))
                self.sendSettings()
                self.host.send(.shows(self.shows.0, mode: self.shows.mode))
                self.host.send(.cameraHidden(self.cameraHidden))
                self.host.send(.steps(hasPrevious: self.steps.hasPrevious, hasNext: self.steps.hasNext))
                self.host.send(.stories(self.stories, current: self.story))
                self.host.send(.stickers(Stickers.all.map(\.info)))
                self.host.send(.ink(ids: self.drawing.penStrokes))
                (self.toldBoard, self.toldStickers) = (nil, nil)
                self.sendBoard()
                self.sendStickers()
            }
        }
        drawing.changed = { [weak self] change in
            switch change {
            case .settings: if self?.isApplying == false { self?.sendSettings() }
            case .removed(let ids): self?.host.send(.removed(ids: ids))
            case .page:
                self.map { $0.host.send(.ink(ids: $0.drawing.penStrokes)) }
                self?.sendStickers()
            case .board:
                self?.sendBoard()
                self?.sendStickers()
            case .stickers: self?.sendStickers()
            }
        }
        UserDefaults.standard.set(code, forKey: "penCode")  // the first one is made here
        if isOn { host.start(code: code) }
    }

    /// Sends the pad the stage's picture, which shows the pen's strokes up to `through` whole (`Drawing.penFinished`
    /// when it was taken). `done` is called once it left, or at once without a pad.
    func send(picture jpeg: Data, through: Int?, then done: @escaping @MainActor () -> Void) {
        host.send(.picture(jpeg: jpeg, through: through), then: done)
    }

    /// This Mac's name (as in Sharing settings), for the pad's status: told only to a pad that has the code.
    private static var macName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?).map { String($0.prefix(40)) } ?? "your Mac"
    }

    /// Makes another pairing code: every iPad has to be given it.
    func renewCode() { code = PenCode.new() }

    /// Tells the pad where the whiteboard's stickers are on stage, when that changed.
    private func sendStickers() {
        let placed = drawing.placedStickers
        guard placed != toldStickers else { return }
        toldStickers = placed
        host.send(.placed(placed))
    }

    /// Tells the pad the whiteboard's zoom, when it shows another percent or went home or left it.
    private func sendBoard() {
        let board = drawing.board
        let message = HostMessage.board(zoom: (board.zoom * 100).rounded() / 100, isHome: board.isHome)
        guard message != toldBoard else { return }
        toldBoard = message
        host.send(message)
    }

    private func sendSettings() { host.send(.settings(drawing.settings, colors: Drawing.colors.map(\.1))) }

    /// The pad changed the ink's settings. What it asks is kept to what the panel could set, and it only hears back
    /// when that differs: its own controls are ahead of an answer while they move.
    private func apply(_ wanted: InkSettings) {
        func kept(_ value: Double, in range: ClosedRange<Double>) -> Double {
            min(max(value.rounded(), range.lowerBound), range.upperBound)
        }
        isApplying = true
        if Drawing.colors.contains(where: { $0.1 == wanted.color }) { drawing.color = wanted.color }
        drawing.width = kept(wanted.width, in: InkSettings.widths)
        drawing.fadeAfter = kept(wanted.fadeAfter, in: InkSettings.stays)
        (drawing.fades, drawing.erases) = (wanted.fades, wanted.erases)
        isApplying = false
        if drawing.settings != wanted { sendSettings() }
    }

    /// What the pad says is only trusted to be ink: points are kept near the stage, and settings to the panel's.
    private func handle(_ message: PadMessage) {
        lastHeard = CACurrentMediaTime()
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: min(max(x, -200), PenLink.size.width + 200), y: min(max(y, -200), PenLink.size.height + 200))
        }
        switch message {
        case .hello(let name): pad = String(name.prefix(40))
        case .hover(let x, let y, let height): drawing.hover(at: point(x, y), height: height)
        case .hoverEnded: drawing.hover(at: nil)
        case .down(let id, let x, let y, let force):
            drawing.pressed(at: point(x, y), press: PenLink.press(force: force), from: .pen, id: id)
        case .move(let x, let y, let force):
            drawing.moved(to: point(x, y), press: PenLink.press(force: force), from: .pen)
        case .up: drawing.released(.pen, time: CACurrentMediaTime())
        case .undo: drawing.undo()
        case .clear: drawing.clear()
        case .step(let forward): onStep(forward)
        case .show(let show): onShow(show)
        case .story(let id): onStory(id)
        case .restartStory: onRestart()
        case .hideCamera(let hidden): onHide(hidden)
        case .moveBoard(let scale, let x, let y, let dx, let dy):
            func kept(_ value: Double, _ bound: Double) -> CGFloat { CGFloat(min(max(value, -bound), bound)) }
            drawing.moveBoard(
                zoom: CGFloat(min(max(scale, 0.5), 2)), around: point(x, y),
                by: CGVector(dx: kept(dx, 2000), dy: kept(dy, 2000)))
        case .resetBoard: drawing.resetBoard()
        case .sticker(let id): drawing.place(sticker: id)
        case .moveSticker(let id, let dx, let dy):
            func kept(_ value: Double) -> CGFloat { CGFloat(min(max(value, -2000), 2000)) }
            drawing.moveSticker(id, by: CGVector(dx: kept(dx), dy: kept(dy)))
        case .resizeSticker(let id, let x, let y, let width):
            func kept(_ value: Double) -> CGFloat { CGFloat(min(max(value, -10000), 10000)) }
            guard [x, y, width].allSatisfy(\.isFinite) else { return }
            let widths = PenLink.stickerWidths
            drawing.resizeSticker(
                id, x: kept(x), y: kept(y), width: CGFloat(min(max(width, widths.lowerBound), widths.upperBound)))
        case .editSticker(let id, let edit): drawing.edit(sticker: id, edit)
        case .touch(let touch): touched(touch)
        case .hold(let key, let down): keys.padHolds(key == .point ? "space" : "cmd", down)
        case .set(let settings): apply(settings)
        }
    }

    /// A finger on the story, as the mouse: it drags, or points and clicks where it lifts while the space bar is held
    /// (on the pad or here), or makes a fist while Command is; two fingers zoom. It points only while it touches.
    private func touched(_ touch: StoryTouch) {
        guard shows.0 == .story else { return letGo() }
        func at(_ x: Double, _ y: Double) -> CGPoint {
            let unit = stageUnit
            let x = min(max(x, -200), PenLink.size.width + 200)
            let y = min(max(y, -200), PenLink.size.height + 200)
            return CGPoint(x: x * unit, y: y * unit)
        }
        switch touch {
        case .down(let x, let y):
            guard finger == nil, !zooming else { return }
            let point = at(x, y)
            if keys.isHeld("space") {
                finger = (.point, point)
                fingers.moved(to: point)
            } else if keys.isHeld("cmd") {
                finger = (.fist, point)
                fingers.fisted(at: point)
            } else {
                finger = (.drag, point)
                fingers.pressed(at: point)
            }
        case .move(let x, let y):
            guard finger != nil else { return }
            finger?.at = at(x, y)
            fingers.moved(to: at(x, y))
        case .up:
            guard let finger else { return }
            if finger.kind == .point { fingers.clicked(at: finger.at) } else { fingers.released() }
            fingers.moved(to: nil)  // no pointer left behind: it is there only while the finger is
            self.finger = nil
        case .zoom(let scale, let x, let y):
            guard scale.isFinite else { return }
            if let finger, finger.kind != .point { fingers.released() }  // a second finger: the drag ends
            finger = nil
            // Begun again until it takes: a drag that just ended holds the gesture until the stage's next frame.
            if !fingers.isZooming { fingers.moved(to: at(x, y)) }  // it zooms around the cursor
            fingers.magnified(
                by: CGFloat(min(max(scale, 0.5), 2)) - 1, phase: fingers.isZooming ? .changed : .began, at: at(x, y))
            zooming = true
        case .zoomEnded:
            guard zooming else { return }
            zooming = false
            fingers.magnified(by: 0, phase: .ended, at: .zero)
            fingers.moved(to: nil)
        }
    }

    /// The pad's fingers and keys let go: the link closed, or the story left the stage.
    private func letGo() {
        if finger != nil { fingers.released() }
        if zooming { fingers.magnified(by: 0, phase: .ended, at: .zero) }
        (finger, zooming) = (nil, false)
        fingers.moved(to: nil)
        for key in ["space", "cmd"] { keys.padHolds(key, false) }
    }
}
