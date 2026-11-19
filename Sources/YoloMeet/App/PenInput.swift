import AppKit
import Observation
import PenLink
import SystemConfiguration

/// The iPad pen app's Apple Pencil on the stage: while it's on, yolo-meet can be found by the app (the pad) on the
/// network they share, or straight from a nearby iPad when they share none, and the pad's strokes are drawn as ink
/// (`Drawing`). The pad shows the stage with its own ink over it, so it is told which of its strokes left the stage
/// and is sent the stage's picture (`StagePicture`). The ink's settings are the panel's, and the pad can change them
/// too. The pad also steps through the story, like the arrow keys, switches the stage between the story and the
/// whiteboard, and hides the camera image, as H does (its deck).
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
    /// What the stage shows, and the mode under the whiteboard (Display mode or the story): the pad is told when either
    /// changes.
    @ObservationIgnored var shows = (StageShow.display, mode: StageShow.display) {
        didSet { if shows != oldValue { host.send(.shows(shows.0, mode: shows.mode)) } }
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

    init(
        drawing: Drawing, stories: [StoryInfo], story: String, onStep: @escaping (Bool) -> Void,
        onShow: @escaping (StageShow) -> Void, onStory: @escaping (String) -> Void, onRestart: @escaping () -> Void,
        onHide: @escaping (Bool) -> Void
    ) {
        (self.drawing, self.stories, self.story) = (drawing, stories, story)
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
            if connected {
                self.host.send(.hello(name: Self.macName))
                self.sendSettings()
                self.host.send(.shows(self.shows.0, mode: self.shows.mode))
                self.host.send(.cameraHidden(self.cameraHidden))
                self.host.send(.stories(self.stories, current: self.story))
                self.host.send(.ink(ids: self.drawing.penStrokes))
            }
        }
        drawing.changed = { [weak self] change in
            switch change {
            case .settings: if self?.isApplying == false { self?.sendSettings() }
            case .removed(let ids): self?.host.send(.removed(ids: ids))
            case .page: self.map { $0.host.send(.ink(ids: $0.drawing.penStrokes)) }
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
        case .set(let settings): apply(settings)
        }
    }
}
