import CryptoKit
import Foundation
import Observation

/// Downloads videos from links (YouTube and most video sites) with yt-dlp. The standalone yt-dlp binary is fetched
/// from its GitHub release on first use, checked against the release's SHA-256 list, and refreshed every two weeks
/// since sites change often. Only the video stream is downloaded (the stage is muted), as H.264 MP4 up to 1080p, so
/// no ffmpeg is needed.
@Observable
final class LinkDownloader {
    /// 0...1 while downloading (nil before the first progress line), absent when idle.
    private(set) var progress: Double??
    private(set) var status: String?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var cancelled = false
    private let directory = URL.applicationSupportDirectory.appending(path: "YoloMeet/Tools")
    private var tool: URL { directory.appending(path: "yt-dlp") }
    private static let release = "https://github.com/yt-dlp/yt-dlp/releases/latest/download"

    /// Downloads `link` into `folder` and returns the file.
    func download(_ link: String, into folder: URL) async throws -> URL {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.hasPrefix("http") == true
        else { throw LinkError.failed("Not a link: \(link)") }
        progress = .some(nil)
        cancelled = false
        defer { (progress, status) = (nil, nil) }
        try await installTool()
        if cancelled { throw CancellationError() }
        status = "Downloading…"
        let output = try await run(tool, [
            "--newline", "--progress", "--no-playlist", "--no-mtime",  // --print alone silences progress
            "-f", "bv*[ext=mp4][vcodec^=avc1][height<=1080]/b[ext=mp4][height<=1080]/b[ext=mp4]",
            "-o", folder.appending(path: "%(title).80s.%(ext)s").path,
            "--print", "after_move:filepath", url.absoluteString,
        ])
        guard let path = output.last(where: { $0.hasPrefix("/") }) else { throw LinkError.failed("yt-dlp saved no file") }
        return URL(filePath: path)
    }

    /// Stops the download in progress and deletes its partial file.
    func cancel(in folder: URL) {
        cancelled = true
        process?.terminate()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where ["part", "ytdl"].contains(file.pathExtension) { try? FileManager.default.removeItem(at: file) }
    }

    private func installTool() async throws {
        let modified = (try? tool.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, modified.timeIntervalSinceNow > -14 * 86_400 { return }
        status = "Getting yt-dlp…"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        async let binary = URLSession.shared.download(from: URL(string: "\(Self.release)/yt-dlp_macos")!)
        async let sums = URLSession.shared.data(from: URL(string: "\(Self.release)/SHA2-256SUMS")!)
        let (file, _) = try await binary
        let listing = String(decoding: try await sums.0, as: UTF8.self)
        let expected = listing.split(separator: "\n").first { $0.hasSuffix(" yt-dlp_macos") }?.split(separator: " ").first
        let actual = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        guard let expected, expected == actual else { throw LinkError.failed("yt-dlp download failed its checksum") }
        _ = try FileManager.default.replaceItemAt(tool, withItemAt: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    }

    /// Runs `executable`, reporting `[download] 42.0%` lines as progress; returns stdout lines.
    private func run(_ executable: URL, _ arguments: [String]) async throws -> [String] {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let (out, err) = (Pipe(), Pipe())
        (process.standardOutput, process.standardError) = (out, err)
        let lines = Lines()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            for line in lines.append(handle.availableData) {
                guard let match = line.firstMatch(of: /\[download\]\s+([\d.]+)%/), let value = Double(match.1) else { continue }
                Task { @MainActor in self?.progress = .some(value / 100) }
            }
        }
        self.process = process
        defer { self.process = nil }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        out.fileHandleForReading.readabilityHandler = nil
        if cancelled { throw CancellationError() }
        _ = lines.append(out.fileHandleForReading.readDataToEndOfFile() + Data("\n".utf8))  // the rest, and a last line
        let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let message = errors.split(separator: "\n").last { $0.hasPrefix("ERROR") }.map(String.init)
            throw LinkError.failed(message ?? "yt-dlp failed")
        }
        return lines.all
    }
}

enum LinkError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let message) = self { message } else { nil } }
}

/// Splits streamed output into lines.
private nonisolated final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private(set) var all: [String] = []

    func append(_ data: Data) -> [String] {
        lock.withLock {
            pending += String(decoding: data, as: UTF8.self)
            var parts = pending.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            pending = parts.removeLast()
            all += parts
            return parts
        }
    }
}
