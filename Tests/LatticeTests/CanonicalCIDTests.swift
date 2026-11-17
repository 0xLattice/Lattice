import XCTest
import CID
@testable import LatticePrimitives
@testable import LatticeBlockTree

/// The block tree keys blocks, grinds and states by their 32-byte digest.
/// That is only sound because every key it accepts is the one canonical
/// shape (dag-cbor sha2-256 CIDv1), and the tie-break it applies to digests
/// is the CID byte order the protocol specifies.
final class CanonicalCIDTests: XCTestCase {
    private func cid(_ seed: Int) -> String {
        testCID("canonical-\(seed)")
    }

    func testDigestOrderIsCIDByteOrder() throws {
        let cids = (0..<200).map(cid)
        for (a, b) in zip(cids, cids.dropFirst() + cids.prefix(1)) {
            let left = try XCTUnwrap(CIDDigest(a)), right = try XCTUnwrap(CIDDigest(b))
            XCTAssertEqual(left < right, forkChoicePrefersBlock(a, over: b), "\(a) vs \(b)")
            XCTAssertEqual(right < left, forkChoicePrefersBlock(b, over: a), "\(b) vs \(a)")
        }
    }

    func testDigestRoundTripsTheCanonicalText() throws {
        for seed in 0..<50 {
            let text = cid(seed)
            XCTAssertEqual(try XCTUnwrap(CIDDigest(text)).string, text)
        }
    }

    func testOnlyTheCanonicalShapeHasADigest() throws {
        let text = cid(0)
        let digest = Array(try CID(text).rawBuffer.suffix(32))
        let raw = CIDIdentity.base32Multibase([0x01, 0x55, 0x12, 0x20] + digest)
        XCTAssertNil(CIDDigest(raw), "raw codec")
        XCTAssertNil(CIDDigest(text.uppercased()), "a spelling other than the canonical text")
        XCTAssertNil(CIDDigest("not-a-cid"))
    }

    /// `CIDDigest` and the canonical-string shortcut it gives answer as the
    /// library's parse and re-encode does, for the canonical text and for
    /// near misses: other spellings, other shapes, broken text.
    func testDigestAndCanonicalStringMatchTheLibraryParse() throws {
        func libraryCanonical(_ text: String) -> String? {
            guard let parsed = try? CID(text),
                  let rebuilt = try? CID(version: parsed.version, codec: parsed.codec, multihash: parsed.multihash)
            else { return nil }
            return rebuilt.toBaseEncodedString
        }
        let digits = Array("abcdefghijklmnopqrstuvwxyz234567")
        let noise = Array("abcdefghijklmnopqrstuvwxyz234567ABZ=01b\u{212A}")
        for seed in 0..<300 {
            let text = cid(seed)
            var texts = [text, text.uppercased(), String(text.dropLast()), text + "a", " " + text]
            let last = digits.firstIndex(of: text.last!)!
            for pad in 1...3 { texts.append(String(text.dropLast()) + String(digits[(last & ~3) | pad])) }
            let digest = Array(try CID(text).rawBuffer.suffix(32))
            texts.append(CIDIdentity.base32Multibase([0x01, 0x55, 0x12, 0x20] + digest))
            texts.append(CIDIdentity.base32Multibase([0x01, 0x71, 0x12, 0x20] + digest + [0]))
            for _ in 0..<40 {
                var characters = Array(text)
                characters[Int.random(in: 0..<characters.count)] = noise.randomElement()!
                texts.append(String(characters))
            }
            for candidate in texts {
                let canonical = libraryCanonical(candidate)
                XCTAssertEqual(CIDIdentity.canonicalString(candidate), canonical, candidate)
                let standard = canonical == candidate
                    && (try? CID(candidate))?.rawBuffer.prefix(4).elementsEqual([0x01, 0x71, 0x12, 0x20]) == true
                    && (try? CID(candidate))?.rawBuffer.count == 36
                XCTAssertEqual(CIDDigest(candidate) != nil, standard, candidate)
                if let held = CIDDigest(candidate) { XCTAssertEqual(held.string, candidate) }
            }
        }
    }
}
