import CoreImage
import Foundation
import Testing

@testable import YoloMeetCore

/// MediaPipe landmarkers converted to Core AI match MediaPipe Tasks' own results on its sample images. Runs when
/// `YOLO_MEET_MEDIAPIPE` points to a folder with the `mediapipe-*.aimodel` bundles, an `img` folder and
/// `reference.json` (normalized landmarks from MediaPipe Tasks, made by the conversion script).
@Suite struct LandmarkerTests {
    static let root = ProcessInfo.processInfo.environment["YOLO_MEET_MEDIAPIPE"].map { URL(filePath: $0) }

    @Test(.enabled(if: root != nil), arguments: [
        ("mediapipe-hand", "hand_landmarker/woman_hands.jpg"), ("mediapipe-hand", "hand_landmarker/thumb_up.jpg"),
        ("mediapipe-pose-lite", "pose_landmarker_lite/pose.jpg"), ("mediapipe-pose-full", "pose_landmarker_full/pose.jpg"),
        ("mediapipe-pose-heavy", "pose_landmarker_heavy/pose.jpg"), ("mediapipe-face", "face_landmarker/portrait.jpg"),
    ])
    func matchesMediaPipe(_ model: String, _ key: String) async throws {
        let root = Self.root!
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "reference.json")))
            as! [String: [String: Any]]
        let expected = (reference[key]!["landmarks"] as! [[[Double]]])
        let image = CIImage(contentsOf: root.appending(path: "img/\(key.split(separator: "/").last!)"))!
        let landmarker = try await Landmarker.load(from: root.appending(path: "\(model).aimodel"))
        let output = try await landmarker.predict(image)
        let size = image.extent.size
        #expect(output.detections.count == expected.count)
        for group in expected {
            // The detection nearest this reference group, compared landmark by landmark in normalized units.
            let center = CGPoint(x: group.map { $0[0] }.reduce(0, +) / Double(group.count), y: group.map { $0[1] }.reduce(0, +) / Double(group.count))
            let detection = try #require(output.detections.min { a, b in
                hypot(a.box.midX / size.width - center.x, a.box.midY / size.height - center.y)
                    < hypot(b.box.midX / size.width - center.x, b.box.midY / size.height - center.y)
            })
            let errors = zip(detection.keypoints, group).map { k, r in
                hypot(k.point.x / size.width - r[0], k.point.y / size.height - r[1])
            }
            let mean = errors.reduce(0, +) / Double(errors.count)
            print("LANDMARKS \(model) \(key): \(group.count) points, mean error \(String(format: "%.4f", mean)), max \(String(format: "%.4f", errors.max()!))")
            // Typically 0.1-0.3% of the image; 1.4% on the small thumbs-up photo.
            #expect(mean < 0.02)
        }
    }

    /// Apple Vision finds the same hands, body and face.
    @Test(.enabled(if: root != nil), arguments: [
        ("vision-hand", "woman_hands.jpg", 2), ("vision-pose", "pose.jpg", 1), ("vision-face", "portrait.jpg", 1),
    ])
    func vision(_ id: String, _ image: String, _ count: Int) async throws {
        let frame = CIImage(contentsOf: Self.root!.appending(path: "img/\(image)"))!
        let output = try await VisionLandmarker(id: id).predict(frame)
        print("VISION \(id) \(image): \(output.detections.count) found, \(output.detections.first?.keypoints.count ?? 0) keypoints")
        #expect(output.detections.count == count)
        #expect(output.detections.allSatisfy { frame.extent.contains($0.box) })
    }
}
