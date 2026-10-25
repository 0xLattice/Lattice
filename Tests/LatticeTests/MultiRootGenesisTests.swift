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

/// Several genesis roots per child chain in one weighed graph (§9.9 genesis
/// admission, §9.4 across roots), with no parent authorization: a child
/// genesis weighs by its `ChildBlockProof` and executes like any child block.
/// Tested against the "Lattice architecture preserved" checklist: the weighed
/// graph with the executed set inside it, validity selects, continuity
/// against any executed parent state (every block, the genesis included),
/// hierarchical GHOST with grinds deduped, weighed-only blocks issue no facts,
/// and the root-exclusion rule.
final class MultiRootGenesisTests: XCTestCase {
    private let childContext = testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
    private let easy = AdmissionFixture.easy

    private func cid(_ block: Block) throws -> String {
        try BlockHeader(node: block).rawCID
    }

    private func work(_ seed: String, _ amount: UInt64 = 1) -> VerifiedWorkContribution {
        VerifiedWorkContribution(id: testCID("grind-\(seed)"), work: UInt256(amount))
    }

    /// Test evidence of `work` securing exactly `block`.
    private func evidence(_ block: Block, _ work: VerifiedWorkContribution) throws -> VerifiedChildEvidence {
        try TreeDriver.evidence(for: block, work: work)
    }

    /// A child tree bootstrapped from `genesis` through the one genesis path,
    /// weighed by `work`.
    private func childTree(
        _ genesis: Block,
        work: VerifiedWorkContribution,
        fetcher: StorableFetcher
    ) async throws -> (tree: ChainTree, facts: BlockImportBatch) {
        let bootstrapped = try await ChainTree.bootstrap(
            genesis: try BlockHeader(node: genesis), evidence: try evidence(genesis, work),
            fetcher: fetcher, context: childContext, parentFacts: try await testParentFacts(fetcher: fetcher)
        ).get()
        return (bootstrapped.tree, bootstrapped.facts)
    }

    /// Every block the tree holds that it executed.
    private func executedSet(_ tree: ChainTree, among blocks: [Block]) throws -> Set<String> {
        Set(try blocks.map(cid).filter { tree.hasExecutedAncestry(blockHash: $0) })
    }

    /// Grind `build` until its block meets its own target.
    private func mined(_ build: (UInt64) async throws -> Block) async throws -> Block {
        for nonce in UInt64(1)..<UInt64(4_000) {
            let block = try await build(nonce)
            if block.proofOfWorkHash() <= block.target { return block }
        }
        throw XCTSkip("no grind found")
    }

    // MARK: - Merge-mined genesis under a real hard-target Nexus carrier

    /// A child genesis committing a REAL parent state is merge-mined into a
    /// Nexus block whose hash meets a hard (non-max) target. It reaches the
    /// executed set with no parent record — only its proof and continuity —
    /// and a rival root carried with more work displaces it.
    func testAMergeMinedGenesisExecutesWithoutAParentRecordAndAHeavierRivalDisplacesIt() async throws {
        let fetcher = StorableFetcher()
        let nexusGenesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            transactions: [AdmissionFixture.unsignedStateChangingGenesisTransaction(
                key: "nexus-state", chainPath: [DEFAULT_ROOT_DIRECTORY]
            )],
            timestamp: 1_000, target: easy, fetcher: fetcher
        )
        XCTAssertNotEqual(nexusGenesis.postState.rawCID, LatticeState.emptyHeader.rawCID, "a real parent state")
        var nexus = try await TreeDriver.tree(genesis: nexusGenesis, context: testChainContext(genesis: nexusGenesis), fetcher: fetcher)

        func childGenesis(nonce: UInt64) async throws -> Block {
            let block = try await BlockBuilder.buildChildGenesis(
                spec: chainLocalSpec(), parentState: nexusGenesis.postState,
                timestamp: 1_500, target: easy, nonce: nonce, fetcher: fetcher
            )
            try await storeBuiltBlock(block, in: fetcher)
            return block
        }
        /// A real Nexus block, mined to `target`, carrying `child`.
        func carrier(of child: Block, target: UInt256, timestamp: Int64) async throws -> Block {
            try await mined { nonce in
                try await buildAndStoreBlock(
                    previous: nexusGenesis, children: ["Child": child],
                    timestamp: timestamp, target: target, nonce: nonce, fetcher: fetcher
                )
            }
        }
        func carriedEvidence(_ child: Block, by carrier: Block) async throws -> VerifiedChildEvidence {
            let proof = try await ChildBlockProof.generate(
                rootHeader: try BlockHeader(node: carrier), childDirectory: "Child", fetcher: fetcher
            )
            return try await proof.verifySecuringWork(child: child, chainPath: childContext.path).get()
        }

        let hard = easy / UInt256(4)
        let genesis = try await childGenesis(nonce: 1)
        let firstCarrier = try await carrier(of: genesis, target: hard, timestamp: 2_000)
        let carrierInsert = try await TreeDriver.insert(firstCarrier, into: &nexus, fetcher: fetcher)
        XCTAssertNotNil(carrierInsert.update, "a real Nexus block")
        let firstEvidence = try await carriedEvidence(genesis, by: firstCarrier)
        XCTAssertEqual(firstEvidence.contribution?.work, workForTarget(hard), "priced by the hard carrier")

        // Continuity is the only parent fact: the parent state is produced by
        // the Nexus executed set. No parent block records this genesis.
        let parentFacts = ParentLevelFacts(tree: nexus)
        let bootstrapped = try await ChainTree.bootstrap(
            genesis: try BlockHeader(node: genesis), evidence: firstEvidence,
            fetcher: fetcher, context: childContext, parentFacts: parentFacts
        ).get()
        var tree = (consume bootstrapped).tree
        XCTAssertTrue(tree.hasExecutedAncestry(blockHash: try cid(genesis)))
        XCTAssertEqual(tree.canonicalTip, try cid(genesis))

        // A rival root, carried by a harder carrier: more work, so it wins.
        let rival = try await childGenesis(nonce: 2)
        let harder = hard / UInt256(4)
        let rivalCarrier = try await carrier(of: rival, target: harder, timestamp: 2_100)
        let rivalEvidence = try await carriedEvidence(rival, by: rivalCarrier)
        XCTAssertNotNil(tree.insertGenesis(rival, spec: chainLocalSpec(), childIndex: testChildIndex(rival), evidence: rivalEvidence).update)
        XCTAssertEqual(tree.canonicalTip, try cid(rival), "the heavier root wins")
        XCTAssertFalse(tree.hasExecutedAncestry(blockHash: try cid(rival)), "weighed, not yet executed")
        let executed = try await TreeDriver.connect(try cid(rival), on: &tree, fetcher: fetcher, parentFacts: parentFacts)
        XCTAssertNotNil(executed.update)
        XCTAssertTrue(tree.hasExecutedAncestry(blockHash: try cid(rival)))
        XCTAssertTrue(tree.hasExecutedAncestry(blockHash: try cid(genesis)), "execution is never revoked")
    }

    // MARK: - Weighed graph; executed set inside it

    /// A rival root weighs from its proof — its descendants' work included —
    /// and is selected by weight, but executes only when connected.
    func testARivalRootWeighsByItsProofAndExecutesLikeAnyBlock() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeChildGenesis(fetcher: fetcher, nonce: 1)
        let rival = try await makeChildGenesis(fetcher: fetcher, nonce: 2)
        let rivalChild = try await AdmissionFixture.makeChild(of: rival, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        var (tree, _) = try await childTree(genesis, work: work("genesis"), fetcher: fetcher)

        XCTAssertEqual(tree.insertGenesis(rival, spec: chainLocalSpec(), childIndex: testChildIndex(rival)).failure,
                       .crossChainEvidenceRequired(.childProof(chainPath: childContext.path, childCID: try cid(rival))),
                       "a child root weighs only by a proof")
        let inserted = try XCTUnwrap(tree.insertGenesis(rival, spec: chainLocalSpec(), childIndex: testChildIndex(rival), evidence: try evidence(rival, work("rival"))).update)
        XCTAssertEqual(inserted.batches.map { $0.facts.count }, [2], "block and work")
        XCTAssertEqual(tree.subtreeWeight(forHash: try cid(rival)), WorkSum(UInt256(1)))
        let weighed = try await TreeDriver.insert(rivalChild, into: &tree, fetcher: fetcher, work: work("rival-child"))
        XCTAssertNotNil(weighed.update)
        XCTAssertEqual(tree.canonicalTip, try cid(rivalChild), "the heavier root wins, executed or not")

        let all = [genesis, rival, rivalChild]
        XCTAssertEqual(try executedSet(tree, among: all), [try cid(genesis)])
        let rivalExecuted = try await TreeDriver.connect(try cid(rival), on: &tree, fetcher: fetcher, parentFacts: try await testParentFacts(fetcher: fetcher))
        XCTAssertNotNil(rivalExecuted.update)
        XCTAssertTrue(tree.hasExecutedAncestry(blockHash: try cid(rival)))
        for hash in try executedSet(tree, among: all) {
            XCTAssertTrue(tree.contains(blockHash: hash), "executed ⊆ weighed")
        }
    }

    // MARK: - Validity selects; root exclusion

    /// An invalid root is excluded while another executed root stands: never
    /// executed, never selected, its subtree still weighs.
    func testAnInvalidRootIsExcludedAndStillWeighs() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeChildGenesis(fetcher: fetcher, nonce: 1)
        let template = try await makeChildGenesis(fetcher: fetcher, nonce: 3)
        let invalid = try await TreeDriver.forgedPostState(of: template, seed: "invalid-root", fetcher: fetcher)
        let below = try await AdmissionFixture.makeChild(of: invalid, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        var (tree, _) = try await childTree(genesis, work: work("genesis"), fetcher: fetcher)

        XCTAssertNotNil(tree.insertGenesis(invalid, spec: chainLocalSpec(), childIndex: testChildIndex(invalid), evidence: try evidence(invalid, work("invalid"))).update)
        let weighedBelow = try await TreeDriver.insert(below, into: &tree, fetcher: fetcher, work: work("below", 5))
        XCTAssertNotNil(weighedBelow.update)
        XCTAssertEqual(tree.canonicalTip, try cid(below))

        let verdict = try await TreeDriver.connect(try cid(invalid), on: &tree, fetcher: fetcher, parentFacts: try await testParentFacts(fetcher: fetcher))
        XCTAssertEqual(verdict.update?.excluded, true)
        XCTAssertTrue(tree.isExcludedRoot(try cid(invalid)))
        XCTAssertFalse(tree.hasExecutedAncestry(blockHash: try cid(invalid)))
        XCTAssertEqual(tree.subtreeWeight(forHash: try cid(invalid)), WorkSum(UInt256(6)), "work weighs")
        XCTAssertEqual(tree.canonicalTip, try cid(genesis), "validity selects")
    }

    /// The root-exclusion rule: a chain's only root is never excluded, and an
    /// executed root is never excluded at all (irrevocable), live or replayed.
    func testTheRootExclusionRuleHoldsAcrossRoots() async throws {
        let fetcher = StorableFetcher()
        let template = try await makeChildGenesis(fetcher: fetcher, nonce: 4)
        let invalid = try await TreeDriver.forgedPostState(of: template, seed: "lone-root", fetcher: fetcher)
        var lone = ChainTree.empty(context: childContext)
        XCTAssertNotNil(lone.insertGenesis(invalid, spec: chainLocalSpec(), childIndex: testChildIndex(invalid), evidence: try evidence(invalid, work("lone"))).update)
        let refused = try await TreeDriver.connect(try cid(invalid), on: &lone, fetcher: fetcher, parentFacts: try await testParentFacts(fetcher: fetcher))
        XCTAssertEqual(refused.failure, .notYetValid, "no executed root to stand on")
        XCTAssertFalse(lone.isExcludedRoot(try cid(invalid)))

        let genesis = try await makeChildGenesis(fetcher: fetcher, nonce: 1)
        var (tree, facts) = try await childTree(genesis, work: work("genesis"), fetcher: fetcher)
        let contradiction = tree.applyConnect(ConnectVerdict(
            blockHash: try cid(genesis), outcome: .invalid(isGenesis: true)
        ))
        XCTAssertEqual(contradiction.failure, .executedVerdictContradiction, "execution is never revoked")
        XCTAssertFalse(tree.isExcludedRoot(try cid(genesis)))
        // The reducer is the fail-closed twin: a durable contradiction does
        // not restore, whatever the order.
        let exclusion = BlockImportBatch.staged([.exclusion(ChainExclusionFact(blockHash: try cid(genesis)))])
        for order in [[facts, exclusion], [exclusion, facts]] {
            XCTAssertThrowsError(try ChainTree.restore(replaying: order, context: childContext))
        }
    }

    // MARK: - Continuity; weighed-only blocks issue no facts

    /// An unexecuted root's declared post-state is a claim: no continuity
    /// until it executes. A genesis whose parent state no executed parent
    /// block produced does not execute.
    func testAWeighedOnlyRootAttestsNothingAndAGenesisNeedsContinuity() async throws {
        let fetcher = StorableFetcher()
        let nexusGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let unproduced = try await BlockBuilder.buildChildGenesis(
            spec: chainLocalSpec(), parentState: LatticeStateHeader(rawCID: testCID("never-produced")),
            timestamp: 1_500, target: easy, nonce: 1, fetcher: fetcher
        )
        try await storeBuiltBlock(unproduced, in: fetcher)
        let nexus = try await TreeDriver.tree(genesis: nexusGenesis, context: testChainContext(genesis: nexusGenesis), fetcher: fetcher)
        let refused = await ChainTree.bootstrap(
            genesis: try BlockHeader(node: unproduced), evidence: try evidence(unproduced, work("unproduced")),
            fetcher: fetcher, context: childContext, parentFacts: ParentLevelFacts(tree: nexus)
        )
        guard case .failure(.crossChainEvidenceRequired(.parentStateContinuity)) = refused else {
            return XCTFail("a genesis proves its parent state like any child block, got \(refused)")
        }

        let keyed = try await makeChildGenesis(
            fetcher: fetcher, nonce: 7,
            transactions: [AdmissionFixture.unsignedStateChangingGenesisTransaction(
                key: "weighed-only", chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"]
            )]
        )
        let genesis = try await makeChildGenesis(fetcher: fetcher, nonce: 1)
        var (tree, _) = try await childTree(genesis, work: work("genesis"), fetcher: fetcher)
        let weighed = try XCTUnwrap(tree.insertGenesis(keyed, spec: chainLocalSpec(), childIndex: testChildIndex(keyed), evidence: try evidence(keyed, work("keyed"))).update)
        XCTAssertNil(weighed.materializedPostState, "a weighed-only root issues nothing")
        XCTAssertFalse(tree.executedSetProduced(stateCID: keyed.postState.rawCID))
        _ = try await TreeDriver.connect(try cid(keyed), on: &tree, fetcher: fetcher, parentFacts: try await testParentFacts(fetcher: fetcher))
        XCTAssertTrue(tree.executedSetProduced(stateCID: keyed.postState.rawCID), "continuity from any executed root")
    }

    // MARK: - Hierarchical GHOST, grinds deduped

    /// GHOST runs across roots on subtree weight; a grind has one location
    /// in the chain, so it cannot weigh under two roots.
    func testGhostAcrossRootsDedupesGrinds() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeChildGenesis(fetcher: fetcher, nonce: 1)
        let rival = try await makeChildGenesis(fetcher: fetcher, nonce: 2)
        let a = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let b = try await AdmissionFixture.makeChild(of: rival, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let shared = work("shared", 2)
        var (tree, _) = try await childTree(genesis, work: shared, fetcher: fetcher)
        XCTAssertEqual(tree.insertGenesis(rival, spec: chainLocalSpec(), childIndex: testChildIndex(rival), evidence: try evidence(rival, shared)).failure,
                       .providerMalformedEvidence, "one grind, one location per chain — roots included")
        XCTAssertNotNil(tree.insertGenesis(rival, spec: chainLocalSpec(), childIndex: testChildIndex(rival), evidence: try evidence(rival, work("rival"))).update)

        let weighedA = try await TreeDriver.insert(a, into: &tree, fetcher: fetcher, work: work("a", 1))
        XCTAssertNotNil(weighedA.update)
        let weighedB = try await TreeDriver.insert(b, into: &tree, fetcher: fetcher, work: work("b", 1))
        XCTAssertNotNil(weighedB.update)
        XCTAssertEqual(tree.canonicalTip, try cid(a), "3 against 2")

        XCTAssertNotNil(tree.addWork(work("b2", 3), to: try cid(b)).update)
        XCTAssertEqual(tree.canonicalTip, try cid(b))
        guard case .duplicate = tree.addWork(work("b2", 3), to: try cid(b)) else {
            return XCTFail("a repeated observation adds nothing")
        }
        XCTAssertEqual(tree.subtreeWeight(forHash: try cid(rival)), WorkSum(UInt256(5)))
    }

    // MARK: - Spec per root

    /// Each root's spec is held by its CID; a block under a spec mismatch is
    /// still scheduled by its ROOT's spec; restore holds whatever specs it is
    /// given, and a root without one only refuses headers beneath it.
    func testEveryRootHoldsItsOwnSpecAndSchedulesItsSubtree() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeChildGenesis(fetcher: fetcher, nonce: 1)
        let otherSpec = ChainSpec.test(premine: 7)
        let rival = try await makeChildGenesis(fetcher: fetcher, nonce: 2, spec: otherSpec)
        var (tree, bootstrapFacts) = try await childTree(genesis, work: work("genesis"), fetcher: fetcher)
        let rivalEvidence = try evidence(rival, work("rival"))
        XCTAssertEqual(tree.insertGenesis(rival, spec: chainLocalSpec(), childIndex: testChildIndex(rival), evidence: rivalEvidence).failure,
                       .providerMalformedEvidence, "a spec that is not the one the genesis names")
        XCTAssertEqual(tree.specs.count, 1, "a refused genesis holds no spec")
        let inserted = try XCTUnwrap(tree.insertGenesis(rival, spec: otherSpec, childIndex: testChildIndex(rival), evidence: rivalEvidence).update)
        XCTAssertEqual(tree.specs.count, 2)

        let valid = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let offSpec = try await storeBuiltBlock(Block(
            version: valid.version, parent: valid.parent, transactions: valid.transactions,
            target: valid.target, nextTarget: valid.nextTarget,
            spec: try VolumeImpl<ChainSpec>(node: otherSpec),
            parentState: valid.parentState, prevState: valid.prevState, postState: valid.postState,
            children: valid.children, height: valid.height, timestamp: valid.timestamp,
            rewardRecipient: valid.rewardRecipient, nonce: valid.nonce
        ), in: fetcher)
        let underOffSpec = try await AdmissionFixture.makeChild(of: offSpec, fetcher: fetcher, timestamp: 3_000, nonce: 1)
        let offSpecInsert = try await TreeDriver.insert(offSpec, into: &tree, fetcher: fetcher, work: work("off"))
        let excluded = try XCTUnwrap(offSpecInsert.update)
        XCTAssertTrue(excluded.excluded)
        let belowInsert = try await TreeDriver.insert(underOffSpec, into: &tree, fetcher: fetcher, work: work("under"))
        let below = try XCTUnwrap(belowInsert.update)
        XCTAssertFalse(below.excluded, "linked to its parent; never selected, as it sits under an exclusion")

        let rivalChild = try await AdmissionFixture.makeChild(of: rival, fetcher: fetcher, timestamp: 2_000, nonce: 2)
        let batches = [bootstrapFacts] + inserted.batches + excluded.batches + below.batches
        var partial = try ChainTree.restore(replaying: batches, context: childContext, specs: [chainLocalSpec()])
        XCTAssertEqual(partial.specs.count, 1)
        let underMissing = try await TreeDriver.insert(rivalChild, into: &partial, fetcher: fetcher, work: work("rc"))
        XCTAssertEqual(underMissing.failure, .notAcceptedAtCurrentChain, "a root without its spec refuses headers")
        let restored = try ChainTree.restore(
            replaying: batches, context: childContext, specs: [chainLocalSpec(), otherSpec]
        )
        XCTAssertEqual(restored.specs.keys.sorted(), tree.specs.keys.sorted())
    }

    // MARK: - Restore

    /// Two roots, one executed and one excluded, with work under both:
    /// restore rebuilds the same selection, executed set and exclusions from
    /// the facts in any order.
    func testTwoRootRestoreIsIndependentOfReplayOrder() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeChildGenesis(fetcher: fetcher, nonce: 1)
        let rival = try await makeChildGenesis(fetcher: fetcher, nonce: 2)
        let template = try await makeChildGenesis(fetcher: fetcher, nonce: 3)
        let invalid = try await TreeDriver.forgedPostState(of: template, seed: "restore", fetcher: fetcher)
        let a = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let b = try await AdmissionFixture.makeChild(of: rival, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let x = try await AdmissionFixture.makeChild(of: invalid, fetcher: fetcher, timestamp: 2_000, nonce: 1)

        var (tree, bootstrapFacts) = try await childTree(genesis, work: work("genesis"), fetcher: fetcher)
        var batches = [bootstrapFacts]
        func keep(_ admission: ChainTreeAdmission) throws {
            batches += try XCTUnwrap(admission.update, "\(admission)").batches
        }
        try keep(tree.insertGenesis(rival, spec: chainLocalSpec(), childIndex: testChildIndex(rival), evidence: try evidence(rival, work("rival"))))
        try keep(tree.insertGenesis(invalid, spec: chainLocalSpec(), childIndex: testChildIndex(invalid), evidence: try evidence(invalid, work("invalid"))))
        try keep(try await TreeDriver.insert(a, into: &tree, fetcher: fetcher, work: work("a", 1)))
        try keep(try await TreeDriver.insert(b, into: &tree, fetcher: fetcher, work: work("b", 2)))
        try keep(try await TreeDriver.insert(x, into: &tree, fetcher: fetcher, work: work("x", 9)))
        try keep(try await TreeDriver.connect(try cid(rival), on: &tree, fetcher: fetcher, parentFacts: try await testParentFacts(fetcher: fetcher)))
        try keep(try await TreeDriver.connect(try cid(invalid), on: &tree, fetcher: fetcher, parentFacts: try await testParentFacts(fetcher: fetcher)))
        try keep(try await TreeDriver.connect(try cid(b), on: &tree, fetcher: fetcher, parentFacts: try await testParentFacts(fetcher: fetcher)))
        XCTAssertEqual(tree.canonicalTip, try cid(b))

        let all = [genesis, rival, invalid, a, b, x]
        let expectedExecuted = try executedSet(tree, among: all)
        XCTAssertEqual(expectedExecuted, Set(try [genesis, rival, b].map(cid)))
        var rng = SystemRandomNumberGenerator()
        for order in [batches, batches.reversed()] + (0..<8).map({ _ in batches.shuffled(using: &rng) }) {
            let restored = try ChainTree.restore(
                replaying: order, context: childContext, specs: [chainLocalSpec()]
            )
            XCTAssertEqual(restored.canonicalTip, tree.canonicalTip)
            XCTAssertEqual(try executedSet(restored, among: all), expectedExecuted)
            XCTAssertTrue(restored.isExcludedRoot(try cid(invalid)))
            XCTAssertFalse(restored.isExcludedRoot(try cid(rival)))
        }
    }

    // MARK: - Review round 2

    /// H-1: a data dir from before the flag day — its root genesis is the old
    /// Nexus genesis — fails restore on every public path.
    func testARestoreOfAnotherNexusGenesisFails() async throws {
        let fetcher = StorableFetcher()
        let old = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let pinnedGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 2)
        let pinned = testChainContext(genesis: pinnedGenesis)
        let preFlagDay = [try testAdmissionBatch(for: old)]
        XCTAssertThrowsError(try ChainTree.restore(replaying: preFlagDay, context: pinned)) {
            XCTAssertEqual($0 as? ChainStateRestoreError, .unpinnedRootGenesis)
        }
        do {
            _ = try await ChainState.restore(replaying: preFlagDay, context: pinned)
            XCTFail("ChainState.restore must enforce the pin")
        } catch {
            XCTAssertEqual(error as? ChainStateRestoreError, .unpinnedRootGenesis)
        }
        do {
            _ = try await ChainLevel.restore(replaying: preFlagDay, context: pinned)
            XCTFail("ChainLevel.restore must enforce the pin")
        } catch {
            XCTAssertEqual(error as? ChainStateRestoreError, .unpinnedRootGenesis)
        }
        // The pin sits at the reducer: replay onto a tree on the root chain
        // refuses a foreign genesis too, empty or restored.
        var empty = ChainTree.empty(context: pinned)
        XCTAssertThrowsError(try empty.replay(preFlagDay[0])) {
            XCTAssertEqual($0 as? ChainStateRestoreError, .unpinnedRootGenesis)
        }
        XCTAssertFalse(empty.contains(blockHash: try cid(old)))
        var restored = try ChainTree.restore(replaying: [try testAdmissionBatch(for: pinnedGenesis)], context: pinned)
        XCTAssertThrowsError(try restored.replay(preFlagDay[0])) {
            XCTAssertEqual($0 as? ChainStateRestoreError, .unpinnedRootGenesis)
        }

        let level = try await ChainLevel.restore(
            replaying: [try testAdmissionBatch(for: pinnedGenesis)], context: pinned
        )
        let tip = await level.chain.canonicalTip
        XCTAssertEqual(tip, try cid(pinnedGenesis))

        // L-3: the executed pinned genesis re-executed is a duplicate.
        let again = try await level.admit(pinnedGenesis, mode: .execution, fetcher: fetcher)
        guard case .duplicate = again else {
            return XCTFail("the executed Nexus genesis re-executes as a duplicate, got \(again)")
        }
    }

    /// M-1: the actor path weighs a child genesis as `insertGenesis` does —
    /// its proof's work, its spec, the block fact alone — in `.header` mode,
    /// and in `.full` mode when execution reaches no verdict.
    func testTheActorPathWeighsAChildGenesisLikeInsertGenesis() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeChildGenesis(fetcher: fetcher, nonce: 1)
        let rival = try await makeChildGenesis(fetcher: fetcher, nonce: 2)
        let level = ChainLevel(chain: ChainState.fromGenesis(block: genesis), context: childContext)
        let package = try await carriedGenesisPackage(rival, fetcher: fetcher)
        let weighed = try await level.admit(rival, mode: .header, fetcher: fetcher, childPackage: package)
        guard case .accepted(let acceptance) = weighed else {
            return XCTFail("a carried child genesis weighs from its header, got \(weighed)")
        }
        XCTAssertEqual(acceptance.facts.facts.count, 2, "block and work, no validation")
        let executed = await level.chain.hasExecutedAncestry(blockHash: try cid(rival))
        XCTAssertFalse(executed)

        // `.full` with no continuity fact for a real parent state: weighed only.
        let parentGenesis = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher, timestamp: 500, nonce: 5,
            transactions: [AdmissionFixture.unsignedStateChangingGenesisTransaction(
                key: "parent-state", chainPath: [DEFAULT_ROOT_DIRECTORY]
            )]
        )
        let anchored = try await BlockBuilder.buildChildGenesis(
            spec: chainLocalSpec(), parentState: parentGenesis.postState,
            timestamp: 1_500, target: easy, nonce: 3, fetcher: fetcher
        )
        try await storeBuiltBlock(anchored, in: fetcher)
        let carrier = try await buildAndStoreBlock(
            previous: parentGenesis, children: ["Child": anchored],
            timestamp: 2_000, target: easy, nonce: 4, fetcher: fetcher
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier), childDirectory: "Child", fetcher: fetcher
        )
        let full = try await level.admit(anchored, fetcher: fetcher, childPackage: ChildValidationPackage(proof: proof))
        guard case .accepted(let fullAcceptance) = full else {
            return XCTFail("a child genesis with no verdict yet is weighed only, got \(full)")
        }
        XCTAssertEqual(fullAcceptance.facts.facts.count, 2, "no validation without a verdict")
    }

    /// M-2: a proven-invalid block is never executed — the reverse of an
    /// executed block never excluded — and a store holding both is a named
    /// fault.
    func testAValidVerdictOnAnExcludedBlockIsRefused() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeChildGenesis(fetcher: fetcher, nonce: 1)
        let block = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        var (tree, facts) = try await childTree(genesis, work: work("genesis"), fetcher: fetcher)
        let inserted = try await TreeDriver.insert(block, into: &tree, fetcher: fetcher, work: work("block"))
        XCTAssertNotNil(inserted.update)
        let job = try XCTUnwrap(tree.connectJob(for: try cid(block)))
        let verdict = await ChainTree.connect(job, fetcher: fetcher, parentFacts: try await testParentFacts(fetcher: fetcher))
        XCTAssertNil(verdict.retryFailure)
        XCTAssertFalse(verdict.provesInvalid)
        let exclusion = BlockImportBatch.staged([.exclusion(ChainExclusionFact(blockHash: try cid(block)))])
        _ = try tree.replay(exclusion)
        XCTAssertTrue(tree.isExcludedRoot(try cid(block)))
        XCTAssertEqual(tree.applyConnect(verdict).failure, .executedVerdictContradiction)
        XCTAssertFalse(tree.isExecuted(blockHash: try cid(block)))
        XCTAssertThrowsError(try tree.replay(BlockImportBatch.validation(blockHash: try cid(block)))) {
            XCTAssertEqual($0 as? ChainStateRestoreError, .executedVerdictContradiction)
        }
        let contradiction = [facts] + inserted.update!.batches + [BlockImportBatch.validation(blockHash: try cid(block)), exclusion]
        XCTAssertThrowsError(try ChainTree.restore(replaying: contradiction.reversed(), context: childContext)) {
            XCTAssertEqual($0 as? ChainStateRestoreError, .executedVerdictContradiction)
        }
    }

    /// L-1: a held genesis offered again with its spec repairs a tree
    /// restored without that spec.
    func testAHeldGenesisRepairsAMissingSpec() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeChildGenesis(fetcher: fetcher, nonce: 1)
        let (_, facts) = try await childTree(genesis, work: work("genesis"), fetcher: fetcher)
        var restored = try ChainTree.restore(replaying: [facts], context: childContext)
        XCTAssertTrue(restored.specs.isEmpty)
        _ = restored.insertGenesis(genesis, spec: chainLocalSpec(), childIndex: testChildIndex(genesis), evidence: try evidence(genesis, work("genesis")))
        XCTAssertEqual(restored.specs.count, 1)
    }

    /// L-2: a child genesis's continuity is the base case of parent
    /// continuity along its chain, so one committing the empty parent state
    /// is dropped — on both admission paths.
    func testAChildGenesisCommittingTheEmptyParentStateIsDropped() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeChildGenesis(fetcher: fetcher, nonce: 1)
        let unanchored = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 2)
        XCTAssertEqual(unanchored.parentState.rawCID, LatticeState.emptyHeader.rawCID)
        var (tree, _) = try await childTree(genesis, work: work("genesis"), fetcher: fetcher)
        XCTAssertEqual(
            tree.insertGenesis(unanchored, spec: chainLocalSpec(), childIndex: testChildIndex(unanchored), evidence: try evidence(unanchored, work("u"))).failure,
            .protocolInvalid
        )
        XCTAssertFalse(tree.contains(blockHash: try cid(unanchored)))

        let level = ChainLevel(chain: ChainState.fromGenesis(block: genesis), context: childContext)
        let carrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(), children: ["Child": unanchored],
            timestamp: 2_000, target: easy, nonce: 3, fetcher: fetcher
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier), childDirectory: "Child", fetcher: fetcher
        )
        for mode in [ImportMode.header, .full] {
            let refused = try await level.admit(
                unanchored, mode: mode, fetcher: fetcher, childPackage: ChildValidationPackage(proof: proof)
            )
            XCTAssertEqual(refused.failure, .protocolInvalid, "\(mode)")
        }
        let held = await level.chain.contains(blockHash: try cid(unanchored))
        XCTAssertFalse(held)
    }
}
