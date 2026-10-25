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

// MARK: - Block Construction Helpers

func emptyTransactions() -> HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>> {
    // known-valid local node; CID computation cannot fail (no Float/Double fields)
    try! HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>>(node: MerkleDictionaryImpl<VolumeImpl<Transaction>>())
}

func emptyChildBlocks() -> HeaderImpl<FlatDictionary<BlockHeader>> {
    // known-valid local node; CID computation cannot fail (no Float/Double fields)
    try! HeaderImpl(node: FlatDictionary<BlockHeader>())
}

func emptyLatticeState() -> LatticeStateHeader {
    // known-valid local node; CID computation cannot fail (no Float/Double fields)
    try! LatticeStateHeader(node: LatticeState.emptyState())
}

func testChainSpec() -> ChainSpec {
    ChainSpec.test(halfLife: 10)
}

func makeGenesisBlock(
    spec: ChainSpec? = nil,
    timestamp: Int64 = 1_000_000,
    target: UInt256 = UInt256(1000),
    nonce: UInt64 = 0
) -> Block {
    let s = spec ?? testChainSpec()
    let emptyState = emptyLatticeState()
    return Block(
        parent: nil,
        transactions: emptyTransactions(),
        target: target,
        nextTarget: target,
        // known-valid local node; CID computation cannot fail (no Float/Double fields)
        spec: try! VolumeImpl<ChainSpec>(node: s),
        parentState: emptyState.removingNode(),
        prevState: emptyState.removingNode(),
        postState: emptyState,
        children: emptyChildBlocks(),
        height: 0,
        timestamp: timestamp,
        rewardRecipient: nil,
        nonce: nonce
    )
}

func makeBlock(
    previous: Block,
    height: UInt64,
    timestamp: Int64,
    target: UInt256 = UInt256(1000),
    nonce: UInt64 = 0,
    children: HeaderImpl<FlatDictionary<BlockHeader>>? = nil
) -> Block {
    // known-valid local node; CID computation cannot fail (no Float/Double fields)
    let prevHeader = try! VolumeImpl<Block>(node: previous)
    let emptyState = emptyLatticeState()
    return Block(
        parent: prevHeader.removingNode(),
        transactions: emptyTransactions(),
        target: target,
        nextTarget: target,
        spec: previous.spec,
        parentState: emptyState.removingNode(),
        prevState: previous.postState.removingNode(),
        postState: emptyState,
        children: children ?? emptyChildBlocks(),
        height: height,
        timestamp: timestamp,
        rewardRecipient: nil,
        nonce: nonce
    )
}

func blockHeader(_ block: Block) -> BlockHeader {
    // known-valid local node; CID computation cannot fail (no Float/Double fields)
    try! VolumeImpl<Block>(node: block)
}

// MARK: - End-to-End: Block Construction and CID

@MainActor
final class BlockConstructionTests: XCTestCase {

    func testGenesisBlockHasDeterministicCID() async {
        let g1 = makeGenesisBlock(timestamp: 1000, nonce: 42)
        let g2 = makeGenesisBlock(timestamp: 1000, nonce: 42)
        let h1 = blockHeader(g1)
        let h2 = blockHeader(g2)
        XCTAssertEqual(h1.rawCID, h2.rawCID, "Same genesis params should produce same CID")
    }

    func testDifferentNonceProducesDifferentCID() async {
        let g1 = makeGenesisBlock(nonce: 1)
        let g2 = makeGenesisBlock(nonce: 2)
        let h1 = blockHeader(g1)
        let h2 = blockHeader(g2)
        XCTAssertNotEqual(h1.rawCID, h2.rawCID)
    }

    func testDifferentTimestampProducesDifferentCID() async {
        let g1 = makeGenesisBlock(timestamp: 1000)
        let g2 = makeGenesisBlock(timestamp: 2000)
        XCTAssertNotEqual(blockHeader(g1).rawCID, blockHeader(g2).rawCID)
    }

    func testBlockReferencesParentCID() async {
        let genesis = makeGenesisBlock()
        let block1 = makeBlock(previous: genesis, height: 1, timestamp: 2000)
        XCTAssertEqual(block1.parent?.rawCID, blockHeader(genesis).rawCID)
    }

    func testDifficultyHashCommitsToAllFields() async {
        let genesis = makeGenesisBlock()
        let block1a = makeBlock(previous: genesis, height: 1, timestamp: 2000, nonce: 1)
        let block1b = makeBlock(previous: genesis, height: 1, timestamp: 2000, nonce: 2)
        XCTAssertNotEqual(block1a.proofOfWorkHash(), block1b.proofOfWorkHash())
    }

}

// MARK: - End-to-End: Real Block Submission through ChainState

@MainActor
final class BlockSubmissionE2ETests: XCTestCase {

    func testSubmitGenesisAndExtendChain() async {
        let genesis = makeGenesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        let genesisHash = blockHeader(genesis).rawCID
        let tip = await chain.canonicalTip
        XCTAssertEqual(tip, genesisHash)

        let block1 = makeBlock(previous: genesis, height: 1, timestamp: 2000)
        let header1 = blockHeader(block1)
        let result1 = await chain.submitTestBlock(
            blockHeader: header1,
            block: block1
        )
        XCTAssertTrue(result1.addedBlock)
        XCTAssertTrue(result1.extendsCanonical)
        XCTAssertTrue(result1.commit?.canonicalChanged == true)

        let newTip = await chain.canonicalTip
        XCTAssertEqual(newTip, header1.rawCID)
        let highest = await chain.getHighestBlockHeight()
        XCTAssertEqual(highest, 1)
    }

    func testSubmitLinearChainOfFiveBlocks() async {
        let genesis = makeGenesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        var prev = genesis
        for i in 1...5 {
            let block = makeBlock(previous: prev, height: UInt64(i), timestamp: Int64(1000 + i * 1000))
            let header = blockHeader(block)
            let result = await chain.submitTestBlock(
                blockHeader: header,
                block: block
            )
            XCTAssertTrue(result.addedBlock, "Block \(i) should be added")
            XCTAssertTrue(result.extendsCanonical, "Block \(i) should extend main chain")
            prev = block
        }

        let highest = await chain.getHighestBlockHeight()
        XCTAssertEqual(highest, 5)

        let tipHash = await chain.canonicalTip
        XCTAssertEqual(tipHash, blockHeader(prev).rawCID)
    }

    func testSubmitDuplicateBlockIsDiscarded() async {
        let genesis = makeGenesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        let block1 = makeBlock(previous: genesis, height: 1, timestamp: 2000)
        let header1 = blockHeader(block1)

        let result1 = await chain.submitTestBlock(
            blockHeader: header1,
            block: block1
        )
        XCTAssertTrue(result1.addedBlock)

        let result2 = await chain.submitTestBlock(
            blockHeader: header1,
            block: block1
        )
        XCTAssertFalse(result2.addedBlock, "Duplicate block should be discarded")
    }

    func testNewProofContributionReweightsOnceWithoutDowngrade() async {
        let target = UInt256(1000)
        let ownWork = workForTarget(target)
        let genesis = makeGenesisBlock(target: target)
        let chain = ChainState.fromGenesis(block: genesis)

        let a1 = makeBlock(previous: genesis, height: 1, timestamp: 2000, target: target, nonce: 1)
        let a2 = makeBlock(previous: a1, height: 2, timestamp: 3000, target: target, nonce: 1)
        let b1 = makeBlock(previous: genesis, height: 1, timestamp: 2000, target: target, nonce: 2)
        let b1Header = blockHeader(b1)

        _ = await chain.submitTestBlock(blockHeader: blockHeader(a1), block: a1)
        _ = await chain.submitTestBlock(blockHeader: blockHeader(a2), block: a2)
        _ = await chain.submitTestBlock(blockHeader: b1Header, block: b1)

        let proof = VerifiedWorkContribution(
            id: testCID("accepted-root-proof"),
            work: ownWork &* UInt256(4)
        )
        let promoted = await chain.submitTestBlock(
            blockHeader: b1Header,
            block: b1,
            contribution: proof
        )

        XCTAssertFalse(promoted.addedBlock)
        XCTAssertTrue(promoted.addedContribution)
        XCTAssertTrue(promoted.commit?.canonicalChanged == true)
        let promotedTip = await chain.canonicalTip
        XCTAssertEqual(promotedTip, b1Header.rawCID)

        let acceptedWork = await chain.getConsensusBlock(hash: b1Header.rawCID)?.work
        let replay = await chain.submitTestBlock(
            blockHeader: b1Header,
            block: b1,
            contribution: proof
        )
        let conflictingReplay = await chain.submitTestBlock(
            blockHeader: b1Header,
            block: b1,
            contribution: VerifiedWorkContribution(
                id: proof.id,
                work: UInt256(1)
            )
        )

        XCTAssertFalse(replay.addedContribution, "a proof fact is counted once")
        XCTAssertFalse(conflictingReplay.addedContribution, "the same proof ID cannot downgrade work")
        let finalWork = await chain.getConsensusBlock(hash: b1Header.rawCID)?.work
        XCTAssertEqual(finalWork, acceptedWork)
    }

}

// MARK: - End-to-End: Fork and Reorg with Real Blocks

@MainActor
final class ForkReorgE2ETests: XCTestCase {

    func testLongerForkReorgsWithRealBlocks() async {
        let genesis = makeGenesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        let a1 = makeBlock(previous: genesis, height: 1, timestamp: 2000, nonce: 1)
        let a2 = makeBlock(previous: a1, height: 2, timestamp: 3000, nonce: 1)

        let _ = await chain.submitTestBlock(blockHeader: blockHeader(a1), block: a1)
        let _ = await chain.submitTestBlock(blockHeader: blockHeader(a2), block: a2)

        let tipAfterA = await chain.canonicalTip
        XCTAssertEqual(tipAfterA, blockHeader(a2).rawCID)

        let b1 = makeBlock(previous: genesis, height: 1, timestamp: 2000, nonce: 2)
        let b2 = makeBlock(previous: b1, height: 2, timestamp: 3000, nonce: 2)
        let b3 = makeBlock(previous: b2, height: 3, timestamp: 4000, nonce: 2)

        let _ = await chain.submitTestBlock(blockHeader: blockHeader(b1), block: b1)
        let _ = await chain.submitTestBlock(blockHeader: blockHeader(b2), block: b2)
        let resultB3 = await chain.submitTestBlock(blockHeader: blockHeader(b3), block: b3)

        XCTAssertTrue(resultB3.commit?.canonicalChanged == true, "Longer B fork should trigger reorg")

        let tipAfterB = await chain.canonicalTip
        XCTAssertEqual(tipAfterB, blockHeader(b3).rawCID)

        let a2OnMain = await chain.isCanonical(hash: blockHeader(a2).rawCID)
        XCTAssertFalse(a2OnMain, "A2 should be off main chain after reorg")

        let b3OnMain = await chain.isCanonical(hash: blockHeader(b3).rawCID)
        XCTAssertTrue(b3OnMain, "B3 should be on main chain after reorg")

        let genesisOnMain = await chain.isCanonical(hash: blockHeader(genesis).rawCID)
        XCTAssertTrue(genesisOnMain, "Genesis should survive reorg")
    }

    func testEqualLengthForkUsesStableSegmentBaseWithRealBlocks() async {
        let genesis = makeGenesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        let a1 = makeBlock(previous: genesis, height: 1, timestamp: 2000, nonce: 1)
        let a2 = makeBlock(previous: a1, height: 2, timestamp: 3000, nonce: 1)

        let _ = await chain.submitTestBlock(blockHeader: blockHeader(a1), block: a1)
        let _ = await chain.submitTestBlock(blockHeader: blockHeader(a2), block: a2)

        let b1 = makeBlock(previous: genesis, height: 1, timestamp: 2000, nonce: 2)
        let b2 = makeBlock(previous: b1, height: 2, timestamp: 3000, nonce: 2)

        let _ = await chain.submitTestBlock(blockHeader: blockHeader(b1), block: b1)
        let resultB2 = await chain.submitTestBlock(blockHeader: blockHeader(b2), block: b2)

        let bWins = forkChoicePrefersBlock(
            blockHeader(b1).rawCID,
            over: blockHeader(a1).rawCID
        )
        XCTAssertEqual(resultB2.commit?.canonicalChanged == true, bWins)
        let tip = await chain.canonicalTip
        XCTAssertEqual(tip, blockHeader(bWins ? b2 : a2).rawCID)
    }
}

// MARK: - End-to-End: ChainState.fromGenesis Validation

@MainActor
final class FromGenesisE2ETests: XCTestCase {

    func testFromGenesisInitializesCorrectly() async {
        let genesis = makeGenesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)
        let genesisHash = blockHeader(genesis).rawCID

        let tip = await chain.canonicalTip
        XCTAssertEqual(tip, genesisHash)

        let highest = await chain.getHighestBlockHeight()
        XCTAssertEqual(highest, 0)

        let contains = await chain.contains(blockHash: genesisHash)
        XCTAssertTrue(contains)

        let onMain = await chain.isCanonical(hash: genesisHash)
        XCTAssertTrue(onMain)

        let block = await chain.getConsensusBlock(hash: genesisHash)
        XCTAssertNotNil(block)
        XCTAssertEqual(block?.blockHeight, 0)
        XCTAssertNil(block?.parentBlockHash)
    }

    func testFromGenesisProducesDeterministicChain() async {
        let genesis = makeGenesisBlock(timestamp: 42, nonce: 7)
        let chain1 = ChainState.fromGenesis(block: genesis)
        let chain2 = ChainState.fromGenesis(block: genesis)

        let tip1 = await chain1.canonicalTip
        let tip2 = await chain2.canonicalTip
        XCTAssertEqual(tip1, tip2, "Same genesis should produce same chain tip")
    }
}

// MARK: - End-to-End: ChainLevel Context

@MainActor
final class ChainLevelE2ETests: XCTestCase {

    func testChainLevelCreation() async {
        let genesis = makeGenesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)
        let level = ChainLevel(testChain: chain)

        let tip = await level.chain.canonicalTip
        XCTAssertEqual(tip, blockHeader(genesis).rawCID)
    }

}

// MARK: - End-to-End: State Continuity

@MainActor
final class StateContinuityE2ETests: XCTestCase {

    func testBlockStateChaining() async {
        let genesis = makeGenesisBlock()
        let block1 = makeBlock(previous: genesis, height: 1, timestamp: 2000)
        XCTAssertEqual(block1.prevState.rawCID, genesis.postState.rawCID,
            "Block 1's homestead should equal genesis frontier")

        let block2 = makeBlock(previous: block1, height: 2, timestamp: 3000)
        XCTAssertEqual(block2.prevState.rawCID, block1.postState.rawCID,
            "Block 2's homestead should equal block 1's frontier")
    }

    func testGenesisHasEmptyHomestead() async {
        let genesis = makeGenesisBlock()
        let emptyState = emptyLatticeState()
        XCTAssertEqual(genesis.prevState.rawCID, emptyState.rawCID,
            "Genesis homestead should be empty state")
    }

    func testChainSpecPersistsAcrossBlocks() async {
        let genesis = makeGenesisBlock()
        let block1 = makeBlock(previous: genesis, height: 1, timestamp: 2000)
        let block2 = makeBlock(previous: block1, height: 2, timestamp: 3000)
        XCTAssertEqual(genesis.spec.rawCID, block1.spec.rawCID)
        XCTAssertEqual(block1.spec.rawCID, block2.spec.rawCID)
    }

    func testBlockIndexIncrements() async {
        let genesis = makeGenesisBlock()
        XCTAssertEqual(genesis.height, 0)
        let block1 = makeBlock(previous: genesis, height: 1, timestamp: 2000)
        XCTAssertEqual(block1.height, 1)
        let block2 = makeBlock(previous: block1, height: 2, timestamp: 3000)
        XCTAssertEqual(block2.height, 2)
    }

    func testTimestampsIncrease() async {
        let genesis = makeGenesisBlock(timestamp: 1000)
        let block1 = makeBlock(previous: genesis, height: 1, timestamp: 2000)
        let block2 = makeBlock(previous: block1, height: 2, timestamp: 3000)
        XCTAssertTrue(genesis.timestamp < block1.timestamp)
        XCTAssertTrue(block1.timestamp < block2.timestamp)
    }
}

// MARK: - End-to-End: Full Pipeline Smoke Test

@MainActor
final class FullPipelineSmokeTests: XCTestCase {

    func testBuildAndReorgTenBlockChain() async {
        let genesis = makeGenesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        var mainChainBlocks: [Block] = [genesis]
        for i in 1...10 {
            let block = makeBlock(
                previous: mainChainBlocks.last!,
                height: UInt64(i),
                timestamp: Int64(1000 + i * 1000),
                nonce: 1
            )
            let result = await chain.submitTestBlock(
                blockHeader: blockHeader(block),
                block: block
            )
            XCTAssertTrue(result.extendsCanonical, "Block \(i) should extend")
            mainChainBlocks.append(block)
        }

        let tipAt10 = await chain.getHighestBlockHeight()
        XCTAssertEqual(tipAt10, 10)

        var forkBlocks: [Block] = [mainChainBlocks[5]]
        for i in 6...15 {
            let block = makeBlock(
                previous: forkBlocks.last!,
                height: UInt64(i),
                timestamp: Int64(1000 + i * 1000),
                nonce: 2
            )
            let result = await chain.submitTestBlock(
                blockHeader: blockHeader(block),
                block: block
            )
            if i < 10 {
                XCTAssertFalse(result.commit?.canonicalChanged == true, "Shorter fork should not reorg at block \(i)")
            }
            forkBlocks.append(block)
        }

        let tipAfterFork = await chain.canonicalTip
        XCTAssertEqual(tipAfterFork, blockHeader(forkBlocks.last!).rawCID, "Fork should be new tip")
        let highestAfterFork = await chain.getHighestBlockHeight()
        XCTAssertEqual(highestAfterFork, 15)

        for i in 6...10 {
            let oldHash = blockHeader(mainChainBlocks[i]).rawCID
            let onMain = await chain.isCanonical(hash: oldHash)
            XCTAssertFalse(onMain, "Old main chain block \(i) should be off main chain")
        }

        for i in 0...5 {
            let commonHash = blockHeader(mainChainBlocks[i]).rawCID
            let onMain = await chain.isCanonical(hash: commonHash)
            XCTAssertTrue(onMain, "Common ancestor block \(i) should remain on main chain")
        }
    }

    func testCIDConsistencyAcrossOperations() async {
        let genesis = makeGenesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)
        let genesisHash = blockHeader(genesis).rawCID

        let block1 = makeBlock(previous: genesis, height: 1, timestamp: 2000)
        let block1Hash = blockHeader(block1).rawCID
        let _ = await chain.submitTestBlock(
            blockHeader: blockHeader(block1),
            block: block1
        )

        let storedGenesis = await chain.getConsensusBlock(hash: genesisHash)
        XCTAssertNotNil(storedGenesis)
        XCTAssertEqual(storedGenesis?.blockHash, genesisHash)

        let storedBlock1 = await chain.getConsensusBlock(hash: block1Hash)
        XCTAssertNotNil(storedBlock1)
        XCTAssertEqual(storedBlock1?.parentBlockHash, genesisHash,
            "Stored block's previous hash should match genesis CID")
    }
}
