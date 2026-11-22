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
import cashew
import WAT

final class ConnectValidatedTierTests: XCTestCase {
    private func blockFact(_ update: ChainTreeUpdate) -> ChainBlockFact? {
        for batch in update.batches {
            for case .block(let fact) in batch.facts { return fact }
        }
        return nil
    }

    func testValidatedTierExecutesLikeEagerAndMaterializesState() async throws {
        // Validated tier (deferred execution): `connect` executes a block
        // already weighed and records the validity verdict. On a valid block
        // it does exactly what admitting header and execution together does —
        // runs the transition, materializes the post-state, emits the block
        // fact carrying the real `stateDiff` — the durable "validated" marker
        // that upgrades a weighed claim. Proven here against the eager
        // control on an identical, independent tree.
        let genesisTimestamp: Int64 = 1_000

        let eagerFetcher = StorableFetcher()
        let eagerGenesis = try await AdmissionFixture.makeGenesis(
            fetcher: eagerFetcher, timestamp: genesisTimestamp
        )
        let candidate = try await AdmissionFixture.makeChild(
            of: eagerGenesis, fetcher: eagerFetcher, timestamp: 2_000, nonce: 1
        )
        let genesisHash = try BlockHeader(node: eagerGenesis).rawCID
        let candidateHash = try BlockHeader(node: candidate).rawCID

        let validateFetcher = StorableFetcher()
        let validateGenesis = try await AdmissionFixture.makeGenesis(
            fetcher: validateFetcher, timestamp: genesisTimestamp
        )
        _ = try await AdmissionFixture.makeChild(
            of: validateGenesis, fetcher: validateFetcher, timestamp: 2_000, nonce: 1
        )
        XCTAssertEqual(try BlockHeader(node: validateGenesis).rawCID, genesisHash)

        var eagerTree = try AdmissionFixture.makeChain(genesis: eagerGenesis)
        let eager = try await eagerTree.admit(candidate, fetcher: eagerFetcher)

        var validateTree = try AdmissionFixture.makeChain(genesis: validateGenesis)
        let weighed = try await validateTree.admit(candidate, mode: .header, fetcher: validateFetcher)
        XCTAssertNotNil(weighed.update, "the header must weigh, got \(weighed)")
        let validated = try await validateTree.admit(
            candidate,
            mode: .execution,
            fetcher: validateFetcher
        )

        let eagerUpdate = try XCTUnwrap(eager.update, "eager admission must apply, got \(eager)")
        let validatedUpdate = try XCTUnwrap(validated.update, "execution must apply, got \(validated)")
        XCTAssertFalse(eagerUpdate.excluded)
        XCTAssertFalse(validatedUpdate.excluded)

        let eagerSnapshot = try XCTUnwrap(eagerTree.forkChoiceSnapshot(startingAt: genesisHash))
        let validatedSnapshot = try XCTUnwrap(validateTree.forkChoiceSnapshot(startingAt: genesisHash))
        XCTAssertEqual(validatedSnapshot, eagerSnapshot)
        XCTAssertEqual(validatedSnapshot.tipHash, candidateHash)

        // Unlike the weighed tier, validation executes: it materializes the
        // post-state exactly as eager does.
        XCTAssertNil(weighed.update?.materializedPostState)
        XCTAssertNotNil(validatedUpdate.materializedPostState)
        XCTAssertNotNil(eagerUpdate.materializedPostState)

        let eagerBlockFact = try XCTUnwrap(blockFact(eagerUpdate))
        let validatedBlockFact = try XCTUnwrap(blockFact(validatedUpdate))
        XCTAssertEqual(validatedBlockFact, eagerBlockFact)
    }

    /// Execution of an already-possessed block reads the map RECORDED for it
    /// rather than walking the trie again. Pinned with a recorded map that
    /// differs from the trie: a re-enumeration would carry the trie's map and
    /// be refused as a conflict, so only the recorded path validates.
    func testValidatedTierPromotesAPossessedBlockFromItsRecordedCommitments() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let candidate = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let candidateHash = try BlockHeader(node: candidate).rawCID
        var tree = try AdmissionFixture.makeChain(genesis: genesis)
        // Possess the block through a fact whose recorded map is not what the
        // (empty) trie would enumerate.
        let recordedMap = ["Alpha": testCID("recorded-alpha")]
        let seed = try testAdmissionBatch(for: candidate)
        let facts: [ChainFact] = seed.facts.map { fact in
            guard case .block(let b) = fact else { return fact }
            return .block(ChainBlockFact(
                blockHash: b.blockHash, parentBlockHash: b.parentBlockHash, blockHeight: b.blockHeight,
                postStateCID: b.postStateCID, prevStateCID: b.prevStateCID, specCID: b.specCID,
                target: b.target, nextTarget: b.nextTarget, timestamp: b.timestamp,
                stateDiff: b.stateDiff, childCommitments: recordedMap
            ))
        }
        _ = try tree.replay(BlockImportBatch(facts: facts))
        XCTAssertEqual(tree.recordedChildCommitments(of: candidateHash), recordedMap)
        XCTAssertFalse(tree.hasExecutedAncestry(blockHash: candidateHash), "possessed, not yet executed")

        let validated = try await tree.admit(candidate, mode: .execution, fetcher: fetcher)
        let update = try XCTUnwrap(validated.update, "executing a possessed block validates it, got \(validated)")
        XCTAssertFalse(update.excluded)
        XCTAssertEqual(blockFact(update)?.childCommitments, recordedMap, "the batch carries the recorded map")
        XCTAssertTrue(tree.hasExecutedAncestry(blockHash: candidateHash), "execution validated the block")
        XCTAssertEqual(
            tree.recordedChildCommitments(of: candidateHash), recordedMap,
            "the recorded map is what execution carried"
        )
    }

    /// The root chain's only genesis is its pinned one, already executed:
    /// executing it again re-states its validation and changes nothing.
    /// Nothing is excluded and the tip does not move.
    func testValidatedTierReExecutesTheNexusGenesisWithoutEffect() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        var tree = try AdmissionFixture.makeChain(genesis: genesis)
        let genesisHash = try BlockHeader(node: genesis).rawCID
        XCTAssertTrue(tree.isExecuted(blockHash: genesisHash))

        let result = try await tree.admit(genesis, mode: .execution, fetcher: fetcher)

        XCTAssertNil(result.failure, "the executed Nexus genesis re-executes as valid, got \(result)")
        XCTAssertNotEqual(result.update?.excluded, true)
        XCTAssertNil(result.update?.commit, "nothing moves")
        XCTAssertTrue(tree.excludedRootsForTesting.isEmpty)
        XCTAssertEqual(tree.canonicalTip, genesisHash, "the only root stays selectable")
    }
}
