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
    /// It is over because the other end is another version of the link (`PenLink.version`).
    private(set) var wasIncompatible = false
    /// TLS is up: the other end has shown it has the pairing code (its keys may still be on their way).
    private(set) var hasCode = false
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
                    case .ready:
                        self.hasCode = true
                        let key = PenFrames.frame(.key, Data([PenLink.version]) + self.session.publicKey)
                        self.connection.send(content: key, completion: .idempotent)
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
        Self.receive(connection, into: Box(reader: PenReader(session: session))) { [weak self] event in
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
                    case .ended(let wasRefused, let wasIncompatible):
                        if wasRefused { self.wasRefused = true }  // the handshake's failure can show here first
                        if wasIncompatible { self.wasIncompatible = true }
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
        case ended(wasRefused: Bool, wasIncompatible: Bool)
    }

    /// The reader, on the connection's queue only.
    private nonisolated final class Box: @unchecked Sendable {
        var reader: PenReader<Incoming, Outgoing>
        init(reader: PenReader<Incoming, Outgoing>) { self.reader = reader }
    }

    /// Reads the connection on its queue, and hands what it read to `deliver`, until it ends.
    private nonisolated static func receive(
        _ connection: NWConnection, into box: Box, deliver: @escaping @Sendable (Event) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
            let read = box.reader.read(data ?? Data())
            if case .success(let (sealer, messages)) = read {
                if let sealer { deliver(.ready(sealer)) }
                if !messages.isEmpty { deliver(.messages(messages)) }
            }
            var wasRefused = false
            if case .tls = error { wasRefused = true }
            if case .failure(let failure) = read {
                return deliver(.ended(wasRefused: wasRefused, wasIncompatible: failure == .incompatible))
            }
            guard !isComplete, error == nil else { return deliver(.ended(wasRefused: wasRefused, wasIncompatible: false)) }
            receive(connection, into: box, deliver: deliver)
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

/// One end's reading of the link: the other end's key (`PenLink.version` first), then its sealed messages.
///
/// What a newer end may add is skipped: frames of kinds this end doesn't know, and messages it can't decode. What
/// can't be right closes the link: a message that doesn't open (changed, dropped, repeated or moved), a second key, a
/// message that isn't sealed, a frame too long. An end whose first frame isn't a key of this version is another
/// version of the link (or of the app, from before it had keys).
nonisolated struct PenReader<Incoming: PenMessage, Outgoing: PenMessage>: Sendable {
    enum Failure: Error, Equatable { case incompatible, broken }

    let session: PenSession
    private var frames = PenFrames(longest: Incoming.largestFrame + 64)  // and the frame and seal around it
    private var opener: PenCipher?

    init(session: PenSession) { self.session = session }

    /// What was just read: the sealer for what this end sends, once the other end's key is in, and its messages.
    mutating func read(_ data: Data) -> Result<(sealer: PenCipher?, messages: [Incoming]), Failure> {
        var sealer: PenCipher?
        var messages: [Incoming] = []
        for frame in frames.split(data) {
            let kind = PenFrames.Kind(rawValue: frame.kind)
            guard opener != nil else {
                // The version, then an X25519 key (32 bytes).
                guard kind == .key, frame.payload.count == 33, frame.payload.first == PenLink.version else {
                    return .failure(.incompatible)
                }
                guard let ciphers = session.ciphers(with: frame.payload.dropFirst(), sending: Outgoing.self, receiving: Incoming.self)
                else { return .failure(.broken) }
                (opener, sealer) = (ciphers.open, ciphers.seal)
                continue
            }
            switch kind {
            case .sealed:
                guard let inner = opener?.open(frame.payload) else { return .failure(.broken) }
                if let message = PenFrames.message(inFrame: inner, as: Incoming.self) { messages.append(message) }
            case .key, .json, .picture:
                return .failure(.broken)
            case nil:
                continue  // a kind from a newer end
            }
        }
        guard !frames.isBroken else { return .failure(opener == nil ? .incompatible : .broken) }
        return .success((sealer, messages))
    }
}
