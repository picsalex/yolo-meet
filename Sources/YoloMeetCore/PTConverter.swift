import Foundation
import Observation

/// Converts PyTorch checkpoints (`.pt`/`.pth`, Ultralytics or RF-DETR) to Core AI by running the bundled
/// `export_models.py --convert` in a private Python environment managed by uv. Python is only used here, never for
/// inference. Everything it installs (venv, Python, uv, Ultralytics settings) stays in `directory`; uv's download
/// cache is disabled, so `removeEnvironment()` leaves nothing behind.
@Observable
public final class PTConverter {
    /// What the converter is doing, nil when idle.
    public private(set) var status: String?
    /// Latest output line from uv or the export script.
    public private(set) var lastLine = ""
    /// Whether the Python environment is set up.
    public private(set) var isInstalled = false

    /// Pinned to the versions the catalog was exported with.
    static let packages = ["ultralytics>=8.4.163", "rfdetr==1.12.0", "coreai-torch>=0.4.3", "torch<=2.13.0"]
    private let script: URL?
    /// Holds the venv, uv's Python and Ultralytics' settings.
    public let directory: URL
    private let python: URL?
    private var venv: URL { directory.appending(path: "venv") }
    private var marker: URL { directory.appending(path: "installed.txt") }

    /// - Parameter python: an existing interpreter with the packages installed (tests); otherwise one is set up.
    public init(
        script: URL?, directory: URL = .applicationSupportDirectory.appending(path: "YoloMeet/Converter"),
        python: URL? = nil
    ) {
        self.script = script
        self.directory = directory
        self.python = python
        isInstalled = FileManager.default.fileExists(atPath: marker.path)
    }

    /// Disk space used by the environment, in bytes (walks ~50k files, so call off the main thread's hot paths).
    public func environmentSize() async -> Int {
        let directory = directory
        return await Task.detached { ModelAsset.size(of: directory) }.value
    }

    /// Deletes the environment; the next `.pt` import sets it up again.
    public func removeEnvironment() {
        try? FileManager.default.removeItem(at: directory)
        isInstalled = false
    }

    /// Returns the exported `.aimodel.zip`, in a temporary folder the caller removes.
    public func convert(_ weights: URL) async throws -> URL {
        guard let script else { throw CustomModelError.unsupported("The converter script is missing from the app bundle.") }
        defer { status = nil }
        let scoped = weights.startAccessingSecurityScopedResource()
        defer { if scoped { weights.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)  // working directory

        let python: URL
        if let existing = self.python { python = existing } else { python = try await environment() }
        status = "Converting \(weights.lastPathComponent) to Core AI…"
        let output = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            try await run(python, [script.path, "--convert", weights.path, "--output", output.path], in: directory)
            guard let zip = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
                .first(where: { $0.lastPathComponent.hasSuffix(".aimodel.zip") })
            else { throw CustomModelError.unsupported("The export produced no model.") }
            return zip
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// The venv's interpreter, creating the venv and installing packages the first time (or when `packages` change).
    private func environment() async throws -> URL {
        let python = venv.appending(path: "bin/python")
        let spec = Self.packages.joined(separator: " ")
        if (try? String(contentsOf: marker, encoding: .utf8)) == spec, FileManager.default.fileExists(atPath: python.path) {
            return python
        }
        let uv = try await uvExecutable()
        status = "Setting up the converter (one time, about 1 GB)…"
        try await run(uv, ["venv", "--python", "3.13", "--clear", venv.path], in: directory)
        try await run(uv, ["pip", "install", "--python", python.path] + Self.packages, in: directory)
        try spec.write(to: marker, atomically: true, encoding: .utf8)
        isInstalled = true
        return python
    }

    /// A uv already on this Mac, else the standalone build downloaded next to the venv.
    private func uvExecutable() async throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(filePath: "/opt/homebrew/bin/uv"), URL(filePath: "/usr/local/bin/uv"),
            home.appending(path: ".local/bin/uv"), home.appending(path: ".cargo/bin/uv"),
            directory.appending(path: "uv-aarch64-apple-darwin/uv"),
        ]
        if let uv = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) { return uv }
        status = "Downloading uv…"
        let url = URL(string: "https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-apple-darwin.tar.gz")!
        let (archive, _) = try await URLSession.shared.download(from: url)
        try await run(URL(filePath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", directory.path], in: directory)
        return candidates[candidates.count - 1]
    }

    /// Runs a process, streaming its output to `lastLine`; throws its last error line on failure.
    private func run(_ executable: URL, _ arguments: [String], in directory: URL) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // Keep every artifact inside the converter folder: no shared uv cache; uv's own Python and Ultralytics'
        // settings/fonts live next to the venv.
        var environment = ProcessInfo.processInfo.environment
        environment["UV_NO_CACHE"] = "1"
        environment["UV_PYTHON_INSTALL_DIR"] = self.directory.appending(path: "python").path
        environment["UV_PYTHON_PREFERENCE"] = "only-managed"  // never tie the venv to a Homebrew/system Python
        environment["YOLO_CONFIG_DIR"] = self.directory.appending(path: "ultralytics").path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let lines = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let line = lines.append(handle.availableData) else { return }
            Task { @MainActor in self?.lastLine = line }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        guard process.terminationStatus == 0 else {
            throw CustomModelError.unsupported(lines.lastError ?? "\(executable.lastPathComponent) failed")
        }
    }
}

/// Collects process output; keeps the latest line and the latest error line (Python's final `XxxError: message`).
private nonisolated final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private var error: String?

    var lastError: String? { lock.withLock { error } }

    /// Returns the newest complete, non-empty line in `data`, if any.
    func append(_ data: Data) -> String? {
        lock.withLock {
            pending += String(decoding: data, as: UTF8.self)
            // Progress bars rewrite the line with carriage returns.
            let lines = pending.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" }.map(String.init)
            pending = lines.last ?? ""
            let complete = lines.dropLast().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if let failure = complete.last(where: { $0.range(of: #"^\w*(Error|Exception):"#, options: .regularExpression) != nil }) {
                error = failure
            }
            return complete.last
        }
    }
}
