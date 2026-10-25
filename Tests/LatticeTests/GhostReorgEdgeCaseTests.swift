import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import UInt256
import cashew
import Foundation

// Edge-case coverage for one-chain GHOST fork choice and reorg bookkeeping.

@MainActor
final class GhostReorgEdgeCaseTests: XCTestCase {

    // A shorter main chain loses to a fork whose *subtree* is heavier because the
    // fork branches (GHOST counts both branches), even though no single fork path
    // is longer than main.
    func testForkWithBranchingSubtreeOutweighsLongerSinglePath() async {
        // main: G→M1→M2→M3 (subtree at M1 = 3).
        // fork: G→F1, F1 has two children F2a, F2b (subtree at F1 = 3: F1,F2a,F2b).
        // Add F3a under F2a → fork subtree 4 > 3.
        let g  = makeBlockMeta(hash: blockCID("G"),  height: 0, childHashes: [blockCID("M1"), blockCID("F1")])
        let m1 = makeBlockMeta(hash: blockCID("M1"), previousHash: blockCID("G"),  height: 1, childHashes: [blockCID("M2")])
        let m2 = makeBlockMeta(hash: blockCID("M2"), previousHash: blockCID("M1"), height: 2, childHashes: [blockCID("M3")])
        let m3 = makeBlockMeta(hash: blockCID("M3"), previousHash: blockCID("M2"), height: 3)
        let f1  = makeBlockMeta(hash: blockCID("F1"),  previousHash: blockCID("G"),  height: 1, childHashes: [blockCID("F2a"), blockCID("F2b")])
        let f2a = makeBlockMeta(hash: blockCID("F2a"), previousHash: blockCID("F1"), height: 2, childHashes: [blockCID("F3a")])
        let f2b = makeBlockMeta(hash: blockCID("F2b"), previousHash: blockCID("F1"), height: 2)
        let f3a = makeBlockMeta(hash: blockCID("F3a"), previousHash: blockCID("F2a"), height: 3)

        let chain = makeChain(
            blocks: [g, m1, m2, m3, f1, f2a, f2b, f3a],
            canonicalHashes: Set([blockCID("G"), blockCID("M1"), blockCID("M2"), blockCID("M3")])
        )
        // subtreeWeight(F1) = {F1,F2a,F2b,F3a} = 4 > subtreeWeight(M1) = {M1,M2,M3} = 3.
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNotNil(reorg, "fork's branching subtree (4) outweighs main's single path (3)")
        // GHOST descent picks the heaviest leaf under F1 — the F2a→F3a branch.
        let tip = await chain.canonicalTip
        XCTAssertEqual(tip, blockCID("F3a"), "descent rides the heavier branch to its leaf")
    }

    // Equal subtree weights fall through to stable segment-base preference.
    func testEqualSubtreeUsesStableSegmentBase() async {
        let g  = makeBlockMeta(hash: blockCID("G"),  height: 0, childHashes: [blockCID("M1"), blockCID("F1")])
        let m1 = makeBlockMeta(hash: blockCID("M1"), previousHash: blockCID("G"),  height: 1, childHashes: [blockCID("M2")])
        let m2 = makeBlockMeta(hash: blockCID("M2"), previousHash: blockCID("M1"), height: 2)
        let f1 = makeBlockMeta(hash: blockCID("F1"), previousHash: blockCID("G"),  height: 1, childHashes: [blockCID("F2")])
        let f2 = makeBlockMeta(hash: blockCID("F2"), previousHash: blockCID("F1"), height: 2)

        let chain = makeChain(blocks: [g, m1, m2, f1, f2], canonicalHashes: Set([blockCID("G"), blockCID("M1"), blockCID("M2")]))
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNotNil(reorg, "equal work and target choose the smaller segment-base hash")
        let tip = await chain.canonicalTip
        XCTAssertEqual(tip, blockCID("F2"))
    }

    // A reorg's GHOST descent must rebuild the FULL winning subtree's main-chain
    // path and drop the entire old suffix, including across a multi-block fork.
    func testReorgRemovesFullOldSuffixAndInstallsWinningPath() async {
        let g  = makeBlockMeta(hash: blockCID("G"),  height: 0, childHashes: [blockCID("M1"), blockCID("F1")])
        let m1 = makeBlockMeta(hash: blockCID("M1"), previousHash: blockCID("G"),  height: 1, childHashes: [blockCID("M2")])
        let m2 = makeBlockMeta(hash: blockCID("M2"), previousHash: blockCID("M1"), height: 2)
        let f1 = makeBlockMeta(hash: blockCID("F1"), previousHash: blockCID("G"),  height: 1, childHashes: [blockCID("F2")])
        let f2 = makeBlockMeta(hash: blockCID("F2"), previousHash: blockCID("F1"), height: 2, childHashes: [blockCID("F3")])
        let f3 = makeBlockMeta(hash: blockCID("F3"), previousHash: blockCID("F2"), height: 3)

        let chain = makeChain(blocks: [g, m1, m2, f1, f2, f3], canonicalHashes: Set([blockCID("G"), blockCID("M1"), blockCID("M2")]))
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNotNil(reorg)
        XCTAssertEqual(reorg?.canonicalBlocksRemoved, Set([blockCID("M1"), blockCID("M2")]), "entire old suffix removed")
        XCTAssertEqual(Set(reorg!.canonicalBlocksAdded.keys), Set([blockCID("F1"), blockCID("F2"), blockCID("F3")]), "winning path installed")
        let tip = await chain.canonicalTip; XCTAssertEqual(tip, blockCID("F3"))
        // Old main blocks are no longer on the main chain.
        let m1OnMain = await chain.isCanonical(hash: blockCID("M1"))
        XCTAssertFalse(m1OnMain)
    }

    // Out-of-order delivery + reorg: a heavier fork's blocks arrive children-before
    // -parents; once the fork is complete its subtree weight back-propagates and the
    // reorg fires. Uses real blocks (BlockBuilder) since the static makeChain harness
    // can't model arrival order.
    func testOutOfOrderForkTriggersReorgOnceComplete() async throws {
        let fetcher = StorableFetcher()
        let diff = UInt256(1000)
        let base = Int64(Date().timeIntervalSince1970 * 1000) - 50_000
        let spec = ChainSpec.test()
        let genesis = try await buildAndStoreGenesis(spec: spec, timestamp: base, target: diff, fetcher: fetcher)
        let chain = ChainState.fromGenesis(block: genesis)
        // Main chain G→A→B (2 blocks).
        let a = try await buildAndStoreBlock(previous: genesis, timestamp: base + 1000, target: diff, nonce: 1, fetcher: fetcher)
        let b = try await buildAndStoreBlock(previous: a, timestamp: base + 2000, target: diff, nonce: 2, fetcher: fetcher)
        for blk in [a, b] {
            _ = await chain.submitTestBlock(blockHeader: try! VolumeImpl<Block>(node: blk), block: blk)
        }
        let cid = { (blk: Block) in try! VolumeImpl<Block>(node: blk).rawCID }
        let tipBefore = await chain.canonicalTip
        XCTAssertEqual(tipBefore, cid(b))

        // Heavier fork G→X→Y→Z (3 blocks), delivered Z, Y, X (children before parents).
        let x = try await buildAndStoreBlock(previous: genesis, timestamp: base + 1500, target: diff, nonce: 91, fetcher: fetcher)
        let y = try await buildAndStoreBlock(previous: x, timestamp: base + 2500, target: diff, nonce: 92, fetcher: fetcher)
        let z = try await buildAndStoreBlock(previous: y, timestamp: base + 3500, target: diff, nonce: 93, fetcher: fetcher)
        for blk in [z, y, x] {
            _ = await chain.submitTestBlock(blockHeader: try! VolumeImpl<Block>(node: blk), block: blk)
        }
        // Once X (the fork base) is delivered, the fork subtree (3) > main (2) ⇒ reorg.
        let tip = await chain.canonicalTip
        XCTAssertEqual(tip, cid(z), "out-of-order heavier fork reorgs once complete")
    }
}

// MARK: - Reorg bookkeeping and fork-choice correctness

@MainActor
final class ReorgBookkeepingTests: XCTestCase {

    // Tip extension must emit the connect set when GHOST descent advances the tip
    // past already-attached out-of-order descendants. Genesis→C0(tip); grandchild
    // G(parent=C1) is attached before C1. The tip jumps C0→C1→G, so the
    // commit must list BOTH C1 and G.
    func test_tipExtendEmitsConnectSetForOutOfOrderDescendants() async throws {
        let fetcher = StorableFetcher()
        let diff = UInt256(1000)
        let base = Int64(Date().timeIntervalSince1970 * 1000) - 50_000
        let spec = ChainSpec.test()
        let genesis = try await buildAndStoreGenesis(spec: spec, timestamp: base, target: diff, fetcher: fetcher)
        let chain = ChainState.fromGenesis(block: genesis)
        let cid = { (blk: Block) in try! VolumeImpl<Block>(node: blk).rawCID }

        // C0 extends genesis and becomes the tip.
        let c0 = try await buildAndStoreBlock(previous: genesis, timestamp: base + 1000, target: diff, nonce: 1, fetcher: fetcher)
        _ = await chain.submitTestBlock(blockHeader: try! VolumeImpl<Block>(node: c0), block: c0)
        let tipAfterC0 = await chain.canonicalTip
        XCTAssertEqual(tipAfterC0, cid(c0))

        // C1 extends C0; G extends C1. Deliver G FIRST (out of order, before C1) so it
        // is attached but not on the main chain; then deliver C1 whose parent is the tip.
        let c1 = try await buildAndStoreBlock(previous: c0, timestamp: base + 2000, target: diff, nonce: 2, fetcher: fetcher)
        let gg = try await buildAndStoreBlock(previous: c1, timestamp: base + 3000, target: diff, nonce: 3, fetcher: fetcher)
        _ = await chain.submitTestBlock(blockHeader: try! VolumeImpl<Block>(node: gg), block: gg)

        let result = await chain.submitTestBlock(blockHeader: try! VolumeImpl<Block>(node: c1), block: c1)
        XCTAssertTrue(result.extendsCanonical, "C1's parent is the tip, so this extends the main chain")
        let finalTip = await chain.canonicalTip
        XCTAssertEqual(finalTip, cid(gg), "the tip advances past the out-of-order grandchild")
        let added = result.commit?.canonicalBlocksAdded
        XCTAssertNotNil(added, "tip-extend that advances past out-of-order descendants must emit a commit")
        XCTAssertTrue(added?.keys.contains(cid(c1)) ?? false, "connect set contains C1")
        XCTAssertTrue(added?.keys.contains(cid(gg)) ?? false, "connect set contains the out-of-order grandchild G")
    }

}
