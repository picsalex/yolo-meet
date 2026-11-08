import SpriteKit
import simd

/// A swirling cloud of particles in the middle of the stage. A fist closed on it gathers the particles into a ball that
/// follows the fist; opening the hand forms a cube there, spinning slowly. On the cube, a pinch pulled away from its
/// center explodes it into its faces (pushed back toward it, reassembles it); both hands pinching resize it when they
/// move apart or closer, and move it when they move together. A fist on the cube breaks it again. Keys: R turns the slow spin on or off, Q/D turn and Z/S tilt while held, 0 resets the
/// turn, tilt and zoom. The cube's top face is actionable: with Space held, an index fingertip on it grows it, and
/// releasing Space shows "Action". The assembled cube has a title; exploded, each face is described.
final class ParticleMorphEffect: Effect {
    /// Released below this, the cube springs back together; above, it stays exploded.
    static let keepExploded: CGFloat = 0.33

    private let system = ParticleSystem()
    /// Where the cloud or shape is, in stage points; nil until the first frame places it in the middle.
    private var home: CGPoint?
    private var formed = false
    /// Whether the current gesture started on the particles.
    private let grip = Grip()
    /// Tilted toward the viewer at rest, so the top face shows.
    private var turning = KeyTurn()
    /// Explode and zoom the hands ask for, the shown ones (eased toward them), and their values (with the position) when
    /// the gesture began.
    private var explode: CGFloat = 0, zoom: CGFloat = 1
    private var shown: (explode: CGFloat, zoom: CGFloat) = (0, 1)
    private var base: (explode: CGFloat, zoom: CGFloat, home: CGPoint) = (0, 1, .zero)
    private let topFace = Actionable()
    private let action = PopLabel("Action")
    private let title = ObjectTitle("Cube", subtitle: "60,000 particles · 6 faces · pull to explode")
    /// In `CubeFace` order.
    private let faces = Callouts([
        "Left face  −X", "Right face  +X", "Bottom face  −Y", "Top face  +Y · actionable", "Back face  −Z",
        "Front face  +Z",
    ])

    override init() {
        super.init()
        particles = system
        for label in [action, title, faces] { node.addChild(label) }
    }

    override func update(_ frame: StageFrame) {
        let u = frame.stage.unit
        let middle = CGPoint(x: frame.stage.viewSize.width / 2, y: frame.stage.viewSize.height / 2)
        var home = self.home ?? middle
        let (cloud, gathered) = (220 * u, 70 * u)
        let size = 150 * u * zoom  // the cube's half-size on stage

        // The cube's reach grows with its explosion.
        let reach = formed ? (1.6 + 1.2 * explode) * size : 1.1 * cloud
        if let gesture = grip.update(frame, isOn: { home.distance(to: $0) < reach }) {
            if gesture.phase == .began { base = (explode, zoom, home) }
            switch gesture.kind {
            case let .fist(location):
                if gesture.phase == .began { system.scatter(kick: formed ? 1 : 0.4) }
                home = location
                if gesture.phase == .ended {
                    system.form(ParticleShapes.cube(system.count))
                    (formed, explode, shown.explode) = (true, 0, 0)
                }
            case let .drag(start, location) where formed && gesture.hands == 2:
                home = CGPoint(x: base.home.x + location.x - start.x, y: base.home.y + location.y - start.y)
            case let .drag(start, location) where formed:
                // Pulled one half-size further from the center: fully exploded.
                let pulled = home.distance(to: location) - home.distance(to: start)
                explode = min(max(base.explode + pulled / size, 0), 1)
                if gesture.phase == .ended, explode < Self.keepExploded { explode = 0 }
            case let .zoom(scale, _) where formed:
                zoom = min(max(base.zoom * scale, 0.4), 3)
            default: break
            }
        }
        self.home = home

        turning.update(frame)
        if frame.keys.pressed.contains("0") { zoom = 1 }
        shown = (shown.explode.approaching(explode, frame.smoothing), shown.zoom.approaching(zoom, frame.smoothing))
        var gathering = false
        if grip.held, case .fist = frame.gesture?.kind { gathering = true }
        system.center = home
        system.radius = gathering ? gathered : cloud
        system.size = 150 * u * shown.zoom * grip.scale
        system.explode = Float(shown.explode)
        system.rotation = turning.rotation

        // The top face, once formed, facing the viewer and not being gathered by a fist.
        let top = ParticleShapes.CubeFace.top
        let face = formed && !gathering && system.faces(top.center)
            ? top.corners(grownBy: Float(topFace.scale), exploded: system.explode).map(system.stagePoint) : nil
        if topFace.update(frame, isOn: face.map { face in { $0.isInside(face) } }), let face {
            action.pop(above: CGRect(enclosing: face), unit: u)
        }
        system.highlight = topFace.scale > 1.001 ? (top.rawValue, top.center, Float(topFace.scale)) : nil

        // Labels: the title on the assembled cube, the faces' descriptions once it's exploded.
        let all = ParticleShapes.CubeFace.allCases
        let bounds = CGRect(enclosing: all.flatMap { $0.corners(exploded: system.explode) }.map(system.stagePoint))
        let exploded = shown.explode > 0.3
        title.update(beside: bounds, visible: formed && !gathering && !exploded, frame: frame)
        let explodeBy = 1 + ParticleShapes.cubeExplode * system.explode
        faces.update(
            anchors: all.map { system.stagePoint($0.center * explodeBy) }, around: bounds,
            visible: formed && !gathering && exploded, frame: frame)
    }
}
