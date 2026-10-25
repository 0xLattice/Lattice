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
        let hash = "\(prefix)_\(i)"
        let prevHash: String? = i == 0 ? nil : "\(prefix)_\(i - 1)"
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
        XCTAssertEqual(tip, "block_0")
        let highest = await chain.getHighestBlockHeight()
        XCTAssertEqual(highest, 0)
        let contains = await chain.contains(blockHash: "block_0")
        XCTAssertTrue(contains)
        let onMain = await chain.isCanonical(hash: "block_0")
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
        XCTAssertEqual(tip, "block_4")
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
        let block = await chain.getConsensusBlock(hash: "block_1")
        XCTAssertNotNil(block)
        XCTAssertEqual(block?.blockHeight, 1)
        XCTAssertEqual(block?.parentBlockHash, "block_0")
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
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2, childHashes: ["A3"])
        let a3 = makeBlockMeta(hash: "A3", previousHash: "A2", height: 3)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2, childHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", height: 3, childHashes: ["B4"])
        let b4 = makeBlockMeta(hash: "B4", previousHash: "B3", height: 4)

        let chain = makeChain(
            blocks: [g, a1, a2, a3, b1, b2, b3, b4],
            canonicalHashes: Set(["G", "A1", "A2", "A3"])
        )

        let revisionBefore = await chain.currentRevision()
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNotNil(reorg)
        XCTAssertTrue(reorg!.canonicalBlocksAdded.keys.contains("B4"))
        XCTAssertTrue(reorg!.canonicalBlocksRemoved.contains("A3"))
        XCTAssertEqual(reorg!.revision, revisionBefore + 1)
        let revisionAfter = await chain.currentRevision()
        XCTAssertEqual(revisionAfter, reorg!.revision)

        let newTip = await chain.canonicalTip
        XCTAssertEqual(newTip, "B4")
    }

    func testShorterForkDoesNotReorg() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2, childHashes: ["A3"])
        let a3 = makeBlockMeta(hash: "A3", previousHash: "A2", height: 3)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2)

        let chain = makeChain(
            blocks: [g, a1, a2, a3, b1, b2],
            canonicalHashes: Set(["G", "A1", "A2", "A3"])
        )

        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNil(reorg)
    }

    func testEqualLengthForkKeepsPreferredBaseCID() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2)

        let chain = makeChain(
            blocks: [g, a1, a2, b1, b2],
            canonicalHashes: Set(["G", "A1", "A2"])
        )

        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNil(reorg, "A1 is the smaller segment-base hash")
    }

}

@MainActor
final class ChainWithMostWorkTests: XCTestCase {

    func testSingleBlockChain() async {
        let g = makeBlockMeta(hash: "G", height: 0)
        let chain = makeChain(blocks: [g])
        let work = await chain.chainWithMostWork(startingBlock: g)
        XCTAssertEqual(work.subtreeWork, WorkSum(UInt256(1)))
        XCTAssertEqual(work.blocks, Set(["G"]))
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
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2, childHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", height: 3)

        let chain = makeChain(blocks: [g, a1, a2, b1, b2, b3])
        let work = await chain.chainWithMostWork(startingBlock: g)
        XCTAssertEqual(work.subtreeWork, WorkSum(UInt256(6)), "subtreeWork(G) = whole subtree = 6 blocks")
        XCTAssertTrue(work.blocks.contains("B3"), "descent rides the heavier B fork to its tip")
        XCTAssertFalse(work.blocks.contains("A1"))
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
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2, childHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", height: 3)

        let chain = makeChain(blocks: [g, a1, b1, b2, b3], canonicalHashes: Set(["G", "A1"]))
        let _ = await chain.reevaluateForkChoice()

        let tip = await chain.canonicalTip
        let tipBlock = await chain.getConsensusBlock(hash: tip)!
        let highest = await chain.getHighestBlockHeight()
        XCTAssertEqual(tipBlock.blockHeight, highest)
    }

    func testReorgRemovesOldMainChainBlocks() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2, childHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", height: 3)

        let chain = makeChain(blocks: [g, a1, a2, b1, b2, b3], canonicalHashes: Set(["G", "A1", "A2"]))
        let _ = await chain.reevaluateForkChoice()

        let a1OnMain = await chain.isCanonical(hash: "A1")
        XCTAssertFalse(a1OnMain)
        let a2OnMain = await chain.isCanonical(hash: "A2")
        XCTAssertFalse(a2OnMain)
        let gOnMain = await chain.isCanonical(hash: "G")
        XCTAssertTrue(gOnMain)
    }

    func testReorgStructContents() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2)

        let chain = makeChain(blocks: [g, a1, b1, b2], canonicalHashes: Set(["G", "A1"]))
        let reorg = await chain.reevaluateForkChoice()

        XCTAssertNotNil(reorg)
        XCTAssertTrue(reorg!.canonicalBlocksAdded.keys.contains("B1"))
        XCTAssertTrue(reorg!.canonicalBlocksAdded.keys.contains("B2"))
        XCTAssertFalse(reorg!.canonicalBlocksAdded.keys.contains("G"))
        XCTAssertTrue(reorg!.canonicalBlocksRemoved.contains("A1"))
        XCTAssertFalse(reorg!.canonicalBlocksRemoved.contains("G"))
    }
}

// MARK: - Nakamoto Consensus / Industry Standard Tests

@MainActor
final class NakamotoConsensusTests: XCTestCase {

    func testNakamotoLongestChainRule() async {
        let (chain, _) = makeLinearChain(length: 6, prefix: "main")
        let tip = await chain.canonicalTip
        XCTAssertEqual(tip, "main_5")
        for i in 0..<6 {
            let onMain = await chain.isCanonical(hash: "main_\(i)")
            XCTAssertTrue(onMain)
        }
    }

    func testSelfishMiningReorg() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["P1", "H1"])
        let p1 = makeBlockMeta(hash: "P1", previousHash: "G", height: 1, childHashes: ["P2"])
        let p2 = makeBlockMeta(hash: "P2", previousHash: "P1", height: 2, childHashes: ["P3"])
        let p3 = makeBlockMeta(hash: "P3", previousHash: "P2", height: 3)
        let h1 = makeBlockMeta(hash: "H1", previousHash: "G", height: 1, childHashes: ["H2"])
        let h2 = makeBlockMeta(hash: "H2", previousHash: "H1", height: 2, childHashes: ["H3"])
        let h3 = makeBlockMeta(hash: "H3", previousHash: "H2", height: 3, childHashes: ["H4"])
        let h4 = makeBlockMeta(hash: "H4", previousHash: "H3", height: 4)

        let chain = makeChain(blocks: [g, p1, p2, p3, h1, h2, h3, h4], canonicalHashes: Set(["G", "P1", "P2", "P3"]))
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNotNil(reorg)
        let selfishTip = await chain.canonicalTip
        XCTAssertEqual(selfishTip, "H4")

        for name in ["P1", "P2", "P3"] {
            let onMain = await chain.isCanonical(hash: name)
            XCTAssertFalse(onMain, "\(name) should be off main chain")
        }
        for name in ["H1", "H2", "H3", "H4"] {
            let onMain = await chain.isCanonical(hash: name)
            XCTAssertTrue(onMain, "\(name) should be on main chain")
        }
        let gOnMainSelfish = await chain.isCanonical(hash: "G")
        XCTAssertTrue(gOnMainSelfish)
    }

    func testEqualWorkUsesStableBlockHashTieBreak() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2, childHashes: ["A3"])
        let a3 = makeBlockMeta(hash: "A3", previousHash: "A2", height: 3)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2, childHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", height: 3)

        let chain = makeChain(blocks: [g, a1, a2, a3, b1, b2, b3], canonicalHashes: Set(["G", "A1", "A2", "A3"]))
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNil(reorg, "The smaller segment-base hash is already canonical")
        let tieTip = await chain.canonicalTip
        XCTAssertEqual(tieTip, "A3")
    }

    func testDeepReorgFromGenesis() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["M1", "F1"])
        let m1 = makeBlockMeta(hash: "M1", previousHash: "G", height: 1, childHashes: ["M2"])
        let m2 = makeBlockMeta(hash: "M2", previousHash: "M1", height: 2)
        let f1 = makeBlockMeta(hash: "F1", previousHash: "G", height: 1, childHashes: ["F2"])
        let f2 = makeBlockMeta(hash: "F2", previousHash: "F1", height: 2, childHashes: ["F3"])
        let f3 = makeBlockMeta(hash: "F3", previousHash: "F2", height: 3, childHashes: ["F4"])
        let f4 = makeBlockMeta(hash: "F4", previousHash: "F3", height: 4, childHashes: ["F5"])
        let f5 = makeBlockMeta(hash: "F5", previousHash: "F4", height: 5)

        let chain = makeChain(blocks: [g, m1, m2, f1, f2, f3, f4, f5], canonicalHashes: Set(["G", "M1", "M2"]))
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNotNil(reorg)
        let deepTip = await chain.canonicalTip
        XCTAssertEqual(deepTip, "F5")
        let deepHighest = await chain.getHighestBlockHeight()
        XCTAssertEqual(deepHighest, 5)
    }

    func testMultipleConcurrentForks() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["A1", "B1", "C1"])
        let a1 = makeBlockMeta(hash: "A1", previousHash: "G", height: 1, childHashes: ["A2"])
        let a2 = makeBlockMeta(hash: "A2", previousHash: "A1", height: 2)
        let b1 = makeBlockMeta(hash: "B1", previousHash: "G", height: 1, childHashes: ["B2"])
        let b2 = makeBlockMeta(hash: "B2", previousHash: "B1", height: 2, childHashes: ["B3"])
        let b3 = makeBlockMeta(hash: "B3", previousHash: "B2", height: 3)
        let c1 = makeBlockMeta(hash: "C1", previousHash: "G", height: 1)

        let chain = makeChain(blocks: [g, a1, a2, b1, b2, b3, c1], canonicalHashes: Set(["G", "A1", "A2"]))
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNotNil(reorg)
        let concurrentTip = await chain.canonicalTip
        XCTAssertEqual(concurrentTip, "B3")
    }

    func testMidChainFork() async {
        let g = makeBlockMeta(hash: "G", height: 0, childHashes: ["M1"])
        let m1 = makeBlockMeta(hash: "M1", previousHash: "G", height: 1, childHashes: ["M2"])
        let m2 = makeBlockMeta(hash: "M2", previousHash: "M1", height: 2, childHashes: ["M3", "F1"])
        let m3 = makeBlockMeta(hash: "M3", previousHash: "M2", height: 3)
        let f1 = makeBlockMeta(hash: "F1", previousHash: "M2", height: 3, childHashes: ["F2"])
        let f2 = makeBlockMeta(hash: "F2", previousHash: "F1", height: 4, childHashes: ["F3"])
        let f3 = makeBlockMeta(hash: "F3", previousHash: "F2", height: 5)

        let chain = makeChain(blocks: [g, m1, m2, m3, f1, f2, f3], canonicalHashes: Set(["G", "M1", "M2", "M3"]))
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNotNil(reorg)
        let midTip = await chain.canonicalTip
        XCTAssertEqual(midTip, "F3")
        let m1OnMain = await chain.isCanonical(hash: "M1")
        XCTAssertTrue(m1OnMain)
        let m2OnMain = await chain.isCanonical(hash: "M2")
        XCTAssertTrue(m2OnMain)
        let m3OnMain = await chain.isCanonical(hash: "M3")
        XCTAssertFalse(m3OnMain)
    }
}

// MARK: - Edge Case Tests

@MainActor
final class EdgeCaseTests: XCTestCase {

    func testSingleBlockNoForks() async {
        let g = makeBlockMeta(hash: "G", height: 0)
        let chain = makeChain(blocks: [g])
        let singleTip = await chain.canonicalTip
        XCTAssertEqual(singleTip, "G")
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
            let hash = "F\(i)_1"
            genesisChildren.append(hash)
            if i == 5 {
                allBlocks.append(makeBlockMeta(hash: hash, previousHash: "G", height: 1, childHashes: ["F5_2"]))
                allBlocks.append(makeBlockMeta(hash: "F5_2", previousHash: "F5_1", height: 2, childHashes: ["F5_3"]))
                allBlocks.append(makeBlockMeta(hash: "F5_3", previousHash: "F5_2", height: 3))
            } else {
                allBlocks.append(makeBlockMeta(hash: hash, previousHash: "G", height: 1))
            }
        }

        let g = makeBlockMeta(hash: "G", height: 0, childHashes: genesisChildren)
        allBlocks.insert(g, at: 0)

        let chain = makeChain(blocks: allBlocks, canonicalHashes: Set(["G", "F0_1"]))
        let reorg = await chain.reevaluateForkChoice()
        XCTAssertNotNil(reorg)
        let manyForksTip = await chain.canonicalTip
        XCTAssertEqual(manyForksTip, "F5_3")
    }

    func testLongLinearChain() async {
        let length = 500
        let (chain, _) = makeLinearChain(length: length)
        let longTip = await chain.canonicalTip
        XCTAssertEqual(longTip, "block_\(length - 1)")
        let longHighest = await chain.getHighestBlockHeight()
        XCTAssertEqual(longHighest, UInt64(length - 1))
        let containsFirst = await chain.contains(blockHash: "block_0")
        XCTAssertTrue(containsFirst)
        let containsLast = await chain.contains(blockHash: "block_\(length - 1)")
        XCTAssertTrue(containsLast)
    }

    func testRevisionExhaustionFailsClosedBeforeMutation() async throws {
        let genesis = makeBlockMeta(hash: "G", height: 0)
        let chain = try ChainState(
            canonicalTip: "G",
            canonicalHashes: ["G"],
            indexToBlockHash: [0: ["G"]],
            hashToBlock: ["G": genesis],
            mutationGeneration: .max
        )
        let extra = VerifiedWorkContribution(
            id: testCID("revision-exhaustion"),
            work: UInt256(2)
        )

        let result = await chain.addWorkContribution(extra, to: "G")
        let revision = await chain.currentRevision()

        XCTAssertFalse(result.addedContribution)
        XCTAssertEqual(revision, .max)
    }
}
