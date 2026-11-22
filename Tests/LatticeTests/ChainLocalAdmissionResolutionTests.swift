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

private struct MismatchingAdmissionFetcher: Fetcher {
    let data: Data

    func fetch(rawCid: String) async throws -> Data {
        data
    }
}

private struct UnknownFailingAdmissionFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw ChainLocalTestError.unexpectedFailure
    }
}

private struct ResolutionCase {
    let name: String
    let fetcher: any Fetcher
    let expectedFailure: BlockImportError
}

final class ChainLocalAdmissionResolutionTests: XCTestCase {
    func testResolutionFailuresHaveTypedOutcomes() async throws {
        let storage = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: storage, timestamp: 1_000)
        let candidate = try await AdmissionFixture.makeChild(of: genesis, fetcher: storage, timestamp: 2_000, nonce: 1)
        let unrelated = try await AdmissionFixture.makeGenesis(fetcher: storage, timestamp: 3_000, nonce: 2)
        let cases = [
            ResolutionCase(
                name: "unavailable provider evidence",
                fetcher: InMemoryContentSource([:]),
                expectedFailure: .unavailableEvidence
            ),
            ResolutionCase(
                name: "provider bytes for a different CID",
                fetcher: MismatchingAdmissionFetcher(data: try XCTUnwrap(unrelated.toData())),
                expectedFailure: .providerMalformedEvidence
            ),
            ResolutionCase(
                // Fail-safe: an unrecognized error is not a completed
                // deterministic check, so it classifies as retryable, never as
                // an excluding verdict (validated-tier invalidity-exclusion).
                name: "unknown failure classifies as retryable, not a verdict",
                fetcher: UnknownFailingAdmissionFetcher(),
                expectedFailure: .unavailableEvidence
            )
        ]
        // Only the CID: the block itself is what must resolve.
        let header = BlockHeader(rawCID: try BlockHeader(node: candidate).rawCID)

        for testCase in cases {
            var tree = try AdmissionFixture.makeChain(genesis: genesis)
            let result = try await tree.admit(header, fetcher: testCase.fetcher)
            XCTAssertEqual(result.failure, testCase.expectedFailure, testCase.name)
            XCTAssertFalse(tree.contains(blockHash: header.rawCID), testCase.name)
        }
    }

    func testInlineBlockHeaderCIDMismatchIsProviderMalformedEvidence() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let candidate = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        let unrelated = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 3_000,
            nonce: 2
        )
        let expectedCID = try BlockHeader(node: candidate).rawCID
        let forged = BlockHeader(
            rawCID: expectedCID,
            node: unrelated,
            encryptionInfo: nil
        )

        var tree = try AdmissionFixture.makeChain(genesis: genesis)
        let result = try await tree.admit(forged, fetcher: fetcher)

        XCTAssertEqual(result.failure, .providerMalformedEvidence)
    }

    /// A difficulty anchor not in hand is UNAVAILABLE evidence, never a
    /// verdict of invalid: the block may be perfectly good and its ancestry
    /// merely not here yet, so it has to stay retriable rather than be
    /// discarded.
    ///
    /// The anchor that matters is the chain's height-1 block — the schedule's
    /// anchor — not genesis, which the schedule never reads. So block 1 is
    /// missing from the tree, which holds block 2 restored as an orphan: the
    /// candidate's parent is held, its anchor is not, and nothing fetched
    /// can supply it.
    func testMissingAnchorAncestorIsUnavailableEvidence() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let blockOne = try await AdmissionFixture.makeChild(
            of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1
        )
        let blockTwo = try await AdmissionFixture.makeChild(
            of: blockOne, fetcher: fetcher, timestamp: 3_000, nonce: 2
        )
        let candidate = try await AdmissionFixture.makeChild(
            of: blockTwo, fetcher: fetcher, timestamp: 4_000, nonce: 3
        )
        let missingAnchor = DenyingFetcher(
            backing: fetcher,
            denied: [try BlockHeader(node: blockOne).rawCID]
        )
        var tree = try ChainTree.restore(
            replaying: [try testAdmissionBatch(for: genesis), try testAdmissionBatch(for: blockTwo)],
            context: testChainContext(genesis: genesis),
            specs: [chainLocalSpec()]
        )
        XCTAssertNil(tree.difficultyAnchor(forBlockHash: try BlockHeader(node: blockTwo).rawCID))

        let result = try await tree.admit(candidate, fetcher: missingAnchor)

        XCTAssertEqual(result.failure, .unavailableEvidence)
        XCTAssertFalse(tree.contains(blockHash: try BlockHeader(node: candidate).rawCID))
    }

    /// A header over a parent the tree does not hold is held, never a
    /// verdict: retried once the predecessor is admitted. Which predecessor
    /// to acquire is the node's to derive from the block's own `parent`.
    func testMissingImmediatePredecessorIsHeldUntilItConnects() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let parent = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        let candidate = try await AdmissionFixture.makeChild(
            of: parent,
            fetcher: fetcher,
            timestamp: 3_000,
            nonce: 2
        )
        let parentCID = try BlockHeader(node: parent).rawCID
        let candidateCID = try BlockHeader(node: candidate).rawCID
        let missingParent = DenyingFetcher(
            backing: fetcher,
            denied: [parentCID]
        )
        var tree = try AdmissionFixture.makeChain(genesis: genesis)

        let result = try await tree.admit(candidate, fetcher: missingParent)

        XCTAssertEqual(result.failure, .unavailableEvidence)
        XCTAssertEqual(candidate.parent?.rawCID, parentCID)
        XCTAssertFalse(tree.contains(blockHash: candidateCID))

        let parentAdmitted = try await tree.admit(parent, fetcher: fetcher)
        XCTAssertNotNil(parentAdmitted.update, "\(parentAdmitted)")
        let retried = try await tree.admit(candidate, mode: .header, fetcher: missingParent)
        XCTAssertNotNil(retried.update, "\(retried)")
    }

    func testMissingPolicyModuleIsUnavailableEvidence() async throws {
        let fetcher = StorableFetcher()
        let policy = try await storeWasmPolicy(
            requiringSubstring: "",
            scope: .transaction,
            fetcher: fetcher
        )
        let spec = chainLocalSpec(wasmPolicies: [policy])
        let genesis = try await buildAndStoreGenesis(
            spec: spec,
            timestamp: 1_000,
            target: AdmissionFixture.easy,
            fetcher: fetcher
        )
        let candidate = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 2_000,
            target: AdmissionFixture.easy,
            nonce: 1,
            fetcher: fetcher
        )
        let missingModule = DenyingFetcher(
            backing: fetcher,
            denied: [policy.moduleCID]
        )
        let candidateHash = try BlockHeader(node: candidate).rawCID
        var tree = try AdmissionFixture.makeChain(genesis: genesis, spec: spec)

        let result = try await tree.admit(candidate, fetcher: missingModule)

        XCTAssertEqual(result.failure, .unavailableEvidence)
        XCTAssertFalse(tree.isExcludedRoot(candidateHash), "availability excludes nothing")
        XCTAssertFalse(tree.isExecuted(blockHash: candidateHash))
    }

    func testProtocolInvalidCandidateIsRejected() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let valid = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let invalid = Block(
            version: valid.version,
            parent: valid.parent,
            transactions: valid.transactions,
            target: valid.target,
            nextTarget: valid.nextTarget,
            spec: valid.spec,
            parentState: valid.parentState,
            prevState: valid.prevState,
            postState: valid.postState,
            children: valid.children,
            height: valid.height + 1,
            timestamp: valid.timestamp,
            rewardRecipient: valid.rewardRecipient,
            nonce: valid.nonce
        )
        try await storeBuiltBlock(invalid, in: fetcher)

        var tree = try AdmissionFixture.makeChain(genesis: genesis)
        let result = try await tree.admit(invalid, fetcher: fetcher)

        XCTAssertEqual(result.failure, .protocolInvalid)
    }

    func testUnboundedHalfLifeNeitherTrapsNorOverWalks() async throws {
        // `halfLife` is an unbounded UInt64 from the spec — attacker-supplied
        // when the parent is disconnected. Nothing may size a walk or a
        // reservation by it (`Int(UInt64.max)` traps); the schedule saturates.
        let fetcher = StorableFetcher()
        let spec = ChainSpec.test(halfLife: UInt64.max)
        let genesis = try await buildAndStoreGenesis(
            spec: spec,
            timestamp: 1_000,
            target: AdmissionFixture.easy,
            fetcher: fetcher
        )
        let first = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let second = try await AdmissionFixture.makeChild(of: first, fetcher: fetcher, timestamp: 3_000, nonce: 2)
        var tree = try AdmissionFixture.makeChain(genesis: genesis, spec: spec)

        let full = try await tree.admit(first, fetcher: fetcher)
        XCTAssertNotNil(full.update, "full admission must apply, got \(full)")
        let weighed = try await tree.admit(second, mode: .header, fetcher: fetcher)
        XCTAssertNotNil(weighed.update, "weighed admission must apply, got \(weighed)")
    }

    func testSideCandidateAdmitsWithoutAncestorFetches() async throws {
        // Every frontier leaf and losing fork has an off-main-chain parent. A
        // side candidate is weighed from the held graph alone, so no candidate
        // pays a sequential fetcher walk for ancestors the node already holds.
        let full = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: full, timestamp: 1_000)
        let mainOne = try await AdmissionFixture.makeChild(of: genesis, fetcher: full, timestamp: 2_000, nonce: 1)
        let mainTwo = try await AdmissionFixture.makeChild(of: mainOne, fetcher: full, timestamp: 3_000, nonce: 2)
        let sideOne = try await AdmissionFixture.makeChild(of: genesis, fetcher: full, timestamp: 2_500, nonce: 3)
        let sideTwo = try await AdmissionFixture.makeChild(of: sideOne, fetcher: full, timestamp: 3_500, nonce: 4)
        let genesisHash = try BlockHeader(node: genesis).rawCID
        let sideOneHash = try BlockHeader(node: sideOne).rawCID

        var tree = try AdmissionFixture.makeChain(genesis: genesis)
        for block in [mainOne, mainTwo, sideOne] {
            let result = try await tree.admit(block, fetcher: full)
            XCTAssertNotNil(result.update, "fixture block must apply, got \(result)")
        }
        XCTAssertEqual(tree.canonicalTip, try BlockHeader(node: mainTwo).rawCID)
        XCTAssertNotEqual(tree.canonicalBlockHash(atHeight: 1), sideOneHash)

        // A fetcher that cannot serve any ancestor beyond the parent still
        // weighs the side candidate: linkage reads the held graph.
        let noAncestors = DenyingFetcher(backing: full, denied: [genesisHash])
        let result = try await tree.admit(sideTwo, mode: .header, fetcher: noAncestors)
        XCTAssertNotNil(result.update, "side candidate must weigh from the held graph, got \(result)")
    }

    func testNotYetAdmissibleCandidateIsDeferredByTypedOutcome() async throws {
        let fetcher = StorableFetcher()
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: now - 100_000)
        let future = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: now + 60_000,
            nonce: 1
        )

        var tree = try AdmissionFixture.makeChain(genesis: genesis)
        let result = try await tree.admit(future, fetcher: fetcher)

        XCTAssertEqual(result.failure, .notYetValid)
    }
}
