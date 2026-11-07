import AppKit
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
}

/// What effects see on every rendered frame.
struct StageFrame {
    let outputs: [String: ModelOutput]
    let stage: Stage
    let time: TimeInterval
    let dt: TimeInterval
    /// Off: effects show results as they are (no smoothing, vanished objects removed at once).
    let smooth: Bool

    /// Per-frame blend factor for exponential smoothing toward model results, independent of frame rate. Results are
    /// already predicted to each video frame, so this only softens jitter.
    var smoothing: CGFloat { smooth ? CGFloat(1 - exp(-dt * 30)) : 1 }

    /// Blend factor that adapts to how far a point is from its target (stage points), like a One Euro filter: small
    /// gaps (jitter) are smoothed, large ones (fast motion) are caught up within a frame or two.
    func smoothing(gap: CGFloat) -> CGFloat { smooth ? CGFloat(1 - exp(-dt * (30 + 4 * Double(gap / stage.unit)))) : 1 }
}

/// Something drawn on the stage. Subclasses add children to `node` and update them in `update(_:)`, which runs every
/// rendered frame (60 fps) with results predicted to the shown video frame; animate toward them to soften jitter.
class Effect {
    let node = SKNode()
    func update(_ frame: StageFrame) {}
}

/// One node per track ID. Nodes fade in when a track appears and fade out once it has been gone for `grace` seconds,
/// so a single missed detection never blinks. Without smoothing, nodes appear and disappear with the detections.
final class TrackedNodes<N: SKNode> {
    private var nodes: [Int: (node: N, lastSeen: TimeInterval)] = [:]
    private let parent: SKNode
    private let grace: TimeInterval
    private let make: () -> N

    init(in parent: SKNode, grace: TimeInterval = 0.35, make: @escaping () -> N) {
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
            if frame.smooth {
                node.alpha = 0
                node.run(.fadeIn(withDuration: 0.2))
            }
            parent.addChild(node)
            nodes[id] = (node, time)
            return node
        }
        for (id, entry) in nodes where frame.smooth ? time - entry.lastSeen > grace : entry.lastSeen < time {
            nodes[id] = nil
            entry.node.run(frame.smooth ? .sequence([.fadeOut(withDuration: 0.25), .removeFromParent()]) : .removeFromParent())
        }
        return visible
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

