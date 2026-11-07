import AppKit
import SpriteKit
import YoloMeetCore

/// A hand gesture, in stage points. Every gesture is reported once with `.began`, then every frame with `.changed`, and
/// once more with `.ended` on the frame it stops, with its values from `HandGestures.settle` earlier (before the
/// release or the hand leaving the frame moved them).
struct HandGesture {
    enum Phase { case began, changed, ended }
    enum Kind {
        /// One hand pinching thumb and middle finger: `location` is the pinch, `start` where it began.
        case drag(start: CGPoint, location: CGPoint)
        /// Both hands pinching: `scale` is the distance between the pinches over that when the zoom began (> 1: apart).
        case zoom(scale: CGFloat, center: CGPoint)
        /// A closed fist: `location` is the hand's center (mean of its points).
        case fist(location: CGPoint)
    }
    var kind: Kind
    var phase: Phase

    /// Where the hand acts: the pinch (drag), between the pinches (zoom), the hand's center (fist). Compare it with an object's
    /// position on `.began` so gestures only act on the object the hand is on.
    var location: CGPoint {
        switch kind {
        case let .drag(_, location), let .fist(location): location
        case let .zoom(_, center): center
        }
    }
}

/// Recognizes `HandGesture`s from a 21-point hand model (`mediapipe-hand`, else `vision-hand`), for every scene. The
/// stage runs it once per frame and hands the result to effects as `frame.gesture`.
///
/// One gesture at a time. A fist wins over pinches; two pinching hands zoom, one drags (a drag turns into a zoom when
/// the second hand pinches, and into a fist when its hand closes, since closing a fist passes through a pinch). When a
/// gesture ends, hands still pinching (or in a fist) must let go before they start another pinch (or fist) gesture, so
/// releasing one hand of a zoom doesn't start a drag. A hand at the frame's edge counts as open: the model's
/// points become unreliable as a hand leaves.
final class HandGestures {
    static let models = ["mediapipe-hand", "vision-hand"]

    /// Thumb tip to middle tip, over the palm's size (its length, wrist to middle knuckle, or 1.3× its width, index to
    /// little knuckle, whichever is longer: tilting the hand shortens one of them): pinching below `on`, released above
    /// `off`.
    static let pinch = (on: 0.3, off: 0.45)
    /// The least curled finger's tip-to-wrist over knuckle-to-wrist distance (index to little): about 1.8 extended,
    /// under 1 curled into the palm.
    static let fist = (on: 1.15, off: 1.35)
    /// A hand the model loses this briefly keeps its last state (with smoothing on).
    static let grace: TimeInterval = 0.2
    /// A hand with a point this close to the frame's edge (fraction of its shorter side) counts as open.
    static let edge: CGFloat = 0.02
    /// How far back `.ended` reports values from: releasing a pinch or fist, or a hand leaving, moves them.
    static let settle: TimeInterval = 0.1
    /// A gesture whose pinch or fist is released for less than this goes on (with its last values meanwhile): a
    /// pinch the model misses for a frame or two keeps the same drag (with smoothing on).
    static let hold: TimeInterval = 0.15

    struct Hand {
        var pinchRatio: CGFloat
        var curl: CGFloat
        var pinching: Bool
        var fist: Bool
        /// Some point is at the frame's edge or outside it: neither pinching nor a fist.
        var atEdge: Bool
        /// Between the thumb and middle tips, in stage points (filtered).
        var pinch: OneEuroFilter
        /// Mean of the 21 points, in stage points (filtered): the fist's center, where the wrist alone would pull it
        /// below the visible fist.
        var center: OneEuroFilter
        var lastSeen: TimeInterval
    }

    private enum Active {
        case drag(Int, start: CGPoint)
        case zoom(Int, Int, distance: CGFloat)
        case fist(Int)
    }

    /// Hands by track ID.
    private(set) var hands: [Int: Hand] = [:]
    private var active: Active?
    /// The active gesture's recent values, newest last, for `.ended`.
    private var history: [(time: TimeInterval, kind: HandGesture.Kind)] = []
    /// When the active gesture stopped holding, while within `hold`.
    private var releasedAt: TimeInterval?
    /// Hands that must release their pinch (false) or fist (true) before starting another gesture of that kind.
    private var consumed: [Int: Bool] = [:]

    func update(_ frame: StageFrame) -> HandGesture? {
        let output = Self.models.lazy.compactMap { frame.outputs[$0] }.first
        for detection in output?.detections ?? [] {
            guard let id = detection.trackID, detection.keypoints.count >= 21, let output else { continue }
            hands[id] = measure(detection.keypoints.map(\.point), in: output.frameSize, previous: hands[id], frame: frame)
        }
        hands = hands.filter { frame.time - $0.value.lastSeen <= (frame.smooth ? Self.grace : 0) }
        consumed = consumed.filter { id, fist in hands[id].map { fist ? $0.fist : $0.pinching } ?? false }

        if let current = active {
            if let kind = kind(of: current) {
                releasedAt = nil
                history.removeAll { $0.time < frame.time - 2 * Self.settle }
                history.append((frame.time, kind))
                return HandGesture(kind: kind, phase: .changed)
            }
            let released = releasedAt ?? frame.time
            if frame.smooth, frame.time - released < Self.hold, !turnsIntoAnother(current), let last = history.last {
                releasedAt = released
                return HandGesture(kind: last.kind, phase: .changed)
            }
            return end(at: released)
        }
        guard let started = start(), let kind = kind(of: started) else { return nil }
        active = started
        history = [(frame.time, kind)]
        return HandGesture(kind: kind, phase: .began)
    }

    private func measure(_ p: [CGPoint], in size: CGSize, previous: Hand?, frame: StageFrame) -> Hand {
        let margin = Self.edge * min(size.width, size.height)
        let inside = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
        let atEdge = !p.allSatisfy(inside.contains)
        let palmSize = max(p[0].distance(to: p[9]), 1.3 * p[5].distance(to: p[17]), 1)
        let pinchRatio = p[4].distance(to: p[12]) / palmSize
        let curl = [(8, 5), (12, 9), (16, 13), (20, 17)]
            .map { tip, knuckle in p[tip].distance(to: p[0]) / max(p[knuckle].distance(to: p[0]), 1) }.max()!
        let fist = !atEdge && curl < (previous?.fist == true ? Self.fist.off : Self.fist.on)
        let pinching = !atEdge && !fist && pinchRatio < (previous?.pinching == true ? Self.pinch.off : Self.pinch.on)
        let center = frame.stage.point(p.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / 21, y: $0.y + $1.y / 21) })
        let pinch = frame.stage.point(p[4].midpoint(p[12]))
        return Hand(
            pinchRatio: pinchRatio, curl: curl, pinching: pinching, fist: fist, atEdge: atEdge,
            pinch: previous?.pinch.filtering(pinch, frame) ?? OneEuroFilter(pinch),
            center: previous?.center.filtering(center, frame) ?? OneEuroFilter(center), lastSeen: frame.time)
    }

    /// The gesture's current values, or nil once it no longer holds.
    private func kind(of active: Active) -> HandGesture.Kind? {
        switch active {
        case let .drag(id, start):
            guard let hand = hands[id], hand.pinching, secondPinch(besides: id) == nil else { return nil }
            return .drag(start: start, location: hand.pinch.value)
        case let .zoom(a, b, distance):
            guard let a = hands[a], let b = hands[b], a.pinching, b.pinching else { return nil }
            return .zoom(scale: a.pinch.value.distance(to: b.pinch.value) / distance, center: a.pinch.value.midpoint(b.pinch.value))
        case let .fist(id):
            guard let hand = hands[id], hand.fist else { return nil }
            return .fist(location: hand.center.value)
        }
    }

    /// A drag ends at once when a second hand pinches (both go on to zoom) or when its hand closes into a fist.
    private func turnsIntoAnother(_ active: Active) -> Bool {
        guard case let .drag(id, _) = active else { return false }
        return secondPinch(besides: id) != nil || hands[id]?.fist == true
    }

    /// Ends the gesture that stopped holding at `time`.
    private func end(at time: TimeInterval) -> HandGesture? {
        // The hands of a drag that goes on as a zoom, or as a fist, stay free.
        var free: Set<Int> = []
        if case let .drag(id, _) = active {
            if let other = secondPinch(besides: id) { free = [id, other] }
            if hands[id]?.fist == true { free = [id] }
        }
        consumed = hands.filter { !free.contains($0.key) && ($0.value.pinching || $0.value.fist) }.mapValues(\.fist)
        active = nil
        releasedAt = nil
        defer { history = [] }
        let settled = history.last { $0.time <= time - Self.settle } ?? history.first
        return settled.map { HandGesture(kind: $0.kind, phase: .ended) }
    }

    private func start() -> Active? {
        let hands = hands.sorted { $0.key < $1.key }
        if let (id, _) = hands.first(where: { $0.value.fist && consumed[$0.key] != true }) { return .fist(id) }
        let pinching = hands.filter { $0.value.pinching && consumed[$0.key] != false }
        if pinching.count >= 2 {
            let (a, b) = (pinching[0], pinching[1])
            return .zoom(a.key, b.key, distance: max(a.value.pinch.value.distance(to: b.value.pinch.value), 1))
        }
        return pinching.first.map { .drag($0.key, start: $0.value.pinch.value) }
    }

    private func secondPinch(besides id: Int) -> Int? {
        hands.first { $0.key != id && $0.value.pinching && consumed[$0.key] != false }?.key
    }
}

/// Debug mode: the recognized gesture and each hand's measures, in the stage's top-left corner.
final class GestureDebugEffect: Effect {
    private let gestures: HandGestures
    private let label = SKLabelNode(fontNamed: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium).fontName)
    private let background = SKShapeNode()
    /// The last gesture's name and when it ended, so the end stays readable for a moment.
    private var ended: (name: String, time: TimeInterval)?

    init(gestures: HandGestures) {
        self.gestures = gestures
        super.init()
        node.zPosition = 1000
        label.numberOfLines = 0
        label.horizontalAlignmentMode = .left
        label.verticalAlignmentMode = .top
        label.fontColor = .white
        background.fillColor = NSColor.black.withAlphaComponent(0.6)
        background.lineWidth = 0
        node.addChild(background)
        node.addChild(label)
    }

    override func update(_ frame: StageFrame) {
        var lines = [title(frame)]
        for (id, hand) in gestures.hands.sorted(by: { $0.key < $1.key }) {
            let state = hand.atEdge ? "edge" : hand.fist ? "fist" : hand.pinching ? "pinch" : "open"
            let measures = String(format: "pinch %.2f  curl %.2f", hand.pinchRatio, hand.curl)
            lines.append("Hand \(id)".padding(toLength: 9, withPad: " ", startingAt: 0)
                + state.padding(toLength: 7, withPad: " ", startingAt: 0) + measures)
        }
        if gestures.hands.isEmpty {
            lines.append(HandGestures.models.contains(where: { frame.outputs[$0] != nil }) ? "No hands" : "No hand model in this scene")
        }
        let u = frame.stage.unit
        let pad = 12 * u
        label.set(\.text, lines.joined(separator: "\n"))
        label.set(\.fontSize, 13 * u)
        label.position = CGPoint(x: 16 * u + pad, y: frame.stage.viewSize.height - 16 * u - pad)
        background.path = CGPath(
            roundedRect: label.frame.insetBy(dx: -pad, dy: -pad), cornerWidth: 8 * u, cornerHeight: 8 * u, transform: nil)
    }

    private func title(_ frame: StageFrame) -> String {
        guard let gesture = frame.gesture else {
            if let ended, frame.time - ended.time < 1 { return "\(ended.name) · ended" }
            return "No gesture"
        }
        let name: String
        switch gesture.kind {
        case let .drag(start, location):
            name = String(format: "Drag  Δ %+.0f, %+.0f", location.x - start.x, location.y - start.y)
        case let .zoom(scale, _):
            name = String(format: "Zoom  ×%.2f", scale)
        case let .fist(location):
            name = String(format: "Fist  at %.0f, %.0f", location.x, location.y)
        }
        if gesture.phase == .ended { ended = (name, frame.time) }
        return gesture.phase == .ended ? "\(name) · ended" : name
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(other.x - x, other.y - y) }
    func midpoint(_ other: CGPoint) -> CGPoint { CGPoint(x: (x + other.x) / 2, y: (y + other.y) / 2) }
}

/// A One Euro filter on a point (Casiez et al.): strong smoothing while it barely moves, which removes jitter, and
/// little lag while it moves fast. Passes points through when the panel's Smoothing switch is off.
struct OneEuroFilter {
    /// Cutoff at rest (Hz): lower is steadier.
    static let minCutoff = 1.0
    /// Cutoff added per stage unit per second of speed: higher follows fast moves more closely.
    static let beta = 0.02
    private(set) var value: CGPoint
    private var velocity = CGPoint.zero

    init(_ value: CGPoint) { self.value = value }

    func filtering(_ point: CGPoint, _ frame: StageFrame) -> OneEuroFilter {
        guard frame.smooth, frame.dt > 0 else { return OneEuroFilter(point) }
        func alpha(_ cutoff: Double) -> CGFloat {
            let r = 2 * .pi * cutoff * frame.dt
            return CGFloat(r / (r + 1))
        }
        var next = self
        let raw = CGPoint(x: (point.x - value.x) / frame.dt, y: (point.y - value.y) / frame.dt)
        next.velocity = velocity.approaching(raw, alpha(1))
        let speed = Double(hypot(next.velocity.x, next.velocity.y) / frame.stage.unit)
        next.value = value.approaching(point, alpha(Self.minCutoff + Self.beta * speed))
        return next
    }
}
