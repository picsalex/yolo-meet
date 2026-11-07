import Foundation
import Observation

/// A model imported by the user.
public struct CustomModel: Codable, Identifiable, Hashable, Sendable {
    /// Folder name on disk (`custom-1a2b3c4d`), stable across renames.
    public let id: String
    public var name: String
    /// "YOLO" or "RF-DETR", inferred at import.
    public let family: String
    public let task: YOLOTask
}

public enum CustomModelError: LocalizedError {
    case unsupported(String)

    public var errorDescription: String? {
        switch self { case .unsupported(let reason): reason }
    }
}

/// User-imported Core AI models, stored under Application Support with an index of display names.
@Observable
public final class CustomModels {
    public private(set) var models: [CustomModel] = []
    public private(set) var isImporting = false
    private var sizes: [String: Int] = [:]
    public let directory: URL
    private var index: URL { directory.appending(path: "models.json") }

    public init(directory: URL = .applicationSupportDirectory.appending(path: "YoloMeet/Custom")) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        models = (try? JSONDecoder().decode([CustomModel].self, from: Data(contentsOf: index))) ?? []
        for model in models { sizes[model.id] = ModelAsset.size(of: url(for: model.id)) }
    }

    public func model(_ id: String) -> CustomModel? { models.first { $0.id == id } }
    public func url(for id: String) -> URL { directory.appending(path: "\(id).aimodel") }
    /// Size of the imported Core AI model on disk, in bytes; measured once, at launch or import.
    public func size(of id: String) -> Int { sizes[id] ?? 0 }

    /// Imports an `.aimodel` (or a zip of one) exported by Ultralytics or RF-DETR. The model is loaded once to validate
    /// it and to infer its family and task.
    public func importModel(from source: URL) async throws {
        isImporting = true
        defer { isImporting = false }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let unzipped = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: unzipped) }
        let asset: URL
        switch source.pathExtension.lowercased() {
        case "aimodel": asset = source
        case "zip":
            try await Self.unzip(source, to: unzipped)
            guard let found = try FileManager.default.contentsOfDirectory(at: unzipped, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "aimodel" })
            else { throw CustomModelError.unsupported("The zip has no .aimodel inside.") }
            asset = found
        case "pt", "pth":
            throw CustomModelError.unsupported(
                "PyTorch weights need an export first: `yolo export model=best.pt format=coreai` (Ultralytics) or "
                    + "`model.export(format=\"coreai\")` (RF-DETR), then import the .aimodel.")
        case "mlpackage", "mlmodel", "mlmodelc":
            throw CustomModelError.unsupported(
                "Core ML models can't be converted to Core AI. Re-export the original weights with format=coreai.")
        default:
            throw CustomModelError.unsupported("Choose an .aimodel (or .aimodel.zip) exported by Ultralytics or RF-DETR.")
        }

        let id = "custom-\(UUID().uuidString.prefix(8).lowercased())"
        let destination = url(for: id)
        try FileManager.default.copyItem(at: asset, to: destination)
        do {
            // RF-DETR writes class names to a sidecar next to the asset rather than into it.
            let sidecar = URL(filePath: asset.path + ".rfdetr.json")
            if let names = Self.rfdetrNames(at: sidecar) { try Self.stampNames(names, into: destination) }
            let loaded = try await YOLOModel.load(from: destination)
            sizes[id] = loaded.info.bytes
            models.append(CustomModel(
                id: id, name: asset.deletingPathExtension().lastPathComponent, family: loaded.info.family,
                task: loaded.task))
            save()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    public func rename(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let i = models.firstIndex(where: { $0.id == id }) else { return }
        models[i].name = name
        save()
    }

    public func delete(_ id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
        models.removeAll { $0.id == id }
        sizes[id] = nil
        save()
    }

    private func save() {
        try? JSONEncoder().encode(models).write(to: index)
    }

    private static func unzip(_ zip: URL, to directory: URL) async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, directory.path]
        try process.run()
        await Task.detached { process.waitUntilExit() }.value
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
    }

    /// `class_id_to_name` from an RF-DETR export sidecar, as an Ultralytics-style names string.
    static func rfdetrNames(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let names = (json["metadata"] as? [String: Any])?["class_id_to_name"] as? [String: String]
        else { return nil }
        let pairs = names.compactMap { key, name in Int(key).map { ($0, name) } }.sorted { $0.0 < $1.0 }
        return "{" + pairs.map { "\($0.0): \"\($0.1)\"" }.joined(separator: ", ") + "}"
    }

    /// Adds `names` to the asset's creator-defined metadata, which Core AI leaves alone.
    static func stampNames(_ names: String, into asset: URL) throws {
        let file = asset.appending(path: "metadata.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:]
        var custom = json["creatorDefinedMetadata"] as? [String: Any] ?? [:]
        guard custom["names"] == nil else { return }
        custom["names"] = names
        json["creatorDefinedMetadata"] = custom
        try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: file)
    }
}
