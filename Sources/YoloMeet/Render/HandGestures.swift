import AppKit
import SpriteKit
import YoloMeetCore

/// A hand gesture, in stage points. Every gesture is reported once with `.began`, then every frame with `.changed`, and
/// once more with `.ended` on the frame it stops, with its values from `HandGestures.settle` earlier (before the
/// release or the hand leaving the frame moved them).
struct HandGesture {
    enum Phase { case began, changed, ended }
    enum Kind {
        /// One hand pinching thumb and middle finger: `location` is the pinch, `start` where it began. Or both hands
        /// pinching and moving together (`hands` 2): the point between the pinches. Drags and zooms only happen outside
        /// action mode and fist mode (Space and Command up).
        case drag(start: CGPoint, location: CGPoint)
        /// Both hands pinching and moving apart or closer: `scale` is the distance between the pinches over that when
        /// they started pinching (> 1: apart).
        case zoom(scale: CGFloat, center: CGPoint)
        /// A closed fist, started while Command is held (fist mode): `location` is the hand's center (mean of its points).
        case fist(location: CGPoint)
    }
    var kind: Kind
    var phase: Phase
    /// Hands making it: 2 for a zoom and for a two-hand drag.
    var hands = 1

    /// Where the hand acts: the pinch (drag), between the pinches (zoom), the hand's center (fist). Compare it with an object's
    /// position on `.began` so gestures only act on the object the hand is on.
    var location: CGPoint {
        switch kind {
        case let .drag(_, location), let .fist(location): location
        case let .zoom(_, center): center
        }
    }
}

/// A one-hand pinch getting ready to start a drag: its hand must stay still while it charges (`HandGestures.charge`),
/// so a pinch made in passing never acts. `progress` goes from 0 to 1, when the drag begins.
struct HandCharge {
    /// The pinch, in stage points.
    var location: CGPoint
    var progress: CGFloat
}

/// Recognizes `HandGesture`s from a 21-point hand model (`mediapipe-hand`, else `vision-hand`), for every scene. The
/// stage runs it once per frame and hands the result to effects as `frame.gesture`.
///
/// One gesture at a time. A fist wins over pinches; one pinching hand drags; two pinching hands zoom when they move
/// apart or closer and drag when they move together, decided once they have moved `pairDecision` and kept until they
/// let go (a one-hand drag ends when the second hand pinches, and turns into a fist when its hand closes, since closing
/// a fist passes through a pinch). A fist only starts while Command is held (fist mode), at once; with Space held (action
/// mode) nothing starts, fingertips only point; drags and zooms start with neither: an accidental fist never acts, and
/// pointing at items never moves them. When a
/// gesture ends, hands still pinching (or in a fist) must let go before they start another pinch (or fist) gesture, so
/// releasing one hand of a zoom doesn't start a drag. A one-hand pinch only starts once its hand has held it still for
/// `charge` (`charging` tells how far along it is); two hands pinching start at once, since that is never an
/// accident. A hand at the frame's edge counts as open: the model's
/// points become unreliable as a hand leaves.
final class HandGestures {
    static let models = ["mediapipe-hand", "vision-hand"]

    /// Thumb tip to middle tip, over the palm's size (its length, wrist to middle knuckle, or 1.3× its width, index to
    /// little knuckle, whichever is longer: tilting the hand shortens one of them): pinching below `on`, released above
    /// `off`.
    static let pinch = (on: 0.3, off: 0.45)
    /// The least curled finger's tip-to-wrist over knuckle-to-wrist distance (index to little): about 1.8 extended,
    /// under 1 curled into the palm, about 1.1 for a relaxed half-closed hand (not a fist).
    static let fist = (on: 1.0, off: 1.2)
    /// A fist's thumb is folded over or beside the fingers: its tip within this much of the palm's size from the index or
    /// middle finger's middle joints (about 0.3 in a fist, 0.8 with the thumb out).
    static let thumbIn: CGFloat = 0.6
    /// How long a one-hand pinch must be held still before its drag starts.
    static let charge: TimeInterval = 0.25
    /// Still: the hand's center moving slower than this (stage points per second at unit 1). Faster restarts the charge.
    static let still: CGFloat = 150
    /// A hand the model loses this briefly keeps its last state (with smoothing on).
    static let grace: TimeInterval = 0.2
    /// A hand with a point this close to the frame's edge (fraction of its shorter side) counts as open.
    static let edge: CGFloat = 0.02
    /// How far back `.ended` reports values from: releasing a pinch or fist, or a hand leaving, moves them.
    static let settle: TimeInterval = 0.1
    /// A gesture whose pinch or fist is released for less than this goes on (with its last values meanwhile): a
    /// pinch the model misses for a frame or two keeps the same drag (with smoothing on).
    static let hold: TimeInterval = 0.15
    /// Two pinching hands are reported once their distance or their midpoint has changed this much (stage points at unit
    /// 1): a zoom if the distance changed more, a two-hand drag if the midpoint moved more.
    static let pairDecision: CGFloat = 12
    /// Closing a pinch moves the point between thumb and middle finger: for this long after both hands pinch, their
    /// starting distance and midpoint follow them, so that motion doesn't count toward the decision.
    static let pairSettle: TimeInterval = 0.15

    struct Hand {
        var pinchRatio: CGFloat
        var curl: CGFloat
        /// Thumb tip to the nearest middle joint of the index or middle finger, over the palm's size.
        var thumb: CGFloat
        /// How fast the hand's center moves (stage points per second at unit 1, filtered).
        var speed: CGFloat
        var pinching: Bool
        var fist: Bool
        /// Some point is at the frame's edge or outside it: neither pinching nor a fist.
        var atEdge: Bool
        /// Between the thumb and middle tips, in stage points (filtered).
        var pinch: OneEuroFilter
        /// Mean of the 21 points, in stage points (filtered): the fist's center, where the wrist alone would pull it
        /// below the visible fist.
        var center: OneEuroFilter
        /// The index fingertip, in stage points (filtered): where the hand points.
        var tip: OneEuroFilter
        var lastSeen: TimeInterval
    }

    private enum Active {
        case drag(Int, start: CGPoint)
        /// Two pinching hands, with their distance and midpoint when they started (after `pairSettle`), and when they
        /// started pinching together.
        case pair(Int, Int, distance: CGFloat, center: CGPoint, since: TimeInterval)
        case fist(Int)
    }
    private enum PairMode { case zoom, drag }

    /// Hands by track ID.
    private(set) var hands: [Int: Hand] = [:]
    private var active: Active?
    /// What a pair of hands does, once decided.
    private var pairMode: PairMode?
    /// Whether the active gesture has been reported (`.began`): a pair isn't until it is decided.
    private var announced = false
    /// The active gesture's recent values, newest last, for `.ended`.
    private var history: [(time: TimeInterval, kind: HandGesture.Kind)] = []
    /// When the active gesture stopped holding, while within `hold`.
    private var releasedAt: TimeInterval?
    /// Hands that must release their pinch (false) or fist (true) before starting another gesture of that kind.
    private var consumed: [Int: Bool] = [:]
    /// The one-hand gesture charging, and since when its hand has been still.
    private var pending: (active: Active, since: TimeInterval)?
    /// The one-hand gesture charging now, nil when none. Call after `update(_:)`.
    private(set) var charging: HandCharge?

    /// The index fingertips of the hands in view, but not of fists (the tip is in the palm) or hands at the frame's edge.
    /// Call after `update(_:)`.
    var pointers: [Pointer] {
        hands.filter { !$0.value.fist && !$0.value.atEdge }.map { Pointer(hand: $0.key, location: $0.value.tip.value) }
            .sorted { $0.hand < $1.hand }
    }

    func update(_ frame: StageFrame) -> HandGesture? {
        let output = Self.models.lazy.compactMap { frame.outputs[$0] }.first
        for detection in output?.detections ?? [] {
            guard let id = detection.trackID, detection.keypoints.count >= 21, let output else { continue }
            hands[id] = measure(detection.keypoints.map(\.point), in: output.frameSize, previous: hands[id], frame: frame)
        }
        hands = hands.filter { frame.time - $0.value.lastSeen <= (frame.smooth ? Self.grace : 0) }
        consumed = consumed.filter { id, fist in hands[id].map { fist ? $0.fist : $0.pinching } ?? false }

        let (action, fists) = (frame.keys.held.contains("space"), frame.keys.held.contains("cmd"))
        charging = nil
        if active == nil {
            guard let started = charged(start(at: frame.time, action: action, fists: fists), frame) else { return nil }
            (active, pairMode, announced, history) = (started, nil, false, [])
        }
        guard let current = active else { return nil }
        let count = if case .pair = current { 2 } else { 1 }
        // Action and fist mode stop a drag or zoom at once (the hands must let go before pinching again).
        if action || fists, !isFist(current) { return end(at: frame.time, hands: count) }
        if holds(current) {
            releasedAt = nil
            decide(frame)
            guard let current = active, let kind = kind(of: current) else { return nil }  // two hands that haven't moved enough to tell
            history.removeAll { $0.time < frame.time - 2 * Self.settle }
            history.append((frame.time, kind))
            defer { announced = true }
            return HandGesture(kind: kind, phase: announced ? .changed : .began, hands: count)
        }
        let released = releasedAt ?? frame.time
        if announced, frame.smooth, frame.time - released < Self.hold, !turnsIntoAnother(current), let last = history.last {
            releasedAt = released
            return HandGesture(kind: last.kind, phase: .changed, hands: count)
        }
        return end(at: released, hands: count)
    }

    /// The gesture to start now: a pair or a fist at once; a one-hand drag once its hand has stayed still (and kept
    /// pinching) for `charge`, meanwhile reported in `charging`.
    private func charged(_ candidate: Active?, _ frame: StageFrame) -> Active? {
        guard case let .drag(id, location) = candidate else {
            pending = nil
            return candidate
        }
        guard let hand = hands[id] else { return nil }
        var since = frame.time
        if let pending, case .drag(id, _) = pending.active { since = pending.since }
        if hand.speed > Self.still { since = frame.time }
        pending = (.drag(id, start: location), since)
        let progress = CGFloat((frame.time - since) / Self.charge)
        guard progress >= 1 else {
            charging = HandCharge(location: location, progress: max(progress, 0))
            return nil
        }
        pending = nil
        return candidate
    }

    private func measure(_ p: [CGPoint], in size: CGSize, previous: Hand?, frame: StageFrame) -> Hand {
        let margin = Self.edge * min(size.width, size.height)
        let inside = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
        let atEdge = !p.allSatisfy(inside.contains)
        let palmSize = max(p[0].distance(to: p[9]), 1.3 * p[5].distance(to: p[17]), 1)
        let pinchRatio = p[4].distance(to: p[12]) / palmSize
        let curl = [(8, 5), (12, 9), (16, 13), (20, 17)]
            .map { tip, knuckle in p[tip].distance(to: p[0]) / max(p[knuckle].distance(to: p[0]), 1) }.max()!
        let thumb = min(p[4].distance(to: p[6]), p[4].distance(to: p[10])) / palmSize
        let fist = !atEdge && curl < (previous?.fist == true ? Self.fist.off : Self.fist.on) && thumb < Self.thumbIn
        let pinching = !atEdge && !fist && pinchRatio < (previous?.pinching == true ? Self.pinch.off : Self.pinch.on)
        let center = frame.stage.point(p.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / 21, y: $0.y + $1.y / 21) })
        let pinch = frame.stage.point(p[4].midpoint(p[12]))
        let tip = frame.stage.point(p[8])
        let centered = previous?.center.filtering(center, frame) ?? OneEuroFilter(center)
        let speed = hypot(centered.velocity.x, centered.velocity.y) / frame.stage.unit
        return Hand(
            pinchRatio: pinchRatio, curl: curl, thumb: thumb, speed: speed, pinching: pinching, fist: fist, atEdge: atEdge,
            pinch: previous?.pinch.filtering(pinch, frame) ?? OneEuroFilter(pinch),
            center: centered,
            tip: previous?.tip.filtering(tip, frame) ?? OneEuroFilter(tip), lastSeen: frame.time)
    }

    /// Whether the gesture's hands still pinch (or make a fist).
    private func holds(_ active: Active) -> Bool {
        switch active {
        case let .drag(id, _): hands[id]?.pinching == true && secondPinch(besides: id) == nil
        case let .pair(a, b, _, _, _): hands[a]?.pinching == true && hands[b]?.pinching == true
        case let .fist(id): hands[id]?.fist == true
        }
    }

    /// Decides what a pair of hands does once they have moved enough (after settling).
    private func decide(_ frame: StageFrame) {
        guard pairMode == nil, case let .pair(a, b, distance, center, since) = active, let (p, q) = pinches(a, b) else { return }
        if frame.time - since < Self.pairSettle {
            active = .pair(a, b, distance: max(p.distance(to: q), 1), center: p.midpoint(q), since: since)
            return
        }
        let (spread, moved) = (abs(p.distance(to: q) - distance), p.midpoint(q).distance(to: center))
        if max(spread, moved) > Self.pairDecision * frame.stage.unit { pairMode = spread > moved ? .zoom : .drag }
    }

    /// The gesture's current values (it holds); nil for a pair not decided yet.
    private func kind(of active: Active) -> HandGesture.Kind? {
        switch active {
        case let .drag(id, start):
            return hands[id].map { .drag(start: start, location: $0.pinch.value) }
        case let .pair(a, b, distance, center, _):
            guard let mode = pairMode, let (p, q) = pinches(a, b) else { return nil }
            return mode == .zoom
                ? .zoom(scale: p.distance(to: q) / distance, center: p.midpoint(q))
                : .drag(start: center, location: p.midpoint(q))
        case let .fist(id):
            return hands[id].map { .fist(location: $0.center.value) }
        }
    }

    private func pinches(_ a: Int, _ b: Int) -> (CGPoint, CGPoint)? {
        guard let a = hands[a], let b = hands[b] else { return nil }
        return (a.pinch.value, b.pinch.value)
    }

    /// A drag ends at once when a second hand pinches (both go on as a pair) or when its hand closes into a fist.
    private func turnsIntoAnother(_ active: Active) -> Bool {
        guard case let .drag(id, _) = active else { return false }
        return secondPinch(besides: id) != nil || hands[id]?.fist == true
    }

    /// Ends the gesture that stopped holding at `time`.
    private func end(at time: TimeInterval, hands count: Int) -> HandGesture? {
        // The hands of a drag that goes on as a pair, or as a fist, stay free.
        var free: Set<Int> = []
        if case let .drag(id, _) = active {
            if let other = secondPinch(besides: id) { free = [id, other] }
            if hands[id]?.fist == true { free = [id] }
        }
        consumed = hands.filter { !free.contains($0.key) && ($0.value.pinching || $0.value.fist) }.mapValues(\.fist)
        active = nil
        releasedAt = nil
        defer { history = [] }
        guard announced else { return nil }  // a pair that let go before it was decided
        let settled = history.last { $0.time <= time - Self.settle } ?? history.first
        return settled.map { HandGesture(kind: $0.kind, phase: .ended, hands: count) }
    }

    /// In fist mode (Command held) only a fist starts, so closing a hand while talking never acts; in action mode (Space
    /// held) nothing starts, so pointing never moves anything; pinches (drag, zoom) only start with neither held. A fist
    /// goes on until the hand opens.
    private func start(at time: TimeInterval, action: Bool, fists: Bool) -> Active? {
        let hands = hands.sorted { $0.key < $1.key }
        if fists {
            return hands.first(where: { $0.value.fist && consumed[$0.key] != true }).map { .fist($0.key) }
        }
        if action { return nil }
        let pinching = hands.filter { $0.value.pinching && consumed[$0.key] != false }
        if pinching.count >= 2 {
            let (a, b) = (pinching[0], pinching[1])
            let (p, q) = (a.value.pinch.value, b.value.pinch.value)
            return .pair(a.key, b.key, distance: max(p.distance(to: q), 1), center: p.midpoint(q), since: time)
        }
        return pinching.first.map { .drag($0.key, start: $0.value.pinch.value) }
    }

    private func isFist(_ active: Active) -> Bool {
        if case .fist = active { true } else { false }
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
            let measures = String(format: "pinch %.2f  curl %.2f  thumb %.2f  speed %3.0f", hand.pinchRatio, hand.curl, hand.thumb, hand.speed)
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
            if let charge = gestures.charging {
                return String(format: "Grab charging  %.0f%%", charge.progress * 100)
            }
            if let ended, frame.time - ended.time < 1 { return "\(ended.name) · ended" }
            return "No gesture"
        }
        let name: String
        switch gesture.kind {
        case let .drag(start, location):
            name = String(format: "Drag%@  Δ %+.0f, %+.0f", gesture.hands == 2 ? " (2 hands)" : "", location.x - start.x, location.y - start.y)
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
    /// Stage points per second (smoothed); zero with smoothing off.
    private(set) var velocity = CGPoint.zero

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
