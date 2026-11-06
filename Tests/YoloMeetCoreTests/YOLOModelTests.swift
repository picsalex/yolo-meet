import CoreImage
import Foundation
import Testing

@testable import YoloMeetCore

/// Runs real models when `YOLO_MEET_MODELS` points to a folder of unzipped `yolo26n*.aimodel` assets and
/// `YOLO_MEET_IMAGE` to Ultralytics' `bus.jpg` (4 people and a bus).
@Suite struct YOLOModelTests {
    static let models = ProcessInfo.processInfo.environment["YOLO_MEET_MODELS"].map { URL(filePath: $0) }
    static let image = ProcessInfo.processInfo.environment["YOLO_MEET_IMAGE"].flatMap { CIImage(contentsOf: URL(filePath: $0)) }
    static let enabled = models != nil && image != nil

    func predict(_ id: String) async throws -> ModelOutput {
        let model = try await YOLOModel.load(from: Self.models!.appending(path: "\(id).aimodel"))
        return try await model.predict(Self.image!)
    }

    @Test(.enabled(if: enabled)) func detect() async throws {
        let output = try await predict("yolo26n")
        let names = output.detections.map { output.name(of: $0.classIndex) }
        #expect(names.filter { $0 == "person" }.count >= 3)
        #expect(names.contains("bus"))
        let extent = Self.image!.extent
        for detection in output.detections {
            #expect(CGRect(origin: .zero, size: extent.size).insetBy(dx: -20, dy: -20).contains(detection.box))
        }
    }

    @Test(.enabled(if: enabled)) func segment() async throws {
        let output = try await predict("yolo26n-seg")
        #expect(output.detections.count >= 4)
        #expect(output.overlay != nil)
    }

    @Test(.enabled(if: enabled)) func pose() async throws {
        let output = try await predict("yolo26n-pose")
        #expect(output.detections.count >= 3)
        #expect(output.detections.allSatisfy { $0.keypoints.count == 17 })
    }

    @Test(.enabled(if: enabled)) func classify() async throws {
        let output = try await predict("yolo26n-cls")
        #expect(output.topClasses.count == 5)
        #expect(output.topClasses[0].confidence > 0.1)
    }

    @Test(.enabled(if: enabled), arguments: ["yolo26n-obb", "yolo26n-sem", "yolo26n-depth"])
    func runs(_ id: String) async throws {
        let output = try await predict(id)
        #expect(output.latency > 0)
        if id != "yolo26n-obb" { #expect(output.overlay != nil) }
    }

    @Test func parseNames() {
        #expect(YOLOModel.parseNames("{0: 'person', 1: \"people's\", 2: 'bus'}") == ["person", "people's", "bus"])
    }

    @Test func tracker() {
        let tracker = Tracker()
        var first = [Detection(box: CGRect(x: 0, y: 0, width: 100, height: 100), confidence: 0.9, classIndex: 0)]
        tracker.update(&first)
        var second = [Detection(box: CGRect(x: 5, y: 5, width: 100, height: 100), confidence: 0.9, classIndex: 0)]
        tracker.update(&second)
        #expect(first[0].trackID == second[0].trackID)
    }
}
