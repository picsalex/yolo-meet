import simd

/// Turns an object with the keys: R turns the slow spin on or off, Q/D turn and Z/S tilt while held, 0 resets the turn
/// and tilt. Call `update` every frame and apply `rotation` (e.g. to `ParticleSystem.rotation`).
struct KeyTurn {
    /// Radians per second with a key held.
    static let keySpeed: Float = 1.6
    /// Tilt toward the viewer and turn at rest (positive: the top comes forward, the front moves right).
    let restingTilt, restingTurn: Float
    /// Radians per second of the automatic spin.
    let autoSpeed: Float
    /// Turn around the vertical axis (positive: the front moves right) and tilt.
    private(set) var turn: Float, tilt: Float
    private var autoSpin: Bool

    /// `spinning`: whether the slow spin is on at first.
    init(restingTilt: Float = 0.45, restingTurn: Float = 0, autoSpeed: Float = 0.5, spinning: Bool = true) {
        (self.restingTilt, self.restingTurn, self.autoSpeed, autoSpin) = (restingTilt, restingTurn, autoSpeed, spinning)
        (tilt, turn) = (restingTilt, restingTurn)
    }

    var rotation: simd_quatf { Self.rotation(tilt: tilt, turn: turn) }

    /// The rotation for a tilt and a turn: e.g. a layout's view at rest, before anything is on stage.
    static func rotation(tilt: Float, turn: Float) -> simd_quatf {
        simd_quatf(angle: tilt, axis: [1, 0, 0]) * simd_quatf(angle: turn, axis: [0, 1, 0])
    }

    mutating func update(_ frame: StageFrame) {
        let keys = frame.keys
        if keys.pressed.contains("r") { autoSpin.toggle() }
        if keys.pressed.contains("0") { (turn, tilt) = (restingTurn, restingTilt) }
        let step = Float(frame.dt) * Self.keySpeed
        if keys.held.contains("d") { turn += step }
        if keys.held.contains("q") { turn -= step }
        if keys.held.contains("s") { tilt += step }
        if keys.held.contains("z") { tilt -= step }
        if autoSpin, keys.held.isDisjoint(with: ["q", "d"]) { turn += Float(frame.dt) * autoSpeed }
    }
}
