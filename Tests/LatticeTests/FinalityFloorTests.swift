import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import UInt256

// SEC-101 /: the per-node depth-based finality floor has been removed
// ENTIRELY. Fork choice is pure heaviest-subtree work, so consensus must NOT
// reject a strictly-heavier valid chain for being too deep, and must still
// reject a lighter chain. These tests drive the same projection entry point as
// the other consensus tests.

@MainActor
final class FinalityFloorTests: XCTestCase {

    /// Main chain G→A1→A2→A3→A4 (tip height 4); a heavier fork B2→B3→B4→B5
    /// branches off A1 (so its earliest orphan B2 is at height 2, buried 2 deep).
    private func forkedChain() -> ChainState {
        let g  = makeBlockMeta(hash: blockCID("G"),  height: 0, childHashes: [blockCID("A1")])
        let a1 = makeBlockMeta(hash: blockCID("A1"), previousHash: blockCID("G"),  height: 1, childHashes: [blockCID("A2"), blockCID("B2")])
        let a2 = makeBlockMeta(hash: blockCID("A2"), previousHash: blockCID("A1"), height: 2, childHashes: [blockCID("A3")])
        let a3 = makeBlockMeta(hash: blockCID("A3"), previousHash: blockCID("A2"), height: 3, childHashes: [blockCID("A4")])
        let a4 = makeBlockMeta(hash: blockCID("A4"), previousHash: blockCID("A3"), height: 4)
        // Fork: 4 blocks off A1 vs the 3 main blocks A2/A3/A4 → strictly heavier.
        let b2 = makeBlockMeta(hash: blockCID("B2"), previousHash: blockCID("A1"), height: 2, childHashes: [blockCID("B3")])
        let b3 = makeBlockMeta(hash: blockCID("B3"), previousHash: blockCID("B2"), height: 3, childHashes: [blockCID("B4")])
        let b4 = makeBlockMeta(hash: blockCID("B4"), previousHash: blockCID("B3"), height: 4, childHashes: [blockCID("B5")])
        let b5 = makeBlockMeta(hash: blockCID("B5"), previousHash: blockCID("B4"), height: 5)

        return makeChain(
            blocks: [g, a1, a2, a3, a4, b2, b3, b4, b5],
            canonicalHashes: Set([blockCID("G"), blockCID("A1"), blockCID("A2"), blockCID("A3"), blockCID("A4")])
        )
    }

    /// A strictly-heavier fork always reorgs — no depth floor can refuse it.
    func testHeavierForkAlwaysReorgs() async {
        let chain = forkedChain()
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNotNil(reorg, "heavier fork reorgs — there is no finality floor")
        let tip = await chain.canonicalTip
        XCTAssertEqual(tip, blockCID("B5"), "tip moves to the heavier fork")
    }

    /// The load-bearing invariant: a DEEP but strictly-heavier reorg is
    /// ACCEPTED. The deepest removed block (A2) is buried 2 deep below the tip,
    /// and a third block makes the fork strictly heavier; the old floor would
    /// have refused this. Pure heaviest-chain must follow it.
    func testDeepStrictlyHeavierForkIsAccepted() async {
        let chain = forkedChain()
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNotNil(reorg, "deep but strictly-heavier fork must NOT be refused for being too deep")
        let tip = await chain.canonicalTip
        XCTAssertEqual(tip, blockCID("B5"))
        // The whole old suffix is gone; the heavier fork is now canonical.
        for (idx, hash) in [(0, blockCID("G")), (1, blockCID("A1")), (2, blockCID("B2")), (3, blockCID("B3")), (4, blockCID("B4")), (5, blockCID("B5"))] {
            let onMain = await chain.canonicalBlockHash(atHeight: UInt64(idx))
            XCTAssertEqual(onMain, hash, "main chain index \(idx) follows the heavier fork")
        }
    }

    /// A lighter fork is still rejected by the first fork-choice comparator.
    func testLighterForkIsRejected() async {
        let g  = makeBlockMeta(hash: blockCID("G"),  height: 0, childHashes: [blockCID("A1")])
        let a1 = makeBlockMeta(hash: blockCID("A1"), previousHash: blockCID("G"),  height: 1, childHashes: [blockCID("A2"), blockCID("B2")])
        let a2 = makeBlockMeta(hash: blockCID("A2"), previousHash: blockCID("A1"), height: 2, childHashes: [blockCID("A3")])
        let a3 = makeBlockMeta(hash: blockCID("A3"), previousHash: blockCID("A2"), height: 3)
        // Lighter fork: only 1 block off A1 vs the 2 main blocks A2/A3.
        let b2 = makeBlockMeta(hash: blockCID("B2"), previousHash: blockCID("A1"), height: 2)

        let chain = makeChain(
            blocks: [g, a1, a2, a3, b2],
            canonicalHashes: Set([blockCID("G"), blockCID("A1"), blockCID("A2"), blockCID("A3")])
        )
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNil(reorg, "lighter fork must be rejected (heaviest-chain only)")
        let tip = await chain.canonicalTip
        XCTAssertEqual(tip, blockCID("A3"), "tip stays on the heavier original chain")
    }

}
