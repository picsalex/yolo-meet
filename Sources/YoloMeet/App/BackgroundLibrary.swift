import AppKit
import ImageIO
import Observation

/// Background images copied into Application Support, with the current selection remembered across launches.
@Observable
final class BackgroundLibrary {
    private(set) var items: [URL] = []
    private(set) var thumbnails: [URL: NSImage] = [:]
    var selected: URL? {
        didSet {
            UserDefaults.standard.set(selected?.lastPathComponent, forKey: "background")
            onChange?(selected)
        }
    }
    /// Receives the new selection (and the restored one when set).
    @ObservationIgnored var onChange: ((URL?) -> Void)? { didSet { onChange?(selected) } }

    private let directory = URL.applicationSupportDirectory.appending(path: "YoloMeet/Backgrounds")

    init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
        selected = UserDefaults.standard.string(forKey: "background").flatMap { name in
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

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        if selected == url { selected = nil }
        reload()
    }

    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        items = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        thumbnails = Dictionary(uniqueKeysWithValues: items.compactMap { url in thumbnail(url).map { (url, $0) } })
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
