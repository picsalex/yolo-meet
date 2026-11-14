import Foundation
import Network

extension NWParameters {
    /// For finding the host: on the network the devices share, or straight between them (peer-to-peer Wi-Fi) when
    /// they share none.
    nonisolated static var penBrowsing: NWParameters {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        return parameters
    }

    /// For the link: TCP without delay, encrypted (TLS) with a key both ends make from the pairing `code`. An end
    /// that doesn't have the code can't connect, and what crosses can't be read or changed on the way. Keepalive
    /// notices within a few seconds that the other end is gone.
    nonisolated static func pen(code: String) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        (tcp.enableKeepalive, tcp.keepaliveIdle, tcp.keepaliveInterval, tcp.keepaliveCount) = (true, 2, 1, 3)
        let tls = NWProtocolTLS.Options()
        let key = PenCode.key(for: code).withUnsafeBytes { DispatchData(bytes: $0) }
        let name = Data("yolo-meet pen".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key as __DispatchData, name as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_256_GCM_SHA384))!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}

/// One connection between the pad and the host: messages in order, each way (`PenFrames`). Once TLS is up, each end
/// sends its key for the connection, and every message after that is sealed (`PenSession`); the channel is ready only
/// then, and messages sent before wait for it. The connection's events arrive, and its frames are read and opened, on
/// a queue of its own (a picture is large); messages and changes reach `received` and `changed` on the main thread,
/// in order.
final class PenChannel<Incoming: PenMessage, Outgoing: PenMessage> {
    var received: ((Incoming) -> Void)?
    /// The connection is ready (true) or over (false): once over it doesn't come back.
    var changed: ((Bool) -> Void)?
    /// It is over because the two ends don't have the same pairing code.
    private(set) var wasRefused = false
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "PenLink", qos: .userInteractive)
    private let session = PenSession()
    /// Seals what this end sends, once both keys are in.
    private var sealer: PenCipher?
    /// Messages sent before then, by number.
    private var pending: [(number: Int, message: Outgoing)] = []
    private var isOver = false
    /// Who waits for a message to leave, by the message's number.
    private var waiting: [Int: @MainActor () -> Void] = [:]
    private var sent = 0

    init(_ connection: NWConnection) { self.connection = connection }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case .ready: self.connection.send(content: PenFrames.frame(.key, self.session.publicKey), completion: .idempotent)
                    case .failed(.tls), .waiting(.tls):
                        self.wasRefused = true
                        self.close()
                    case .failed, .cancelled: self.over()
                    default: break  // waiting: the network may come back, or keepalive ends it
                    }
                }
            }
        }
        connection.start(queue: queue)
        Self.receive(connection, into: Reader(session: session)) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.isOver else { return }
                    switch event {
                    case .ready(let sealer):
                        self.sealer = sealer
                        let pending = self.pending
                        self.pending = []
                        for (number, message) in pending { self.transmit(message, number: number) }
                        self.changed?(true)
                    case .messages(let messages):
                        for message in messages { self.received?(message) }
                    case .ended(let wasRefused):
                        if wasRefused { self.wasRefused = true }  // the handshake's failure can show here first
                        self.close()
                    }
                }
            }
        }
    }

    /// `done` is called once the message left for the network, or when the connection is over, whichever is first:
    /// a message can wait for as long as the other end doesn't read.
    func send(_ message: Outgoing, then done: (@MainActor () -> Void)? = nil) {
        guard !isOver else { return done?() ?? () }
        sent += 1
        waiting[sent] = done
        if sealer == nil { pending.append((sent, message)) } else { transmit(message, number: sent) }
    }

    func close() {
        connection.cancel()
        over()
    }

    /// Seals a message and sends it.
    private func transmit(_ message: Outgoing, number: Int) {
        guard let sealed = sealer?.seal(PenFrames.frame(message)) else { return close() }
        connection.send(content: PenFrames.frame(.sealed, sealed), completion: .contentProcessed { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { _ = self?.waiting.removeValue(forKey: number)?() }
            }
        })
    }

    private nonisolated enum Event: Sendable {
        /// Both keys are in: what this end sends is sealed with this.
        case ready(PenCipher)
        case messages([Incoming])
        case ended(wasRefused: Bool)
    }

    /// What the connection's queue keeps: the frames read so far, and the other end's sealing once its key is in.
    private nonisolated final class Reader: @unchecked Sendable {
        let session: PenSession
        var frames = PenFrames(longest: Incoming.largestFrame + 64)  // and the frame and seal around it
        var opener: PenCipher?

        init(session: PenSession) { self.session = session }

        /// The events in what was just read: the other end's key, then its sealed messages; nil when the link is
        /// broken (something that isn't either, or a message that doesn't open).
        func read(_ data: Data) -> [Event]? {
            var events: [Event] = [], messages: [Incoming] = []
            for frame in frames.split(data) {
                switch PenFrames.Kind(rawValue: frame.kind) {
                case .key where opener == nil:
                    guard let ciphers = session.ciphers(with: frame.payload, sending: Outgoing.self, receiving: Incoming.self)
                    else { return nil }
                    opener = ciphers.open
                    events.append(.ready(ciphers.seal))
                case .sealed where opener != nil:
                    guard let inner = opener?.open(frame.payload), let message = PenFrames.message(inFrame: inner, as: Incoming.self)
                    else { return nil }
                    messages.append(message)
                default:
                    return nil  // unsealed messages, a second key, or a kind this end doesn't know
                }
            }
            return frames.isBroken ? nil : events + (messages.isEmpty ? [] : [.messages(messages)])
        }
    }

    /// Reads the connection on its queue, and hands what it read to `deliver`, until it ends.
    private nonisolated static func receive(
        _ connection: NWConnection, into reader: Reader, deliver: @escaping @Sendable (Event) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
            let events = reader.read(data ?? Data())
            for event in events ?? [] { deliver(event) }
            guard events != nil, !isComplete, error == nil else {
                var wasRefused = false
                if case .tls = error { wasRefused = true }
                return deliver(.ended(wasRefused: wasRefused))
            }
            receive(connection, into: reader, deliver: deliver)
        }
    }

    private func over() {
        guard !isOver else { return }
        isOver = true
        pending = []
        let waiting = waiting.values
        self.waiting = [:]
        for done in waiting { done() }
        changed?(false)
    }
}
