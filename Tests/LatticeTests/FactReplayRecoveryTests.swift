import Foundation
import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import UInt256

final class FactReplayRecoveryTests: XCTestCase {
    func testFactReplayIsOrderIndependentAndRecomputesForkChoice() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: recoverySpec(),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )
        let light = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 2,
            target: UInt256.max,
            nonce: 1,
            fetcher: fetcher
        )
        let heavy = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 3,
            target: UInt256.max / UInt256(2),
            nonce: 2,
            fetcher: fetcher
        )
        let batches = try [genesis, light, heavy].map {
            try testAdmissionBatch(for: $0)
        }

        let forward = try ChainTree.restoreWithoutContext(replaying: batches)
        let reverse = try ChainTree.restoreWithoutContext(replaying: Array(batches.reversed()))
        let heavyCID = try BlockHeader(node: heavy).rawCID

        let forwardTip = forward.canonicalTip
        let reverseTip = reverse.canonicalTip
        let forwardWork = forward.getTipCumulativeWork()
        let reverseWork = reverse.getTipCumulativeWork()
        XCTAssertEqual(forwardTip, heavyCID)
        XCTAssertEqual(reverseTip, heavyCID)
        XCTAssertEqual(forwardWork, reverseWork)
    }

    func testFactReplayIsIdempotentAcrossEncodedDurableBatches() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: recoverySpec(),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )
        let block = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 2,
            target: UInt256.max,
            fetcher: fetcher
        )
        let batches = try [genesis, block].map {
            try testAdmissionBatch(for: $0)
        }
        let encoded = try JSONEncoder().encode(batches)
        let decoded = try JSONDecoder().decode([BlockImportBatch].self, from: encoded)

        let restored = try ChainTree.restoreWithoutContext(
            replaying: decoded + Array(decoded.reversed())
        )

        let restoredTip = restored.canonicalTip
        let revision = restored.currentRevision()
        XCTAssertEqual(restoredTip, try BlockHeader(node: block).rawCID)
        // The genesis insert and the block: two mutations, replayed once.
        XCTAssertEqual(revision, 2)
    }

    func testFactReplayRejectsMissingGenesisAndConflictingImmutableFacts() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: recoverySpec(),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )
        let block = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 2,
            target: UInt256.max,
            fetcher: fetcher
        )
        let genesisBatch = try testAdmissionBatch(for: genesis)
        let blockBatch = try testAdmissionBatch(for: block)

        await XCTAssertThrowsErrorAsync(
            try ChainTree.restoreWithoutContext(replaying: [blockBatch])
        )

        guard case .block(let fact) = blockBatch.facts[0] else {
            return XCTFail("expected block fact")
        }
        let conflicting = BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: fact.blockHash,
                parentBlockHash: fact.parentBlockHash,
                blockHeight: fact.blockHeight,
                postStateCID: fact.postStateCID,
                prevStateCID: fact.prevStateCID,
                specCID: fact.specCID,
                target: fact.target,
                nextTarget: fact.nextTarget,
                timestamp: fact.timestamp + 1,
                stateDiff: fact.stateDiff
            )),
            blockBatch.facts[1],
        ])
        await XCTAssertThrowsErrorAsync(
            try ChainTree.restoreWithoutContext(
                replaying: [genesisBatch, blockBatch, conflicting]
            )
        )
    }

    func testZeroWorkGenesisRejectedOnDurableReplay() async throws {
        // A zero-work (target 0) genesis is invalid — genesis must satisfy its own
        // target like every block — so the durable/replay path rejects it rather
        // than restoring it. This matches admission, which never stores one.
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: recoverySpec(),
            timestamp: 1,
            target: .zero,
            fetcher: fetcher
        )
        let batch = try testAdmissionBatch(for: genesis)
        // Sanity: the work fact really is zero-work, so this exercises the rule.
        if case .work(let fact) = batch.facts[1] {
            XCTAssertEqual(fact.contribution.work, .zero)
        } else {
            return XCTFail("expected a work fact")
        }

        do {
            _ = try ChainTree.restoreWithoutContext(replaying: [batch])
            XCTFail("a zero-work genesis must not restore")
        } catch {
            // expected: zero-work genesis is not a valid consensus graph
        }
    }

    func testRevisionFloorIsFinalAndStableAcrossRepeatedRecovery() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: recoverySpec(),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )
        let block = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 2,
            target: UInt256.max,
            fetcher: fetcher
        )
        let batches = try [genesis, block].map {
            try testAdmissionBatch(for: $0)
        }

        let first = try ChainTree.restoreWithoutContext(
            replaying: batches,
            revisionFloor: 100
        )
        let second = try ChainTree.restoreWithoutContext(
            replaying: batches,
            revisionFloor: first.currentRevision()
        )

        let firstRevision = first.currentRevision()
        let secondRevision = second.currentRevision()
        XCTAssertEqual(firstRevision, 100)
        XCTAssertEqual(secondRevision, 100)
    }

}

private func recoverySpec() -> ChainSpec {
    ChainSpec.test(
        initialReward: 1,
        halvingInterval: 1_000,
        halfLife: 10
    )
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {}
}
