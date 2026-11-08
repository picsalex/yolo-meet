import RealityKit
import SpriteKit

/// An item a hand points at with its index fingertip and acts on with the space bar. Holding Space enters action mode:
/// the item pointed at grows (`scale`) and so does the fingertip's joint in `handSkeleton()`; releasing Space while
/// pointing at it acts. One per item; call `update` every frame.
final class Actionable {
    /// The item's size while pointed at (1 at rest).
    let grown: CGFloat
    /// Whether a fingertip is on it in action mode (Space held, or released this frame).
    private(set) var pointed = false
    /// The item's size now, eased between 1 and `grown` (while pointed at in action mode): draw the item at it, and
    /// hit-test it at it too (so a fingertip on its grown edge keeps it pointed).
    private(set) var scale: CGFloat = 1

    init(grown: CGFloat = 1.15) { self.grown = grown }

    /// `isOn` tells whether a stage point is on the item, nil when it can't be pointed at now (hidden, facing away).
    /// Returns true on the frame the space bar acts on it: released while it's pointed at, one item per release.
    func update(_ frame: StageFrame, isOn: ((CGPoint) -> Bool)?) -> Bool {
        let (holding, releasing) = (frame.keys.held.contains("space"), frame.keys.released.contains("space"))
        pointed = holding || releasing ? isOn.flatMap { frame.pointer(on: $0) } != nil : false
        scale = scale.approaching(pointed && holding ? grown : 1, frame.smoothing)
        return pointed && releasing && frame.pointing.claimAction()
    }
}

/// A word that pops in above an item and fades, e.g. to confirm an action. Add it to an effect's `node`.
final class PopLabel: SKLabelNode {
    init(_ text: String) {
        super.init()
        fontName = Theme.titleFont
        self.text = text
        fontColor = .white
        verticalAlignmentMode = .bottom
        alpha = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Pops it centered above `rect` (stage points).
    func pop(above rect: CGRect, unit u: CGFloat) {
        fontSize = 40 * u
        position = CGPoint(x: rect.midX, y: rect.maxY + 24 * u)
        removeAllActions()
        (alpha, xScale, yScale) = (1, 0.6, 0.6)
        let grow = SKAction.scale(to: 1, duration: 0.15)
        grow.timingMode = .easeOut
        run(.sequence([grow, .wait(forDuration: 0.8), .fadeOut(withDuration: 0.4)]))
    }
}

extension CGPoint {
    /// Whether the point is inside a convex polygon (corners in order around it), e.g. a face on stage.
    func isInside(_ polygon: [CGPoint]) -> Bool {
        let sides = polygon.indices.map { i in
            let (a, b) = (polygon[i], polygon[(i + 1) % polygon.count])
            return (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x)
        }
        return sides.allSatisfy { $0 >= 0 } || sides.allSatisfy { $0 <= 0 }
    }
}

extension CGRect {
    /// The smallest rectangle around the points.
    init(enclosing points: [CGPoint]) {
        let (xs, ys) = (points.map(\.x), points.map(\.y))
        self.init(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

extension Entity {
    /// The entity's on-stage bounds (stage points), from its visual bounds: the 3D layer's world is in stage points,
    /// seen straight on.
    var stageBounds: CGRect {
        let b = visualBounds(relativeTo: nil)
        return CGRect(x: CGFloat(b.min.x), y: CGFloat(b.min.y), width: CGFloat(b.extents.x), height: CGFloat(b.extents.y))
    }
}
