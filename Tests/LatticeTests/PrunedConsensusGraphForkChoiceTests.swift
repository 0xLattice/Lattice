import Foundation
import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import cashew
import UInt256

final class ConsensusGraphRecoveryTests: XCTestCase {
    func testCompleteConsensusGraphSurvivesFactReplay() async throws {
        let fetcher = StorableFetcher()
        let target = UInt256(1_000)
        let base = Int64(Date().timeIntervalSince1970 * 1_000) - 30_000
        let genesis = try await buildAndStoreGenesis(
            spec: consensusGraphSpec(),
            timestamp: base,
            target: target,
            fetcher: fetcher
        )
        let first = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: base + 1_000,
            target: target,
            nonce: 1,
            fetcher: fetcher
        )
        let second = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: base + 2_000,
            target: target,
            nonce: 2,
            fetcher: fetcher
        )
        let descendant = try await buildAndStoreBlock(
            previous: second,
            timestamp: base + 3_000,
            target: target,
            nonce: 3,
            fetcher: fetcher
        )
        var chain = ChainTree.fromGenesis(block: genesis)

        for block in [first, second, descendant] {
            let header = try BlockHeader(node: block)
            let result = chain.submitBlock(
                blockHeader: header,
                block: block,
                contribution: VerifiedWorkContribution(
                    id: header.rawCID,
                    work: workForTarget(block.target)
                )
            )
            XCTAssertTrue(result.addedBlock)
        }

        let genesisHash = try BlockHeader(node: genesis).rawCID
        let firstHash = try BlockHeader(node: first).rawCID
        let secondHash = try BlockHeader(node: second).rawCID
        let descendantHash = try BlockHeader(node: descendant).rawCID
        let expectedHashes = Set([genesisHash, firstHash, secondHash, descendantHash])
        let rootValue = chain.getConsensusBlock(hash: genesisHash)
        let branchValue = chain.getConsensusBlock(hash: secondHash)
        let root = try XCTUnwrap(rootValue)
        let branch = try XCTUnwrap(branchValue)

        for hash in expectedHashes {
            let contains = chain.contains(blockHash: hash)
            XCTAssertTrue(contains)
        }
        XCTAssertEqual(Set(root.childHashes), [firstHash, secondHash])
        XCTAssertEqual(branch.childHashes, [descendantHash])

        let restored = try ChainTree.restoreWithoutContext(replaying: [
            testAdmissionBatch(for: genesis),
            testAdmissionBatch(for: first),
            testAdmissionBatch(for: second),
            testAdmissionBatch(for: descendant),
        ])
        let originalRootWork = chain.subtreeWeight(forHash: genesisHash)
        let restoredRootWork = restored.subtreeWeight(forHash: genesisHash)
        let originalTip = chain.canonicalTip
        let restoredTip = restored.canonicalTip

        for hash in expectedHashes {
            let contains = restored.contains(blockHash: hash)
            XCTAssertTrue(contains)
        }
        XCTAssertEqual(restoredTip, originalTip)
        XCTAssertEqual(restoredRootWork, originalRootWork)
        for hash in expectedHashes {
            let value = restored.getConsensusBlock(hash: hash)
            let meta = try XCTUnwrap(value)
            XCTAssertFalse(meta.workContributions.isEmpty)
        }
    }
}

private func consensusGraphSpec() -> ChainSpec {
    ChainSpec.test()
}
