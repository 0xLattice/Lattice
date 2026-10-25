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
}
