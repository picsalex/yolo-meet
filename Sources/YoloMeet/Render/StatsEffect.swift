import AppKit
import SpriteKit
import YoloMeetCore

/// "Stats for nerds": capture, render and per-model numbers in the stage's top-right corner.
final class StatsEffect: Effect {
    private let model: AppModel
    private let label = SKLabelNode(fontNamed: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium).fontName)
    private let background = SKShapeNode()
    private var lastRefresh: TimeInterval = 0

    init(model: AppModel) {
        self.model = model
        super.init()
        node.zPosition = 1000
        label.numberOfLines = 0
        label.horizontalAlignmentMode = .left
        label.verticalAlignmentMode = .top
        label.fontColor = .white
        background.fillColor = NSColor.black.withAlphaComponent(0.6)
        background.lineWidth = 0
        node.addChild(background)
        node.addChild(label)
    }

    override func update(_ frame: StageFrame) {
        // Text layout is the expensive part, so refresh 4 times a second; numbers are averaged over a second anyway.
        if frame.time - lastRefresh > 0.25 {
            lastRefresh = frame.time
            label.text = text(frame)
        }
        let u = frame.stage.unit
        label.fontSize = 13 * u
        let pad = 12 * u
        let size = label.frame.size
        label.position = CGPoint(
            x: frame.stage.viewSize.width - size.width - 2 * pad - 16 * u, y: frame.stage.viewSize.height - pad - 16 * u)
        background.path = CGPath(
            roundedRect: label.frame.insetBy(dx: -pad, dy: -pad), cornerWidth: 8 * u, cornerHeight: 8 * u, transform: nil)
    }

    private func text(_ frame: StageFrame) -> String {
        let camera = model.pipeline.camera
        var lines = [
            row(model.source.rawValue, "\(Int(camera.size.width))×\(Int(camera.size.height)) @ \(Int(camera.fps.rounded())) fps"),
            row("Stage", "\(Int(frame.stage.viewSize.width))×\(Int(frame.stage.viewSize.height)) @ \(model.renderFPS) fps"),
        ]
        if model.source == .camera, model.backgrounds.selected != nil { lines.append(row("Background", "replaced (Vision)")) }
        for output in frame.outputs.values.sorted(by: { $0.modelID < $1.modelID }) {
            let info = output.info
            lines.append("")
            lines.append([output.modelID, output.task.title, info.family, info.architecture].compactMap { $0 }.joined(separator: " · "))
            lines.append(row("  Speed", String(format: "%.0f fps · %.1f ms", output.fps, output.latency * 1000)))
            lines.append(row("  Model", [
                String(format: "%.1f MB", Double(info.bytes) / 1_000_000),
                info.parameters.map { String(format: "%.1fM params", Double($0) / 1_000_000) },
                info.gflops.map { String(format: "%.1f GFLOPs", $0) },
            ].compactMap { $0 }.joined(separator: " · ")))
            let input = "\(Int(output.inputSize.width))×\(Int(output.inputSize.height))\(info.isDynamic ? "" : " fixed")"
            lines.append(row("  Input", "\(input) \(info.precision) · Core AI"))
            switch output.task {
            case .detect, .segment, .pose, .obb, .hand, .face: lines.append(row("  Objects", "\(output.detections.count)"))
            case .classify: lines.append(row("  Top-1", output.topClasses.first.map { output.name(of: $0.index) } ?? "—"))
            case .semantic, .depth: break
            }
        }
        return lines.joined(separator: "\n")
    }

    private func row(_ title: String, _ value: String) -> String {
        title.padding(toLength: 12, withPad: " ", startingAt: 0) + value
    }
}
