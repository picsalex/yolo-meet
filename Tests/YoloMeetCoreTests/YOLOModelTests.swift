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

    /// Variable-size exports take `imgsz` on the frame's long side, at the frame's aspect; results stay in frame pixels.
    @Test(.enabled(if: enabled), arguments: [320, 640, 960])
    func imageSize(_ imgsz: Int) async throws {
        let model = try await YOLOModel.load(from: Self.models!.appending(path: "yolo26n.aimodel"))
        #expect(model.info.isDynamic)
        model.imgsz = imgsz
        let output = try await model.predict(Self.image!)
        let width = Int((810 * Double(imgsz) / 1080 / 32).rounded(.up)) * 32  // bus.jpg is 810x1080
        #expect(output.inputSize == CGSize(width: width, height: imgsz))
        let bus = try #require(output.detections.first { output.name(of: $0.classIndex) == "bus" })
        #expect(bus.box.minX < 60 && bus.box.maxX > 750 && abs(bus.box.minY - 230) < 40)
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

    /// A raw RF-DETR export (no app metadata) is recognized from its output names; class ids are COCO's (bus = 6).
    @Test(.enabled(if: enabled)) func rawRFDETR() async throws {
        let output = try await predict("rfdetr-raw")
        #expect(output.task == .detect)
        #expect(output.info.family == "RF-DETR")
        #expect(output.detections.contains { $0.classIndex == 6 })
    }

    @Test(.enabled(if: enabled)) @MainActor func importCustom() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let custom = CustomModels(directory: directory)
        try await custom.importModel(from: Self.models!.appending(path: "rfdetr-raw.aimodel"))
        try await custom.importModel(from: Self.models!.appending(path: "yolo26n-seg.aimodel"))
        #expect(custom.models.map(\.family) == ["RF-DETR", "YOLO"])
        #expect(custom.models.map(\.task) == [.detect, .segment])
        // RF-DETR class names come from the sidecar next to the imported asset.
        let id = custom.models[0].id
        let output = try await YOLOModel.load(from: custom.url(for: id)).predict(Self.image!)
        #expect(output.detections.contains { output.name(of: $0.classIndex) == "bus" })
        custom.rename(id, to: "My detector")
        #expect(CustomModels(directory: directory).models[0].name == "My detector")
        custom.delete(id)
        #expect(custom.models.count == 1)
        await #expect(throws: CustomModelError.self) { try await custom.importModel(from: URL(filePath: "/tmp/best.pt")) }
    }

    /// Converts a `.pt` with an existing Python environment (`YOLO_MEET_PYTHON`, `YOLO_MEET_WEIGHTS`), then imports it.
    @Test(.enabled(if: enabled && ProcessInfo.processInfo.environment["YOLO_MEET_PYTHON"] != nil))
    @MainActor func convertPyTorch() async throws {
        let environment = ProcessInfo.processInfo.environment
        let script = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../scripts/export_models.py")
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let converter = PTConverter(
            script: script.standardized, directory: directory, python: URL(filePath: environment["YOLO_MEET_PYTHON"]!))
        let zip = try await converter.convert(URL(filePath: environment["YOLO_MEET_WEIGHTS"]!))
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let custom = CustomModels(directory: directory.appending(path: "custom"))
        try await custom.importModel(from: zip)
        #expect(custom.models.first?.family == "YOLO")
        let output = try await YOLOModel.load(from: custom.url(for: custom.models[0].id)).predict(Self.image!)
        #expect(output.info.parameters ?? 0 > 1_000_000)
        #expect(output.detections.count >= 3)
        #expect(custom.size(of: custom.models[0].id) > 1_000_000)
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

    /// The stage shows the newest frame with results carried forward to its capture time.
    @Test func predicted() {
        func output(at time: Double, x: CGFloat) -> ModelOutput {
            var output = ModelOutput(modelID: "m", task: .pose, names: [], info: ModelInfo(
                family: "YOLO", architecture: nil, parameters: nil, gflops: nil, isDynamic: true, precision: "FP16", bytes: 0),
                frameSize: CGSize(width: 100, height: 100))
            output.time = time
            var detection = Detection(box: CGRect(x: x, y: 0, width: 10, height: 10), confidence: 0.9, classIndex: 0)
            detection.trackID = 1
            detection.keypoints = [Keypoint(point: CGPoint(x: x, y: 5), confidence: 0.9)]
            output.detections = [detection]
            return output
        }
        let history = [output(at: 1.0, x: 0), output(at: 1.1, x: 20)]  // moving 200 px/s
        #expect(abs(history.predicted(at: 1.15)!.detections[0].box.minX - 30) < 1e-6)
        #expect(abs(history.predicted(at: 1.15)!.detections[0].keypoints[0].point.x - 30) < 1e-6)
        #expect(abs(history.predicted(at: 2)!.detections[0].box.minX - 50) < 1e-6)  // at most 0.15 s ahead
        #expect(history.predicted(at: 1.1)?.detections[0].box.minX == 20)
        #expect([output(at: 1.0, x: 7)].predicted(at: 1.2)?.detections[0].box.minX == 7)  // one run: as is
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
