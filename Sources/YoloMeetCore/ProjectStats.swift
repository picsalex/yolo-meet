import Foundation

/// A project's public numbers, shown on stage: its GitHub repository's stars and forks, and its PyPI package's latest
/// version and wheel size. `refresh()` fetches them from GitHub's and PyPI's public JSON APIs, read-only: no token, no
/// cookies, nothing about the user sent. What comes back is checked before it's used (numbers in range, a plain version
/// number), and kept between launches. Until a fetch succeeds (offline, rate limited, an API changed), `current` is the
/// last numbers kept, or the built-in ones.
public final class ProjectStats {
    public struct Snapshot: Codable, Equatable, Sendable {
        public var stars: Int
        public var forks: Int
        public var version: String
        /// The latest release's wheel, in bytes.
        public var wheelBytes: Int
        /// When the numbers were last fetched, both sources at once; nil: built in.
        public var fetched: Date?

        public init(stars: Int, forks: Int, version: String, wheelBytes: Int, fetched: Date? = nil) {
            (self.stars, self.forks, self.version, self.wheelBytes, self.fetched) =
                (stars, forks, version, wheelBytes, fetched)
        }

        /// Stars and forks as GitHub writes them: "63.6k", "12k".
        public var starsText: String { ProjectStats.compact(stars) }
        public var forksText: String { ProjectStats.compact(forks) }
        /// The wheel's size in megabytes (10⁶ bytes, as pip writes it).
        public var wheelMB: Float { Float(wheelBytes) / 1_000_000 }
        /// As pip writes it: "1.5 MB".
        public var wheelText: String { String(format: "%.1f MB", wheelMB) }
    }

    /// "owner/name" on GitHub, and the package's name on PyPI.
    public let repository: String
    public let package: String
    /// The numbers to show now.
    public private(set) var current: Snapshot
    private let defaults: UserDefaults
    private var key: String { "ProjectStats.\(repository).\(package)" }
    private var refreshing = false

    public init(repository: String, package: String, fallback: Snapshot, defaults: UserDefaults = .standard) {
        (self.repository, self.package, self.defaults) = (repository, package, defaults)
        let key = "ProjectStats.\(repository).\(package)"
        let kept = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        current = kept.flatMap(Self.checked) ?? fallback
    }

    /// Fetches the numbers again: at launch and from Settings › Refresh (`Story.refresh`), not on a timer (GitHub
    /// allows 60 requests an hour without a token). Each source that answers updates its numbers; one that fails
    /// leaves them. It never throws and never blocks the stage: call it in a task. True when both sources answered.
    @discardableResult public func refresh() async -> Bool {
        if refreshing { return false }
        refreshing = true
        defer { refreshing = false }
        async let repo = Self.get(
            "https://api.github.com/repos/\(repository)", accept: "application/vnd.github+json",
            parse: Self.parseRepository)
        async let pkg = Self.get(
            "https://pypi.org/pypi/\(package)/json", accept: "application/json", parse: Self.parsePackage)
        let (counts, release) = await (repo, pkg)
        var next = current
        if let counts { (next.stars, next.forks) = counts }
        if let release { (next.version, next.wheelBytes) = release }
        if counts != nil, release != nil { next.fetched = Date() }
        guard let next = Self.checked(next) else { return false }
        if next != current {
            current = next
            if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: key) }
        }
        return counts != nil && release != nil
    }

    // MARK: - Fetching and checking

    /// No cookies, no cache on disk, a short timeout: the request carries nothing but the URL and a generic client name.
    nonisolated private static let configuration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "yolo-meet"]
        return configuration
    }()

    /// The largest answer read: PyPI's lists every past release too (1.4 MB for ultralytics in November 2026).
    nonisolated static let maxBytes = 8_000_000

    /// The body of a successful HTTPS GET, `parse`d, or nil. Off the main actor (PyPI's answer is large to decode),
    /// and given up as soon as it's longer than `maxBytes`, as announced or as it arrives (`CappedBody`).
    @concurrent nonisolated static func get<Value: Sendable>(
        _ address: String, accept: String, limit: Int = maxBytes, parse: @Sendable (Data) -> Value?
    ) async -> Value? {
        guard let url = URL(string: address), url.scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let data = await withCheckedContinuation { continuation in
            let body = CappedBody(limit: limit, continuation)
            let session = URLSession(configuration: configuration, delegate: body, delegateQueue: nil)
            session.dataTask(with: request).resume()
            session.finishTasksAndInvalidate()
        }
        return data.flatMap(parse)
    }

    /// A response's body, collected as it arrives (in chunks: reading an answer byte by byte, `URLSession.bytes`, takes
    /// seconds for PyPI's), or nil: not a 200, longer than `limit`, or failed. URLSession calls a delegate on one
    /// queue at a time, hence `@unchecked Sendable`.
    private nonisolated final class CappedBody: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let limit: Int
        private var data = Data()
        private var continuation: CheckedContinuation<Data?, Never>?

        init(limit: Int, _ continuation: CheckedContinuation<Data?, Never>) {
            (self.limit, self.continuation) = (limit, continuation)
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            let http = response as? HTTPURLResponse
            let fits = http?.statusCode == 200 && (http?.expectedContentLength ?? 0) <= limit
            if fits { data.reserveCapacity(max(Int(response.expectedContentLength), 0)) }
            completionHandler(fits ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            data.append(chunk)
            if data.count > limit { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            continuation?.resume(returning: error == nil && data.count <= limit ? data : nil)
            continuation = nil
        }
    }

    /// Stars and forks from GitHub's repository JSON.
    nonisolated static func parseRepository(_ data: Data) -> (stars: Int, forks: Int)? {
        struct Repository: Decodable {
            let stars: Int
            let forks: Int
            enum CodingKeys: String, CodingKey {
                case stars = "stargazers_count"
                case forks = "forks_count"
            }
        }
        guard let repo = try? JSONDecoder().decode(Repository.self, from: data) else { return nil }
        return (repo.stars, repo.forks)
    }

    /// The latest version and its pure-Python wheel's size from PyPI's package JSON.
    nonisolated static func parsePackage(_ data: Data) -> (version: String, wheelBytes: Int)? {
        struct Package: Decodable {
            struct Info: Decodable { let version: String }
            struct File: Decodable {
                let filename: String
                let packagetype: String
                let size: Int
            }
            let info: Info
            let urls: [File]
        }
        guard let package = try? JSONDecoder().decode(Package.self, from: data),
            let wheel = package.urls.first(where: { $0.packagetype == "bdist_wheel" })
        else { return nil }
        return (package.info.version, wheel.size)
    }

    /// The numbers if they look right, or nil: counts in range, a release version like "8.4.215" (no pre-release
    /// tags or other text to draw on stage), a wheel between 10 kB and 100 MB.
    nonisolated static func checked(_ s: Snapshot) -> Snapshot? {
        let counts = 0..<10_000_000
        let parts = s.version.split(separator: ".", omittingEmptySubsequences: false)
        let version =
            (2...4).contains(parts.count) && s.version.count <= 16
            && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
        guard counts.contains(s.stars), counts.contains(s.forks), version,
            (10_000...100_000_000).contains(s.wheelBytes)
        else { return nil }
        return s
    }

    /// A count as GitHub writes it: 999, 1k, 12k, 63.6k, 112k, 1.2m (rounded to one decimal under 100, the ".0"
    /// dropped).
    public nonisolated static func compact(_ n: Int) -> String {
        func short(_ value: Double, _ unit: String) -> String {
            let rounded = value < 100 ? (value * 10).rounded() / 10 : value.rounded()
            let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
            return text + unit
        }
        if n < 1000 { return String(n) }
        if n < 999_500 { return short(Double(n) / 1000, "k") }
        return short(Double(n) / 1_000_000, "m")
    }
}
