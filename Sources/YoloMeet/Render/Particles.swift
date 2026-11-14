import CoreGraphics
import Metal
import simd

/// Tens of thousands of glowing points, simulated on the GPU, that swirl as a cloud or fly into a shape. An effect sets
/// `particles` to one and steers it every frame (mode, center, sizes, rotation); the stage simulates and draws it over
/// the 3D layer, under the 2D layer, with additive blending (light).
///
/// Simulated in world units of `ParticleSystem.worldUnit` stage points (so the motion looks the same at any stage
/// size). The physics follow WonderSnap's particle update (github.com/AkbarSheikh-debug/wondersnap, MIT): a cloud is a
/// radial spring with an orbit and a swirling flow, and forming is a staggered, critically damped spring to each
/// particle's point of the shape.
final class ParticleSystem {
    enum Mode: Float { case cloud = 0, form = 1 }

    /// Stage points per world unit at stage unit 1.
    static let worldUnit: CGFloat = 200
    /// Stiffness of the spring that pulls each particle to its point of the shape (per second squared), critically
    /// damped.
    static let formStiffness: Float = 80

    let count: Int
    var mode = Mode.cloud
    /// Center of the cloud or shape, in stage points. Particles are pulled toward it, so moving it drags them along.
    var center = CGPoint.zero
    /// Cloud radius, in stage points.
    var radius: CGFloat = 200
    /// Half the shape's size (shapes span -1...1), in stage points.
    var size: CGFloat = 150
    /// How far the shape's parts have moved out (0 assembled, 1 at their full `ParticleShape.offsets`).
    var explode: Float = 0
    /// Turns the shape (x right, y up, z toward the viewer).
    var rotation = simd_quatf(angle: 0, axis: [0, 1, 0])
    /// Grows one part of the shape (`ParticleShape.parts`) by `scale` around `center` (in the shape's -1...1 units, e.g.
    /// a cube face's center: the face grows in its plane). Its particles spring to their new points.
    var highlight: (part: Int, center: SIMD3<Float>, scale: Float)?
    /// Point diameter in stage points at stage unit 1.
    var pointSize: Float = 3
    var color = SIMD3<Float>(0.3, 0.75, 1)
    /// Light per particle: lower it for more particles or brighter colors.
    var brightness: Float = 0.5
    /// Seconds over which the particles' colors fade from the previous shape's to a new shape's.
    static let colorFade: TimeInterval = 0.8

    /// The shape's placement as the particles show it (`shownPoint`): its rotation and size as one matrix and its
    /// center, in stage points, with their speeds; and the frame it was last advanced to.
    private var shown: (matrix: simd_float3x3, center: SIMD3<Float>, speed: simd_float3x3, centerSpeed: SIMD3<Float>)?
    private var shownTime: TimeInterval?
    private var shape: (points: [SIMD4<Float>], offsets: [SIMD4<Float>], colors: [SIMD4<Float>])?
    private var shapeChanged = false
    private var formStart: TimeInterval?
    /// When the colors started fading to the shape's; nil: on the next frame.
    private var colorStart: TimeInterval?
    private var kick: Float = 0
    fileprivate var buffers: [any MTLBuffer] = []  // position, velocity, seed, target, offset, color, previous color

    init(count: Int = 60_000) { self.count = count }

    /// Where a point of the shape (in its -1...1 units, exploded points included) is on stage, as the shape is set now
    /// (its particles spring there): for hit-testing parts of it.
    func stagePoint(_ point: SIMD3<Float>) -> CGPoint {
        let p = rotation.act(point) * Float(size)
        return CGPoint(x: center.x + CGFloat(p.x), y: center.y + CGFloat(p.y))
    }

    /// Where a point of the shape is on stage as the particles show it, and its depth (-1 back, 1 front, at the shape's
    /// size): they spring to their points, so when the shape moves, turns or resizes they trail `stagePoint`. Draw 2D
    /// content on the shape with it to stay on the particles. Call `follow(_:)` first each frame, after setting the
    /// shape's placement.
    func shownPoint(_ point: SIMD3<Float>) -> (point: CGPoint, depth: Float) {
        guard let shown else { return (stagePoint(point), rotation.act(point).z) }
        let p = shown.matrix * point
        return (CGPoint(x: CGFloat(shown.center.x + p.x), y: CGFloat(shown.center.y + p.y)), p.z / Float(max(size, 1)))
    }

    /// Advances `shownPoint` to this frame with the particles' spring (the stage also calls it, once per frame).
    func follow(time: TimeInterval, dt: TimeInterval) {
        guard shownTime != time else { return }
        shownTime = time
        let target = (simd_matrix3x3(rotation) * Float(size), SIMD3<Float>(Float(center.x), Float(center.y), 0))
        guard var s = shown else {
            shown = (target.0, target.1, simd_float3x3(0), .zero)
            return
        }
        // As the shader: substeps of a critically damped spring.
        let dt = Float(min(dt, 0.1)), k = Self.formStiffness
        let steps = min(max(Int((dt * 120).rounded(.up)), 1), 8)
        let h = dt / Float(steps)
        for _ in 0..<steps {
            s.speed += (k * (target.0 - s.matrix) - 2 * k.squareRoot() * s.speed) * h
            s.centerSpeed += (k * (target.1 - s.center) - 2 * k.squareRoot() * s.centerSpeed) * h
            s.matrix += s.speed * h
            s.center += s.centerSpeed * h
        }
        shown = s
    }

    /// Whether a direction of the shape (e.g. a face's normal) turns toward the viewer.
    func faces(_ direction: SIMD3<Float>) -> Bool { rotation.act(direction).z > 0.05 }

    /// Flies the particles into `shape` (one point per particle), staggered; without `staggered`, every particle springs
    /// at once, so those whose point hasn't moved stay still (e.g. a variant of the shape already formed).
    func form(_ shape: ParticleShape, staggered: Bool = true) {
        precondition(shape.points.count == count && shape.offsets.count == count, "one point per particle")
        let parts = shape.parts.isEmpty ? Array(repeating: 0, count: count) : shape.parts
        precondition(parts.count == count, "one part per point")
        // A point's own color has alpha 1; 0 draws it in the system's `color` (`ParticleColors` keeps them so).
        let colors = shape.colors.isEmpty ? Array(repeating: .zero, count: count) : shape.colors.gpu
        precondition(colors.count == count, "one color per point")
        self.shape = (zip(shape.points, parts).map { SIMD4($0, Float($1)) }, shape.offsets.map { SIMD4($0, 0) }, colors)
        shapeChanged = true
        formStart = staggered ? nil : -1e6  // nil: set on the next frame; long ago: every particle springs at once
        if staggered { shown = nil }  // starts where the shape is
        mode = .form
    }

    /// Moves some particles' points (in the shape's units) and sets their colors at once, without forming again or
    /// fading the colors: to animate part of the formed shape every frame (e.g. data flowing through it). The others
    /// keep theirs. The particles spring to their new points as usual.
    func place(_ indices: [Int], at points: [SIMD3<Float>], colors: [SIMD3<Float>]) {
        guard shape != nil else { return }
        let direct = !shapeChanged && buffers.count == 7  // else the next frame copies the shape, these included
        let targets = direct ? buffers[3].contents().bindMemory(to: SIMD4<Float>.self, capacity: count) : nil
        let now = direct ? buffers[5].contents().bindMemory(to: SIMD4<Float>.self, capacity: count) : nil
        let before = direct ? buffers[6].contents().bindMemory(to: SIMD4<Float>.self, capacity: count) : nil
        for (k, i) in indices.enumerated() {
            let point = SIMD4(points[k], shape!.points[i].w), color = SIMD4(colors[k], 1)
            (shape!.points[i], shape!.colors[i]) = (point, color)
            if direct { (targets![i], now![i], before![i]) = (point, color, color) }
        }
    }

    /// Colors some particles at once (no fade), without forming again: e.g. a part of the formed shape lighting up.
    func paint(_ indices: [Int], color: SIMD3<Float>) {
        guard shape != nil else { return }
        let direct = !shapeChanged && buffers.count == 7
        let now = direct ? buffers[5].contents().bindMemory(to: SIMD4<Float>.self, capacity: count) : nil
        let before = direct ? buffers[6].contents().bindMemory(to: SIMD4<Float>.self, capacity: count) : nil
        let color = SIMD4(color, 1)
        for i in indices {
            shape!.colors[i] = color
            if direct { (now![i], before![i]) = (color, color) }
        }
    }

    /// Breaks the shape back into a cloud, with an outward burst (`kick`, 0 for none). `plainColors`: the particles'
    /// own colors fade back to the system's `color` (over `colorFade`); otherwise they keep them.
    func scatter(kick: Float = 1, plainColors: Bool = false) {
        mode = .cloud
        self.kick = kick
        if plainColors, shape != nil {
            shape!.colors = Array(repeating: .zero, count: count)
            shapeChanged = true
        }
    }

    /// Creates the GPU buffers on first use: particles start spread over the whole stage.
    fileprivate func prepare(device: any MTLDevice, stage: Stage) -> Bool {
        if buffers.isEmpty {
            let world = Float(Self.worldUnit * stage.unit)
            let (w, h) = (Float(stage.viewSize.width) / world, Float(stage.viewSize.height) / world)
            let positions = (0..<count).map { _ in
                SIMD4<Float>(.random(in: 0...w), .random(in: 0...h), .random(in: -1...1), 0)
            }
            let seeds = (0..<count).map { _ in SIMD4(SIMD3<Float>.randomDirection(), .random(in: 0...1)) }
            let length = count * MemoryLayout<SIMD4<Float>>.stride
            guard let position = device.makeBuffer(bytes: positions, length: length),
                let velocity = device.makeBuffer(length: length), let seed = device.makeBuffer(bytes: seeds, length: length),
                let target = device.makeBuffer(length: length), let offset = device.makeBuffer(length: length),
                let color = device.makeBuffer(bytes: [SIMD4<Float>](repeating: .zero, count: count), length: length),
                let previous = device.makeBuffer(bytes: [SIMD4<Float>](repeating: .zero, count: count), length: length)
            else { return false }
            buffers = [position, velocity, seed, target, offset, color, previous]
        }
        if shapeChanged, let shape {
            let length = count * MemoryLayout<SIMD4<Float>>.stride
            buffers[3].contents().copyMemory(from: shape.points, byteCount: length)
            buffers[4].contents().copyMemory(from: shape.offsets, byteCount: length)
            // The colors shown so far fade out as the new ones fade in (from where a fade under way had got to, roughly).
            buffers[6].contents().copyMemory(from: buffers[5].contents(), byteCount: length)
            buffers[5].contents().copyMemory(from: shape.colors, byteCount: length)
            (shapeChanged, colorStart) = (false, nil)
        }
        return true
    }

    fileprivate func uniforms(stage: Stage, time: TimeInterval, dt: TimeInterval) -> ParticleUniforms {
        if mode == .form, formStart == nil { formStart = time }
        if colorStart == nil { colorStart = time }
        let colorMix = Float(min(max((time - colorStart!) / Self.colorFade, 0), 1))
        follow(time: time, dt: dt)
        let world = Float(Self.worldUnit * stage.unit)
        let r = simd_matrix3x3(rotation)
        defer { kick = 0 }  // one burst
        return ParticleUniforms(
            time: [Float(min(dt, 0.1)), Float(time.truncatingRemainder(dividingBy: 1000)), Float(time - (formStart ?? time)), mode.rawValue],
            center: [Float(center.x) / world, Float(center.y) / world, 0, Float(radius) / world],
            shape: [Float(size) / world, kick, pointSize * Float(stage.unit), world],
            view: [Float(stage.viewSize.width), Float(stage.viewSize.height), explode, Float(highlight?.part ?? -1)],
            highlight: highlight.map { SIMD4($0.center, $0.scale) } ?? [0, 0, 0, 1],
            color: SIMD4(color, brightness),
            // Rows of the rotation matrix (simd matrices are column-major).
            rot0: [r[0][0], r[1][0], r[2][0], colorMix], rot1: [r[0][1], r[1][1], r[2][1], 0], rot2: [r[0][2], r[1][2], r[2][2], 0])
    }
}

nonisolated extension SIMD3 where Scalar == Float {
    /// A direction picked evenly over all directions: a unit vector.
    static func randomDirection() -> Self {
        while true {
            let v = Self.random(in: -1...1)
            let l = simd_length(v)
            if l > 0.01, l <= 1 { return v / l }
        }
    }
}

/// Matches `Uniforms` in the shader: float4s only, so both sides lay it out the same.
struct ParticleUniforms {
    var time: SIMD4<Float>  // dt, time, seconds since forming began, mode
    var center: SIMD4<Float>  // center (world), cloud radius (world)
    var shape: SIMD4<Float>  // shape half-size (world), kick, point size (pixels), pixels per world unit
    var view: SIMD4<Float>  // stage size (pixels), explode, highlighted part (-1 none)
    var highlight: SIMD4<Float>  // highlighted part's center (shape units), scale
    var color: SIMD4<Float>  // rgb, brightness
    var rot0, rot1, rot2: SIMD4<Float>  // rotation rows; rot0.w: how far the colors have faded to the shape's (0...1)
}

/// Simulates and draws the effects' particle systems: a compute pass, then one additive point pass over `texture`.
final class ParticleRenderer {
    private let step: any MTLComputePipelineState
    private let draw: any MTLRenderPipelineState

    init?(device: any MTLDevice, pixelFormat: MTLPixelFormat) {
        guard let library = try? device.makeLibrary(source: Self.shaders, options: nil),
            let function = library.makeFunction(name: "stepParticles"),
            let step = try? device.makeComputePipelineState(function: function)
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "particleVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "particleFragment")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = pixelFormat
        color.isBlendingEnabled = true  // additive: light adds up, alpha stays
        (color.sourceRGBBlendFactor, color.destinationRGBBlendFactor) = (.one, .one)
        (color.sourceAlphaBlendFactor, color.destinationAlphaBlendFactor) = (.zero, .one)
        guard let draw = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        (self.step, self.draw) = (step, draw)
    }

    func render(
        _ systems: [ParticleSystem], over texture: any MTLTexture, stage: Stage, time: TimeInterval, dt: TimeInterval,
        commandBuffer: any MTLCommandBuffer
    ) {
        let systems = systems.filter { $0.prepare(device: commandBuffer.device, stage: stage) }
        let uniforms = systems.map { $0.uniforms(stage: stage, time: time, dt: dt) }
        guard !systems.isEmpty, let compute = commandBuffer.makeComputeCommandEncoder() else { return }
        compute.setComputePipelineState(step)
        for (system, var u) in zip(systems, uniforms) {
            let b = system.buffers
            compute.setBuffers(Array(b[0..<4]), offsets: [0, 0, 0, 0], range: 0..<4)
            compute.setBytes(&u, length: MemoryLayout<ParticleUniforms>.stride, index: 4)
            compute.setBuffer(b[4], offset: 0, index: 5)
            compute.dispatchThreads(
                MTLSize(width: system.count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: min(step.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1))
        }
        compute.endEncoding()

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(draw)
        for (system, var u) in zip(systems, uniforms) {
            encoder.setVertexBuffer(system.buffers[0], offset: 0, index: 0)
            encoder.setVertexBuffer(system.buffers[1], offset: 0, index: 1)
            encoder.setVertexBuffer(system.buffers[5], offset: 0, index: 2)
            encoder.setVertexBuffer(system.buffers[6], offset: 0, index: 3)
            encoder.setVertexBytes(&u, length: MemoryLayout<ParticleUniforms>.stride, index: 4)
            encoder.setFragmentBytes(&u, length: MemoryLayout<ParticleUniforms>.stride, index: 4)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: system.count)
        }
        encoder.endEncoding()
    }

    private static let shaders = """
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms {
            float4 time;    // dt, time, seconds since forming began, mode (0 cloud, 1 form)
            float4 center;  // center (world), cloud radius (world)
            float4 shape;   // shape half-size (world), kick, point size (pixels), pixels per world unit
            float4 view;    // stage size (pixels), explode, highlighted part (-1 none)
            float4 highlight;  // highlighted part's center (shape units), scale
            float4 color;   // rgb, brightness
            float4 rot0, rot1, rot2;
        };

        // WonderSnap's constants (world units, seconds).
        constant float SWIRL = 0.45, K_RAD = 14.0, DAMP = 2.2, KICK = 2.2, K_FORM = \(ParticleSystem.formStiffness), STAGGER = 0.6;
        constant float ORBIT = 1.6, RAD_DAMP = 5.0;
        constant float3 K1 = float3(1.7, 2.3, 0.0), K2 = float3(0.0, 1.9, 2.6), K3 = float3(2.4, 0.0, 1.5);

        // Gradient of a sum of moving plane waves: crossed with the radius, a swirling flow over the cloud.
        static float3 gradPhi(float3 p, float t) {
            return K1 * cos(dot(K1, p) + 0.9 * t) + K2 * cos(dot(K2, p) - 0.7 * t) + K3 * cos(dot(K3, p) + 1.1 * t);
        }

        kernel void stepParticles(
            device float4 *positions [[buffer(0)]], device float4 *velocities [[buffer(1)]],
            const device float4 *seeds [[buffer(2)]], const device float4 *targets [[buffer(3)]],
            constant Uniforms &u [[buffer(4)]], const device float4 *offsets [[buffer(5)]],
            uint id [[thread_position_in_grid]]
        ) {
            float4 seed = seeds[id];
            float3 c = u.center.xyz;
            float3 p = positions[id].xyz - c, v = velocities[id].xyz + seed.xyz * (u.shape.y * KICK);
            // Small substeps keep the stiff forming spring stable when a frame is late.
            int steps = clamp(int(ceil(u.time.x * 120.0)), 1, 8);
            float h = u.time.x / float(steps);
            // A second random per particle for the cloud's depth, so the cloud is a ball, not a shell.
            float depth = 0.35 + 0.65 * fract(seed.w * 7.31 + 0.17);
            float4 point = targets[id];  // w: the point's part
            float3 local = point.w == u.view.w ? u.highlight.xyz + (point.xyz - u.highlight.xyz) * u.highlight.w : point.xyz;
            float3 target = (local + offsets[id].xyz * u.view.z) * u.shape.x;
            float3 goal = float3(dot(u.rot0.xyz, target), dot(u.rot1.xyz, target), dot(u.rot2.xyz, target));
            for (int i = 0; i < steps; i++) {
                float t = u.time.y + float(i) * h;
                float r = length(p) + 1e-5;
                float3 n = p / r;
                float3 tang = cross(n, gradPhi(p, t));
                float3 acc;
                if (u.time.w < 0.5) {
                    float R = u.center.w * depth;
                    float angle = seed.w * 6.2831853;
                    float3 axis = normalize(cross(seed.xyz, float3(sin(angle), 0.37, cos(angle))));
                    float3 orbit = cross(axis, p) * ORBIT;
                    float vr = dot(v, n);
                    float centripetal = (dot(v, v) - vr * vr) / r;
                    acc = (orbit + tang * SWIRL - v) * DAMP + n * ((R - r) * K_RAD - vr * RAD_DAMP - centripetal);
                } else {
                    float delay = seed.w * STAGGER;
                    float e = smoothstep(delay, delay + 0.35, u.time.z + float(i) * h);
                    float k = K_FORM * e;
                    acc = k * (goal - p) - 2.0 * sqrt(k) * v + (1.0 - e) * (tang * SWIRL - v * DAMP);
                }
                v += acc * h;
                p += v * h;
            }
            positions[id] = float4(p + c, 0.0);
            velocities[id] = float4(v, 0.0);
        }

        struct Point {
            float4 position [[position]];
            float size [[point_size]];
            float3 color;
        };

        vertex Point particleVertex(
            uint id [[vertex_id]], const device float4 *positions [[buffer(0)]],
            const device float4 *velocities [[buffer(1)]], const device float4 *colors [[buffer(2)]],
            const device float4 *previousColors [[buffer(3)]], constant Uniforms &u [[buffer(4)]]
        ) {
            float3 p = positions[id].xyz;
            float2 pixel = p.xy * u.shape.w;
            // Nearer particles (z toward the viewer) are a little bigger and brighter; fast ones run hotter (whiter).
            float near = clamp((p.z - u.center.z) / max(max(u.center.w, u.shape.x), 0.1), -1.0, 1.0);
            float speed = length(velocities[id].xyz);
            Point out;
            out.position = float4(pixel / u.view.xy * 2.0 - 1.0, 0.0, 1.0);
            out.size = max(u.shape.z * (1.0 + 0.3 * near), 1.0);
            // The point's own color, if any, faded in from its previous one (rot0.w: 0 previous, 1 new).
            float3 now = colors[id].w > 0.5 ? colors[id].rgb : u.color.rgb;
            float3 before = previousColors[id].w > 0.5 ? previousColors[id].rgb : u.color.rgb;
            float3 base = mix(before, now, u.rot0.w);
            // Fast points run hotter, unless dark: a black point (no light) stays unseen as it moves.
            float hot = clamp(speed * 0.18, 0.0, 0.75) * clamp(max(base.r, max(base.g, base.b)) * 2.0, 0.0, 1.0);
            out.color = mix(base, float3(1.0), hot) * u.color.w * (0.75 + 0.25 * near);
            return out;
        }

        fragment float4 particleFragment(Point in [[stage_in]], float2 coord [[point_coord]]) {
            float2 c = coord * 2.0 - 1.0;
            float d2 = dot(c, c);
            if (d2 > 1.0) discard_fragment();
            float glow = exp(-d2 * 4.0) * 0.8 + exp(-d2 * 18.0) * 0.6;  // soft halo, hot core
            return float4(in.color * glow, 1.0);
        }
        """
}
