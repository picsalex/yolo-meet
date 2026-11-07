import AppKit
import RealityKit
import YoloMeetCore

/// A glowing dot with sparks on each fingertip of every tracked hand. Works with any model in MediaPipe's 21-point
/// hand order (`mediapipe-hand`, `vision-hand`).
final class FingertipGlowEffect: Effect {
    static let fingertips = [4, 8, 12, 16, 20]
    let model: String
    let color: NSColor
    private var unit: CGFloat = 1
    private lazy var hands = TrackedNodes(in: entity) { [unowned self] in
        let hand = Entity()
        for _ in Self.fingertips {
            let dot = GlowingDot(color: color)
            dot.resize(unit: unit)
            dot.isEnabled = false  // until its fingertip is placed
            hand.addChild(dot)
        }
        return hand
    }

    init(model: String, color: NSColor = NSColor(red: 0.25, green: 0.85, blue: 1, alpha: 1)) {
        self.model = model
        self.color = color
    }

    override func update(_ frame: StageFrame) {
        let detections = frame.outputs[model]?.detections.filter { $0.trackID != nil } ?? []
        let resized = frame.stage.unit != unit
        unit = frame.stage.unit
        for (hand, detection) in zip(hands.sync(detections.map { $0.trackID! }, in: frame), detections) {
            for (dot, index) in zip(hand.children, Self.fingertips) {
                guard let dot = dot as? GlowingDot, let tip = detection.keypoints[safe: index] else { continue }
                if resized { dot.resize(unit: unit) }
                let target = frame.stage.position(tip.point)
                // Smoothed toward the predicted fingertip, like the pose effects.
                let gap = CGFloat(simd_distance(dot.position, target))
                dot.position = dot.isEnabled ? dot.position + (target - dot.position) * Float(frame.smoothing(gap: gap)) : target
                dot.isEnabled = true
            }
        }
    }
}
