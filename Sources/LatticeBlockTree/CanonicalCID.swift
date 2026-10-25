import LatticePrimitives

/// The 32-byte sha2-256 digest of a canonical Lattice CID — CIDv1, dag-cbor,
/// sha2-256: the bytes `01 71 12 20` then the digest — held inline as four
/// words, most significant first. Every such CID is exactly its digest, so
/// the digest is the whole identity and the CID text is rebuilt from it.
///
/// Words are packed big-endian, so ordering the words orders the digest
/// bytes, which orders the CID bytes: the shared prefix never decides.
struct CIDDigest: Hashable, Comparable, Sendable {
    var w0: UInt64
    var w1: UInt64
    var w2: UInt64
    var w3: UInt64

    /// The bytes every canonical CID begins with.
    static let prefix: [UInt8] = [0x01, 0x71, 0x12, 0x20]
    /// "b" and 58 base32 digits: 36 bytes is 288 bits, 2 short of 58 digits.
    private static let textLength = 59

    /// The digest of `cid` when it is a canonical CID spelled canonically
    /// (multibase "b", lowercase, unpadded); nil for any other text,
    /// including another spelling of the same CID. Strict on purpose: decoding
    /// and `string` are then inverse, so the text a caller asks with matches
    /// exactly the text a held identity answers with.
    init?(_ cid: String) {
        let text = cid.utf8
        guard text.count == Self.textLength, text.first == UInt8(ascii: "b") else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(36)
        var buffer: UInt32 = 0
        var bits = 0
        for character in text.dropFirst() {
            let value: UInt32
            switch character {
            case UInt8(ascii: "a")...UInt8(ascii: "z"): value = UInt32(character - UInt8(ascii: "a"))
            case UInt8(ascii: "2")...UInt8(ascii: "7"): value = UInt32(character - UInt8(ascii: "2")) + 26
            default: return nil
            }
            buffer = buffer << 5 | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bits)))
            }
        }
        // The two bits past the last byte are padding and must be zero.
        guard bits == 2, buffer & 0b11 == 0, bytes.count == 36,
              bytes.prefix(4).elementsEqual(Self.prefix) else { return nil }
        self.init(digest: bytes[4...])
    }

    init(digest: some Collection<UInt8>) {
        precondition(digest.count == 32)
        var words: [UInt64] = [0, 0, 0, 0]
        for (index, byte) in digest.enumerated() {
            words[index / 8] = words[index / 8] << 8 | UInt64(byte)
        }
        self.init(w0: words[0], w1: words[1], w2: words[2], w3: words[3])
    }

    init(w0: UInt64, w1: UInt64, w2: UInt64, w3: UInt64) {
        self.w0 = w0
        self.w1 = w1
        self.w2 = w2
        self.w3 = w3
    }

    var digest: [UInt8] {
        [w0, w1, w2, w3].flatMap { word in
            (0..<8).reversed().map { UInt8(truncatingIfNeeded: word >> (UInt64($0) * 8)) }
        }
    }

    /// The canonical CID text: byte for byte `CIDIdentity.canonicalString`.
    var string: String {
        CIDIdentity.base32Multibase(Self.prefix + digest)
    }

    static func < (lhs: CIDDigest, rhs: CIDDigest) -> Bool {
        (lhs.w0, lhs.w1, lhs.w2, lhs.w3) < (rhs.w0, rhs.w1, rhs.w2, rhs.w3)
    }
}

/// A held block's identity.
typealias BlockID = CIDDigest
/// A grind's identity: the CID of the block or run its work was proven on.
typealias GrindID = CIDDigest
/// A post- or pre-state a block declares, when that state is a canonical CID.
typealias StateID = CIDDigest
