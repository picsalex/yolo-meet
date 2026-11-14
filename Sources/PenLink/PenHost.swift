import Foundation
import Network

/// The host's end of the link: advertises the service while it's started and talks to one pad at a time. A pad that
/// connects takes the place of the one before it, so a pad that dropped without saying so can come straight back; only
/// a pad that has the pairing code gets that far.
public final class PenHost {
    public var received: ((PadMessage) -> Void)?
    /// A pad connected (true), or the pad went away (false).
    public var changed: ((Bool) -> Void)?
    private var listener: NWListener?
    private var channel: PenChannel<PadMessage, HostMessage>?
    /// Connections that haven't shown they have the code yet, with where they come from, oldest first: a few seconds
    /// each, and room for a new one is always made (`makingRoom`).
    private var arriving: [(channel: PenChannel<PadMessage, HostMessage>, from: String)] = []
    /// The pairing code, while started.
    private var code: String?

    public init() {}

    /// The port it listens on, once listening (for tests).
    var port: NWEndpoint.Port? { listener?.port }

    /// Starts, or starts again when the `code` is another: the pad that had the old one is let go.
    public func start(code: String) {
        guard code != self.code else { return }
        stop()
        self.code = code
        listen()
    }

    public func stop() {
        code = nil
        listener?.cancel()
        listener = nil
        let arriving = arriving
        self.arriving = []
        for (channel, _) in arriving { channel.close() }
        drop()
    }

    /// `done` is called once the message left for the network, or at once when no pad is connected: the next of a
    /// stream of large messages (the stage's pictures) is only worth making then.
    public func send(_ message: HostMessage, then done: (@MainActor () -> Void)? = nil) {
        if let channel { channel.send(message, then: done) } else { done?() }
    }

    private func listen() {
        guard let code, let listener = try? NWListener(using: .pen(code: code)) else { return retry() }
        // Under the app's name, not the Mac's (which often has its owner's name in it): nearby devices see it too.
        listener.service = NWListener.Service(name: PenLink.serviceName, type: PenLink.service)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard case .failed = state, let self, self.listener === listener else { return }
                listener?.cancel()
                self.listener = nil
                self.retry()
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    /// The listener couldn't start or failed (the network changed): again in a moment.
    private func retry() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            if code != nil, listener == nil { listen() }
        }
    }

    /// A connection is the pad once it is ready, which takes the code: until then it changes nothing, so whoever
    /// doesn't have the code can't push the pad out. Nor can they hold the door: a new connection is never turned
    /// away, another waiting one makes room for it (`makingRoom`).
    private func accept(_ connection: NWConnection) {
        guard listener != nil else { return connection.cancel() }
        let from = Self.address(of: connection.endpoint)
        if let index = Self.makingRoom(for: from, among: arriving.map(\.from)) { arriving.remove(at: index).channel.close() }
        let channel = PenChannel<PadMessage, HostMessage>(connection)
        channel.received = { [weak self, weak channel] in if self?.channel === channel { self?.received?($0) } }
        channel.changed = { [weak self, weak channel] ready in
            guard let self, let channel else { return }
            if let index = self.arriving.firstIndex(where: { $0.channel === channel }) {
                self.arriving.remove(at: index)
                guard ready else { return }
                self.drop()
                self.channel = channel
                self.changed?(true)
            } else if self.channel === channel, !ready {
                self.channel = nil
                self.changed?(false)
            }
        }
        arriving.append((channel, from))
        channel.start()
        Task { [weak channel] in
            try? await Task.sleep(for: .seconds(4))
            if let channel, arriving.contains(where: { $0.channel === channel }) { channel.close() }
        }
    }

    /// Connections waiting at most from one address, and in all.
    static let (perAddress, waitingAtMost) = (2, 16)

    /// Which waiting connection (by index, among their addresses, oldest first) makes room for a new one from `from`,
    /// if one must: `from`'s own oldest once it has `perAddress`; when all places are taken, the oldest of the address
    /// that holds the most. Whoever floods from one address or many only pushes out their own, as long as they hold
    /// more than the pad, which holds one.
    static func makingRoom(for from: String, among waiting: [String]) -> Int? {
        let own = waiting.indices.filter { waiting[$0] == from }
        if own.count >= perAddress { return own.first }
        guard waiting.count >= waitingAtMost else { return nil }
        let counts = waiting.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let most = counts.values.max() ?? 0
        return waiting.firstIndex { counts[$0] == most }
    }

    /// The address a connection comes from, without its port.
    private static func address(of endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint { "\(host)" } else { "\(endpoint)" }
    }

    private func drop() {
        guard let channel else { return }
        self.channel = nil
        channel.close()
        changed?(false)
    }
}
