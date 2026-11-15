// Offscreen render of a yolo-meet story: walks it step by step like the stage does (so particles fly from one step's
// layout to the next), and writes PNGs of the requested steps at the requested times. No camera, no models, no hands:
// effects get empty model outputs and no gestures, so live steps and gesture-only phases render without them.
//
// Built and run by render_story.sh, which compiles this file with the app's sources. Arguments:
//   <out dir> <story id> [--black] [--size WxH] [--background image] [--dwell seconds] <shot>...
// A shot is STEP@SECONDS[,SECONDS...]: STEP is the 1-based step number as in the panel, or S.B.N for step S's
// branch B (1-based), its step N, e.g. 12@1,4.5,8.3 or 13.1.2@2.
import AppKit
import CoreImage
import Metal
import SpriteKit

var args = Array(CommandLine.arguments.dropFirst())
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
guard args.count >= 2 else { fail("usage: <out dir> <story id> [--black] [--size WxH] [--background image] [--dwell s] STEP@T[,T...]...") }
let outDir = URL(filePath: args.removeFirst())
let storyID = args.removeFirst()
var black = false, size = CGSize(width: 1280, height: 720), backgroundPath: String?, dwell = 2.5
var shotSpecs: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--black": black = true
    case "--size":
        let p = args.removeFirst().split(separator: "x").compactMap { Double($0) }
        size = CGSize(width: p[0], height: p[1])
    case "--background": backgroundPath = args.removeFirst()
    case "--dwell": dwell = Double(args.removeFirst()) ?? dwell
    default: shotSpecs.append(a)
    }
}
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard let story = Story.all.first(where: { $0.id == storyID }) else {
    fail("no story \"\(storyID)\"; stories: \(Story.all.map(\.id).joined(separator: ", "))")
}

// Shots, as places in the story.
func place(_ spec: Substring) -> Story.Place {
    let n = spec.split(separator: ".").compactMap { Int($0) }
    guard let s = n.first, s >= 1, s <= story.steps.count else { fail("bad step \(spec) (1...\(story.steps.count))") }
    if n.count == 3 { return Story.Place(step: s - 1, branch: n[1] - 1, substep: n[2] - 1) }
    return Story.Place(step: s - 1)
}
var wanted: [Story.Place: [Double]] = [:]
for spec in shotSpecs {
    let parts = spec.split(separator: "@")
    guard parts.count == 2 else { fail("bad shot \(spec): expected STEP@SECONDS[,SECONDS...]") }
    wanted[place(parts[0]), default: []] += parts[1].split(separator: ",").compactMap { Double($0) }
}
if wanted.isEmpty { fail("no shots: give at least one STEP@SECONDS") }

// Rendering, as StageView does: video (or black), effects drawn `behind`, particles, then 2D content.
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let ci = CIContext(mtlCommandQueue: queue)
let background: CIImage = {
    let bounds = CGRect(origin: .zero, size: size)
    guard !black, let path = backgroundPath, let image = CIImage(contentsOf: URL(filePath: path)) else {
        return CIImage(color: .black).cropped(to: bounds)
    }
    let s = max(size.width / image.extent.width, size.height / image.extent.height)
    let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
    return scaled.transformed(by: CGAffineTransform(
        translationX: (size.width - scaled.extent.width) / 2 - scaled.extent.minX,
        y: (size.height - scaled.extent.height) / 2 - scaled.extent.minY)).cropped(to: bounds)
}()
let frameSize = backgroundPath.flatMap { CIImage(contentsOf: URL(filePath: $0))?.extent.size } ?? size
let stage = Stage(frameSize: frameSize, viewSize: size)
let scene = SKScene(size: size), backScene = SKScene(size: size)
(scene.backgroundColor, backScene.backgroundColor) = (.clear, .clear)
let renderer = SKRenderer(device: device), backRenderer = SKRenderer(device: device)
(renderer.scene, backRenderer.scene) = (scene, backScene)
let particles = ParticleRenderer(device: device, pixelFormat: .bgra8Unorm)!
let descriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
let texture = device.makeTexture(descriptor: descriptor)!
let pointing = Pointing()
let dt = 1.0 / 60
var time = 0.0
var effects: [Effect] = []
var stepStart = 0.0
var current = Story.Place()
var advance = false

func frame(loop: TimeInterval?, shot: String? = nil) {
    time += dt
    var f = StageFrame(outputs: [:], stage: stage, time: time, dt: dt, smooth: true)
    let elapsed = time - stepStart
    if let loop, loop > 0 {
        (f.stepTime, f.loopCount) = (elapsed.truncatingRemainder(dividingBy: loop), Int(elapsed / loop))
    } else {
        f.stepTime = elapsed
    }
    f.cameraHidden = black
    pointing.next()
    f.pointing = pointing
    f.nextStep = { advance = true }
    f.branches = StageFrame.Branches(count: story.step(at: current).branches.count)
    for effect in effects { effect.update(f) }
    let commands = queue.makeCommandBuffer()!
    let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: commands)
    destination.isFlipped = true
    destination.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    _ = try? ci.startTask(toRender: background, from: CGRect(origin: .zero, size: size), to: destination, at: .zero)
    let overlay = MTLRenderPassDescriptor()
    overlay.colorAttachments[0].texture = texture
    overlay.colorAttachments[0].loadAction = .load
    overlay.colorAttachments[0].storeAction = .store
    let bounds = CGRect(origin: .zero, size: size)
    if !backScene.children.isEmpty {
        backRenderer.update(atTime: time)
        backRenderer.render(withViewport: bounds, commandBuffer: commands, renderPassDescriptor: overlay)
    }
    let systems = effects.compactMap(\.particles)
    if !systems.isEmpty { particles.render(systems, over: texture, stage: stage, time: time, dt: dt, commandBuffer: commands) }
    renderer.update(atTime: time)
    renderer.render(withViewport: bounds, commandBuffer: commands, renderPassDescriptor: overlay)
    commands.commit()
    commands.waitUntilCompleted()
    if let shot {
        let url = outDir.appending(path: "\(shot).png")
        try? ci.writePNGRepresentation(
            of: CIImage(mtlTexture: texture)!.oriented(.downMirrored), to: url, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        print("wrote \(url.path)")
    }
}

/// Shows a place's effects, as StageView.swapEffects does (an instant swap: old content isn't faded out here).
func show(_ place: Story.Place, from previous: Story.Place?) {
    let fade = previous.map { story.transition(from: $0, to: place) == .fade } ?? true
    for effect in effects { effect.node.removeFromParent() }
    effects = story.step(at: place).effects()
    for effect in effects {
        effect.continuing = !fade
        (effect.behind ? backScene : scene).addChild(effect.node)
    }
    (current, stepStart) = (place, time)
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return Double(info.phys_footprint) / 1_048_576
}

// The story's `prepare`, measured: how long it takes, its longest stall of the main thread, and the memory it adds.
if let prepare = story.prepare {
    let (m0, t0) = (footprintMB(), Date())
    var last = Date(), worst = 0.0
    let ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { _ in
        MainActor.assumeIsolated { worst = max(worst, Date().timeIntervalSince(last)); last = Date() }
    }
    await prepare()
    ticker.invalidate()
    print(String(format: "prepare: %.0f ms, longest main-thread stall %.0f ms, +%.0f MB", Date().timeIntervalSince(t0) * 1000, worst * 1000, footprintMB() - m0))
}

// Walk the story in the panel's order up to the last wanted place, dwelling on the places between.
let order = story.places
let lastIndex = order.lastIndex { wanted[$0] != nil }!
var previous: Story.Place?
for place in order[...lastIndex] {
    // Branches are entered from their step; places in branches nobody asked for are skipped.
    if place.branch != nil, !wanted.keys.contains(where: { $0.step == place.step && $0.branch == place.branch }) { continue }
    show(place, from: previous)
    previous = place
    let loop = story.step(at: place).loop
    let times = (wanted[place] ?? []).sorted()
    let label = place.branch.map { "step\(place.step + 1).\($0 + 1).\(place.substep + 1)" } ?? "step\(place.step + 1)"
    let end = max(times.last ?? 0, wanted[place] == nil ? dwell : 0)
    var shots = times.map { (Int(($0 / dt).rounded()), String(format: "%@-%.1fs", label, $0)) }
    var i = 0
    while Double(i) * dt <= end + dt / 2 {
        let due = shots.first.map { $0.0 <= i } ?? false
        frame(loop: loop, shot: due ? shots.removeFirst().1 : nil)
        i += 1
    }
    if advance { advance = false }  // a gesture would have moved on: the walk does anyway
}
print(String(format: "footprint at the end: %.0f MB", footprintMB()))
exit(0)
