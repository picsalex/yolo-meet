import CryptoKit
import Foundation

/// Forward secrecy for the link. The pairing code's TLS (`NWParameters.pen(code:)`) proves both ends have the code
/// and encrypts what crosses, but with the code alone as its key: whoever recorded a session and learns the code later
/// could read it, the stage's pictures included. So once TLS is up, each end sends a key made for this connection
/// alone (X25519), and every message after that is sealed (ChaChaPoly) with keys made from both. Those keys are never
/// sent nor kept, so a recorded session stays unreadable even to whoever has the code. TLS still vouches that the
/// keys came from the other end.
nonisolated struct PenSession: Sendable {
    private let key = Curve25519.KeyAgreement.PrivateKey()

    /// This end's key for this connection, to send first.
    var publicKey: Data { key.publicKey.rawRepresentation }

    /// The ciphers for the two directions, from the other end's key: one seals what `Outgoing` sends, the other
    /// opens what `Incoming` sends. Nil when `peer` isn't a key.
    func ciphers<Outgoing: PenMessage, Incoming: PenMessage>(
        with peer: Data, sending: Outgoing.Type, receiving: Incoming.Type
    ) -> (seal: PenCipher, open: PenCipher)? {
        guard let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer),
            let secret = try? key.sharedSecretFromKeyAgreement(with: peerKey)
        else { return nil }
        // Both keys, in the same order at both ends, so the keys belong to this exchange alone.
        let keys = [publicKey, peer].sorted { $0.lexicographicallyPrecedes($1) }.reduce(Data(), +)
        func cipher(for sender: String) -> PenCipher {
            PenCipher(key: secret.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: Data("yolo-meet pen session".utf8), sharedInfo: Data(sender.utf8) + keys,
                outputByteCount: 32))
        }
        return (cipher(for: Outgoing.sender), cipher(for: Incoming.sender))
    }
}

/// One direction's sealing: each message is sealed with the next number as its nonce, and opened in the same order
/// (the link keeps it), so a message can't be dropped, repeated or moved without the next one failing to open.
nonisolated struct PenCipher: Sendable {
    private let key: SymmetricKey
    private var count: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    /// The sealed message and its tag; the nonce isn't sent, both ends count.
    mutating func seal(_ data: Data) -> Data? {
        defer { count += 1 }
        guard let box = try? ChaChaPoly.seal(data, using: key, nonce: nonce()) else { return nil }
        return Data(box.ciphertext) + box.tag
    }

    /// Nil when it doesn't open: it wasn't sealed with this key, or not as the next one.
    mutating func open(_ sealed: Data) -> Data? {
        defer { count += 1 }
        guard sealed.count >= 16,
            let box = try? ChaChaPoly.SealedBox(nonce: nonce(), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        else { return nil }
        return try? ChaChaPoly.open(box, using: key)
    }

    private func nonce() -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: count.bigEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}
