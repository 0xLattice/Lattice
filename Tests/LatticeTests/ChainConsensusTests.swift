import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import UInt256

// MARK: - Test Helpers

func makeBlockMeta(
    hash: String,
    previousHash: String? = nil,
    height: UInt64,
    childHashes: [String] = [],
    work: UInt256 = UInt256(1)
) -> BlockMeta {
    let contribution = VerifiedWorkContribution(
        id: testCID("work:\(hash)"),
        work: work
    )
    return BlockMeta(
        blockHash: hash,
        parentBlockHash: previousHash,
        blockHeight: height,
        childHashes: childHashes,
        workContributions: [contribution]
    )
}

func makeChain(
    blocks: [BlockMeta],
    canonicalHashes: Set<String>? = nil
) -> ChainState {
    let tip = blocks.max(by: { a, b in
        if canonicalHashes != nil {
            let aOnMain = canonicalHashes!.contains(a.blockHash)
            let bOnMain = canonicalHashes!.contains(b.blockHash)
            if aOnMain != bOnMain { return !aOnMain }
        }
        return a.blockHeight < b.blockHeight
    })!
    var indexMap: [UInt64: Set<String>] = [:]
    var hashMap: [String: BlockMeta] = [:]
    for block in blocks {
        indexMap[block.blockHeight, default: Set()].insert(block.blockHash)
        hashMap[block.blockHash] = block
    }
    var mainHashes = canonicalHashes ?? []
    if canonicalHashes == nil {
        var cursor: BlockMeta? = tip
        while let block = cursor {
            mainHashes.insert(block.blockHash)
            cursor = block.parentBlockHash.flatMap { hashMap[$0] }
        }
    }
    return try! ChainState(
        canonicalTip: tip.blockHash,
        canonicalHashes: mainHashes,
        indexToBlockHash: indexMap,
        hashToBlock: hashMap
    )
}

func makeLinearChain(length: Int, prefix: String = "block") -> (ChainState, [BlockMeta]) {
    var blocks: [BlockMeta] = []
    for i in 0..<length {
        let hash = blockCID("\(prefix)_\(i)")
        let prevHash: String? = i == 0 ? nil : blockCID("\(prefix)_\(i - 1)")
        let meta = makeBlockMeta(hash: hash, previousHash: prevHash, height: UInt64(i))
        blocks.append(meta)
    }
    for i in 0..<(blocks.count - 1) {
        blocks[i].childHashes = [blocks[i + 1].blockHash]
    }
    let chain = makeChain(blocks: blocks)
    return (chain, blocks)
}

// MARK: - ChainState Tests (async, run via @MainActor)

@MainActor
final class ChainStateGenesisTests: XCTestCase {

    func testFromGenesisCreatesValidState() async {
        let (chain, _) = makeLinearChain(length: 1)
        let tip = await chain.canonicalTip
        XCTAssertEqual(tip, blockCID("block_0"))
        let highest = await chain.getHighestBlockHeight()
        XCTAssertEqual(highest, 0)
        let contains = await chain.contains(blockHash: blockCID("block_0"))
        XCTAssertTrue(contains)
        let onMain = await chain.isCanonical(hash: blockCID("block_0"))
        XCTAssertTrue(onMain)
    }

    func testFromGenesisDoesNotContainOtherBlocks() async {
        let (chain, _) = makeLinearChain(length: 1)
        let contains = await chain.contains(blockHash: "nonexistent")
        XCTAssertFalse(contains)
    }
}

@MainActor
final class LinearChainTests: XCTestCase {

    func testLinearChainTipIsHighest() async {
        let (chain, _) = makeLinearChain(length: 5)
        let tip = await chain.canonicalTip
        XCTAssertEqual(tip, blockCID("block_4"))
        let highest = await chain.getHighestBlockHeight()
        XCTAssertEqual(highest, 4)
    }

    func testAllBlocksOnMainChain() async {
        let (chain, blocks) = makeLinearChain(length: 5)
        for block in blocks {
            let onMain = await chain.isCanonical(hash: block.blockHash)
            XCTAssertTrue(onMain, "\(block.blockHash) should be on main chain")
        }
    }

    func testGetConsensusBlock() async {
        let (chain, _) = makeLinearChain(length: 3)
        let block = await chain.getConsensusBlock(hash: blockCID("block_1"))
        XCTAssertNotNil(block)
        XCTAssertEqual(block?.blockHeight, 1)
        XCTAssertEqual(block?.parentBlockHash, blockCID("block_0"))
    }

    func testGetConsensusBlockNotFound() async {
        let (chain, _) = makeLinearChain(length: 3)
        let block = await chain.getConsensusBlock(hash: "nonexistent")
        XCTAssertNil(block)
    }
}

@MainActor
final class ForkChoiceTests: XCTestCase {

    func testLongerForkTriggersReorg() async {
        let g = makeBlockMeta(hash: blockCID("G"), height: 0, childHashes: [blockCID("A1"), blockCID("B1")])
        let a1 = makeBlockMeta(hash: blockCID("A1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("A2")])
        let a2 = makeBlockMeta(hash: blockCID("A2"), previousHash: blockCID("A1"), height: 2, childHashes: [blockCID("A3")])
        let a3 = makeBlockMeta(hash: blockCID("A3"), previousHash: blockCID("A2"), height: 3)
        let b1 = makeBlockMeta(hash: blockCID("B1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("B2")])
        let b2 = makeBlockMeta(hash: blockCID("B2"), previousHash: blockCID("B1"), height: 2, childHashes: [blockCID("B3")])
        let b3 = makeBlockMeta(hash: blockCID("B3"), previousHash: blockCID("B2"), height: 3, childHashes: [blockCID("B4")])
        let b4 = makeBlockMeta(hash: blockCID("B4"), previousHash: blockCID("B3"), height: 4)

        let chain = makeChain(
            blocks: [g, a1, a2, a3, b1, b2, b3, b4],
            canonicalHashes: Set([blockCID("G"), blockCID("A1"), blockCID("A2"), blockCID("A3")])
        )

        let revisionBefore = await chain.currentRevision()
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNotNil(reorg)
        XCTAssertTrue(reorg!.canonicalBlocksAdded.keys.contains(blockCID("B4")))
        XCTAssertTrue(reorg!.canonicalBlocksRemoved.contains(blockCID("A3")))
        XCTAssertEqual(reorg!.revision, revisionBefore + 1)
        let revisionAfter = await chain.currentRevision()
        XCTAssertEqual(revisionAfter, reorg!.revision)

        let newTip = await chain.canonicalTip
        XCTAssertEqual(newTip, blockCID("B4"))
    }

    func testShorterForkDoesNotReorg() async {
        let g = makeBlockMeta(hash: blockCID("G"), height: 0, childHashes: [blockCID("A1"), blockCID("B1")])
        let a1 = makeBlockMeta(hash: blockCID("A1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("A2")])
        let a2 = makeBlockMeta(hash: blockCID("A2"), previousHash: blockCID("A1"), height: 2, childHashes: [blockCID("A3")])
        let a3 = makeBlockMeta(hash: blockCID("A3"), previousHash: blockCID("A2"), height: 3)
        let b1 = makeBlockMeta(hash: blockCID("B1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("B2")])
        let b2 = makeBlockMeta(hash: blockCID("B2"), previousHash: blockCID("B1"), height: 2)

        let chain = makeChain(
            blocks: [g, a1, a2, a3, b1, b2],
            canonicalHashes: Set([blockCID("G"), blockCID("A1"), blockCID("A2"), blockCID("A3")])
        )

        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNil(reorg)
    }

    func testEqualLengthForkKeepsPreferredBaseCID() async {
        let g = makeBlockMeta(hash: blockCID("G"), height: 0, childHashes: [blockCID("A1"), blockCID("B1")])
        let a1 = makeBlockMeta(hash: blockCID("A1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("A2")])
        let a2 = makeBlockMeta(hash: blockCID("A2"), previousHash: blockCID("A1"), height: 2)
        let b1 = makeBlockMeta(hash: blockCID("B1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("B2")])
        let b2 = makeBlockMeta(hash: blockCID("B2"), previousHash: blockCID("B1"), height: 2)

        let chain = makeChain(
            blocks: [g, a1, a2, b1, b2],
            canonicalHashes: Set([blockCID("G"), blockCID("A1"), blockCID("A2")])
        )

        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNil(reorg, "A1 is the smaller segment-base hash")
    }

}

@MainActor
final class ChainWithMostWorkTests: XCTestCase {

    func testSingleBlockChain() async {
        let g = makeBlockMeta(hash: blockCID("G"), height: 0)
        let chain = makeChain(blocks: [g])
        let work = await chain.chainWithMostWork(startingBlock: g)
        XCTAssertEqual(work.subtreeWork, WorkSum(UInt256(1)))
        XCTAssertEqual(work.blocks, Set([blockCID("G")]))
    }

    func testLinearChainWork() async {
        let (chain, blocks) = makeLinearChain(length: 4)
        let work = await chain.chainWithMostWork(startingBlock: blocks[0])
        XCTAssertEqual(work.subtreeWork, WorkSum(UInt256(4)))
        XCTAssertEqual(work.blocks.count, 4)
    }

    // chainWithMostWork returns the starting block's GHOST subtree work
    // block's whole subtree weight), and its `blocks` is the heaviest-subtree
    // descent path. G's subtree = all 6 blocks; the descent rides the heavier B fork.
    func testForkedChainPicksMoreWork() async {
        let g = makeBlockMeta(hash: blockCID("G"), height: 0, childHashes: [blockCID("A1"), blockCID("B1")])
        let a1 = makeBlockMeta(hash: blockCID("A1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("A2")])
        let a2 = makeBlockMeta(hash: blockCID("A2"), previousHash: blockCID("A1"), height: 2)
        let b1 = makeBlockMeta(hash: blockCID("B1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("B2")])
        let b2 = makeBlockMeta(hash: blockCID("B2"), previousHash: blockCID("B1"), height: 2, childHashes: [blockCID("B3")])
        let b3 = makeBlockMeta(hash: blockCID("B3"), previousHash: blockCID("B2"), height: 3)

        let chain = makeChain(blocks: [g, a1, a2, b1, b2, b3])
        let work = await chain.chainWithMostWork(startingBlock: g)
        XCTAssertEqual(work.subtreeWork, WorkSum(UInt256(6)), "subtreeWork(G) = whole subtree = 6 blocks")
        XCTAssertTrue(work.blocks.contains(blockCID("B3")), "descent rides the heavier B fork to its tip")
        XCTAssertFalse(work.blocks.contains(blockCID("A1")))
    }

}

// MARK: - Smoke Tests / Invariant Checks

@MainActor
final class ChainInvariantTests: XCTestCase {

    func testTipAlwaysOnMainChain() async {
        let (chain, _) = makeLinearChain(length: 10)
        let tip = await chain.canonicalTip
        let onMain = await chain.isCanonical(hash: tip)
        XCTAssertTrue(onMain)
    }

    func testTipAlwaysInBlockMap() async {
        let (chain, _) = makeLinearChain(length: 10)
        let tip = await chain.canonicalTip
        let block = await chain.getConsensusBlock(hash: tip)
        XCTAssertNotNil(block)
    }

    func testMainChainConnectivity() async {
        let (chain, blocks) = makeLinearChain(length: 10)
        for block in blocks {
            if let prevHash = block.parentBlockHash {
                let prevOnMain = await chain.isCanonical(hash: prevHash)
                let currentOnMain = await chain.isCanonical(hash: block.blockHash)
                if currentOnMain {
                    XCTAssertTrue(prevOnMain, "\(block.blockHash) on main but parent \(prevHash) not")
                }
            }
        }
    }

    func testReorgTipIsHighestInWinningFork() async {
        let g = makeBlockMeta(hash: blockCID("G"), height: 0, childHashes: [blockCID("A1"), blockCID("B1")])
        let a1 = makeBlockMeta(hash: blockCID("A1"), previousHash: blockCID("G"), height: 1)
        let b1 = makeBlockMeta(hash: blockCID("B1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("B2")])
        let b2 = makeBlockMeta(hash: blockCID("B2"), previousHash: blockCID("B1"), height: 2, childHashes: [blockCID("B3")])
        let b3 = makeBlockMeta(hash: blockCID("B3"), previousHash: blockCID("B2"), height: 3)

        let chain = makeChain(blocks: [g, a1, b1, b2, b3], canonicalHashes: Set([blockCID("G"), blockCID("A1")]))
        let _ = await chain.reevaluateForkChoice()

        let tip = await chain.canonicalTip
        let tipBlock = await chain.getConsensusBlock(hash: tip)!
        let highest = await chain.getHighestBlockHeight()
        XCTAssertEqual(tipBlock.blockHeight, highest)
    }

    func testReorgRemovesOldMainChainBlocks() async {
        let g = makeBlockMeta(hash: blockCID("G"), height: 0, childHashes: [blockCID("A1"), blockCID("B1")])
        let a1 = makeBlockMeta(hash: blockCID("A1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("A2")])
        let a2 = makeBlockMeta(hash: blockCID("A2"), previousHash: blockCID("A1"), height: 2)
        let b1 = makeBlockMeta(hash: blockCID("B1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("B2")])
        let b2 = makeBlockMeta(hash: blockCID("B2"), previousHash: blockCID("B1"), height: 2, childHashes: [blockCID("B3")])
        let b3 = makeBlockMeta(hash: blockCID("B3"), previousHash: blockCID("B2"), height: 3)

        let chain = makeChain(blocks: [g, a1, a2, b1, b2, b3], canonicalHashes: Set([blockCID("G"), blockCID("A1"), blockCID("A2")]))
        let _ = await chain.reevaluateForkChoice()

        let a1OnMain = await chain.isCanonical(hash: blockCID("A1"))
        XCTAssertFalse(a1OnMain)
        let a2OnMain = await chain.isCanonical(hash: blockCID("A2"))
        XCTAssertFalse(a2OnMain)
        let gOnMain = await chain.isCanonical(hash: blockCID("G"))
        XCTAssertTrue(gOnMain)
    }

    func testReorgStructContents() async {
        let g = makeBlockMeta(hash: blockCID("G"), height: 0, childHashes: [blockCID("A1"), blockCID("B1")])
        let a1 = makeBlockMeta(hash: blockCID("A1"), previousHash: blockCID("G"), height: 1)
        let b1 = makeBlockMeta(hash: blockCID("B1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("B2")])
        let b2 = makeBlockMeta(hash: blockCID("B2"), previousHash: blockCID("B1"), height: 2)

        let chain = makeChain(blocks: [g, a1, b1, b2], canonicalHashes: Set([blockCID("G"), blockCID("A1")]))
        let reorg = await chain.reevaluateForkChoice()

        XCTAssertNotNil(reorg)
        XCTAssertTrue(reorg!.canonicalBlocksAdded.keys.contains(blockCID("B1")))
        XCTAssertTrue(reorg!.canonicalBlocksAdded.keys.contains(blockCID("B2")))
        XCTAssertFalse(reorg!.canonicalBlocksAdded.keys.contains(blockCID("G")))
        XCTAssertTrue(reorg!.canonicalBlocksRemoved.contains(blockCID("A1")))
        XCTAssertFalse(reorg!.canonicalBlocksRemoved.contains(blockCID("G")))
    }
}

// MARK: - Nakamoto Consensus / Industry Standard Tests

@MainActor
final class NakamotoConsensusTests: XCTestCase {

    func testNakamotoLongestChainRule() async {
        let (chain, _) = makeLinearChain(length: 6, prefix: "main")
        let tip = await chain.canonicalTip
        XCTAssertEqual(tip, blockCID("main_5"))
        for i in 0..<6 {
            let onMain = await chain.isCanonical(hash: blockCID("main_\(i)"))
            XCTAssertTrue(onMain)
        }
    }

    func testSelfishMiningReorg() async {
        let g = makeBlockMeta(hash: blockCID("G"), height: 0, childHashes: [blockCID("P1"), blockCID("H1")])
        let p1 = makeBlockMeta(hash: blockCID("P1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("P2")])
        let p2 = makeBlockMeta(hash: blockCID("P2"), previousHash: blockCID("P1"), height: 2, childHashes: [blockCID("P3")])
        let p3 = makeBlockMeta(hash: blockCID("P3"), previousHash: blockCID("P2"), height: 3)
        let h1 = makeBlockMeta(hash: blockCID("H1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("H2")])
        let h2 = makeBlockMeta(hash: blockCID("H2"), previousHash: blockCID("H1"), height: 2, childHashes: [blockCID("H3")])
        let h3 = makeBlockMeta(hash: blockCID("H3"), previousHash: blockCID("H2"), height: 3, childHashes: [blockCID("H4")])
        let h4 = makeBlockMeta(hash: blockCID("H4"), previousHash: blockCID("H3"), height: 4)

        let chain = makeChain(blocks: [g, p1, p2, p3, h1, h2, h3, h4], canonicalHashes: Set([blockCID("G"), blockCID("P1"), blockCID("P2"), blockCID("P3")]))
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNotNil(reorg)
        let selfishTip = await chain.canonicalTip
        XCTAssertEqual(selfishTip, blockCID("H4"))

        for name in [blockCID("P1"), blockCID("P2"), blockCID("P3")] {
            let onMain = await chain.isCanonical(hash: name)
            XCTAssertFalse(onMain, "\(name) should be off main chain")
        }
        for name in [blockCID("H1"), blockCID("H2"), blockCID("H3"), blockCID("H4")] {
            let onMain = await chain.isCanonical(hash: name)
            XCTAssertTrue(onMain, "\(name) should be on main chain")
        }
        let gOnMainSelfish = await chain.isCanonical(hash: blockCID("G"))
        XCTAssertTrue(gOnMainSelfish)
    }

    func testEqualWorkUsesStableBlockHashTieBreak() async {
        let g = makeBlockMeta(hash: blockCID("G"), height: 0, childHashes: [blockCID("A1"), blockCID("B1")])
        let a1 = makeBlockMeta(hash: blockCID("A1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("A2")])
        let a2 = makeBlockMeta(hash: blockCID("A2"), previousHash: blockCID("A1"), height: 2, childHashes: [blockCID("A3")])
        let a3 = makeBlockMeta(hash: blockCID("A3"), previousHash: blockCID("A2"), height: 3)
        let b1 = makeBlockMeta(hash: blockCID("B1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("B2")])
        let b2 = makeBlockMeta(hash: blockCID("B2"), previousHash: blockCID("B1"), height: 2, childHashes: [blockCID("B3")])
        let b3 = makeBlockMeta(hash: blockCID("B3"), previousHash: blockCID("B2"), height: 3)

        let chain = makeChain(blocks: [g, a1, a2, a3, b1, b2, b3], canonicalHashes: Set([blockCID("G"), blockCID("A1"), blockCID("A2"), blockCID("A3")]))
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNil(reorg, "The smaller segment-base hash is already canonical")
        let tieTip = await chain.canonicalTip
        XCTAssertEqual(tieTip, blockCID("A3"))
    }

    func testDeepReorgFromGenesis() async {
        let g = makeBlockMeta(hash: blockCID("G"), height: 0, childHashes: [blockCID("M1"), blockCID("F1")])
        let m1 = makeBlockMeta(hash: blockCID("M1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("M2")])
        let m2 = makeBlockMeta(hash: blockCID("M2"), previousHash: blockCID("M1"), height: 2)
        let f1 = makeBlockMeta(hash: blockCID("F1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("F2")])
        let f2 = makeBlockMeta(hash: blockCID("F2"), previousHash: blockCID("F1"), height: 2, childHashes: [blockCID("F3")])
        let f3 = makeBlockMeta(hash: blockCID("F3"), previousHash: blockCID("F2"), height: 3, childHashes: [blockCID("F4")])
        let f4 = makeBlockMeta(hash: blockCID("F4"), previousHash: blockCID("F3"), height: 4, childHashes: [blockCID("F5")])
        let f5 = makeBlockMeta(hash: blockCID("F5"), previousHash: blockCID("F4"), height: 5)

        let chain = makeChain(blocks: [g, m1, m2, f1, f2, f3, f4, f5], canonicalHashes: Set([blockCID("G"), blockCID("M1"), blockCID("M2")]))
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNotNil(reorg)
        let deepTip = await chain.canonicalTip
        XCTAssertEqual(deepTip, blockCID("F5"))
        let deepHighest = await chain.getHighestBlockHeight()
        XCTAssertEqual(deepHighest, 5)
    }

    func testMultipleConcurrentForks() async {
        let g = makeBlockMeta(hash: blockCID("G"), height: 0, childHashes: [blockCID("A1"), blockCID("B1"), blockCID("C1")])
        let a1 = makeBlockMeta(hash: blockCID("A1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("A2")])
        let a2 = makeBlockMeta(hash: blockCID("A2"), previousHash: blockCID("A1"), height: 2)
        let b1 = makeBlockMeta(hash: blockCID("B1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("B2")])
        let b2 = makeBlockMeta(hash: blockCID("B2"), previousHash: blockCID("B1"), height: 2, childHashes: [blockCID("B3")])
        let b3 = makeBlockMeta(hash: blockCID("B3"), previousHash: blockCID("B2"), height: 3)
        let c1 = makeBlockMeta(hash: blockCID("C1"), previousHash: blockCID("G"), height: 1)

        let chain = makeChain(blocks: [g, a1, a2, b1, b2, b3, c1], canonicalHashes: Set([blockCID("G"), blockCID("A1"), blockCID("A2")]))
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNotNil(reorg)
        let concurrentTip = await chain.canonicalTip
        XCTAssertEqual(concurrentTip, blockCID("B3"))
    }

    func testMidChainFork() async {
        let g = makeBlockMeta(hash: blockCID("G"), height: 0, childHashes: [blockCID("M1")])
        let m1 = makeBlockMeta(hash: blockCID("M1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("M2")])
        let m2 = makeBlockMeta(hash: blockCID("M2"), previousHash: blockCID("M1"), height: 2, childHashes: [blockCID("M3"), blockCID("F1")])
        let m3 = makeBlockMeta(hash: blockCID("M3"), previousHash: blockCID("M2"), height: 3)
        let f1 = makeBlockMeta(hash: blockCID("F1"), previousHash: blockCID("M2"), height: 3, childHashes: [blockCID("F2")])
        let f2 = makeBlockMeta(hash: blockCID("F2"), previousHash: blockCID("F1"), height: 4, childHashes: [blockCID("F3")])
        let f3 = makeBlockMeta(hash: blockCID("F3"), previousHash: blockCID("F2"), height: 5)

        let chain = makeChain(blocks: [g, m1, m2, m3, f1, f2, f3], canonicalHashes: Set([blockCID("G"), blockCID("M1"), blockCID("M2"), blockCID("M3")]))
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNotNil(reorg)
        let midTip = await chain.canonicalTip
        XCTAssertEqual(midTip, blockCID("F3"))
        let m1OnMain = await chain.isCanonical(hash: blockCID("M1"))
        XCTAssertTrue(m1OnMain)
        let m2OnMain = await chain.isCanonical(hash: blockCID("M2"))
        XCTAssertTrue(m2OnMain)
        let m3OnMain = await chain.isCanonical(hash: blockCID("M3"))
        XCTAssertFalse(m3OnMain)
    }
}

// MARK: - Edge Case Tests

@MainActor
final class EdgeCaseTests: XCTestCase {

    func testSingleBlockNoForks() async {
        let g = makeBlockMeta(hash: blockCID("G"), height: 0)
        let chain = makeChain(blocks: [g])
        let singleTip = await chain.canonicalTip
        XCTAssertEqual(singleTip, blockCID("G"))
        let singleHighest = await chain.getHighestBlockHeight()
        XCTAssertEqual(singleHighest, 0)
    }

    func testNonexistentBlockReturnsNil() async {
        let (chain, _) = makeLinearChain(length: 1)
        let nope = await chain.getConsensusBlock(hash: "nope")
        XCTAssertNil(nope)
    }

    func testManyForksFromSameParent() async {
        var allBlocks: [BlockMeta] = []
        var genesisChildren: [String] = []

        for i in 0..<10 {
            let hash = blockCID("F\(i)_1")
            genesisChildren.append(hash)
            if i == 5 {
                allBlocks.append(makeBlockMeta(hash: hash, previousHash: blockCID("G"), height: 1, childHashes: [blockCID("F5_2")]))
                allBlocks.append(makeBlockMeta(hash: blockCID("F5_2"), previousHash: blockCID("F5_1"), height: 2, childHashes: [blockCID("F5_3")]))
                allBlocks.append(makeBlockMeta(hash: blockCID("F5_3"), previousHash: blockCID("F5_2"), height: 3))
            } else {
                allBlocks.append(makeBlockMeta(hash: hash, previousHash: blockCID("G"), height: 1))
            }
        }

        let g = makeBlockMeta(hash: blockCID("G"), height: 0, childHashes: genesisChildren)
        allBlocks.insert(g, at: 0)

        let chain = makeChain(blocks: allBlocks, canonicalHashes: Set([blockCID("G"), blockCID("F0_1")]))
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNotNil(reorg)
        let manyForksTip = await chain.canonicalTip
        XCTAssertEqual(manyForksTip, blockCID("F5_3"))
    }

    func testLongLinearChain() async {
        let length = 500
        let (chain, _) = makeLinearChain(length: length)
        let longTip = await chain.canonicalTip
        XCTAssertEqual(longTip, blockCID("block_\(length - 1)"))
        let longHighest = await chain.getHighestBlockHeight()
        XCTAssertEqual(longHighest, UInt64(length - 1))
        let containsFirst = await chain.contains(blockHash: blockCID("block_0"))
        XCTAssertTrue(containsFirst)
        let containsLast = await chain.contains(blockHash: blockCID("block_\(length - 1)"))
        XCTAssertTrue(containsLast)
    }

    func testRevisionExhaustionFailsClosedBeforeMutation() async throws {
        let genesis = makeBlockMeta(hash: blockCID("G"), height: 0)
        let chain = try ChainState(
            canonicalTip: blockCID("G"),
            canonicalHashes: [blockCID("G")],
            indexToBlockHash: [0: [blockCID("G")]],
            hashToBlock: [blockCID("G"): genesis],
            mutationGeneration: .max
        )
        let extra = VerifiedWorkContribution(
            id: testCID("revision-exhaustion"),
            work: UInt256(2)
        )

        let result = await chain.addWorkContribution(extra, to: blockCID("G"))
        let revision = await chain.currentRevision()

        XCTAssertFalse(result.addedContribution)
        XCTAssertEqual(revision, .max)
    }
}
