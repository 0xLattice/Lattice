
/// The 32-byte sha2-256 digest of a canonical Lattice CID — CIDv1, dag-cbor,
/// sha2-256: the bytes `01 71 12 20` then the digest — held inline as four
/// words, most significant first. Every such CID is exactly its digest, so
/// the digest is the whole identity and the CID text is rebuilt from it.
///
/// Words are packed big-endian, so ordering the words orders the digest
/// bytes, which orders the CID bytes: the shared prefix never decides.
package struct CIDDigest: Hashable, Comparable, Sendable {
    package var w0: UInt64
    package var w1: UInt64
    package var w2: UInt64
    package var w3: UInt64

    /// The bytes every canonical CID begins with.
    static let prefix: [UInt8] = [0x01, 0x71, 0x12, 0x20]
    /// "b" and 58 base32 digits: 36 bytes is 288 bits, 2 short of 58 digits.
    private static let textLength = 59

    /// The digest of `cid` when it is a canonical CID spelled canonically
    /// (multibase "b", lowercase, unpadded); nil for any other text,
    /// including another spelling of the same CID. Strict on purpose: decoding
    /// and `string` are then inverse, so the text a caller asks with matches
    /// exactly the text a held identity answers with.
    package init?(_ cid: String) {
        let text = cid.utf8
        guard text.count == Self.textLength, text.first == UInt8(ascii: "b") else { return nil }
        // Decoded straight into the words: byte n of the 36 is the prefix
        // for n < 4, then digest byte n - 4.
        var words: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
        var buffer: UInt32 = 0
        var bits = 0
        var index = 0
        for character in text.dropFirst() {
            let value: UInt32
            switch character {
            case UInt8(ascii: "a")...UInt8(ascii: "z"): value = UInt32(character - UInt8(ascii: "a"))
            case UInt8(ascii: "2")...UInt8(ascii: "7"): value = UInt32(character - UInt8(ascii: "2")) + 26
            default: return nil
            }
            buffer = buffer << 5 | value
            bits += 5
            guard bits >= 8 else { continue }
            bits -= 8
            let byte = UInt64(UInt8(truncatingIfNeeded: buffer >> UInt32(bits)))
            switch index {
            case 0..<4: guard byte == UInt64(Self.prefix[index]) else { return nil }
            case 4..<12: words.0 = words.0 << 8 | byte
            case 12..<20: words.1 = words.1 << 8 | byte
            case 20..<28: words.2 = words.2 << 8 | byte
            default: words.3 = words.3 << 8 | byte
            }
            index += 1
        }
        // The two bits past the last byte are padding and must be zero.
        guard bits == 2, buffer & 0b11 == 0, index == 36 else { return nil }
        self.init(w0: words.0, w1: words.1, w2: words.2, w3: words.3)
    }

    package init(w0: UInt64, w1: UInt64, w2: UInt64, w3: UInt64) {
        self.w0 = w0
        self.w1 = w1
        self.w2 = w2
        self.w3 = w3
    }

    /// Byte `index` of the 36-byte CID: the prefix, then the digest.
    @inline(__always)
    private func cidByte(_ index: Int) -> UInt8 {
        if index < 4 { return Self.prefix[index] }
        let offset = index - 4
        let word: UInt64
        switch offset >> 3 {
        case 0: word = w0
        case 1: word = w1
        case 2: word = w2
        default: word = w3
        }
        return UInt8(truncatingIfNeeded: word >> UInt64((7 - offset & 7) * 8))
    }

    /// The canonical CID text: byte for byte `CIDIdentity.canonicalString`
    /// (multibase "b", lowercase base32, unpadded), encoded straight from the
    /// words into the string's own storage.
    package var string: String {
        String(unsafeUninitializedCapacity: Self.textLength) { out in
            let alphabet: StaticString = "abcdefghijklmnopqrstuvwxyz234567"
            let digits = alphabet.utf8Start
            out[0] = UInt8(ascii: "b")
            var position = 1
            var buffer: UInt32 = 0
            var bits = 0
            for index in 0..<36 {
                buffer = buffer << 8 | UInt32(cidByte(index))
                bits += 8
                while bits >= 5 {
                    bits -= 5
                    out[position] = digits[Int(buffer >> UInt32(bits) & 31)]
                    position += 1
                }
            }
            // 288 bits: the last digit carries 3 bits and 2 zero bits.
            out[position] = digits[Int(buffer << UInt32(5 - bits) & 31)]
            return position + 1
        }
    }

    package static func < (lhs: CIDDigest, rhs: CIDDigest) -> Bool {
        (lhs.w0, lhs.w1, lhs.w2, lhs.w3) < (rhs.w0, rhs.w1, rhs.w2, rhs.w3)
    }
}

