import XCTest
import UInt256
import CID
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport

final class CIDIdentityTests: XCTestCase {
    /// CIDv1 encoded in multibase base16 rather than Lattice's canonical
    /// base32. It names the exact same raw CID as `canonicalCID` below.
    private let alternateCID =
        "f01711220e9eb6c60800df90fc8e237ed53246f396e87579aba406aaa7976a056859ee22d"

    private func contribution(
        id: String,
        work: UInt64
    ) -> VerifiedWorkContribution {
        try! JSONDecoder().decode(
            VerifiedWorkContribution.self,
            from: Data("{\"id\":\"\(id)\",\"work\":\"0x\(String(work, radix: 16))\"}".utf8)
        )
    }

    func testCanonicalCIDIdentityNormalizesEquivalentAlternateMultibase() throws {
        let canonicalCID = try XCTUnwrap(CIDIdentity.canonicalString(alternateCID))

        XCTAssertNotEqual(canonicalCID, alternateCID)
        XCTAssertTrue(CIDIdentity.isCanonical(canonicalCID))
        XCTAssertFalse(CIDIdentity.isCanonical(alternateCID))
    }

    func testAliasCannotBecomeASecondPhysicalGrind() throws {
        let canonicalCID = try XCTUnwrap(CIDIdentity.canonicalString(alternateCID))
        let work = WorkMeasure([
            contribution(id: canonicalCID, work: 7),
            contribution(id: alternateCID, work: 11),
        ])

        XCTAssertEqual(Set(work.entries.keys), [canonicalCID])
        XCTAssertEqual(work.total, WorkSum(UInt256(11)))
    }

    /// A canonical CID that is not the standard one — a long one, or a short
    /// one of another codec — is its own canonical form through the parse.
    func testNonStandardCanonicalCIDsAreTheirOwnCanonicalForm() throws {
        func identityCID(digestLength: Int) -> String {
            var length = [UInt8]()
            var n = digestLength
            repeat {
                length.append(UInt8(n & 0x7f) | (n >= 0x80 ? 0x80 : 0))
                n >>= 7
            } while n > 0
            let bytes: [UInt8] = [0x01, 0x55, 0x00] + length
                + [UInt8](repeating: 0xab, count: digestLength)
            return "f" + bytes.map { String(format: "%02x", $0) }.joined()
        }
        // Raw codec over a 25,000-byte identity digest: ~40 KB of base32.
        let long = try XCTUnwrap(CIDIdentity.canonicalString(identityCID(digestLength: 25_000)))
        XCTAssertGreaterThan(long.utf8.count, 40_000)
        XCTAssertEqual(CIDIdentity.canonicalString(long), long)

        // A short canonical CID the parse proves (the standard CID never
        // reaches it: `CIDDigest` proves it without a parse).
        let digest = Array(try CID(testCID("short-is-remembered")).rawBuffer.suffix(32))
        let short = CIDIdentity.base32Multibase([0x01, 0x55, 0x12, 0x20] + digest)
        XCTAssertEqual(CIDIdentity.canonicalString(short), short)
    }

    /// The local base32 encoder is the library's v1 text form, byte for byte,
    /// across every tail length (bytes mod 5): CIDs spelled in base16 with
    /// codec and hash shapes whose binary lengths are 24, 25, 36, 37, 68, 69.
    func testBase32MultibaseMatchesTheLibraryEncoder() throws {
        // (codec varint, hash code, digest length): raw / dag-json codecs over
        // sha1, sha2-256 and sha2-512.
        let shapes: [([UInt8], UInt8, Int)] = [
            ([0x55], 0x11, 20), ([0xa9, 0x02], 0x11, 20),
            ([0x55], 0x12, 32), ([0xa9, 0x02], 0x12, 32),
            ([0x55], 0x13, 64), ([0xa9, 0x02], 0x13, 64),
        ]
        for (codec, hash, length) in shapes {
            let digest = (0..<length).map { _ in UInt8.random(in: 0...255) }
            let bytes: [UInt8] = [0x01] + codec + [hash, UInt8(length)] + digest
            let hex = "f" + bytes.map { String(format: "%02x", $0) }.joined()
            let parsed = try CID(hex)
            // The library's own v1 text form: a CID rebuilt from its parts.
            let cid = try CID(version: parsed.version, codec: parsed.codec, multihash: parsed.multihash)
            XCTAssertEqual(cid.rawBuffer, bytes)
            XCTAssertEqual(
                Array(CIDIdentity.base32Multibase(cid.rawBuffer).utf8),
                Array(cid.toBaseEncodedString.utf8),
                "\(bytes.count) bytes"
            )
            XCTAssertEqual(CIDIdentity.canonicalString(hex), cid.toBaseEncodedString)
        }
        for seed in 0..<64 {
            let cid = try CID(testCID("base32-\(seed)"))
            XCTAssertEqual(CIDIdentity.base32Multibase(cid.rawBuffer), cid.toBaseEncodedString)
        }
    }

}
