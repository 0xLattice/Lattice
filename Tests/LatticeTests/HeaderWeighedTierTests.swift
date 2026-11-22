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

/// The weighed tier (§9.9 header admission): `insertRootHeader` /
/// `insertChildHeader` weigh a block from its header and verified work,
/// executing nothing; `connect` is the validated tier.
final class HeaderWeighedTierTests: XCTestCase {
    func testWeighedAdmissionMatchesEagerForkChoiceWithoutMaterializedState() async throws {
        // Deferred execution (weight-first-acquisition): a header admission
        // possesses the block and verifies its PoW, so its work enters fork
        // choice with exactly the eager path's weight — the consensus graph
        // never reads `stateDiff` — while it executes no state transition and
        // materializes no post-state. Header-then-execution is the control.
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

        // A second, independent tree seeded from an identical genesis so the
        // two fork-choice graphs are directly comparable. The same candidate
        // header is admitted into both.
        let weighedFetcher = StorableFetcher()
        let weighedGenesis = try await AdmissionFixture.makeGenesis(
            fetcher: weighedFetcher, timestamp: genesisTimestamp
        )
        _ = try await AdmissionFixture.makeChild(
            of: weighedGenesis, fetcher: weighedFetcher, timestamp: 2_000, nonce: 1
        )
        XCTAssertEqual(try BlockHeader(node: weighedGenesis).rawCID, genesisHash)

        var eagerTree = try AdmissionFixture.makeChain(genesis: eagerGenesis)
        let eager = try await eagerTree.admit(candidate, fetcher: eagerFetcher)

        var weighedTree = try AdmissionFixture.makeChain(genesis: weighedGenesis)
        let weighed = try await weighedTree.admit(
            candidate,
            mode: .header,
            fetcher: weighedFetcher
        )

        let eagerUpdate = try XCTUnwrap(eager.update, "eager admission must apply, got \(eager)")
        let weighedUpdate = try XCTUnwrap(weighed.update, "weighed admission must apply, got \(weighed)")

        // Fork choice is identical: the weighed block contributes the same work
        // to the same tip over the same main-chain set.
        let eagerSnapshot = try XCTUnwrap(eagerTree.forkChoiceSnapshot(startingAt: genesisHash))
        let weighedSnapshot = try XCTUnwrap(weighedTree.forkChoiceSnapshot(startingAt: genesisHash))
        XCTAssertEqual(weighedSnapshot, eagerSnapshot)
        XCTAssertEqual(weighedSnapshot.tipHash, candidateHash)

        // The discriminator between the tiers: the eager tier executes the
        // transition and materializes the post-state; the weighed tier executes
        // nothing and materializes nothing. (This candidate happens to carry no
        // state-changing transactions, so both diffs are empty — the observable
        // difference is that eager still computed and materialized the state.)
        XCTAssertNil(weighedUpdate.materializedPostState)
        XCTAssertNotNil(eagerUpdate.materializedPostState)
        XCTAssertFalse(weighedTree.isExecuted(blockHash: candidateHash))
        XCTAssertTrue(eagerTree.isExecuted(blockHash: candidateHash))

        // Both tiers record the same declared block fact — same block hash, the
        // same declared `postStateCID` claim, height, and target — differing
        // only in the (materialized) stateDiff. Header claim identical; only
        // execution is deferred.
        func blockFact(_ update: ChainTreeUpdate) -> ChainBlockFact? {
            for batch in update.batches {
                for case .block(let fact) in batch.facts { return fact }
            }
            return nil
        }
        let eagerBlockFact = try XCTUnwrap(blockFact(eagerUpdate))
        let weighedBlockFact = try XCTUnwrap(blockFact(weighedUpdate))
        XCTAssertEqual(weighedBlockFact.blockHash, eagerBlockFact.blockHash)
        XCTAssertEqual(weighedBlockFact.postStateCID, eagerBlockFact.postStateCID)
        XCTAssertEqual(weighedBlockFact.blockHeight, eagerBlockFact.blockHeight)
        XCTAssertEqual(weighedBlockFact.target, eagerBlockFact.target)
        XCTAssertEqual(weighedBlockFact.prevStateCID, eagerBlockFact.prevStateCID)
        XCTAssertEqual(weighedBlockFact.stateDiff, StateDiff.empty)
    }

    func testWeighedCompletesWithBodylessFetcherWhileExecutionWaits() async throws {
        // The bandwidth payoff, proven as a differential: a fetcher that serves
        // ONLY the block boundary (root + tries) and has NO tx bodies / states /
        // spec lets a header admission COMPLETE, while the same block's
        // execution gets no verdict — the weighed tier never touched tier-3,
        // and a missing body is availability: retried, never excluded.
        let full = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: full, timestamp: 1_000)
        let candidate = try await buildAndStoreBlock(
            previous: genesis,
            transactions: [AdmissionFixture.signedStateChangingGenesisTransaction(
                key: "bodyless-tx",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )],
            timestamp: 2_000,
            target: AdmissionFixture.easy,
            nonce: 1,
            fetcher: full
        )
        let header = try BlockHeader(node: candidate)

        // A fetcher holding ONLY block boundaries and the chain spec — what any
        // node holds after weighing the parent and bootstrapping its genesis —
        // and no body.
        let bodyless = StorableFetcher()
        try await header.storeBlockBoundary(fetcher: full, storer: bodyless)
        try await BlockHeader(node: genesis).storeBlockBoundary(fetcher: full, storer: bodyless)
        bodyless.store(
            rawCid: genesis.spec.rawCID,
            data: try await full.fetch(rawCid: genesis.spec.rawCID)
        )
        let unresolved = BlockHeader(rawCID: header.rawCID)

        // Header admission succeeds against the body-less fetcher.
        var weighedTree = try AdmissionFixture.makeChain(genesis: genesis)
        let weighed = try await weighedTree.admit(unresolved, mode: .header, fetcher: bodyless)
        XCTAssertNotNil(weighed.update, "weighed admission must apply with a body-less fetcher, got \(weighed)")

        // The SAME block admitted with its execution against the SAME body-less
        // fetcher gets no verdict: execution resolves tier-3, which the fetcher
        // cannot serve. The block keeps its weight and is not excluded.
        var eagerTree = try AdmissionFixture.makeChain(genesis: genesis)
        let eager = try await eagerTree.admit(unresolved, fetcher: bodyless)
        XCTAssertEqual(eager.failure, .unavailableEvidence)
        XCTAssertTrue(eagerTree.contains(blockHash: header.rawCID))
        XCTAssertFalse(eagerTree.isExcludedRoot(header.rawCID))
        XCTAssertFalse(eagerTree.isExecuted(blockHash: header.rawCID))
    }

    /// A PoW-valid (easy target) re-header of `valid` with one linkage field
    /// changed, stored so admission can resolve it.
    private func storeVariant(
        of valid: Block,
        fetcher: StorableFetcher,
        height: UInt64? = nil,
        nextTarget: UInt256? = nil,
        spec: VolumeImpl<ChainSpec>? = nil,
        prevState: LatticeStateHeader? = nil
    ) async throws -> Block {
        try await storeBuiltBlock(Block(
            version: valid.version,
            parent: valid.parent,
            transactions: valid.transactions,
            target: valid.target,
            nextTarget: nextTarget ?? valid.nextTarget,
            spec: spec ?? valid.spec,
            parentState: valid.parentState,
            prevState: prevState ?? valid.prevState,
            postState: valid.postState,
            children: valid.children,
            height: height ?? valid.height,
            timestamp: valid.timestamp,
            rewardRecipient: valid.rewardRecipient,
            nonce: valid.nonce
        ), in: fetcher)
    }

    func testWeighedAdmissionRejectsHeadersThatDoNotLinkToTheirParent() async throws {
        // Weighed = possess + structurally verify. Work alone binds nothing to
        // the parent: a peer can grind one trivial hash over the tip with any
        // height, prevState, spec or nextTarget. Each is a completed
        // deterministic check, decided from the header whether or not
        // execution follows (§9.9): a wrong height is dropped and a target off
        // the schedule is a proof-of-work failure — never admitted, never in
        // fork choice — while `prevState != parent.postState` and
        // `spec != parent.spec` are validity: weighed and excluded at once,
        // never selected.
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let genesisHash = try BlockHeader(node: genesis).rawCID
        let valid = try await buildAndStoreBlock(
            previous: genesis,
            transactions: [AdmissionFixture.signedStateChangingGenesisTransaction(
                key: "linkage-tx",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )],
            timestamp: 2_000,
            target: AdmissionFixture.easy,
            nonce: 1,
            fetcher: fetcher
        )
        XCTAssertNotEqual(valid.prevState.rawCID, valid.postState.rawCID)
        let foreignSpec = ChainSpec.test(halfLife: 6)

        let refused: [(String, Block, BlockImportError)] = [
            ("height tip+2", try await storeVariant(
                of: valid, fetcher: fetcher, height: valid.height + 1
            ), .protocolInvalid),
            ("height UInt64.max", try await storeVariant(
                of: valid, fetcher: fetcher, height: UInt64.max
            ), .protocolInvalid),
            ("nextTarget off schedule", try await storeVariant(
                of: valid, fetcher: fetcher, nextTarget: valid.nextTarget - UInt256(1)
            ), .proofOfWorkInvalid),
        ]
        let excluded: [(String, Block)] = [
            ("prevState != parent.postState", try await storeVariant(
                of: valid, fetcher: fetcher, prevState: valid.postState
            )),
            ("spec differs from parent", try await storeVariant(
                of: valid, fetcher: fetcher,
                spec: try VolumeImpl<ChainSpec>(node: foreignSpec)
            )),
        ]
        for mode in [TestAdmitMode.header, .full] {
            for (name, variant, failure) in refused {
                let header = try BlockHeader(node: variant)
                XCTAssertTrue(variant.validateProofOfWork(nexusHash: variant.proofOfWorkHash()), name)
                var tree = try AdmissionFixture.makeChain(genesis: genesis)
                let result = try await tree.admit(header, mode: mode, fetcher: fetcher)
                XCTAssertEqual(result.failure, failure, "\(name) \(mode)")
                XCTAssertFalse(tree.contains(blockHash: header.rawCID), "\(name) \(mode)")
            }
            for (name, variant) in excluded {
                let header = try BlockHeader(node: variant)
                XCTAssertTrue(variant.validateProofOfWork(nexusHash: variant.proofOfWorkHash()), name)
                var tree = try AdmissionFixture.makeChain(genesis: genesis)
                let result = try await tree.admit(header, mode: mode, fetcher: fetcher)
                let update = try XCTUnwrap(result.update, "\(name) \(mode): \(result)")
                XCTAssertTrue(update.excluded, "\(name) \(mode)")
                XCTAssertTrue(tree.contains(blockHash: header.rawCID), "\(name) \(mode): its work weighs")
                XCTAssertTrue(tree.isExcludedRoot(header.rawCID), "\(name) \(mode)")
                XCTAssertFalse(tree.isExecuted(blockHash: header.rawCID), "\(name) \(mode)")
                XCTAssertEqual(tree.canonicalTip, genesisHash, "\(name) \(mode): never selected")
            }
        }

        // The control: the correctly linked block is still weighed in without
        // being executed.
        var tree = try AdmissionFixture.makeChain(genesis: genesis)
        let accepted = try await tree.admit(valid, mode: .header, fetcher: fetcher)
        let update = try XCTUnwrap(accepted.update, "linked block must be weighed in, got \(accepted)")
        XCTAssertFalse(update.excluded)
        XCTAssertNil(update.materializedPostState)
    }

    func testWeighedAdmissionRejectsATargetEasierThanTheSchedule() async throws {
        // A target easier than the parent's schedule is trivially satisfied by
        // one hash: off the schedule, a proof-of-work failure whether or not
        // execution follows.
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            timestamp: 1_000,
            target: AdmissionFixture.easy / UInt256(2),
            fetcher: fetcher
        )
        let tooEasy = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 2_000,
            target: AdmissionFixture.easy,
            nonce: 1,
            fetcher: fetcher
        )
        XCTAssertGreaterThan(tooEasy.target, genesis.nextTarget)
        let header = try BlockHeader(node: tooEasy)

        for mode in [TestAdmitMode.header, .full] {
            var tree = try AdmissionFixture.makeChain(genesis: genesis)
            let result = try await tree.admit(header, mode: mode, fetcher: fetcher)
            XCTAssertEqual(result.failure, .proofOfWorkInvalid, "\(mode)")
            XCTAssertFalse(tree.contains(blockHash: header.rawCID), "\(mode)")
        }
    }

    func testWeighedNotYetAdmissibleCandidateIsDeferredNotRejected() async throws {
        // The timestamp rule is node-local and retriable: a header from the
        // near future is held, never excluded.
        let fetcher = StorableFetcher()
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: now - 100_000)
        let future = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: now + 60_000,
            nonce: 1
        )
        let header = try BlockHeader(node: future)

        var tree = try AdmissionFixture.makeChain(genesis: genesis)
        let result = try await tree.admit(header, mode: .header, fetcher: fetcher)

        XCTAssertEqual(result.failure, .notYetValid)
        XCTAssertFalse(tree.contains(blockHash: header.rawCID))
    }

    func testWeighedAdmissionNeverAcceptsAGenesis() async throws {
        // A genesis is only ever admitted as a root (`insertGenesis`); a
        // parentless header has nothing to link to.
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let rival = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let header = try BlockHeader(node: rival)

        var tree = try AdmissionFixture.makeChain(genesis: genesis)
        let result = try await tree.admit(header, mode: .header, fetcher: fetcher)

        XCTAssertEqual(result.failure, .protocolInvalid)
        XCTAssertFalse(tree.contains(blockHash: header.rawCID))
    }

    func testWeighedChildAdmissionRunsTheSameHeaderLinkage() async throws {
        // A child block's securing proof binds it to a parent grind, not to its
        // own predecessor: the weighed tier must run the same same-chain header
        // linkage for children as for roots.
        let fetcher = StorableFetcher()
        let parentGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let childGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let childGenesisHash = try BlockHeader(node: childGenesis).rawCID
        let childPath = [DEFAULT_ROOT_DIRECTORY, "Child"]
        let valid = try await buildAndStoreBlock(
            previous: childGenesis,
            transactions: [AdmissionFixture.signedStateChangingGenesisTransaction(
                key: "child-linkage-tx",
                chainPath: childPath
            )],
            parentChainBlock: parentGenesis,
            timestamp: 2_000,
            target: AdmissionFixture.easy,
            nonce: 1,
            fetcher: fetcher
        )
        XCTAssertNotEqual(valid.prevState.rawCID, valid.postState.rawCID)

        // Each variant is co-mined into its own carrier so its securing proof
        // verifies; only the same-chain linkage is wrong.
        func packaged(_ child: Block, nonce: UInt64) async throws -> TestChildPackage {
            let carrier = try await buildAndStoreGenesis(
                spec: chainLocalSpec(),
                children: ["Child": child],
                timestamp: 3_000,
                target: AdmissionFixture.easy,
                nonce: nonce,
                fetcher: fetcher
            )
            return TestChildPackage(proof: try await ChildBlockProof.generate(
                rootHeader: try BlockHeader(node: carrier),
                childDirectory: "Child",
                fetcher: fetcher
            ))
        }
        func childTree() throws -> ChainTree {
            try ChainTree.fromGenesis(
                block: childGenesis,
                context: testChainContext(path: childPath),
                spec: chainLocalSpec()
            )
        }

        let dropped = try await storeVariant(of: valid, fetcher: fetcher, height: valid.height + 1)
        var droppedTree = try childTree()
        let droppedResult = try await droppedTree.admit(
            try BlockHeader(node: dropped),
            mode: .header,
            fetcher: fetcher,
            child: try await packaged(dropped, nonce: 10)
        )
        XCTAssertEqual(droppedResult.failure, .protocolInvalid, "height tip+2")
        XCTAssertFalse(droppedTree.contains(blockHash: try BlockHeader(node: dropped).rawCID), "height tip+2")

        let unlinked = try await storeVariant(of: valid, fetcher: fetcher, prevState: valid.postState)
        let unlinkedHash = try BlockHeader(node: unlinked).rawCID
        var unlinkedTree = try childTree()
        let unlinkedResult = try await unlinkedTree.admit(
            try BlockHeader(node: unlinked),
            mode: .header,
            fetcher: fetcher,
            child: try await packaged(unlinked, nonce: 11)
        )
        let unlinkedUpdate = try XCTUnwrap(unlinkedResult.update, "prevState != parent.postState: \(unlinkedResult)")
        XCTAssertTrue(unlinkedUpdate.excluded, "prevState != parent.postState")
        XCTAssertTrue(unlinkedTree.isExcludedRoot(unlinkedHash))
        XCTAssertEqual(unlinkedTree.canonicalTip, childGenesisHash, "never selected")

        var tree = try childTree()
        let accepted = try await tree.admit(
            valid,
            mode: .header,
            fetcher: fetcher,
            child: try await packaged(valid, nonce: 20)
        )
        let update = try XCTUnwrap(accepted.update, "linked child must be weighed in, got \(accepted)")
        XCTAssertFalse(update.excluded)
        XCTAssertNil(update.materializedPostState)
    }

    func testInvalidHeaderOverAnUnheldParentIsHeldThenDropped() async throws {
        // A header's height is a claim about its parent: over a parent the
        // tree does not hold it decides nothing and is held (§9.9), and once
        // the parent is held the same header is dropped — no verdict before
        // its rule can be checked, and the verdict once it can.
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let unheld = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let valid = try await AdmissionFixture.makeChild(of: unheld, fetcher: fetcher, timestamp: 3_000, nonce: 2)
        let invalid = try await storeVariant(
            of: valid, fetcher: fetcher, height: valid.height + 1
        )
        let header = try BlockHeader(node: invalid)

        for mode in [TestAdmitMode.header, .full] {
            var tree = try AdmissionFixture.makeChain(genesis: genesis)
            let held = try await tree.admit(header, mode: mode, fetcher: fetcher)
            XCTAssertEqual(held.failure, .unavailableEvidence, "\(mode)")
            XCTAssertFalse(tree.contains(blockHash: header.rawCID), "\(mode)")

            let parent = try await tree.admit(unheld, mode: .header, fetcher: fetcher)
            XCTAssertNotNil(parent.update, "\(mode): \(parent)")
            let dropped = try await tree.admit(header, mode: mode, fetcher: fetcher)
            XCTAssertEqual(dropped.failure, .protocolInvalid, "\(mode)")
            XCTAssertFalse(tree.contains(blockHash: header.rawCID), "\(mode)")
        }
    }

    func testWeighedMissingParentIsUnavailable() async throws {
        // The parent is the one thing header linkage needs from the tree. Its
        // absence is availability, not a verdict: held and retried.
        let full = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: full, timestamp: 1_000)
        let parent = try await AdmissionFixture.makeChild(of: genesis, fetcher: full, timestamp: 2_000, nonce: 1)
        let candidate = try await AdmissionFixture.makeChild(of: parent, fetcher: full, timestamp: 3_000, nonce: 2)
        let header = try BlockHeader(node: candidate)

        // Candidate boundary + chain spec only; the parent root is absent.
        let parentless = StorableFetcher()
        try await header.storeBlockBoundary(fetcher: full, storer: parentless)
        parentless.store(
            rawCid: genesis.spec.rawCID,
            data: try await full.fetch(rawCid: genesis.spec.rawCID)
        )

        var tree = try AdmissionFixture.makeChain(genesis: genesis)
        let result = try await tree.admit(
            BlockHeader(rawCID: header.rawCID), mode: .header, fetcher: parentless
        )

        XCTAssertEqual(result.failure, .unavailableEvidence)
        XCTAssertFalse(tree.contains(blockHash: header.rawCID))
    }

    func testWeighedCandidateOverAnUnknownParentParksWithoutWalkingItsAncestry() async throws {
        // Genesis -> B1...B5 are all held, but the tree knows only genesis.
        // B5's parent is not in it, so admission holds B5 without walking B4,
        // B3, B2, B1 through the fetcher: each hop would be one network
        // request per out-of-order block, and none of those hops is checked
        // for work.
        let full = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: full, timestamp: 1_000)
        var blocks: [Block] = []
        var previous = genesis
        for i in 1...5 {
            let block = try await AdmissionFixture.makeChild(
                of: previous, fetcher: full, timestamp: 1_000 + Int64(i) * 1_000, nonce: UInt64(i)
            )
            blocks.append(block)
            previous = block
        }
        let cids = try blocks.map { try BlockHeader(node: $0).rawCID }
        let recording = RecordingFetcher(backing: full)

        var tree = try AdmissionFixture.makeChain(genesis: genesis)
        let result = try await tree.admit(
            BlockHeader(rawCID: cids[4]), mode: .header, fetcher: recording
        )

        XCTAssertEqual(result.failure, .unavailableEvidence)
        let fetched = await recording.fetched
        XCTAssertTrue(fetched.contains(cids[4]), "\(fetched)")
        XCTAssertTrue(
            Set(fetched).isDisjoint(with: cids.prefix(4) + [try BlockHeader(node: genesis).rawCID]),
            "nothing below B5 is fetched: \(fetched)"
        )
        XCTAssertLessThanOrEqual(fetched.count, 2, "B5's boundary only: \(fetched)")
    }

    func testForgedAncestryUnderATriviallyMinedCandidateParksAtBoundedCost() async throws {
        // A forged ancestry: blocks that carry no proof of work, each
        // committing `nextTarget = max`, so the candidate on top declares the
        // maximum target and its own PoW is free. Admitting it must cost the
        // same few fetches however long the forged chain is -- nothing walks
        // attacker-served links.
        func admitOverForgedAncestry(length: Int) async throws -> (ChainTreeAdmission, fetches: Int) {
            let full = StorableFetcher()
            let genesis = try await AdmissionFixture.makeGenesis(fetcher: full, timestamp: 1_000)
            var previous = genesis
            for i in 1...length {
                previous = try await buildAndStoreBlock(
                    previous: previous, timestamp: 1_000 + Int64(i) * 1_000,
                    target: UInt256(1), nextTarget: .max, nonce: UInt64(i), fetcher: full
                )
                XCTAssertFalse(previous.validateProofOfWork(nexusHash: previous.proofOfWorkHash()))
            }
            let candidate = try await buildAndStoreBlock(
                previous: previous, timestamp: previous.timestamp + 1_000,
                target: .max, nextTarget: .max, nonce: 0, fetcher: full
            )
            XCTAssertTrue(candidate.validateProofOfWork(nexusHash: candidate.proofOfWorkHash()))
            let recording = RecordingFetcher(backing: full)
            var tree = try AdmissionFixture.makeChain(genesis: genesis)
            let result = try await tree.admit(
                BlockHeader(rawCID: try BlockHeader(node: candidate).rawCID),
                mode: .header, fetcher: recording
            )
            return (result, await recording.fetched.count)
        }

        let short = try await admitOverForgedAncestry(length: 4)
        let long = try await admitOverForgedAncestry(length: 32)
        for (outcome, label) in [(short, "4"), (long, "32")] {
            XCTAssertEqual(outcome.0.failure, .unavailableEvidence, label)
            XCTAssertLessThanOrEqual(outcome.fetches, 3, label)
        }
        XCTAssertEqual(short.fetches, long.fetches, "the cost must not depend on the forged depth")
    }

    // MARK: - Liveness: a held header is admitted once its ancestry connects

    /// Builds genesis -> B1...B(count), all held in `fetcher`, with timestamps
    /// 1_000 apart, and the anchor every one of them must resolve to.
    private func heldChain(
        count: Int, fetcher: StorableFetcher
    ) async throws -> (genesis: Block, blocks: [Block], cids: [String], anchor: DifficultyAnchor) {
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        var blocks: [Block] = []
        var previous = genesis
        for i in 1...count {
            previous = try await AdmissionFixture.makeChild(
                of: previous, fetcher: fetcher, timestamp: 1_000 + Int64(i) * 1_000, nonce: UInt64(i)
            )
            blocks.append(previous)
        }
        let cids = try blocks.map { try BlockHeader(node: $0).rawCID }
        let anchor = DifficultyAnchor(
            blockHeight: 1, timestamp: blocks[0].timestamp, target: blocks[0].target
        )
        return (genesis, blocks, cids, anchor)
    }

    func testCandidateOverAHeightOneParentAnchorsOnIt() async throws {
        // B2 over a B1 the tree does not hold is held; once B1 is weighed, B2
        // is weighed over it and B1, its parent, is itself its anchor.
        let fetcher = StorableFetcher()
        let held = try await heldChain(count: 2, fetcher: fetcher)
        var tree = try AdmissionFixture.makeChain(genesis: held.genesis)

        let parked = try await tree.admit(held.blocks[1], mode: .header, fetcher: fetcher)
        XCTAssertEqual(parked.failure, .unavailableEvidence)
        XCTAssertFalse(tree.contains(blockHash: held.cids[1]))

        let blockOne = try await tree.admit(held.blocks[0], mode: .header, fetcher: fetcher)
        XCTAssertNotNil(blockOne.update, "B1 extends genesis, got \(blockOne)")
        let blockTwo = try await tree.admit(held.blocks[1], mode: .header, fetcher: fetcher)
        XCTAssertNotNil(blockTwo.update, "a height-1 parent anchors its child, got \(blockTwo)")
        XCTAssertEqual(tree.difficultyAnchor(forBlockHash: held.cids[1]), held.anchor)
    }

    func testParkedCandidateIsAdmittedOnceItsAncestryConnects() async throws {
        // B5 parks while only genesis is known. After B1...B4 are admitted in
        // order, re-admitting the same B5 must be accepted and inherit block
        // one's anchor. Parking is only safe if it is never permanent.
        let fetcher = StorableFetcher()
        let held = try await heldChain(count: 5, fetcher: fetcher)
        var tree = try AdmissionFixture.makeChain(genesis: held.genesis)

        let parked = try await tree.admit(held.blocks[4], mode: .header, fetcher: fetcher)
        XCTAssertEqual(parked.failure, .unavailableEvidence)

        for block in held.blocks.prefix(4) {
            let result = try await tree.admit(block, mode: .header, fetcher: fetcher)
            XCTAssertNotNil(result.update, "B\(block.height) extends the chain, got \(result)")
        }

        let readmitted = try await tree.admit(held.blocks[4], mode: .header, fetcher: fetcher)
        XCTAssertNotNil(readmitted.update, "B5 must be admitted once B4 connects, got \(readmitted)")
        XCTAssertEqual(
            tree.difficultyAnchor(forBlockHash: held.cids[4]), held.anchor,
            "B5 inherits block one's anchor"
        )
    }

    /// A tree on the root context holding `batches` (the genesis's first),
    /// as a node restores it.
    private func restored(_ batches: [BlockImportBatch], genesis: Block) throws -> ChainTree {
        try ChainTree.restore(
            replaying: batches, context: testChainContext(genesis: genesis), specs: [chainLocalSpec()]
        )
    }

    func testCandidateOverAHeldButDisconnectedParentIsAdmittedOnceThatParentConnects() async throws {
        // B2 is held without B1 (restored as an orphan), so it is DISCONNECTED
        // and carries no anchor. B3 over B2 cannot resolve one (B2 has none,
        // B1 is not in the graph) and is held. Once B1 is weighed, B2's anchor
        // is backfilled from it and B3 is accepted.
        let fetcher = StorableFetcher()
        let held = try await heldChain(count: 3, fetcher: fetcher)
        var tree = try restored(
            [try testAdmissionBatch(for: held.genesis), try testAdmissionBatch(for: held.blocks[1])],
            genesis: held.genesis
        )
        XCTAssertTrue(tree.contains(blockHash: held.cids[1]))
        XCTAssertNil(
            tree.difficultyAnchor(forBlockHash: held.cids[1]),
            "a disconnected B2 has no anchor to inherit"
        )

        let parked = try await tree.admit(held.blocks[2], mode: .header, fetcher: fetcher)
        XCTAssertEqual(parked.failure, .unavailableEvidence)
        XCTAssertFalse(tree.contains(blockHash: held.cids[2]))

        let blockOne = try await tree.admit(held.blocks[0], mode: .header, fetcher: fetcher)
        XCTAssertNotNil(blockOne.update, "B1 extends genesis, got \(blockOne)")

        let readmitted = try await tree.admit(held.blocks[2], mode: .header, fetcher: fetcher)
        XCTAssertNotNil(readmitted.update, "B3 must be admitted once B2 connects, got \(readmitted)")
        XCTAssertEqual(
            tree.difficultyAnchor(forBlockHash: held.cids[1]), held.anchor,
            "B2's anchor is backfilled from B1"
        )
        XCTAssertEqual(
            tree.difficultyAnchor(forBlockHash: held.cids[2]), held.anchor,
            "B3 inherits block one's anchor"
        )
    }

    func testRestoredOrphanResolvesItsAnchorOnceItsAncestryIsReplayed() async throws {
        // Restore replays facts in the order they were written, so an orphan
        // (B2 recorded before B1) comes back without an anchor. Replaying B1
        // after it connects the orphan: the anchor lookup resolves and B3 over
        // B2 is accepted. The control restore without B1 parks B3 on B2.
        let fetcher = StorableFetcher()
        let held = try await heldChain(count: 3, fetcher: fetcher)
        let genesisBatch = try testAdmissionBatch(for: held.genesis)
        let orphanBatch = try testAdmissionBatch(for: held.blocks[1])
        let connectingBatch = try testAdmissionBatch(for: held.blocks[0])

        var orphaned = try restored([genesisBatch, orphanBatch], genesis: held.genesis)
        XCTAssertNil(
            orphaned.difficultyAnchor(forBlockHash: held.cids[1]),
            "control: the replayed orphan has no anchor"
        )
        let parked = try await orphaned.admit(held.blocks[2], mode: .header, fetcher: fetcher)
        XCTAssertEqual(parked.failure, .unavailableEvidence)

        var connected = try restored([genesisBatch, orphanBatch, connectingBatch], genesis: held.genesis)
        XCTAssertEqual(
            connected.difficultyAnchor(forBlockHash: held.cids[1]), held.anchor,
            "the replayed B1 connects the orphan B2"
        )
        let accepted = try await connected.admit(held.blocks[2], mode: .header, fetcher: fetcher)
        XCTAssertNotNil(accepted.update, "B3 over the connected B2 is accepted, got \(accepted)")
    }

    func testWeighedAdmissionIssuesNoCrossChainFacts() async throws {
        // Deferred-execution safety: a weighed (not-yet-executed) block must
        // attest NO parent-state continuity, because a child consuming such a
        // fact would bind to unvalidated — possibly invalid or soon-reorged —
        // parent state. Its batch carries the block and its work and no
        // validation; only executing it makes its post-state attestable.
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let predecessor = try await buildAndStoreBlock(
            previous: genesis,
            transactions: [AdmissionFixture.signedStateChangingGenesisTransaction(
                key: "issuance-tx",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )],
            timestamp: 2_000,
            target: AdmissionFixture.easy,
            nonce: 1,
            fetcher: fetcher
        )
        XCTAssertNotEqual(predecessor.prevState.rawCID, predecessor.postState.rawCID)
        let predecessorHash = try BlockHeader(node: predecessor).rawCID
        var tree = try AdmissionFixture.makeChain(genesis: genesis)

        let weighed = try await tree.admit(predecessor, mode: .header, fetcher: fetcher)
        let update = try XCTUnwrap(weighed.update, "\(weighed)")
        let facts = update.batches.flatMap(\.facts)
        XCTAssertEqual(facts.count, 2, "block and work only: \(facts)")
        XCTAssertFalse(facts.contains {
            if case .validation = $0 { return true }
            return false
        })
        XCTAssertFalse(
            tree.executedSetAdvanced(from: genesis.postState.rawCID, to: predecessor.postState.rawCID),
            "a weighed block attests nothing"
        )

        let executed = try await tree.admit(predecessor, mode: .execution, fetcher: fetcher)
        XCTAssertNotNil(executed.update, "\(executed)")
        XCTAssertTrue(tree.isExecuted(blockHash: predecessorHash))
        XCTAssertTrue(
            tree.executedSetAdvanced(from: genesis.postState.rawCID, to: predecessor.postState.rawCID),
            "the executed block attests its post-state"
        )
    }
}

/// Records every CID fetched, in order, so a test can name exactly which
/// objects an admission read.
private actor RecordingFetcher: Fetcher {
    let backing: StorableFetcher
    private(set) var fetched: [String] = []

    init(backing: StorableFetcher) {
        self.backing = backing
    }

    func fetch(rawCid: String) async throws -> Data {
        fetched.append(rawCid)
        return try await backing.fetch(rawCid: rawCid)
    }
}
