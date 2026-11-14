import CryptoKit
import Foundation

/// The pairing code: a secret yolo-meet makes and shows in its panel, typed once into the pen app. Both ends make the
/// link's key from it (`NWParameters.pen(code:)`), so only a pad that has the code can connect, and nobody else on the
/// network can read or change what crosses.
public nonisolated enum PenCode {
    /// Digits and letters that aren't mistaken for one another: no I, L, O or U.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    /// Characters in a code, five bits each: 100 bits, far too many to find by trying.
    public static let length = 20

    public static func new() -> String {
        var random = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &random)] })
    }

    /// The code as it was typed: without dashes and spaces, in capitals, and with the letters it never has read as
    /// the digits they look like. Nil when that isn't a whole code.
    public static func read(_ typed: String) -> String? {
        var code = ""
        for character in typed.uppercased() where character != "-" && !character.isWhitespace {
            code.append(character == "O" ? "0" : character == "I" || character == "L" ? "1" : character)
        }
        return code.count == length && code.allSatisfy(alphabet.contains) ? code : nil
    }

    /// The code in groups of four, to read and type.
    public static func shown(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { String(code.dropFirst($0).prefix(4)) }.joined(separator: "-")
    }

    /// The link's key for a code.
    static func key(for code: String) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(code.utf8)), salt: Data("yolo-meet pen".utf8),
            info: Data("link key".utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }
}
