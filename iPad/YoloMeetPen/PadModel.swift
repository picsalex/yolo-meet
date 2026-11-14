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
    /// yolo-meet's pairing code, typed once and kept in the keychain: the link is encrypted with it (`PenCode`).
    private(set) var code = Keychain.read("pairing code")
    /// The ink's settings, and the colors to pick from (hex).
    private(set) var settings = InkSettings(color: "E1FF25", width: 6, fades: false, fadeAfter: 4, erases: false)
    private(set) var colors: [String] = []
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
        case .settings(let settings, let colors):
            if settings.erases != self.settings.erases { end() }  // the pen's touch was for the other tool
            (self.settings, self.colors) = (settings, colors)
            if !settings.erases { eraser = nil }
        case .ink(let ids): keep { ids.contains($0.id) }
        case .removed(let ids): keep { !ids.contains($0.id) }
        case .picture(let jpeg, let through):
            pictures.received += 1
            let number = pictures.received
            Task {
                // Decoded off the main thread: the pen is read on it.
                guard let image = await UIImage(data: jpeg)?.byPreparingForDisplay(), number > pictures.shown else { return }
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
            strokes.append(Stroke(id: id, color: settings.color, points: [(point, settings.width * PenLink.press(force: force))]))
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
        Binding { self.settings[keyPath: path] } set: { value in self.change { $0[keyPath: path] = value } }
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
