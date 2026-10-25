import Foundation
import Crypto
import CID
import Synchronization

/// Normalizes textual CID input before it becomes a consensus identity key.
public enum CIDIdentity {
    // Structural: a CID is length-prefixed with a UInt16 in the child-proof wire
    // format, so this is the encoding capacity, not a policy cap on CID length.
    // The canonical round-trip below is the real identity check; this only bounds
    // parse work on untrusted input to what the wire can represent.
    static let maximumTextBytes = Int(UInt16.max)

    /// Strings already proven canonical. The check is a pure function of the
    /// string but costs a full multibase parse, and the same
    /// identity recurs across a block's facts and its successors' (hash,
    /// parent, state, spec), so each is proven once. A canonical string is its
    /// own canonical form, so membership is the whole answer. Bounded: the set
    /// is dropped when full and holds only strings of at most
    /// `provenCanonicalMaxBytes` (a real CID is ~59), so distinct inputs —
    /// near-64 KiB CIDs from a peer included — cost at most a few MiB.
    ///
    /// ASCII only: `String` equality is Unicode canonical equivalence, under
    /// which a non-ASCII spelling (U+212A KELVIN SIGN for "K") would match a
    /// remembered ASCII CID that the parser itself refuses. Between ASCII
    /// strings equality is byte equality.
    private static let provenCanonical = Mutex<Set<String>>([])
    static let provenCanonicalCapacity = 1 << 16
    static let provenCanonicalMaxBytes = 128

    public static func canonicalString(_ value: String) -> String? {
        let memoizable = value.utf8.count <= provenCanonicalMaxBytes
            && value.utf8.allSatisfy { $0 < 0x80 }
        if memoizable, provenCanonical.withLock({ $0.contains(value) }) { return value }
        guard let canonical = parseCanonicalString(value) else { return nil }
        if memoizable, canonical == value {
            provenCanonical.withLock {
                if $0.count >= provenCanonicalCapacity { $0.removeAll(keepingCapacity: true) }
                $0.insert(value)
            }
        }
        return canonical
    }

    package static func isProvenCanonical(_ value: String) -> Bool {
        provenCanonical.withLock { $0.contains(value) }
    }

    /// Start from an empty set, so a measurement sees cold-cache cost.
    package static func forgetProvenCanonical() {
        provenCanonical.withLock { $0.removeAll() }
    }

    private static func parseCanonicalString(_ value: String) -> String? {
        guard !value.isEmpty,
              value.utf8.count <= maximumTextBytes,
              let parsed = try? CID(value),
              let canonical = try? CID(
                version: parsed.version,
                codec: parsed.codec,
                multihash: parsed.multihash
              )
        else { return nil }
        guard canonical.version == .v1 else { return canonical.toBaseEncodedString }
        return base32Multibase(canonical.rawBuffer)
    }

    private static let base32Alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

    /// Multibase base32 — "b" then RFC 4648 lowercase, unpadded: the text
    /// `CID.toBaseEncodedString` gives every v1 CID. Encoded here because the
    /// library's generic encoder was most of the identity check's cost; a test
    /// pins this to the library's output.
    package static func base32Multibase(_ bytes: [UInt8]) -> String {
        var text = [UInt8(ascii: "b")]
        text.reserveCapacity(1 + (bytes.count * 8 + 4) / 5)
        var buffer: UInt32 = 0
        var bits = 0
        for byte in bytes {
            buffer = buffer << 8 | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                text.append(base32Alphabet[Int(buffer >> UInt32(bits) & 31)])
            }
        }
        if bits > 0 {
            text.append(base32Alphabet[Int(buffer << UInt32(5 - bits) & 31)])
        }
        return String(decoding: text, as: UTF8.self)
    }

    public static func isCanonical(_ value: String) -> Bool {
        canonicalString(value) == value
    }

    /// Whether `value` is Lattice's one standard CID, spelled canonically:
    /// CIDv1, dag-cbor, sha2-256, a 32-byte digest — the bytes `01 71 12 20`
    /// then the digest (`CIDDigest`). Every CID link in a block header must
    /// be one; a header with any other link is malformed (spec §3.1).
    public static func isStandard(_ value: String) -> Bool {
        CIDDigest(value) != nil
    }

    /// The standard CID naming `data`, whatever `data` decodes as.
    package static func standardCID(of data: Data) -> String {
        base32Multibase([0x01, 0x71, 0x12, 0x20] + Array(SHA256.hash(data: data)))
    }
}
