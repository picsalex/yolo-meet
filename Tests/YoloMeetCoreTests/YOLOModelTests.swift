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

    @Test(.enabled(if: enabled), arguments: ["yolo26n", "yolo11n", "yolov8n", "yolov5nu", "rfdetr-nano"])
    func detect(_ id: String) async throws {
        let output = try await predict(id)
        let names = output.detections.map { output.name(of: $0.classIndex) }
        #expect(names.filter { $0 == "person" }.count >= 3)
        // bus.jpg is 810x1080 with the bus spanning the width around y 230...750.
        let bus = try #require(output.detections.first { output.name(of: $0.classIndex) == "bus" })
        #expect(bus.box.minX < 60 && bus.box.maxX > 750 && abs(bus.box.minY - 230) < 40 && abs(bus.box.maxY - 750) < 60)
    }

    @Test(.enabled(if: enabled), arguments: ["yolo26n-seg", "yolo11n-seg", "yolov8n-seg", "rfdetr-seg-nano"])
    func segment(_ id: String) async throws {
        let output = try await predict(id)
        #expect(output.detections.count >= 4)
        #expect(output.overlay != nil)
    }

    @Test(.enabled(if: enabled), arguments: ["yolo26n-pose", "yolo11n-pose", "yolov8n-pose", "rfdetr-pose"])
    func pose(_ id: String) async throws {
        let output = try await predict(id)
        #expect(output.detections.count >= 3)
        #expect(output.detections.allSatisfy { $0.keypoints.count == 17 })
    }

    @Test(.enabled(if: enabled), arguments: ["yolo26n-cls", "yolo11n-cls", "yolov8n-cls"])
    func classify(_ id: String) async throws {
        let output = try await predict(id)
        #expect(output.topClasses.count == 5)
        #expect(output.topClasses[0].confidence > 0.1)
    }

    @Test(.enabled(if: enabled), arguments: ["yolo26n-obb", "yolo11n-obb", "yolov8n-obb", "yolo26n-sem", "yolo26n-depth"])
    func runs(_ id: String) async throws {
        let output = try await predict(id)
        #expect(output.latency > 0)
        if !id.hasSuffix("-obb") { #expect(output.overlay != nil) }
    }

    /// Asset names must match scripts/export_models.py.
    @Test @MainActor func catalog() {
        #expect(ModelCatalog.entries.count == 35 + 25 + 25 + 5 + 11)
        #expect(Set(ModelCatalog.entries.map(\.id)).count == ModelCatalog.entries.count)
        for id in ["yolo26x-depth", "yolo11m-obb", "yolov8s-cls", "yolov5lu", "rfdetr-large", "rfdetr-seg-2xlarge"] {
            #expect(ModelCatalog.entry(id) != nil)
        }
        #expect(ModelCatalog.entry("yolov5nu")?.title == "YOLOv5n Detect")
        #expect(ModelCatalog.entry("rfdetr-pose")?.title == "RF-DETR-XL Pose")
        #expect(ModelCatalog.entry("rfdetr-xlarge") == nil)  // XL detection is not Apache-2.0
    }

    /// Export metadata feeds the stats overlay.
    @Test(.enabled(if: enabled), arguments: ["yolo26n", "rfdetr-nano"])
    func info(_ id: String) async throws {
        let info = try await predict(id).info
        #expect(info.parameters ?? 0 > 1_000_000)
        #expect(info.gflops ?? 0 > 1)
        #expect(info.architecture == (id.hasPrefix("rfdetr") ? "Transformer" : "CNN"))
        #expect(info.bytes > 1_000_000)
    }

    @Test func parseNames() {
        #expect(YOLOModel.parseNames("{0: 'person', 1: \"people's\", 2: 'bus'}") == ["person", "people's", "bus"])
    }

    @Test @MainActor func deleteAll() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for id in ["yolo26n", "yolo26s-seg"] {
            try FileManager.default.createDirectory(
                at: directory.appending(path: "\(id).aimodel"), withIntermediateDirectories: true)
        }
        let store = ModelStore(directory: directory)
        #expect(store.downloaded == ["yolo26n", "yolo26s-seg"])
        store.deleteAll()
        #expect(store.downloaded.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
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
