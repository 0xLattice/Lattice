import Foundation
import Crypto
import Multikey
import cashew
import CID
import Multicodec

public struct CryptoUtils {
    public static let signatureDomain = "lattice-tx-v1:"

    // MARK: - Key Generation (Ed25519 default)

    public static func generateKeyPair() -> (privateKey: String, publicKey: String) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let pubKeyData = privateKey.publicKey.rawRepresentation
        let privKeyData = privateKey.rawRepresentation
        let mk = Multikey(keyType: .ed25519, keyBytes: pubKeyData)
        return (privKeyData.hexString, mk.hexEncoded)
    }

    // MARK: - Signing

    public static func sign(message: String, privateKeyHex: String) -> String? {
        guard let privateKeyData = Data(hex: privateKeyHex),
              let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData) else {
            return nil
        }
        let messageData = signaturePayload(message)
        guard let signature = try? privateKey.signature(for: messageData) else { return nil }
        return signature.hexString
    }

    // MARK: - Verification (dispatches by key type in Multikey encoding)

    public static func verify(message: String, signature: String, publicKeyHex: String) -> Bool {
        guard let sigData = Data(hex: signature),
              sigData.hexString == signature else { return false }
        let messageData = signaturePayload(message)

        // Exactly ONE accepted key encoding: Multikey. The pre-genesis legacy
        // branch that also accepted a bare 32-byte Ed25519 hex key gave the
        // same key two valid encodings on live consensus surface — fail closed
        // on anything that is not canonical Multikey.
        guard let (mk, canonical) = multikey(fromHex: publicKeyHex),
              canonical == publicKeyHex else {
            return false
        }
        return verifyWithMultikey(mk, message: messageData, signature: sigData)
    }

    /// `Multikey.decode(fromHex:)` and the key's `hexEncoded`: Multikey reads
    /// hex exactly as `Data(hex:)` does and spells it as `hexString` does,
    /// so these are the same values, without formatting a string per byte.
    static func multikey(fromHex hex: String) -> (key: Multikey, hex: String)? {
        guard let data = Data(hex: hex), let key = try? Multikey.decode(from: data) else { return nil }
        return (key, key.encode().hexString)
    }

    static func signaturePayload(_ message: String) -> Data {
        var data = Data(signatureDomain.utf8)
        data.append(contentsOf: message.utf8)
        return data
    }

    private static func verifyWithMultikey(_ mk: Multikey, message: Data, signature: Data) -> Bool {
        switch mk.keyType {
        case .ed25519:
            guard mk.keyBytes.count == 32,
                  let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: mk.keyBytes),
                  signature.count == 64 else { return false }
            return pubKey.isValidSignature(signature, for: message)
        default:
            return false
        }
    }

    // MARK: - Address derivation

    /// Derive an address from a public key.
    /// Returns the CID of the PublicKey struct — consistent with the on-chain
    /// address format used since the original protocol design.
    public static func createAddress(from publicKey: String) -> String {
        let publicKey = multikey(fromHex: publicKey)?.hex ?? publicKey
        // known-valid local node; CID computation cannot fail (no Float/Double fields)
        return try! HeaderImpl<PublicKey>(node: PublicKey(key: publicKey)).rawCID
    }

    /// Cheap structural pre-check: `address` is a canonical CIDv1 / dag-cbor /
    /// sha2-256 (32-byte) CID — the shape `createAddress(from:)` produces. This
    /// is necessary but NOT sufficient: a structurally valid CID for any other
    /// content also passes. Callers that disburse value MUST additionally bind
    /// the address to a public key via ``isAddress(_:of:)``. Decodes with the
    /// same `CID` primitive used to *build* the address — no bespoke base32 —
    /// and rejects non-canonical encodings (the re-encoded form must match the
    /// input byte-for-byte).
    public static func isValidAddress(_ address: String) -> Bool {
        guard let cid = try? CID(address) else { return false }
        guard cid.version == .v1, cid.codec == .dag_cbor else { return false }
        guard cid.multihash.algorithm == .sha2_256, cid.multihash.length == 32 else { return false }
        return CIDIdentity.isCanonical(address)
    }

    /// Confirm `address` is the CID of the `PublicKey` for `publicKeyHex` — i.e.
    /// it round-trips through the exact construction path ``createAddress(from:)``
    /// uses. A structurally-valid CID for any other content fails here. Fail
    /// closed: also require the structural check so a malformed `publicKeyHex`
    /// that happens to derive a matching string cannot slip through.
    public static func isAddress(_ address: String, of publicKeyHex: String) -> Bool {
        guard isValidAddress(address) else { return false }
        return createAddress(from: publicKeyHex) == address
    }

    // MARK: - Hashing

    public static func sha256(_ input: String) -> String {
        Data(SHA256.hash(data: Data(input.utf8))).hexString
    }
}

public extension Data {
    init?(hex: String) {
        guard let data = hexBytes(hex) else { return nil }
        self = data
    }

    /// Lowercase, two digits per byte: what `String(format: "%02x")` spells.
    var hexString: String {
        String(unsafeUninitializedCapacity: count * 2) { buffer in
            var index = 0
            for byte in self {
                buffer[index] = hexDigit(byte >> 4)
                buffer[index + 1] = hexDigit(byte & 0x0f)
                index += 2
            }
            return index
        }
    }
}

@inline(__always)
private func hexDigit(_ value: UInt8) -> UInt8 {
    value < 10 ? value &+ UInt8(ascii: "0") : value &- 10 &+ UInt8(ascii: "a")
}

@inline(__always)
private func hexValue(_ digit: UInt8) -> UInt8? {
    switch digit {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): digit &- UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): digit &- UInt8(ascii: "a") &+ 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): digit &- UInt8(ascii: "A") &+ 10
    default: nil
    }
}

/// `Data(hex:)`. Text of ASCII hex digits alone, after an optional `0x`, is
/// read a byte at a time. Anything else takes the Character-wise parse,
/// which is what defines the result: it counts Characters, and
/// `UInt8(_:radix:)` also takes a sign (`+f`, `-0`). On ASCII hex digits
/// the two agree.
package func hexBytes(_ hex: String) -> Data? {
    var digits = Substring(hex).utf8
    if digits.starts(with: "0x".utf8) { digits = digits.dropFirst(2) }
    if digits.allSatisfy({ hexValue($0) != nil }) {
        guard digits.count % 2 == 0 else { return nil }
        var data = Data(count: digits.count / 2)
        data.withUnsafeMutableBytes { bytes in
            var index = digits.startIndex
            for offset in 0..<bytes.count {
                let high = hexValue(digits[index])!
                index = digits.index(after: index)
                bytes[offset] = high << 4 | hexValue(digits[index])!
                index = digits.index(after: index)
            }
        }
        return data
    }
    let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
    guard clean.count % 2 == 0 else { return nil }
    var data = Data(capacity: clean.count / 2)
    var index = clean.startIndex
    while index < clean.endIndex {
        let next = clean.index(index, offsetBy: 2)
        guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
        data.append(byte)
        index = next
    }
    return data
}
