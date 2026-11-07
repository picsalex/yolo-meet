import AppKit
import RealityKit

/// A soft round light, white, `size` pixels wide: opacity falls from the center through `stops` (radius share,
/// opacity) to the edge.
func radialGlow(size: Int = 128, stops: [(CGFloat, CGFloat)]) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let gradient = CGGradient(
        colorsSpace: space, colors: stops.map { CGColor(gray: 1, alpha: $0.1) } as CFArray, locations: stops.map(\.0))!
    let center = CGPoint(x: size / 2, y: size / 2)
    context.drawRadialGradient(
        gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: CGFloat(size / 2), options: [])
    return context.makeImage()!
}

/// A light with a bright core and a wide halo, for RealityKit sprites and particles.
let glowTexture = try! TextureResource(
    image: radialGlow(stops: [(0, 1), (0.25, 0.35), (1, 0)]), options: .init(semantic: .color))

/// A glowing dot in the 3D layer: a steady light (overlapping additive particles that stay put) with sparks drifting
/// off it that stay where they were born, so they trail behind when the dot moves. Sizes are in stage points at `unit`
/// 1; call `resize(unit:)` when the stage unit changes (particle sizes don't follow the entity's scale).
final class GlowingDot: Entity {
    private var color = NSColor.white
    private var radius: Float = 16
    private let core = Entity()

    convenience init(color: NSColor, radius: Float = 16) {
        self.init()
        (self.color, self.radius) = (color, radius)
        addChild(core)
        resize(unit: 1)
    }

    func resize(unit: CGFloat) {
        let size = radius * Float(unit)
        var light = ParticleEmitterComponent()
        light.emitterShape = .point
        light.speed = 0
        light.mainEmitter.birthRate = 80
        light.mainEmitter.lifeSpan = 0.25  // about 20 particles at once, so the light doesn't flicker
        light.mainEmitter.size = 2 * size
        light.mainEmitter.image = glowTexture
        light.mainEmitter.blendMode = .additive
        light.mainEmitter.opacityCurve = .constant
        light.mainEmitter.color = .constant(.single(color.withAlphaComponent(0.05)))
        core.components.set(light)

        var sparks = ParticleEmitterComponent()
        sparks.emitterShape = .sphere
        sparks.birthLocation = .volume
        sparks.birthDirection = .normal
        sparks.emitterShapeSize = [size / 2, size / 2, size / 2]
        sparks.speed = 1.7 * size
        sparks.speedVariation = 0.8 * size
        sparks.fieldSimulationSpace = .global  // trails
        sparks.mainEmitter.birthRate = 24
        sparks.mainEmitter.lifeSpan = 0.7
        sparks.mainEmitter.size = 0.22 * size
        sparks.mainEmitter.sizeVariation = 0.08 * size
        sparks.mainEmitter.image = glowTexture
        sparks.mainEmitter.blendMode = .additive
        sparks.mainEmitter.opacityCurve = .linearFadeOut
        sparks.mainEmitter.color = .evolving(start: .single(.white), end: .single(color))
        components.set(sparks)
    }
}
