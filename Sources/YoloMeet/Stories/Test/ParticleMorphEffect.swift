import SpriteKit
import simd

/// A swirling cloud of particles in the middle of the stage. A fist closed on it gathers the particles into a ball that
/// follows the fist; opening the hand forms a cube there, spinning slowly. On the cube, a pinch pulled away from its
/// center explodes it into its faces (pushed back toward it, reassembles it); both hands pinching resize it when they
/// move apart or closer, and move it when they move together. A fist on the cube breaks it again. Keys: R turns the slow spin on or off, Q/D turn and Z/S tilt while held, 0 resets the
/// turn, tilt and zoom. The cube's top face is actionable: an index fingertip on it grows it, and the space bar then
/// shows "Action".
final class ParticleMorphEffect: Effect {
    /// Released below this, the cube springs back together; above, it stays exploded.
    static let keepExploded: CGFloat = 0.33
    /// Radians per second: the automatic spin, and turning or tilting with a key held.
    static let (autoSpeed, keySpeed): (Float, Float) = (0.5, 1.6)
    /// Tilt toward the viewer at rest, so the top face shows.
    static let restingTilt: Float = 0.45

    private let system = ParticleSystem()
    /// Where the cloud or shape is, in stage points; nil until the first frame places it in the middle.
    private var home: CGPoint?
    private var formed = false
    /// Whether the current gesture started on the particles.
    private var held = false
    /// Turn around the vertical axis (positive: the front moves right) and tilt (positive: the top comes forward).
    private var turn: Float = 0, tilt = restingTilt
    private var autoSpin = true
    /// Explode and zoom the hands ask for, the shown ones (eased toward them), and their values (with the position) when
    /// the gesture began.
    private var explode: CGFloat = 0, zoom: CGFloat = 1
    private var shown: (explode: CGFloat, zoom: CGFloat) = (0, 1)
    private var base: (explode: CGFloat, zoom: CGFloat, home: CGPoint) = (0, 1, .zero)
    private let topFace = Actionable()
    private let action = PopLabel("Action")

    override init() {
        super.init()
        particles = system
        node.addChild(action)
    }

    override func update(_ frame: StageFrame) {
        let u = frame.stage.unit
        let middle = CGPoint(x: frame.stage.viewSize.width / 2, y: frame.stage.viewSize.height / 2)
        var home = self.home ?? middle
        let (cloud, gathered) = (220 * u, 70 * u)
        let size = 150 * u * zoom  // the cube's half-size on stage

        if let gesture = frame.gesture {
            if gesture.phase == .began {
                // The cube's reach grows with its explosion.
                let reach = formed ? (1.6 + 1.2 * explode) * size : 1.1 * cloud
                held = home.distance(to: gesture.location) < reach
                base = (explode, zoom, home)
            }
            switch gesture.kind {
            case _ where !held: break
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
            if gesture.phase == .ended { held = false }
        }
        self.home = home

        rotate(frame)
        shown = (shown.explode.approaching(explode, frame.smoothing), shown.zoom.approaching(zoom, frame.smoothing))
        var gathering = false
        if held, case .fist = frame.gesture?.kind { gathering = true }
        system.center = home
        system.radius = gathering ? gathered : cloud
        system.size = 150 * u * shown.zoom
        system.explode = Float(shown.explode)
        system.rotation = simd_quatf(angle: tilt, axis: [1, 0, 0]) * simd_quatf(angle: turn, axis: [0, 1, 0])

        // The top face, once formed, facing the viewer and not being gathered by a fist.
        let top = ParticleShapes.CubeFace.top
        let face = formed && !gathering && system.faces(top.center)
            ? top.corners(grownBy: Float(topFace.scale), exploded: system.explode).map(system.stagePoint) : nil
        if topFace.update(frame, isOn: face.map { face in { $0.isInside(face) } }), let face {
            action.pop(above: CGRect(enclosing: face), unit: u)
        }
        system.highlight = topFace.scale > 1.001 ? (top.rawValue, top.center, Float(topFace.scale)) : nil
    }

    private func rotate(_ frame: StageFrame) {
        let keys = frame.keys
        if keys.pressed.contains("r") { autoSpin.toggle() }
        if keys.pressed.contains("0") { (turn, tilt, zoom) = (0, Self.restingTilt, 1) }
        let step = Float(frame.dt) * Self.keySpeed
        if keys.held.contains("d") { turn += step }
        if keys.held.contains("q") { turn -= step }
        if keys.held.contains("s") { tilt += step }
        if keys.held.contains("z") { tilt -= step }
        if autoSpin, keys.held.isDisjoint(with: ["q", "d"]) { turn += Float(frame.dt) * Self.autoSpeed }
    }
}
