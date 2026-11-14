import Foundation
import Network
import Testing

@testable import PenLink

@Suite struct PenLinkTests {
    @Test func framesSplitAnywhere() {
        let sent: [PadMessage] = [
            .hello(name: "iPad"), .hover(x: 10, y: 20.5, height: 0.4), .down(id: 7, x: 1, y: 2, force: 0.8),
            .move(x: 3, y: 4, force: 1.2), .up, .undo, .clear, .set(InkSettings(color: "00FFFF", width: 9, fades: true, fadeAfter: 12, erases: true)), .hoverEnded,
        ]
        let bytes = sent.reduce(Data()) { $0 + PenFrames.frame($1) }
        // Whatever the size of the pieces the bytes arrive in, the messages come out whole and in order.
        for size in [1, 3, 7, 64, bytes.count] {
            var (frames, received) = (PenFrames(), [PadMessage]())
            for start in stride(from: 0, to: bytes.count, by: size) {
                received += frames.take(bytes[start..<min(start + size, bytes.count)])
            }
            #expect(received == sent)
        }
    }

    /// A picture crosses as its JPEG and nothing more, whole in small pieces, and other messages follow it.
    @Test func picturesCross() {
        let jpeg = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let sent: [HostMessage] = [
            .picture(jpeg: jpeg, through: 7), .removed(ids: [7]), .picture(jpeg: Data(), through: nil),
            .picture(jpeg: jpeg, through: Int(Int32.max)),
        ]
        let bytes = sent.reduce(Data()) { $0 + PenFrames.frame($1) }
        #expect(PenFrames.frame(sent[0]).count == jpeg.count + 9)  // the header and the stroke, no base64
        var (frames, received) = (PenFrames(), [HostMessage]())
        for start in stride(from: 0, to: bytes.count, by: 1 << 16) {
            received += frames.take(bytes[start..<min(start + 1 << 16, bytes.count)])
        }
        #expect(received == sent)
    }

    /// Frames that aren't a message for this end are skipped; a frame longer than any message breaks the stream.
    @Test func badFramesAreSkipped() {
        var frames = PenFrames()
        let data = PenFrames.frame(.json, Data("nonsense".utf8)) + PenFrames.frame(.json, Data(#"{"fly":{}}"#.utf8))
            + PenFrames.frame(kind: 9, Data([1, 2, 3])) + PenFrames.frame(HostMessage.picture(jpeg: Data([1]), through: 1))
            + PenFrames.frame(PadMessage.up)
        #expect(frames.take(data, as: PadMessage.self) == [.up])  // a picture isn't a pad's message
        #expect(!frames.isBroken)
        var header = Data([0])
        withUnsafeBytes(of: UInt32(PenFrames.limit + 1).bigEndian) { header.append(contentsOf: $0) }
        #expect(frames.take(header + PenFrames.frame(PadMessage.undo), as: PadMessage.self).isEmpty)
        #expect(frames.isBroken)
        #expect(frames.take(PenFrames.frame(PadMessage.undo), as: PadMessage.self).isEmpty)  // nothing after it
    }

    /// Each end's key makes the same two keys at both ends: what one seals the other opens, in order, and nothing
    /// else opens.
    @Test func sessionsSeal() throws {
        let (host, pad) = (PenSession(), PenSession())
        var hostSide = try #require(host.ciphers(with: pad.publicKey, sending: HostMessage.self, receiving: PadMessage.self))
        var padSide = try #require(pad.ciphers(with: host.publicKey, sending: PadMessage.self, receiving: HostMessage.self))
        let messages = [Data("one".utf8), Data(), Data(repeating: 7, count: 100_000)]
        let sealed = messages.map { hostSide.seal.seal($0)! }
        #expect(sealed.map { padSide.open.open($0) } == messages)
        #expect(padSide.open.open(hostSide.seal.seal(Data("four".utf8))!) == Data("four".utf8))
        // Out of order, repeated or changed, a message doesn't open.
        var late = pad.ciphers(with: host.publicKey, sending: PadMessage.self, receiving: HostMessage.self)!
        #expect(late.open.open(sealed[1]) == nil)
        var again = pad.ciphers(with: host.publicKey, sending: PadMessage.self, receiving: HostMessage.self)!
        var changed = sealed[0]
        changed[0] ^= 1
        #expect(again.open.open(changed) == nil)
        // The pad's direction has its own key: the host can't open its own messages as the pad's.
        var mirror = host.ciphers(with: pad.publicKey, sending: HostMessage.self, receiving: PadMessage.self)!
        #expect(mirror.open.open(sealed[0]) == nil)
        // Another connection's keys open nothing of this one.
        var stranger = PenSession().ciphers(with: host.publicKey, sending: PadMessage.self, receiving: HostMessage.self)!
        #expect(stranger.open.open(sealed[0]) == nil)
        #expect(host.ciphers(with: Data([1, 2, 3]), sending: HostMessage.self, receiving: PadMessage.self) == nil)
    }

    /// The host reads only small frames from the pad: a long one breaks the link.
    @Test func padFramesAreSmall() {
        var frames = PenFrames(longest: PadMessage.largestFrame)
        #expect(frames.take(PenFrames.frame(PadMessage.up), as: PadMessage.self) == [.up])
        #expect(frames.take(PenFrames.frame(.json, Data(repeating: 0x20, count: PadMessage.largestFrame + 1)), as: PadMessage.self).isEmpty)
        #expect(frames.isBroken)
    }

    /// The other end's key, then its sealed messages: whatever a newer end adds is skipped, and whatever can't be
    /// right closes the link.
    @Test func readerTakesKeyThenSealed() throws {
        let (host, pad) = (PenSession(), PenSession())
        var reader = PenReader<PadMessage, HostMessage>(session: host)
        var padSide = try #require(pad.ciphers(with: host.publicKey, sending: PadMessage.self, receiving: HostMessage.self))
        let key = PenFrames.frame(.key, Data([PenLink.version]) + pad.publicKey)
        func sealed(_ frame: Data) -> Data { PenFrames.frame(.sealed, padSide.seal.seal(frame)!) }
        // The key and a message in one read; then a newer end's frame kind, and a message this end can't decode.
        let first = try reader.read(key + sealed(PenFrames.frame(PadMessage.undo))).get()
        #expect(first.sealer != nil && first.messages == [.undo])
        let next = try reader.read(
            PenFrames.frame(kind: 9, Data([1])) + sealed(PenFrames.frame(.json, Data(#"{"fly":{}}"#.utf8)))
                + sealed(PenFrames.frame(kind: 9, Data([2]))) + sealed(PenFrames.frame(PadMessage.up))).get()
        #expect(next.sealer == nil && next.messages == [.up])
        // A changed message, a second key, or one that isn't sealed: the link is broken.
        var changed = sealed(PenFrames.frame(PadMessage.clear))
        changed[changed.endIndex - 1] ^= 1
        #expect(throws: PenReader<PadMessage, HostMessage>.Failure.broken) { try reader.read(changed).get() }
        var again = PenReader<PadMessage, HostMessage>(session: host)
        _ = try again.read(key).get()
        #expect(throws: PenReader<PadMessage, HostMessage>.Failure.broken) { try again.read(key).get() }
        var plain = PenReader<PadMessage, HostMessage>(session: host)
        _ = try plain.read(key).get()
        #expect(throws: PenReader<PadMessage, HostMessage>.Failure.broken) { try plain.read(PenFrames.frame(PadMessage.up)).get() }
    }

    /// An end of another version says so: a key of another version, no key first, or the JSON lines from before
    /// frames (read as a frame far too long).
    @Test func otherVersionsAreTold() {
        let pad = PenSession()
        for first in [
            PenFrames.frame(.key, Data([PenLink.version &+ 1]) + pad.publicKey), PenFrames.frame(.key, pad.publicKey),
            PenFrames.frame(.key, Data([PenLink.version]) + pad.publicKey.dropLast()),  // a key from before versions, starting with it
            PenFrames.frame(PadMessage.up), Data(#"{"hello":{"name":"iPad"}}"#.utf8) + Data([0x0A]),
        ] {
            var reader = PenReader<PadMessage, HostMessage>(session: PenSession())
            #expect(throws: PenReader<PadMessage, HostMessage>.Failure.incompatible) { try reader.read(first).get() }
        }
    }

    /// The host makes room for every new connection: an address that floods only pushes out its own, and when all
    /// places are taken, the busiest address gives one up, not the pad's.
    @Test func roomIsMadeFromTheBusiest() {
        #expect(PenHost.makingRoom(for: "pad", among: []) == nil)
        #expect(PenHost.makingRoom(for: "a", among: ["a", "pad", "a"]) == 0)  // its own oldest
        #expect(PenHost.makingRoom(for: "pad", among: ["a", "pad"]) == nil)
        // Eight addresses, two each, fill every place: the pad's new connection takes the oldest of one of them.
        let full = (0..<8).flatMap { ["x\($0)", "x\($0)"] }
        #expect(full.count == PenHost.waitingAtMost)
        #expect(PenHost.makingRoom(for: "pad", among: full) == 0)
        // Then the flood goes on: it never pushes out the pad, which holds one.
        var waiting = Array(full.dropFirst()) + ["pad"]
        for k in 0..<100 {
            let from = "x\(k % 8)"
            if let index = PenHost.makingRoom(for: from, among: waiting) { waiting.remove(at: index) }
            waiting.append(from)
            #expect(waiting.contains("pad"))
        }
    }

    /// Without a pad, a message is done at once: whoever waits for it to leave doesn't wait for good.
    @Test func sendingToNoPadIsDone() {
        var isDone = false
        PenHost().send(.removed(ids: [1])) { isDone = true }
        #expect(isDone)
    }

    @Test func eraserGrowsWithTheLine() {
        var ink = InkSettings(color: "FFFFFF", width: InkSettings.widths.lowerBound, fades: false, fadeAfter: 4, erases: true)
        let small = ink.eraserRadius
        ink.width = InkSettings.widths.upperBound
        #expect(small > InkSettings.widths.lowerBound / 2 && ink.eraserRadius > small)
    }

    @Test func pressFollowsForce() {
        #expect(PenLink.press(force: 1) == 1)
        #expect(PenLink.press(force: 0) == 0.35)
        #expect(PenLink.press(force: 0.5) < PenLink.press(force: 1.5))
        #expect(PenLink.press(force: 100) == 2.2)
    }

    @Test func codesAreReadAsTyped() throws {
        let code = PenCode.new()
        #expect(code.count == PenCode.length && PenCode.new() != code)
        #expect(PenCode.read(code) == code)
        #expect(PenCode.read(" " + PenCode.shown(code).lowercased() + " ") == code)
        #expect(PenCode.shown("0123456789ABCDEFGHJK") == "0123-4567-89AB-CDEF-GHJK")
        #expect(PenCode.read("oil3-4567-89ab-cdef-ghjk") == "0113456789ABCDEFGHJK")  // O, I and L are never in a code
        #expect(PenCode.read(String(code.dropLast())) == nil)
        #expect(PenCode.read(code.dropLast() + "U") == nil)
        #expect(PenCode.key(for: code).count == 32 && PenCode.key(for: code) != PenCode.key(for: PenCode.new()))
    }

    /// The link is open to an end that has the pairing code, and closed to one that has another or none: it can
    /// neither connect nor say anything. Needs sockets on this machine.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YOLO_MEET_NO_NETWORK"] == nil))
    func linkTakesTheCode() async throws {
        final class Host {
            var channels: [PenChannel<PadMessage, HostMessage>] = []
            var received: [PadMessage] = []
        }
        let (code, host) = (PenCode.new(), Host())
        let listener = try NWListener(using: .pen(code: code))
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated {
                let channel = PenChannel<PadMessage, HostMessage>(connection)
                channel.received = { host.received.append($0) }
                host.channels.append(channel)
                channel.start()
            }
        }
        listener.start(queue: .main)
        for _ in 0..<100 where (listener.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let port = try #require(listener.port)

        /// How a pad with these parameters fares: whether it got ready, and whether it was refused for its code.
        func pad(_ parameters: NWParameters, says message: PadMessage) async throws -> (isReady: Bool, wasRefused: Bool) {
            let channel = PenChannel<HostMessage, PadMessage>(NWConnection(host: "127.0.0.1", port: port, using: parameters))
            var isReady: Bool?
            channel.changed = { isReady = isReady ?? $0 }
            channel.start()
            channel.send(message)  // goes once the link is ready, if it ever is
            for _ in 0..<200 where isReady == nil { try await Task.sleep(for: .milliseconds(20)) }
            try await Task.sleep(for: .milliseconds(200))
            let result = (isReady == true, channel.wasRefused)
            channel.close()
            return result
        }
        #expect(try await pad(.pen(code: code), says: .undo) == (true, false))
        #expect(host.received == [.undo])
        #expect(try await pad(.pen(code: PenCode.new()), says: .clear) == (false, true))
        #expect(try await pad(.tcp, says: .clear) == (false, false))  // TCP connects, but the link never gets ready
        #expect(host.received == [.undo])
        listener.cancel()
        for channel in host.channels { channel.close() }
    }

    /// A pad that stopped reading holds messages back: when the connection ends, whoever waits for them to leave is
    /// told, so the stage's pictures start again for the next pad. Needs sockets on this machine.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YOLO_MEET_NO_NETWORK"] == nil))
    func waitingEndsWithTheConnection() async throws {
        final class Deaf { var connections: [NWConnection] = [] }  // accepted, sends its key, never reads
        let (listener, deaf) = (try NWListener(using: .tcp), Deaf())
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated { deaf.connections.append(connection) }
            connection.start(queue: .main)
            connection.send(content: PenFrames.frame(.key, Data([PenLink.version]) + PenSession().publicKey), completion: .idempotent)
        }
        listener.start(queue: .main)
        for _ in 0..<100 where (listener.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let port = try #require(listener.port)
        let channel = PenChannel<PadMessage, HostMessage>(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        var (isReady, left) = (false, 0)
        channel.changed = { isReady = $0 }
        channel.start()
        for _ in 0..<100 where !isReady { try await Task.sleep(for: .milliseconds(20)) }
        #expect(isReady)
        let picture = HostMessage.picture(jpeg: Data(repeating: 1, count: 1 << 20), through: nil)
        for _ in 0..<48 { channel.send(picture) { left += 1 } }
        try await Task.sleep(for: .milliseconds(500))
        #expect(left < 48)  // more than the machine holds for an end that doesn't read
        channel.close()
        #expect(left == 48)
        channel.send(picture) { left += 1 }  // and at once from then on
        #expect(left == 49)
        listener.cancel()
    }
}

/// The tests that advertise on Bonjour, one at a time: run together, each would see the others' hosts. They need the
/// local network (set `YOLO_MEET_NO_NETWORK` to skip them), and no other yolo-meet advertising the pen nearby.
@Suite(.serialized) struct PenLinkBonjourTests {
    /// The pad finds the host with Bonjour on this machine, and messages cross both ways. Needs the local network
    /// (set `YOLO_MEET_NO_NETWORK` to skip it), and no other yolo-meet advertising the pen nearby.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YOLO_MEET_NO_NETWORK"] == nil))
    func padReachesHost() async throws {
        let (host, client, code) = (PenHost(), PenClient(), PenCode.new())
        var (fromPad, fromHost) = ([PadMessage](), [HostMessage]())
        let ink = InkSettings(color: "E1FF25", width: 6, fades: false, fadeAfter: 4, erases: false)
        let style = HostMessage.settings(ink, colors: ["E1FF25", "00FFFF"])
        let picture = HostMessage.picture(jpeg: Data(repeating: 0x2F, count: 300_000), through: 1)
        var pictureLeft = false
        let stroke: [PadMessage] = [.hello(name: "test"), .down(id: 1, x: 100, y: 200, force: 1), .move(x: 110, y: 205, force: 1.5), .up]
        host.received = {
            fromPad.append($0)
            if $0 == .hello(name: "test") {
                host.send(style)
                host.send(picture) { pictureLeft = true }
            }
        }
        client.received = { fromHost.append($0) }
        client.changed = { if case .connected = $0 { stroke.forEach(client.send) } }
        host.start(code: code)
        client.start(code: code)
        for _ in 0..<150 where fromPad.count < stroke.count || fromHost.count < 2 { try await Task.sleep(for: .milliseconds(100)) }
        client.stop()
        host.stop()
        #expect(fromPad == stroke)
        #expect(fromHost == [style, picture])
        #expect(pictureLeft)
    }

    /// Connections that never prove they have the code can't keep the pad out: a flood of them from one address only
    /// ever holds two places, so the pad gets in. Needs sockets on this machine (and advertises the host on it).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YOLO_MEET_NO_NETWORK"] == nil))
    func stallingConnectionsDontKeepThePadOut() async throws {
        let (host, code) = (PenHost(), PenCode.new())
        var connected = false
        host.changed = { if $0 { connected = true } }
        host.start(code: code)
        for _ in 0..<100 where (host.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let port = try #require(host.port)
        // Plain TCP: they connect, and never say anything.
        let stalls = (0..<20).map { _ in NWConnection(host: "127.0.0.1", port: port, using: .tcp) }
        for stall in stalls { stall.start(queue: .main) }
        try await Task.sleep(for: .milliseconds(300))
        let pad = PenChannel<HostMessage, PadMessage>(NWConnection(host: "127.0.0.1", port: port, using: .pen(code: code)))
        pad.start()
        for _ in 0..<100 where !connected { try await Task.sleep(for: .milliseconds(20)) }
        #expect(connected)
        pad.close()
        for stall in stalls { stall.cancel() }
        host.stop()
    }

    /// A host that is advertised but never answers (here: it takes the connection and says nothing) doesn't keep the
    /// pad from the right one, even when its name comes first. Needs the local network, and no other yolo-meet
    /// advertising the pen nearby.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YOLO_MEET_NO_NETWORK"] == nil))
    func padSkipsAHostThatNeverAnswers() async throws {
        final class Stalled { var connections: [NWConnection] = [] }
        let (stall, stalled) = (try NWListener(using: .tcp), Stalled())
        stall.service = NWListener.Service(name: "a stalled host", type: PenLink.service)  // sorts first
        stall.newConnectionHandler = { connection in
            MainActor.assumeIsolated { stalled.connections.append(connection) }
            connection.start(queue: .main)
        }
        stall.start(queue: .main)
        let (host, client, code) = (PenHost(), PenClient(), PenCode.new())
        var states: [PenClient.State] = []
        client.changed = { states.append($0) }
        host.start(code: code)
        // The client starts once both are advertised, so that it sees the stalled host first.
        let browser = NWBrowser(for: .bonjour(type: PenLink.service, domain: nil), using: .tcp)
        var names: Set<String> = []
        browser.browseResultsChangedHandler = { results, _ in
            let found = results.compactMap { if case .service(let name, _, _, _) = $0.endpoint { name } else { nil } }
            MainActor.assumeIsolated { names = Set(found) }
        }
        browser.start(queue: .main)
        for _ in 0..<100 where !names.isSuperset(of: ["a stalled host", PenLink.serviceName]) {
            try await Task.sleep(for: .milliseconds(50))
        }
        browser.cancel()
        client.start(code: code)
        for _ in 0..<150 where !states.contains(where: { if case .connected = $0 { true } else { false } }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(states.last == .connected(PenLink.serviceName))
        #expect(!stalled.connections.isEmpty)  // it did try the stalled host first
        client.stop()
        host.stop()
        stall.cancel()
    }
}
