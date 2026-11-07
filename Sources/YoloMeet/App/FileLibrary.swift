import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Observation

/// Files copied into a folder in Application Support (background images, media), with thumbnails and the current
/// selection remembered across launches.
@Observable
final class FileLibrary {
    private(set) var items: [URL] = []
    private(set) var thumbnails: [URL: NSImage] = [:]
    var selected: URL? {
        didSet {
            UserDefaults.standard.set(selected?.lastPathComponent, forKey: key)
            onChange?(selected)
        }
    }
    /// Receives the new selection (and the restored one when set).
    @ObservationIgnored var onChange: ((URL?) -> Void)? { didSet { onChange?(selected) } }

    let directory: URL
    private let key: String

    /// - Parameters: folder: under YoloMeet in Application Support; key: where the selection is remembered.
    init(folder: String, key: String) {
        directory = .applicationSupportDirectory.appending(path: "YoloMeet/\(folder)")
        self.key = key
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
        selected = UserDefaults.standard.string(forKey: key).flatMap { name in
            items.first { $0.lastPathComponent == name }
        }
    }

    func add(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let destination = directory.appending(path: "\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
            try? FileManager.default.copyItem(at: url, to: destination)
        }
        reload()
        if let last = urls.last { selected = items.first { $0.lastPathComponent.hasSuffix(last.lastPathComponent) } }
    }

    /// Selects a file already written into `directory` (e.g. a downloaded video).
    func adopt(_ url: URL) {
        reload()
        selected = items.first { $0.standardizedFileURL == url.standardizedFileURL }
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        if selected == url { selected = nil }
        reload()
    }

    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        items = files.filter { !$0.lastPathComponent.hasSuffix(".part") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        thumbnails = Dictionary(uniqueKeysWithValues: items.compactMap { url in thumbnail(url).map { (url, $0) } })
        for url in items where thumbnails[url] == nil && Self.isVideo(url) {
            Task { thumbnails[url] = await Self.videoThumbnail(url) }
        }
    }

    static func isVideo(_ url: URL) -> Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true }

    private static func videoThumbnail(_ url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        guard let image = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    private func thumbnail(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 240,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}
