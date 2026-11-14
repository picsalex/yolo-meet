import Foundation
import Network

/// The pad's end of the link: looks for the host while it's started, connects to it with the pairing code, and
/// connects again when the link drops.
public final class PenClient {
    public nonisolated enum State: Equatable, Sendable {
        /// Not started with a pairing code yet.
        case unpaired
        /// Looking for the host.
        case searching
        /// Looking isn't allowed or possible yet: usually Local Network access is off for the app in Settings.
        case blocked
        /// A host is there, but it doesn't have the same pairing code. It is tried again every few seconds.
        case refused
        /// A host is there, but it is another version of yolo-meet than this app's: one of them needs updating. It is
        /// tried again every few seconds.
        case outdated
        /// Connected to the host of this name.
        case connected(String)
    }

    public var received: ((HostMessage) -> Void)?
    public var changed: ((State) -> Void)?
    public private(set) var state = State.unpaired { didSet { if state != oldValue { changed?(state) } } }
    private var browser: NWBrowser?
    private var channel: PenChannel<HostMessage, PadMessage>?
    /// The pairing code, while started.
    private var code: String?
    /// The hosts that didn't have the code, and those that never answered (unreachable, or stalling), by name: the
    /// others are tried first, so one bad host can't keep the pad from the right one.
    private var refused: Set<String> = []
    private var unanswered: Set<String> = []
    /// The hosts of another version of the link, by name.
    private var outdated: Set<String> = []
    /// Every host was tried: they are tried again in a while.
    private var isWaiting = false

    public init() {}

    /// Starts with the pairing `code`, or starts again when it is another.
    public func start(code: String) {
        guard code != self.code else { return }
        stop()
        (self.code, state) = (code, .searching)
        browse()
    }

    public func stop() {
        (code, refused, unanswered, outdated, isWaiting) = (nil, [], [], [], false)
        browser?.cancel()
        browser = nil
        let channel = channel
        self.channel = nil
        channel?.close()
        state = .unpaired
    }

    public func send(_ message: PadMessage) {
        if case .connected = state { channel?.send(message) }
    }

    private func browse() {
        let browser = NWBrowser(for: .bonjour(type: PenLink.service, domain: nil), using: .penBrowsing)
        browser.browseResultsChangedHandler = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.connect() }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                guard let self, self.browser === browser else { return }
                switch state {
                case .waiting: if self.channel == nil { self.state = .blocked }
                case .ready: if self.state == .blocked { self.state = .searching }
                case .failed:
                    browser?.cancel()
                    self.browser = nil
                    self.later { if self.browser == nil { self.browse() } }
                default: break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// Connects to a host the browser sees (the first by name that hasn't refused the code nor failed to answer),
    /// unless one is connected or connecting. When every host was tried, they are all tried again in a while: one may
    /// have the code, or answer, by then.
    private func connect() {
        guard let code, channel == nil else { return }
        let hosts = (browser?.browseResults ?? []).map { result -> (name: String, endpoint: NWEndpoint) in
            if case .service(let name, _, _, _) = result.endpoint { (name, result.endpoint) } else { ("yolo-meet", result.endpoint) }
        }.sorted { $0.name < $1.name }
        let tried = refused.union(unanswered).union(outdated)
        guard let host = hosts.first(where: { !tried.contains($0.name) }) else {
            guard !hosts.isEmpty else { return state = .searching }
            state = !outdated.isEmpty ? .outdated : !refused.isEmpty ? .refused : .searching
            guard !isWaiting else { return }
            isWaiting = true
            return later(seconds: 4) {
                (self.refused, self.unanswered, self.outdated, self.isWaiting) = ([], [], [], false)
                self.connect()
            }
        }
        let channel = PenChannel<HostMessage, PadMessage>(NWConnection(to: host.endpoint, using: .pen(code: code)))
        channel.received = { [weak self, weak channel] in if self?.channel === channel { self?.received?($0) } }
        channel.changed = { [weak self, weak channel] ready in
            guard let self, let channel, self.channel === channel else { return }
            if ready {
                (self.refused, self.unanswered, self.outdated, self.state) = ([], [], [], .connected(host.name))
            } else if channel.wasRefused {
                self.channel = nil
                self.refused.insert(host.name)
                self.connect()  // the next host, if there is one
            } else if channel.wasIncompatible {
                self.channel = nil
                self.outdated.insert(host.name)
                self.connect()
            } else if !self.isConnected {
                // It never got ready: the next host first, this one again with the others in a while.
                self.channel = nil
                self.unanswered.insert(host.name)
                self.connect()
            } else {
                self.channel = nil
                if case .connected = self.state { self.state = .searching }
                self.later { self.connect() }
            }
        }
        self.channel = channel
        channel.start()
        // A host that is advertised but can't be reached would leave the connection waiting for good.
        later(seconds: 5) { [weak channel] in
            if let channel, self.channel === channel, !self.isConnected { channel.close() }
        }
    }

    private var isConnected: Bool { if case .connected = state { true } else { false } }

    /// Later, unless the client was stopped or started with another code meanwhile.
    private func later(seconds: Double = 1, _ action: @escaping () -> Void) {
        Task { [code] in
            try? await Task.sleep(for: .seconds(seconds))
            if code != nil, code == self.code { action() }
        }
    }
}
