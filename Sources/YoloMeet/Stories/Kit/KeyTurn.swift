import simd

/// Turns an object with the keys: R turns the slow spin on or off, Q/D turn and Z/S tilt while held, 0 resets the turn
/// and tilt. Call `update` every frame and apply `rotation` (e.g. to `ParticleSystem.rotation`).
struct KeyTurn {
    /// Radians per second with a key held.
    static let keySpeed: Float = 1.6
    /// Tilt toward the viewer at rest (positive: the top comes forward).
    let restingTilt: Float
    /// Radians per second of the automatic spin.
    let autoSpeed: Float
    /// Turn around the vertical axis (positive: the front moves right) and tilt.
    private(set) var turn: Float = 0, tilt: Float
    private var autoSpin: Bool

    /// `spinning`: whether the slow spin is on at first.
    init(restingTilt: Float = 0.45, autoSpeed: Float = 0.5, spinning: Bool = true) {
        (self.restingTilt, self.autoSpeed, tilt, autoSpin) = (restingTilt, autoSpeed, restingTilt, spinning)
    }

    var rotation: simd_quatf { simd_quatf(angle: tilt, axis: [1, 0, 0]) * simd_quatf(angle: turn, axis: [0, 1, 0]) }

    mutating func update(_ frame: StageFrame) {
        let keys = frame.keys
        if keys.pressed.contains("r") { autoSpin.toggle() }
        if keys.pressed.contains("0") { (turn, tilt) = (0, restingTilt) }
        let step = Float(frame.dt) * Self.keySpeed
        if keys.held.contains("d") { turn += step }
        if keys.held.contains("q") { turn -= step }
        if keys.held.contains("s") { tilt += step }
        if keys.held.contains("z") { tilt -= step }
        if autoSpin, keys.held.isDisjoint(with: ["q", "d"]) { turn += Float(frame.dt) * autoSpeed }
    }
}
