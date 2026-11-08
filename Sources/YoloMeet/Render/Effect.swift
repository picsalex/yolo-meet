import AppKit
import RealityKit
import SpriteKit
import YoloMeetCore

/// Maps frame pixels (top-left origin) to stage points (SpriteKit, bottom-left origin), with the frame aspect-filling
/// the stage.
struct Stage {
    let frameSize: CGSize
    let viewSize: CGSize

    var scale: CGFloat { max(viewSize.width / frameSize.width, viewSize.height / frameSize.height) }
    /// Resolution-independent unit: 1 at 720 pixels of stage height. Multiply line widths and font sizes by it.
    var unit: CGFloat { viewSize.height / 720 }

    func point(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: (viewSize.width - frameSize.width * scale) / 2 + p.x * scale,
            y: viewSize.height - ((viewSize.height - frameSize.height * scale) / 2 + p.y * scale))
    }

    func rect(_ r: CGRect) -> CGRect {
        let (topLeft, bottomRight) = (point(CGPoint(x: r.minX, y: r.minY)), point(CGPoint(x: r.maxX, y: r.maxY)))
        return CGRect(x: topLeft.x, y: bottomRight.y, width: bottomRight.x - topLeft.x, height: topLeft.y - bottomRight.y)
    }

    var frameRect: CGRect { rect(CGRect(origin: .zero, size: frameSize)) }

    /// A frame point in the 3D layer's space (stage points), at depth `z` (0 is the video, positive toward the viewer).
    func position(_ p: CGPoint, z: Float = 0) -> SIMD3<Float> {
        let point = point(p)
        return [Float(point.x), Float(point.y), z]
    }
}

/// What effects see on every rendered frame.
struct StageFrame {
    let outputs: [String: ModelOutput]
    let stage: Stage
    let time: TimeInterval
    let dt: TimeInterval
    /// Off: effects show results as they are (no smoothing, vanished objects removed at once).
    let smooth: Bool
    /// The hand gesture in progress, recognized by the stage for every scene (`HandGestures`).
    var gesture: HandGesture? = nil
    /// Keyboard keys for effects, while YOLO-meet is the active app (`StageKeys`).
    var keys = Keys()

    struct Keys {
        /// The keys effects may use, named as on AZERTY (`StageKeys`: Z Q S D are W A S D on QWERTY). Arrow and page keys
        /// belong to the clicker (previous and next step).
        static let reserved: Set<String> = ["r", "z", "q", "s", "d", "0"]
        /// Keys down now (hold to act every frame).
        var held: Set<String> = []
        /// Keys pressed since the last frame (toggles).
        var pressed: Set<String> = []
    }

    /// Per-frame blend factor for exponential smoothing toward model results, independent of frame rate. Results are
    /// already predicted to each video frame, so this only softens jitter.
    var smoothing: CGFloat { smooth ? CGFloat(1 - exp(-dt * 30)) : 1 }

    /// Blend factor that adapts to how far a point is from its target (stage points), like a One Euro filter: small
    /// gaps (jitter) are smoothed, large ones (fast motion) are caught up within a frame or two.
    func smoothing(gap: CGFloat) -> CGFloat { smooth ? CGFloat(1 - exp(-dt * (30 + 4 * Double(gap / stage.unit)))) : 1 }
}

/// Something drawn on the stage. Subclasses add children to `node` (2D, SpriteKit) and/or `entity` (3D and particles,
/// RealityKit) and update them in `update(_:)`, which runs every rendered frame (60 fps) with results predicted to the
/// shown video frame; animate toward them to soften jitter. The stage draws the video, then the 3D layer, then 2D.
class Effect {
    let node = SKNode()
    /// Root of the effect's 3D content, in stage points: x right, y up (as `node`), z toward the viewer, seen through
    /// an orthographic camera, so `frame.stage.position(_:)` places content on a frame point.
    let entity = Entity()
    /// Glowing particles simulated on the GPU, drawn over the 3D layer and under the 2D layer.
    var particles: ParticleSystem?
    /// Draws `node` just over the video, under the 3D layer and the particles, instead of on top of them (e.g. hand
    /// skeletons that objects should hide). Set it before the stage shows the effect (in `init`).
    var behind = false
    func update(_ frame: StageFrame) {}
}

/// Content shown per track: a SpriteKit node (fades in and out) or a RealityKit entity (appears and goes at once).
protocol TrackedContent: AnyObject {
    associatedtype Parent
    func appear(in parent: Parent, fading: Bool)
    func retire(fading: Bool)
}

extension SKNode: TrackedContent {
    func appear(in parent: SKNode, fading: Bool) {
        if fading {
            alpha = 0
            run(.fadeIn(withDuration: 0.2))
        }
        parent.addChild(self)
    }

    func retire(fading: Bool) {
        run(fading ? .sequence([.fadeOut(withDuration: 0.25), .removeFromParent()]) : .removeFromParent())
    }
}

extension Entity: TrackedContent {
    func appear(in parent: Entity, fading: Bool) { parent.addChild(self) }
    func retire(fading: Bool) { removeFromParent() }
}

/// One node (or entity) per track ID. Nodes fade in when a track appears and fade out once it has been gone for
/// `grace` seconds, so a single missed detection never blinks. Without smoothing, nodes appear and disappear with the
/// detections.
final class TrackedNodes<N: TrackedContent> {
    private var nodes: [Int: (node: N, lastSeen: TimeInterval)] = [:]
    private let parent: N.Parent
    private let grace: TimeInterval
    private let make: () -> N

    init(in parent: N.Parent, grace: TimeInterval = 0.35, make: @escaping () -> N) {
        self.parent = parent
        self.grace = grace
        self.make = make
    }

    /// Returns the node for each visible track ID and retires nodes of tracks gone for longer than `grace`.
    func sync(_ ids: [Int], in frame: StageFrame) -> [N] {
        let time = frame.time
        let visible = ids.map { id -> N in
            if let entry = nodes[id] {
                nodes[id]?.lastSeen = time
                return entry.node
            }
            let node = make()
            node.appear(in: parent, fading: frame.smooth)
            nodes[id] = (node, time)
            return node
        }
        for (id, entry) in nodes where frame.smooth ? time - entry.lastSeen > grace : entry.lastSeen < time {
            nodes[id] = nil
            entry.node.retire(fading: frame.smooth)
        }
        return visible
    }
}

/// SpriteKit redoes text layout or shape tessellation on every property write, even an equal one.
protocol ChangeOnly: AnyObject {}
extension SKNode: ChangeOnly {}
extension ChangeOnly {
    /// Writes `value` only when it differs.
    func set<Value: Equatable>(_ property: ReferenceWritableKeyPath<Self, Value>, _ value: Value) {
        if self[keyPath: property] != value { self[keyPath: property] = value }
    }
}

extension CGFloat {
    func approaching(_ target: CGFloat, _ k: CGFloat) -> CGFloat { self + (target - self) * k }
}

extension CGPoint {
    func approaching(_ target: CGPoint, _ k: CGFloat) -> CGPoint {
        CGPoint(x: x.approaching(target.x, k), y: y.approaching(target.y, k))
    }
}

extension CGRect {
    func approaching(_ target: CGRect, _ k: CGFloat) -> CGRect {
        CGRect(
            x: minX.approaching(target.minX, k), y: minY.approaching(target.minY, k),
            width: width.approaching(target.width, k), height: height.approaching(target.height, k))
    }
}

