import CoreAI
import Foundation
import Observation

/// Model families offered in the catalog: Ultralytics YOLO generations oldest first, then RF-DETR.
public enum ModelFamily: String, CaseIterable, Sendable {
    case yolov5, yolov8, yolo11, yolo26, rfdetr

    public var title: String {
        switch self {
        case .yolov5: "YOLOv5"
        case .yolov8: "YOLOv8"
        case .yolo11: "YOLO11"
        case .yolo26: "YOLO26"
        case .rfdetr: "RF-DETR"
        }
    }

    /// Tasks with official weights. YOLOv5 ships anchor-free detection only (`yolov5nu`).
    public var tasks: [YOLOTask] {
        switch self {
        case .yolo26: YOLOTask.allCases
        case .yolo11, .yolov8: [.detect, .segment, .pose, .obb, .classify]
        case .yolov5: [.detect]
        case .rfdetr: [.detect, .segment, .pose]
        }
    }

    /// Ultralytics' own models, as opposed to other vendors' (RF-DETR by Roboflow).
    public var isUltralytics: Bool { self != .rfdetr }

    /// Grid columns.
    public var sizes: [String] { self == .rfdetr ? ["n", "s", "m", "l", "xl", "2xl"] : ["n", "s", "m", "l", "x"] }
}

/// A downloadable model. `id` is the asset name (`yolo26n-seg`, `yolov5su`, `rfdetr-seg-nano`), which is also its
/// folder name on disk.
public struct CatalogEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let family: ModelFamily
    public let task: YOLOTask
    public let size: String
    public let url: URL

    public var title: String {
        family == .rfdetr ? "RF-DETR-\(size.uppercased()) \(task.title)" : "\(family.title)\(size) \(task.title)"
    }
}

/// Models listed in the app: Core AI exports from scripts/export_models.py, attached to the `models-v1` release.
public enum ModelCatalog {
    static let release = "https://github.com/picsalex/yolo-meet/releases/download/models-v1"
    static let suffixes: [YOLOTask: String] = [
        .detect: "", .segment: "-seg", .pose: "-pose", .obb: "-obb", .classify: "-cls", .semantic: "-sem", .depth: "-depth",
    ]
    static let rfdetrSizes = ["n": "nano", "s": "small", "m": "medium", "l": "large", "xl": "xlarge", "2xl": "2xlarge"]

    public static let entries: [CatalogEntry] = ModelFamily.allCases.flatMap { family in
        family.tasks.flatMap { task in
            family.sizes.compactMap { size in
                id(family, task, size).map {
                    CatalogEntry(
                        id: $0, family: family, task: task, size: size, url: URL(string: "\(release)/\($0).aimodel.zip")!)
                }
            }
        }
    }

    public static func entry(_ id: String) -> CatalogEntry? { entries.first { $0.id == id } }

    /// Asset name, or nil where the family has no checkpoint for that task and size.
    private static func id(_ family: ModelFamily, _ task: YOLOTask, _ size: String) -> String? {
        switch (family, task) {
        case (.rfdetr, .detect): ["n", "s", "m", "l"].contains(size) ? "rfdetr-\(rfdetrSizes[size]!)" : nil
        case (.rfdetr, .segment): "rfdetr-seg-\(rfdetrSizes[size]!)"
        case (.rfdetr, .pose): size == "xl" ? "rfdetr-pose" : nil  // single keypoint preview (XLarge)
        case (.rfdetr, _): nil
        default: "\(family.rawValue)\(size)\(family == .yolov5 ? "u" : "")\(suffixes[task]!)"
        }
    }
}

/// Downloads, stores and deletes models under Application Support.
@Observable
public final class ModelStore {
    public private(set) var downloaded: Set<String> = []
    /// Download progress (0...1) by model id, present while downloading.
    public private(set) var progress: [String: Double] = [:]
    public var lastError: String?

    public let directory: URL
    @ObservationIgnored private var observations: [String: NSKeyValueObservation] = [:]

    public init(directory: URL = .applicationSupportDirectory.appending(path: "YoloMeet/Models")) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        downloaded = Set(names.filter { $0.hasSuffix(".aimodel") }.map { String($0.dropLast(".aimodel".count)) })
    }

    public func url(for id: String) -> URL { directory.appending(path: "\(id).aimodel") }

    public func download(_ entry: CatalogEntry) {
        guard progress[entry.id] == nil else { return }
        progress[entry.id] = 0
        let task = URLSession.shared.downloadTask(with: entry.url) { [weak self] file, response, error in
            // The temporary file is deleted when this handler returns, so unzip here.
            let result = Result { try Self.install(file: file, response: response, error: error, into: self?.directory) }
            Task { @MainActor in self?.finish(entry.id, result) }
        }
        observations[entry.id] = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in if self?.progress[entry.id] != nil { self?.progress[entry.id] = value } }
        }
        task.resume()
    }

    /// Removes a model and Core AI's compiled copy of it.
    public func delete(_ id: String) {
        try? AIModelCache.default.deleteEntries(for: url(for: id))
        try? FileManager.default.removeItem(at: url(for: id))
        downloaded.remove(id)
    }

    /// Removes every downloaded model and all of the app's Core AI compiled models.
    public func deleteAll() {
        downloaded.forEach(delete)
        try? AIModelCache.default.deleteAll()
    }

    private func finish(_ id: String, _ result: Result<Void, any Error>) {
        progress[id] = nil
        observations[id] = nil
        switch result {
        case .success: downloaded.insert(id)
        case .failure(let error): lastError = "\(id): \(error.localizedDescription)"
        }
    }

    private nonisolated static func install(file: URL?, response: URLResponse?, error: (any Error)?, into directory: URL?)
        throws
    {
        if let error { throw error }
        guard let file, let directory, (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let unzip = Process()
        unzip.executableURL = URL(filePath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", file.path, directory.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
    }
}
