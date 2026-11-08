import AppKit
import RealityKit

/// A slowly spinning 3D shape in the middle of the stage, moved and resized by hand gestures (`frame.gesture`) that
/// start on it: drag moves it, zoom (hands on either side) resizes it, a fist carries it and releasing the fist turns it
/// into the next shape. It's actionable: an index fingertip on it grows it, and the space bar then shows "Action".
final class ManipulationEffect: Effect {
    private static let shapes: [(mesh: MeshResource, color: NSColor)] = [
        (.generateBox(size: 180, cornerRadius: 24), NSColor(red: 0.25, green: 0.85, blue: 1, alpha: 1)),
        (.generateSphere(radius: 100), NSColor(red: 1, green: 0.45, blue: 0.3, alpha: 1)),
        (.generateCylinder(height: 180, radius: 80), NSColor(red: 0.55, green: 1, blue: 0.4, alpha: 1)),
        (.generateCone(height: 190, radius: 100), NSColor(red: 1, green: 0.8, blue: 0.2, alpha: 1)),
    ]
    private let shape = ModelEntity()
    private var shapeIndex = 0
    /// Where the shape goes, in stage points; nil until the first frame places it in the middle.
    private var target: CGPoint?
    private var zoom: CGFloat = 1
    /// Position and zoom when the current gesture began.
    private var base: (position: CGPoint, zoom: CGFloat) = (.zero, 1)
    private var shown: (position: CGPoint, zoom: CGFloat)?
    private var angle: Float = 0
    /// Whether the current gesture started on the shape.
    private var held = false
    /// How far from the shape's center (stage points at zoom 1 and unit 1) a gesture takes hold of it: the shapes are
    /// about 100 in radius, plus a margin around them.
    private static let reach: CGFloat = 160
    private let pointing = Actionable(grown: 1.1)
    private let action = PopLabel("Action")

    override init() {
        super.init()
        entity.addChild(shape)
        node.addChild(action)
        show(0)
    }

    override func update(_ frame: StageFrame) {
        let middle = CGPoint(x: frame.stage.viewSize.width / 2, y: frame.stage.viewSize.height / 2)
        var target = self.target ?? middle
        if let gesture = frame.gesture {
            if gesture.phase == .began {
                base = (target, zoom)
                let reach = Self.reach * (shown?.zoom ?? zoom) * frame.stage.unit
                held = (shown?.position ?? target).distance(to: gesture.location) < reach
            }
            switch gesture.kind {
            case _ where !held: break
            case let .drag(start, location):
                target = CGPoint(x: base.position.x + location.x - start.x, y: base.position.y + location.y - start.y)
            case let .zoom(scale, _):
                zoom = min(max(base.zoom * scale, 0.3), 5)
            case let .fist(location):
                target = location
                if gesture.phase == .ended { show((shapeIndex + 1) % Self.shapes.count) }
            }
        }
        self.target = target

        // Gestures are already filtered: ease at a steady rate (smooths the jump to a fist); snap on the first frame.
        let k = frame.smoothing
        let now = shown.map { ($0.position.approaching(target, k), $0.zoom.approaching(zoom, k)) } ?? (target, zoom)
        shown = now
        angle += Float(frame.dt) * 0.6
        shape.position = [Float(now.0.x), Float(now.0.y), 0]
        shape.scale = .init(repeating: Float(now.1 * frame.stage.unit * pointing.scale))
        shape.orientation = simd_quatf(angle: angle, axis: simd_normalize([0.3, 1, 0.2]))
        let bounds = shape.stageBounds
        if pointing.update(frame, isOn: bounds.contains) { action.pop(above: bounds, unit: frame.stage.unit) }
    }

    private func show(_ index: Int) {
        shapeIndex = index
        let (mesh, color) = Self.shapes[index]
        shape.model = ModelComponent(mesh: mesh, materials: [SimpleMaterial(color: color, roughness: 0.3, isMetallic: false)])
    }
}
