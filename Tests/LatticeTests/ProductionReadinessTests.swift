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

/// Storing, not throwing: the difficulty schedule anchors at the height-1
/// ancestor, so a chain deeper than two blocks has to be able to reach back
/// through itself. A block's parent is carried by CID alone, which makes that
/// reach a real fetch.
private let fetcher = StorableFetcher()

private struct RuntimeGenesisResult {
    let block: Block
    let blockHash: String
    var chain: ChainTree
}

private func makeRuntimeGenesis(
    config: GenesisConfig,
    fetcher: any Fetcher
) async throws -> RuntimeGenesisResult {
    let result = try await GenesisCeremony.create(config: config, fetcher: fetcher)
    return RuntimeGenesisResult(
        block: result.block,
        blockHash: result.blockHash,
        chain: ChainTree.fromGenesis(block: result.block)
    )
}

// MARK: - Genesis Ceremony Tests

@MainActor
final class GenesisCeremonyTests: XCTestCase {

    func testCreateDeterministicGenesis() async throws {
        let config = GenesisConfig(spec: ChainSpec.test(halfLife: 10), timestamp: 500)

        let result1 = try await makeRuntimeGenesis(config: config, fetcher: fetcher)
        let result2 = try await makeRuntimeGenesis(config: config, fetcher: fetcher)

        XCTAssertEqual(result1.blockHash, result2.blockHash,
            "Same genesis config must produce identical genesis block")

        let tip1 = result1.chain.canonicalTip
        let tip2 = result2.chain.canonicalTip
        XCTAssertEqual(tip1, tip2)
    }

    func testVerifyValidGenesis() async throws {
        let config = GenesisConfig(
            spec: ChainSpec.test(halfLife: 10),
            timestamp: 42
        )
        let result = try await makeRuntimeGenesis(config: config, fetcher: fetcher)
        XCTAssertTrue(GenesisCeremony.verify(block: result.block, config: config))
    }

    func testVerifyRejectsWrongTimestamp() async throws {
        let config = GenesisConfig(
            spec: ChainSpec.test(halfLife: 10),
            timestamp: 42
        )
        let result = try await makeRuntimeGenesis(config: config, fetcher: fetcher)

        let wrongConfig = GenesisConfig(spec: config.spec, timestamp: 999)
        XCTAssertFalse(GenesisCeremony.verify(block: result.block, config: wrongConfig))
    }

    func testVerifyRejectsNonCanonicalTarget() async throws {
        let spec = ChainSpec.test(halfLife: 10)
        let config = GenesisConfig(spec: spec, timestamp: 0)
        let result = try await makeRuntimeGenesis(config: config, fetcher: fetcher)
        // The ceremony genesis uses the canonical max target and verifies.
        XCTAssertTrue(GenesisCeremony.verify(block: result.block, config: config))

        // A genesis built with any non-canonical target is not a valid ceremony
        // genesis, regardless of config (target is not a config field).
        let store = StorableFetcher()
        let nonCanonical = try await buildAndStoreGenesis(
            spec: spec, timestamp: 0, target: UInt256(1), fetcher: store
        )
        XCTAssertFalse(GenesisCeremony.verify(block: nonCanonical, config: config))
    }

    func testVerifyRejectsSpecMismatch() async throws {
        let specA = ChainSpec.test(halfLife: 10)
        // ChainSpec no longer carries a directory; mismatch on a real field (premine)
        // so the two specs genuinely differ.
        let specB = ChainSpec.test(
            premine: 999,
            halfLife: 10
        )
        let configA = GenesisConfig(spec: specA, timestamp: 0)
        let result = try await makeRuntimeGenesis(config: configA, fetcher: fetcher)

        let configC = GenesisConfig(spec: specB, timestamp: 0)
        XCTAssertTrue(GenesisCeremony.verify(block: result.block, config: configA))
        XCTAssertFalse(GenesisCeremony.verify(block: result.block, config: configC))
    }

    func testGenesisChainTreeIsUsable() async throws {
        let config = GenesisConfig(spec: ChainSpec.test(halfLife: 10), timestamp: 500)
        var result = try await makeRuntimeGenesis(config: config, fetcher: fetcher)

        let height = result.chain.getHighestBlockHeight()
        XCTAssertEqual(height, 0)

        let contains = result.chain.contains(blockHash: result.blockHash)
        XCTAssertTrue(contains)

        let onMain = result.chain.isCanonical(hash: result.blockHash)
        XCTAssertTrue(onMain)

        let block1 = try await buildAndStoreBlock(
            previous: result.block, timestamp: 1_000, target: UInt256.max,
            nonce: 1, fetcher: fetcher
        )
        let submitResult = result.chain.submitTestBlock(
            blockHeader: try! VolumeImpl<Block>(node: block1),
            block: block1
        )
        XCTAssertTrue(submitResult.extendsCanonical, "Should be able to extend genesis chain")
    }
}

// MARK: - Block Validation on Receipt Tests

@MainActor
final class BlockReceptionTests: XCTestCase {

    func testReceivedBlockDataIsStoredAndResolvable() async throws {
        let config = GenesisConfig(spec: ChainSpec.test(halfLife: 10), timestamp: 500)

        let storableFetcher = StorableFetcher()

        let result = try await makeRuntimeGenesis(config: config, fetcher: fetcher)
        if let data = result.block.toData() {
            await storableFetcher.store(rawCid: result.blockHash, data: data)
        }

        let block1 = try await buildAndStoreBlock(
            previous: result.block, timestamp: 1_000,
            target: UInt256.max, nonce: 1, fetcher: fetcher
        )
        let block1Hash = try! VolumeImpl<Block>(node: block1).rawCID
        guard let block1Data = block1.toData() else {
            XCTFail("Block serialization failed")
            return
        }

        await storableFetcher.store(rawCid: block1Hash, data: block1Data)

        let fetchedData = try await storableFetcher.fetch(rawCid: block1Hash)
        XCTAssertEqual(fetchedData, block1Data)

        let resolvedBlock = Block(data: fetchedData)
        XCTAssertNotNil(resolvedBlock, "Block must deserialize from stored data")
    }

    func testSubmitBlockAfterStoringData() async throws {
        let config = GenesisConfig(spec: ChainSpec.test(halfLife: 10), timestamp: 500)
        var result = try await makeRuntimeGenesis(config: config, fetcher: fetcher)

        let block1 = try await buildAndStoreBlock(
            previous: result.block, timestamp: 1_000,
            target: UInt256.max, nonce: 1, fetcher: fetcher
        )
        let header = try! VolumeImpl<Block>(node: block1)
        let submitResult = result.chain.submitTestBlock(
            blockHeader: header,
            block: block1
        )
        XCTAssertTrue(submitResult.extendsCanonical)

        let tip = result.chain.canonicalTip
        XCTAssertEqual(tip, header.rawCID)
    }
}

// MARK: - End-to-End: Genesis -> Mine -> Submit -> Verify

@MainActor
final class GenesisToBlockE2ETests: XCTestCase {

    func testFullCycle() async throws {
        let spec = ChainSpec.test(halfLife: 10)
        let genesisConfig = GenesisConfig(spec: spec, timestamp: 500)
        var genesis = try await makeRuntimeGenesis(config: genesisConfig, fetcher: fetcher)

        XCTAssertTrue(GenesisCeremony.verify(block: genesis.block, config: genesisConfig))

        var prev = genesis.block
        for i in 1...10 {
            let template = try await buildAndStoreBlock(
                previous: prev, timestamp: Int64(i) * 1000,
                target: UInt256.max, nonce: 0, fetcher: fetcher
            )
            let mined = BlockBuilder.mine(block: template, target: UInt256.max, maxAttempts: 10)!
            // Store the MINED block, not just the template: mining changes the
            // nonce, so the block the next one descends from is this one, and it
            // is this one an anchor walk will have to resolve.
            try await VolumeImpl<Block>(node: mined).storeBlock(storer: fetcher)

            let header = try! VolumeImpl<Block>(node: mined)
            let result = genesis.chain.submitTestBlock(
                blockHeader: header,
                block: mined
            )
            XCTAssertTrue(result.extendsCanonical, "Block \(i) should extend")
            prev = mined
        }

        let height = genesis.chain.getHighestBlockHeight()
        XCTAssertEqual(height, 10)

        let tipHash = genesis.chain.canonicalTip
        XCTAssertEqual(tipHash, try! VolumeImpl<Block>(node: prev).rawCID)

        let genesisOnMain = genesis.chain.isCanonical(hash: genesis.blockHash)
        XCTAssertTrue(genesisOnMain)
    }

    func testTwoNodesSameGenesis() async throws {
        let spec = ChainSpec.test(halfLife: 10)
        let genesisConfig = GenesisConfig(spec: spec, timestamp: 500)

        var nodeA = try await makeRuntimeGenesis(config: genesisConfig, fetcher: fetcher)
        var nodeB = try await makeRuntimeGenesis(config: genesisConfig, fetcher: fetcher)

        XCTAssertEqual(nodeA.blockHash, nodeB.blockHash, "Both nodes must agree on genesis")

        let blockA1 = try await buildAndStoreBlock(
            previous: nodeA.block, timestamp: 1_000,
            target: UInt256.max, nonce: 1, fetcher: fetcher
        )
        let headerA1 = try! VolumeImpl<Block>(node: blockA1)

        let resultOnA = nodeA.chain.submitTestBlock(
            blockHeader: headerA1, block: blockA1
        )
        XCTAssertTrue(resultOnA.extendsCanonical)

        let resultOnB = nodeB.chain.submitTestBlock(
            blockHeader: headerA1, block: blockA1
        )
        XCTAssertTrue(resultOnB.extendsCanonical, "Node B accepts block mined by Node A")

        let tipA = nodeA.chain.canonicalTip
        let tipB = nodeB.chain.canonicalTip
        XCTAssertEqual(tipA, tipB, "Both nodes must agree on chain tip")
    }

    func testTwoNodesReachConsensusAfterFork() async throws {
        let spec = ChainSpec.test(halfLife: 10)
        let genesisConfig = GenesisConfig(spec: spec, timestamp: 500)
        var nodeA = try await makeRuntimeGenesis(config: genesisConfig, fetcher: fetcher)
        var nodeB = try await makeRuntimeGenesis(config: genesisConfig, fetcher: fetcher)

        let blockA1 = try await buildAndStoreBlock(
            previous: nodeA.block, timestamp: 1_000,
            target: UInt256.max, nonce: 1, fetcher: fetcher
        )
        let blockA2 = try await buildAndStoreBlock(
            previous: blockA1, timestamp: 2_000,
            target: UInt256.max, nonce: 2, fetcher: fetcher
        )

        let blockB1 = try await buildAndStoreBlock(
            previous: nodeB.block, timestamp: 1_000,
            target: UInt256.max, nonce: 100, fetcher: fetcher
        )

        let _ = nodeA.chain.submitTestBlock(
            blockHeader: try! VolumeImpl(node: blockA1), block: blockA1
        )
        let _ = nodeA.chain.submitTestBlock(
            blockHeader: try! VolumeImpl(node: blockA2), block: blockA2
        )

        let _ = nodeB.chain.submitTestBlock(
            blockHeader: try! VolumeImpl(node: blockB1), block: blockB1
        )

        let tipB_before = nodeB.chain.canonicalTip
        XCTAssertEqual(tipB_before, try! VolumeImpl<Block>(node: blockB1).rawCID)

        let resultA1onB = nodeB.chain.submitTestBlock(
            blockHeader: try! VolumeImpl(node: blockA1), block: blockA1
        )
        let resultA2onB = nodeB.chain.submitTestBlock(
            blockHeader: try! VolumeImpl(node: blockA2), block: blockA2
        )

        XCTAssertTrue(
            resultA1onB.commit?.canonicalChanged == true || resultA2onB.commit?.canonicalChanged == true,
            "Node B should reorg when A wins the stable tie or becomes strictly heavier"
        )

        let tipA = nodeA.chain.canonicalTip
        let tipB = nodeB.chain.canonicalTip
        XCTAssertEqual(tipA, tipB, "Both nodes must converge on same tip after reorg")
    }
}
