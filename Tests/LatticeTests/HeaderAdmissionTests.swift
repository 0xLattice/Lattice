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

/// Header admission (spec §9.9): work weighs and validity selects, so a
/// header whose work verifies against a known parent is weighed, and only
/// three deterministic rules exclude it. Every other header outcome is a
/// proof-of-work failure (blame), a drop, or a hold.
final class HeaderAdmissionTests: XCTestCase {
    private let easy = AdmissionFixture.easy
    private let rootContext = testChainContext()
    private let childContext = testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])

    private func cid(_ block: Block) throws -> String {
        try BlockHeader(node: block).rawCID
    }

    private func kinds(_ batches: [BlockImportBatch]?) -> [[String]] {
        (batches ?? []).map { batch in
            batch.facts.map { fact in
                switch fact {
                case .block: "block"
                case .work: "work"
                case .validation: "validation"
                case .exclusion: "exclusion"
                }
            }
        }
    }

    /// `template` with some header fields replaced, stored.
    private func variant(
        of template: Block,
        spec: VolumeImpl<ChainSpec>? = nil,
        prevState: LatticeStateHeader? = nil,
        parentState: LatticeStateHeader? = nil,
        timestamp: Int64? = nil,
        height: UInt64? = nil,
        nextTarget: UInt256? = nil,
        nonce: UInt64? = nil,
        fetcher: StorableFetcher
    ) async throws -> Block {
        try await storeBuiltBlock(Block(
            version: template.version,
            parent: template.parent,
            transactions: template.transactions,
            target: template.target,
            nextTarget: nextTarget ?? template.nextTarget,
            spec: spec ?? template.spec,
            parentState: parentState ?? template.parentState,
            prevState: prevState ?? template.prevState,
            postState: template.postState,
            children: template.children,
            height: height ?? template.height,
            timestamp: timestamp ?? template.timestamp,
            rewardRecipient: template.rewardRecipient,
            nonce: nonce ?? template.nonce
        ), in: fetcher)
    }

    /// The two linkage failures, each a height-1 sibling of `valid`.
    private func linkageFailures(
        of valid: Block,
        genesis: Block,
        fetcher: StorableFetcher
    ) async throws -> [(rule: String, block: Block)] {
        let otherSpec = try VolumeImpl<ChainSpec>(node: ChainSpec.test(premine: 7))
        XCTAssertNotEqual(otherSpec.rawCID, genesis.spec.rawCID)
        return [
            ("spec", try await variant(of: valid, spec: otherSpec, fetcher: fetcher)),
            ("prevState", try await variant(
                of: valid, prevState: LatticeStateHeader(rawCID: testCID("not-the-parent-post")),
                fetcher: fetcher
            )),
        ]
    }

    // MARK: 1. Linkage failures weigh and exclude

    func testEachLinkageFailureIsWeighedExcludedAndWeighsInItsAncestors() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let valid = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        var tree = try await TreeDriver.tree(genesis: genesis, context: rootContext, fetcher: fetcher)
        let genesisCID = try cid(genesis)

        for (rule, block) in try await linkageFailures(of: valid, genesis: genesis, fetcher: fetcher) {
            let before = try XCTUnwrap(tree.subtreeWeight(forHash: genesisCID))
            let inserted = try await TreeDriver.insert(block, into: &tree, fetcher: fetcher)
            let update = try XCTUnwrap(inserted.update, "\(rule): \(inserted)")
            XCTAssertTrue(update.excluded, rule)
            XCTAssertEqual(kinds(update.batches), [["block", "work"], ["exclusion"]], rule)
            XCTAssertTrue(tree.isExcludedRoot(try cid(block)), rule)
            XCTAssertEqual(tree.subtreeWeight(forHash: genesisCID), before + WorkSum(UInt256(1)), "\(rule): its work counts in its ancestors")
            XCTAssertEqual(tree.canonicalTip, genesisCID, "\(rule): never selected")
            XCTAssertFalse(tree.hasExecutedAncestry(blockHash: try cid(block)), rule)
        }

        // A valid sibling is selected over two excluded ones.
        _ = try await TreeDriver.insert(valid, into: &tree, fetcher: fetcher)
        XCTAssertEqual(tree.canonicalTip, try cid(valid))
    }

    // MARK: 2. Descendants of an excluded block

    func testADescendantOfAnExcludedBlockWeighsAndNeverBecomesTheTip() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let valid = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let excluded = try await variant(
            of: valid, prevState: LatticeStateHeader(rawCID: testCID("forged-prev")), fetcher: fetcher
        )
        let x1 = try await AdmissionFixture.makeChild(of: excluded, fetcher: fetcher, timestamp: 3_000, nonce: 2)
        let x2 = try await AdmissionFixture.makeChild(of: x1, fetcher: fetcher, timestamp: 4_000, nonce: 3)
        var tree = try await TreeDriver.tree(genesis: genesis, context: rootContext, fetcher: fetcher)
        _ = try await TreeDriver.insert(valid, into: &tree, fetcher: fetcher)
        let excludedInsert = try await TreeDriver.insert(excluded, into: &tree, fetcher: fetcher)
        let excludedUpdate = try XCTUnwrap(excludedInsert.update)
        XCTAssertTrue(excludedUpdate.excluded)

        for block in [x1, x2] {
            // Linkage runs against the excluded parent's snapshot and passes.
            let inserted = try await TreeDriver.insert(block, into: &tree, fetcher: fetcher)
            let update = try XCTUnwrap(inserted.update)
            XCTAssertFalse(update.excluded)
            XCTAssertEqual(kinds(update.batches), [["block", "work"]])
        }
        XCTAssertEqual(tree.subtreeWeight(forHash: try cid(excluded)), WorkSum(UInt256(3)), "the excluded subtree weighs")
        XCTAssertEqual(tree.subtreeWeight(forHash: try cid(genesis)), WorkSum(UInt256(5)))
        XCTAssertEqual(tree.canonicalTip, try cid(valid), "the heavier excluded subtree is never selected")
        for block in [excluded, x1, x2] {
            XCTAssertFalse(tree.hasExecutedAncestry(blockHash: try cid(block)), "the executed set stays within the selectable graph")
        }
        // Execution never admits a block under an excluded root.
        _ = try await TreeDriver.connect(try cid(x1), on: &tree, fetcher: fetcher)
        XCTAssertFalse(tree.hasExecutedAncestry(blockHash: try cid(x1)))
        XCTAssertEqual(tree.canonicalTip, try cid(valid))
    }

    // MARK: 3. The root-exclusion rule

    /// Several roots exist only on a child chain: the root chain admits its
    /// configured genesis alone.
    func testAGenesisExclusionIsRefusedUnlessAnotherExecutedRootExists() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await makeChildGenesis(fetcher: fetcher)
        let rival = try await makeChildGenesis(fetcher: fetcher, nonce: 5)
        let spec = chainLocalSpec()
        let genesisCID = try cid(genesis)
        let rivalCID = try cid(rival)

        // The only root, weighed but not executed: its exclusion is refused.
        var tree = ChainTree.empty(context: childContext)
        let genesisEvidence = try await carriedGenesisEvidence(genesis, fetcher: fetcher)
        XCTAssertNotNil(tree.insertGenesis(genesis, spec: spec, childIndex: testChildIndex(genesis), evidence: genesisEvidence).update)
        let refused = tree.applyConnect(ConnectVerdict(blockHash: genesisCID, outcome: .invalid(isGenesis: true)))
        XCTAssertEqual(refused.failure, .notYetValid, "a chain's only root cannot be excluded")
        XCTAssertFalse(tree.isExcludedRoot(genesisCID))

        // A header never weighs a genesis: only `insertGenesis` admits a root.
        let rivalEvidence = try await carriedGenesisEvidence(rival, nonce: 1, fetcher: fetcher)
        let inputs = try await TreeDriver.headerInputs(rival, fetcher: fetcher)
        XCTAssertEqual(
            tree.insertChildHeader(rival, childIndex: inputs.childIndex, evidence: rivalEvidence).failure,
            .protocolInvalid
        )
        XCTAssertFalse(tree.contains(blockHash: rivalCID))

        // With another executed root standing, the exclusion is recorded.
        XCTAssertNotNil(tree.insertGenesis(rival, spec: spec, childIndex: testChildIndex(rival), evidence: rivalEvidence).update)
        let rivalExecuted = try await TreeDriver.connect(
            rivalCID, on: &tree, fetcher: fetcher, parentFacts: try await testParentFacts(fetcher: fetcher)
        )
        XCTAssertNotNil(rivalExecuted.update)
        let excluded = tree.applyConnect(ConnectVerdict(blockHash: genesisCID, outcome: .invalid(isGenesis: true)))
        XCTAssertEqual(excluded.update?.excluded, true)
        XCTAssertTrue(tree.isExcludedRoot(genesisCID))
        XCTAssertEqual(tree.canonicalTip, rivalCID)

        // Execution is never revoked: an invalid verdict for the executed
        // rival is a local fault, recorded nowhere.
        let contradiction = tree.applyConnect(ConnectVerdict(blockHash: rivalCID, outcome: .invalid(isGenesis: true)))
        XCTAssertEqual(contradiction.failure, .executedVerdictContradiction)
        XCTAssertFalse(tree.isExcludedRoot(rivalCID))
        XCTAssertTrue(tree.hasExecutedAncestry(blockHash: rivalCID))
    }

    /// The root chain admits only its configured genesis, on every path.
    func testTheRootChainAdmitsOnlyItsConfiguredGenesis() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let rival = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 5)
        let pinned = testChainContext(genesis: genesis)
        var tree = ChainTree.empty(context: pinned)
        XCTAssertEqual(tree.insertGenesis(rival, spec: chainLocalSpec(), childIndex: testChildIndex(rival)).failure, .protocolInvalid)
        XCTAssertNotNil(tree.insertGenesis(genesis, spec: chainLocalSpec(), childIndex: testChildIndex(genesis)).update)
        XCTAssertThrowsError(try ChainTree.restore(
            replaying: [try testAdmissionBatch(for: genesis), try testAdmissionBatch(for: rival)],
            context: pinned
        ), "restore refuses another root on the root chain")
        let job = ConnectJob(
            blockHash: try cid(rival),
            context: pinned,
            contribution: VerifiedWorkContribution(id: try cid(rival), work: 1),
            recordedChildCommitments: nil,
            anchors: AnchorSnapshot(anchors: [:])
        )
        let refused = await ChainTree.connect(job, fetcher: fetcher)
        XCTAssertEqual(refused.retryFailure, .protocolInvalid, "connect refuses another root genesis")
    }

    // MARK: 4. A future timestamp is held

    func testAFutureTimestampProducesNoFactAndIsAdmittedLater() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let block = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 5_000, nonce: 1)
        var tree = try await TreeDriver.tree(genesis: genesis, context: rootContext, fetcher: fetcher)
        let inputs = try await TreeDriver.headerInputs(block, fetcher: fetcher)

        let early = tree.insertRootHeader(
            block, childIndex: inputs.childIndex,
            validationContext: ValidationContext(nowMilliseconds: 4_999)
        )
        XCTAssertEqual(early.failure, .notYetValid)
        XCTAssertFalse(tree.contains(blockHash: try cid(block)), "no fact for a held header")

        let later = tree.insertRootHeader(
            block, childIndex: inputs.childIndex,
            validationContext: ValidationContext(nowMilliseconds: 5_000)
        )
        XCTAssertEqual(kinds(later.update?.batches), [["block", "work"]])
        XCTAssertEqual(tree.canonicalTip, try cid(block))
    }

    /// The schedule is checked before the clock: a future-dated header off
    /// the schedule is a proof-of-work failure (blame), never held, so a
    /// zero-cost header cannot make a node hold it. A future-dated header on
    /// the schedule is still held.
    func testAFutureTimestampOffTheScheduleIsAProofOfWorkFailureNotAHold() async throws {
        let fetcher = StorableFetcher()
        let early = ValidationContext(nowMilliseconds: 1_999)

        let hardGenesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(), timestamp: 1_000, target: easy / UInt256(2), nonce: 9, fetcher: fetcher
        )
        let maxTarget = try await buildAndStoreBlock(
            previous: hardGenesis, timestamp: 2_000, target: .max, nonce: 1, fetcher: fetcher
        )
        XCTAssertGreaterThan(maxTarget.target, hardGenesis.nextTarget)
        var hard = try await TreeDriver.tree(genesis: hardGenesis, context: rootContext, fetcher: fetcher)
        let maxInputs = try await TreeDriver.headerInputs(maxTarget, fetcher: fetcher)
        let tooEasy = hard.insertRootHeader(
            maxTarget, childIndex: maxInputs.childIndex, validationContext: early
        )
        XCTAssertEqual(tooEasy.failure, .proofOfWorkInvalid)
        XCTAssertFalse(hard.contains(blockHash: try cid(maxTarget)))

        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let valid = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let offSchedule = try await variant(of: valid, nextTarget: valid.nextTarget - UInt256(1), fetcher: fetcher)
        var tree = try await TreeDriver.tree(genesis: genesis, context: rootContext, fetcher: fetcher)
        let offInputs = try await TreeDriver.headerInputs(offSchedule, fetcher: fetcher)
        let offScheduleInsert = tree.insertRootHeader(
            offSchedule, childIndex: offInputs.childIndex, validationContext: early
        )
        XCTAssertEqual(offScheduleInsert.failure, .proofOfWorkInvalid)
        XCTAssertFalse(tree.contains(blockHash: try cid(offSchedule)))

        let validInputs = try await TreeDriver.headerInputs(valid, fetcher: fetcher)
        let held = tree.insertRootHeader(
            valid, childIndex: validInputs.childIndex, validationContext: early
        )
        XCTAssertEqual(held.failure, .notYetValid)
        XCTAssertFalse(tree.contains(blockHash: try cid(valid)), "no fact for a held header")
    }

    // MARK: 5. A structural fault is dropped

    func testAWrongHeightProducesNoFactAndRestoreMatches() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let valid = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let wrongHeight = try await variant(of: valid, height: 2, fetcher: fetcher)
        var tree = try await TreeDriver.tree(genesis: genesis, context: rootContext, fetcher: fetcher)
        var emitted = [try testAdmissionBatch(for: genesis)]

        let dropped = try await TreeDriver.insert(wrongHeight, into: &tree, fetcher: fetcher)
        XCTAssertEqual(dropped.failure, .protocolInvalid, "dropped without blame")
        XCTAssertFalse(tree.contains(blockHash: try cid(wrongHeight)))
        let inserted = try await TreeDriver.insert(valid, into: &tree, fetcher: fetcher)
        emitted += try XCTUnwrap(inserted.update).batches

        let restored = try ChainTree.restore(replaying: emitted.reversed(), context: testChainContext(genesis: genesis), specs: [chainLocalSpec()])
        XCTAssertEqual(restored.canonicalTip, tree.canonicalTip)
        XCTAssertFalse(restored.contains(blockHash: try cid(wrongHeight)))
    }

    // MARK: 6. Merged mining is unchanged

    /// A share whose hash misses Nexus's target but clears the child's: the
    /// child weighs it through its proof; the carrier is never admitted on
    /// Nexus, and inserting it there is a proof-of-work failure.
    func testAShareThatMissesNexusButClearsTheChildWeighsTheChildOnly() async throws {
        let fetcher = StorableFetcher()
        let nexusGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let childGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        // The child commits the carrier's entering state (`parentState ==
        // carrier.prevState`), which any height-1 Nexus block enters from.
        let nexusSibling = try await AdmissionFixture.makeChild(of: nexusGenesis, fetcher: fetcher, timestamp: 2_000, nonce: 7)
        let childBlock = try await AdmissionFixture.makeChild(
            of: childGenesis, fetcher: fetcher, timestamp: 2_000, nonce: 1, parentChainBlock: nexusSibling
        )
        let hardTarget = UInt256(1)
        let carrier = try await buildAndStoreBlock(
            previous: nexusGenesis, children: ["Child": childBlock],
            timestamp: 3_000, target: hardTarget, nonce: 2, fetcher: fetcher
        )
        XCTAssertGreaterThan(carrier.proofOfWorkHash(), hardTarget, "the share misses Nexus")

        var nexus = try await TreeDriver.tree(genesis: nexusGenesis, context: rootContext, fetcher: fetcher)
        let carrierInputs = try await TreeDriver.headerInputs(carrier, fetcher: fetcher)
        XCTAssertEqual(nexus.insertRootHeader(carrier, childIndex: carrierInputs.childIndex).failure, .proofOfWorkInvalid)
        XCTAssertFalse(nexus.contains(blockHash: try cid(carrier)), "the carrier is never admitted on Nexus")

        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier), childDirectory: "Child", fetcher: fetcher
        )
        let evidence = try await proof.verifySecuringWork(child: childBlock, chainPath: childContext.path).get()
        XCTAssertNotNil(evidence.contribution, "the share clears the child's target")
        var child = try await TreeDriver.tree(genesis: childGenesis, context: childContext, fetcher: fetcher)
        let before = try XCTUnwrap(child.subtreeWeight(forHash: try cid(childGenesis)))
        let inserted = try await TreeDriver.insert(childBlock, into: &child, fetcher: fetcher, evidence: evidence)
        XCTAssertEqual(kinds(inserted.update?.batches), [["block", "work"]])
        XCTAssertEqual(child.canonicalTip, try cid(childBlock))
        XCTAssertGreaterThan(try XCTUnwrap(child.subtreeWeight(forHash: try cid(childGenesis))), before)
    }

    // MARK: 7. Order independence

    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func digest(_ tree: inout ChainTree, over blocks: [Block]) throws -> [String] {
        try blocks.map { block in
            let hash = try cid(block)
            return [
                hash,
                "\(tree.contains(blockHash: hash))",
                "\(tree.subtreeWeight(forHash: hash).map { "\($0)" } ?? "-")",
                "\(tree.isExcludedRoot(hash))",
            ].joined(separator: "|")
        } + ["tip=\(tree.canonicalTip)"]
    }

    func testRandomInsertOrdersIncludingInvalidHeadersReachOneTipAndDigest() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let a = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let a2 = try await AdmissionFixture.makeChild(of: a, fetcher: fetcher, timestamp: 3_000, nonce: 2)
        let b = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_100, nonce: 3)
        var headers = [a, a2, b]
        let failures = try await linkageFailures(of: a, genesis: genesis, fetcher: fetcher).map(\.block)
        headers += failures
        let onExcluded = try await AdmissionFixture.makeChild(of: failures[1], fetcher: fetcher, timestamp: 3_100, nonce: 4)
        let onExcluded2 = try await AdmissionFixture.makeChild(of: onExcluded, fetcher: fetcher, timestamp: 4_100, nonce: 5)
        headers += [onExcluded, onExcluded2]
        // Never weighed: a structural drop and headers off the schedule.
        headers.append(try await variant(of: a, height: 7, fetcher: fetcher))
        headers.append(try await variant(of: a, timestamp: genesis.timestamp, fetcher: fetcher))
        headers.append(try await variant(of: b, nextTarget: b.nextTarget - UInt256(1), fetcher: fetcher))

        var reference: [String]?
        var rng = SplitMix64(state: 0x1A77_1CE0)
        for _ in 0..<8 {
            var tree = try await TreeDriver.tree(genesis: genesis, context: rootContext, fetcher: fetcher)
            var emitted = [try testAdmissionBatch(for: genesis)]
            var pending = headers.shuffled(using: &rng)
            // Headers-first delivery: an unknown parent is retried later.
            while !pending.isEmpty {
                var retry: [Block] = []
                for block in pending {
                    let result = try await TreeDriver.insert(block, into: &tree, fetcher: fetcher)
                    if let update = result.update {
                        emitted += update.batches
                    } else if result.failure == .unavailableEvidence {
                        retry.append(block)
                    }
                }
                XCTAssertLessThan(retry.count, pending.count, "every round admits something")
                if retry.count == pending.count { break }
                pending = retry
            }
            let live = try digest(&tree, over: [genesis] + headers)
            var restored = try ChainTree.restore(
                replaying: emitted.shuffled(using: &rng), context: testChainContext(genesis: genesis), specs: [chainLocalSpec()]
            )
            XCTAssertEqual(try digest(&restored, over: [genesis] + headers), live, "restore reaches the same digest")
            if let reference {
                XCTAssertEqual(live, reference, "insert order decides nothing")
            } else {
                reference = live
            }
        }
        XCTAssertEqual(reference?.last, "tip=\(try cid(a2))")
    }

    // MARK: 8. Run attribution stays monotone

    func testRunAttributionStaysMonotoneAsExcludedHeadersArrive() async throws {
        let fetcher = StorableFetcher()
        let parentGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let childGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let childBlock = try await AdmissionFixture.makeChild(of: childGenesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let committer = try await buildAndStoreBlock(
            previous: parentGenesis, children: ["Child": childBlock],
            timestamp: 2_000, target: easy, nonce: 1, fetcher: fetcher
        )
        let r1 = try await AdmissionFixture.makeChild(of: committer, fetcher: fetcher, timestamp: 3_000, nonce: 2)
        let r2 = try await AdmissionFixture.makeChild(of: r1, fetcher: fetcher, timestamp: 4_000, nonce: 3)
        let r2Excluded = try await variant(
            of: r2, prevState: LatticeStateHeader(rawCID: testCID("forged-run-prev")), fetcher: fetcher
        )
        let r3 = try await AdmissionFixture.makeChild(of: r2Excluded, fetcher: fetcher, timestamp: 5_000, nonce: 4)

        var parent = try await TreeDriver.tree(genesis: parentGenesis, context: rootContext, fetcher: fetcher)
        let committerCID = try cid(committer)
        var last = WorkSum.zero
        for block in [committer, r1, r2Excluded, r3, r2] {
            let inserted = try await TreeDriver.insert(block, into: &parent, fetcher: fetcher)
            XCTAssertNotNil(inserted.update)
            parent.serveRuns(for: "Child")
            let runWork = try XCTUnwrap(parent.runWork(of: committerCID, directory: "Child"))
            XCTAssertGreaterThanOrEqual(runWork, last, "run work never falls")
            last = runWork
        }
        XCTAssertTrue(parent.isExcludedRoot(try cid(r2Excluded)))
    }

    // MARK: 9. The target schedule is part of the proof of work

    func testATargetEasierThanTheScheduleIsAProofOfWorkFailure() async throws {
        let fetcher = StorableFetcher()
        let hardGenesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(), timestamp: 1_000, target: easy / UInt256(2), nonce: 9, fetcher: fetcher
        )
        let tooEasy = try await buildAndStoreBlock(
            previous: hardGenesis, timestamp: 2_000, target: easy, nonce: 1, fetcher: fetcher
        )
        XCTAssertGreaterThan(tooEasy.target, hardGenesis.nextTarget)
        var tree = try await TreeDriver.tree(genesis: hardGenesis, context: rootContext, fetcher: fetcher)
        let refused = try await TreeDriver.insert(tooEasy, into: &tree, fetcher: fetcher)
        XCTAssertEqual(refused.failure, .proofOfWorkInvalid)
        XCTAssertFalse(tree.contains(blockHash: try cid(tooEasy)))

        // A committed `nextTarget` off the ASERT schedule fails the same way.
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let valid = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let offSchedule = try await variant(of: valid, nextTarget: valid.nextTarget - UInt256(1), fetcher: fetcher)
        var other = try await TreeDriver.tree(genesis: genesis, context: rootContext, fetcher: fetcher)
        let offScheduleInsert = try await TreeDriver.insert(offSchedule, into: &other, fetcher: fetcher)
        XCTAssertEqual(offScheduleInsert.failure, .proofOfWorkInvalid)
        XCTAssertFalse(other.contains(blockHash: try cid(offSchedule)))
    }

    // MARK: - The chain's spec

    /// A root's spec is held by its CID: restore holds whatever specs it is
    /// given, and a root whose spec is not held refuses the headers beneath
    /// it — never silently scheduled by another spec.
    func testTheHeldSpecIsTheGenesisSpec() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let block = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let seed = try testAdmissionBatch(for: genesis)
        let wrong = ChainSpec.test(premine: 7)
        let pinned = testChainContext(genesis: genesis)
        let inputs = try await TreeDriver.headerInputs(block, fetcher: fetcher)
        for specs in [[wrong], []] {
            var deaf = try ChainTree.restore(replaying: [seed], context: pinned, specs: specs)
            XCTAssertEqual(deaf.insertRootHeader(block, childIndex: inputs.childIndex).failure, .notAcceptedAtCurrentChain)
        }
        XCTAssertThrowsError(try ChainTree.fromGenesis(block: genesis, context: rootContext, spec: wrong))
        var held = try ChainTree.restore(replaying: [seed], context: pinned, specs: [chainLocalSpec()])
        XCTAssertNotNil(held.insertRootHeader(block, childIndex: inputs.childIndex).update)
    }

    // MARK: - Round-1 review

    /// The attack decision M1 closes: height 1 anchors ASERT, so an old
    /// timestamp there — weighed and merely excluded — would saturate every
    /// descendant's target. An old timestamp is off the schedule at every
    /// height, and an excluded height-1 block still binds its descendants to
    /// the schedule.
    func testAnOldOrExcludedHeightOneBlockCannotMakeDescendantsCheap() async throws {
        let fetcher = StorableFetcher()
        let hard = easy / UInt256(2)
        let genesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(), timestamp: 1_000, target: hard, nonce: 9, fetcher: fetcher
        )
        var tree = try await TreeDriver.tree(genesis: genesis, context: rootContext, fetcher: fetcher)
        let template = try await buildAndStoreBlock(
            previous: genesis, timestamp: 2_000, target: hard, nonce: 1, fetcher: fetcher
        )
        func mined(_ build: (UInt64) async throws -> Block) async throws -> Block {
            for nonce in UInt64(100)..<UInt64(400) {
                let block = try await build(nonce)
                if block.proofOfWorkHash() <= block.target { return block }
            }
            throw XCTSkip("no grind found")
        }
        for oldTimestamp: Int64 in [0, genesis.timestamp] {
            let old = try await mined { try await self.variant(of: template, timestamp: oldTimestamp, nonce: $0, fetcher: fetcher) }
            let refused = try await TreeDriver.insert(old, into: &tree, fetcher: fetcher)
            XCTAssertEqual(refused.failure, .proofOfWorkInvalid, "timestamp \(oldTimestamp)")
            XCTAssertFalse(tree.contains(blockHash: try cid(old)))
            let descendant = try await buildAndStoreBlock(
                previous: old, timestamp: 3_000, target: easy, nonce: 1, fetcher: fetcher
            )
            let orphan = try await TreeDriver.insert(descendant, into: &tree, fetcher: fetcher)
            XCTAssertEqual(orphan.failure, .unavailableEvidence, "nothing to build on")
        }

        let excluded = try await mined {
            try await self.variant(
                of: template, prevState: LatticeStateHeader(rawCID: testCID("forged-anchor-prev")),
                nonce: $0, fetcher: fetcher
            )
        }
        let excludedInsert = try await TreeDriver.insert(excluded, into: &tree, fetcher: fetcher)
        XCTAssertEqual(excludedInsert.update?.excluded, true)
        let cheap = try await buildAndStoreBlock(
            previous: excluded, timestamp: 3_000, target: easy, nonce: 1, fetcher: fetcher
        )
        XCTAssertGreaterThan(cheap.target, excluded.nextTarget)
        let cheapInsert = try await TreeDriver.insert(cheap, into: &tree, fetcher: fetcher)
        XCTAssertEqual(cheapInsert.failure, .proofOfWorkInvalid)
        XCTAssertFalse(tree.contains(blockHash: try cid(cheap)))
    }

    /// Genesis carries its real launch time `T`, the only lower bound on
    /// block 1's anchor timestamp: a block 1 at or before `T` is a
    /// proof-of-work failure, one after it is weighed.
    func testABlockOneAtOrBeforeTheGenesisLaunchTimeIsAProofOfWorkFailure() async throws {
        let fetcher = StorableFetcher()
        let launch: Int64 = 1_700_000_000_000
        let genesis = try await GenesisCeremony.create(
            config: GenesisConfig(spec: chainLocalSpec(), timestamp: launch), fetcher: fetcher
        ).block
        try await storeBuiltBlock(genesis, in: fetcher)
        var tree = try await TreeDriver.tree(genesis: genesis, context: rootContext, fetcher: fetcher)
        for timestamp in [0, launch - 1, launch] {
            let early = try await buildAndStoreBlock(
                previous: genesis, timestamp: timestamp, target: easy, nonce: 1, fetcher: fetcher
            )
            let refused = try await TreeDriver.insert(early, into: &tree, fetcher: fetcher)
            XCTAssertEqual(refused.failure, .proofOfWorkInvalid, "timestamp \(timestamp)")
            XCTAssertFalse(tree.contains(blockHash: try cid(early)))
        }
        let onTime = try await buildAndStoreBlock(
            previous: genesis, timestamp: launch + 1, target: easy, nonce: 1, fetcher: fetcher
        )
        let weighed = try await TreeDriver.insert(onTime, into: &tree, fetcher: fetcher)
        XCTAssertEqual(kinds(weighed.update?.batches), [["block", "work"]])
    }

    /// Both batches of an excluded header land, or neither.
    func testAnExcludedHeaderIsAppliedAllOrNothing() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let valid = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let excluded = try await variant(
            of: valid, prevState: LatticeStateHeader(rawCID: testCID("forged-prev-capacity")), fetcher: fetcher
        )
        // Room for exactly one more mutation.
        var tree = try ChainTree.restore(
            replaying: [try testAdmissionBatch(for: genesis)], revisionFloor: UInt64.max - 1,
            context: testChainContext(genesis: genesis), specs: [chainLocalSpec()]
        )
        let refused = try await TreeDriver.insert(excluded, into: &tree, fetcher: fetcher)
        XCTAssertEqual(refused.failure, .revisionExhausted)
        XCTAssertFalse(tree.contains(blockHash: try cid(excluded)), "no half-applied header")
        let linked = try await TreeDriver.insert(valid, into: &tree, fetcher: fetcher)
        XCTAssertEqual(kinds(linked.update?.batches), [["block", "work"]], "one batch still fits")
    }

    /// The configured Nexus genesis that misses its own target is a
    /// proof-of-work failure at bootstrap, on both admission paths.
    func testAGenesisTargetMissIsAProofOfWorkFailureAtBootstrap() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(), timestamp: 1_000, target: UInt256(1), nonce: 3, fetcher: fetcher
        )
        XCTAssertGreaterThan(genesis.proofOfWorkHash(), UInt256(1))
        let header = try BlockHeader(node: genesis)
        let pinned = testChainContext(genesis: genesis)
        guard case .failure(let failure) = await ChainTree.bootstrap(
            genesis: header, fetcher: fetcher, context: pinned
        ) else {
            return XCTFail("a target miss bootstraps nothing")
        }
        XCTAssertEqual(failure, .proofOfWorkInvalid)
        do {
            _ = try await ChainLevel.bootstrap(
                context: pinned, genesisHeader: header, fetcher: fetcher,
                validationContentStorer: fetcher, materializedVolumeStorer: fetcher,
                stage: testAdmissionStage
            )
            XCTFail("a target miss bootstraps nothing")
        } catch let error as BlockImportError {
            XCTAssertEqual(error, .proofOfWorkInvalid)
        }
    }

    /// Nexus → Middle → Leaf, with one share: its hash misses Nexus's and
    /// Middle's targets and clears Leaf's. Only Leaf weighs it.
    private struct DepthTwo {
        let fetcher: StorableFetcher
        let nexusGenesis: Block
        let middleGenesis: Block
        let leafGenesis: Block
        let middle: Block
        let leaf: Block
        let root: Block
        let proof: ChildBlockProof
    }

    private let middleContext = testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Middle"])
    private let leafContext = testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Middle", "Leaf"])

    private func depthTwo(middleParentState: LatticeStateHeader? = nil) async throws -> DepthTwo {
        let fetcher = StorableFetcher()
        let hard = UInt256(1)
        let nexusGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let middleGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let leafGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 2)
        let middleTemplate = try await AdmissionFixture.makeChild(of: middleGenesis, fetcher: fetcher, timestamp: 2_000, nonce: 8)
        let leaf = try await AdmissionFixture.makeChild(
            of: leafGenesis, fetcher: fetcher, timestamp: 2_000, nonce: 1, parentChainBlock: middleTemplate
        )
        let nexusTemplate = try await AdmissionFixture.makeChild(of: nexusGenesis, fetcher: fetcher, timestamp: 2_000, nonce: 9)
        var middle = try await buildAndStoreBlock(
            previous: middleGenesis, children: ["Leaf": leaf], parentChainBlock: nexusTemplate,
            timestamp: 2_500, target: hard, nonce: 2, fetcher: fetcher
        )
        if let middleParentState {
            middle = try await variant(of: middle, parentState: middleParentState, fetcher: fetcher)
        }
        let root = try await buildAndStoreBlock(
            previous: nexusGenesis, children: ["Middle": middle],
            timestamp: 3_000, target: hard, nonce: 3, fetcher: fetcher
        )
        XCTAssertGreaterThan(root.proofOfWorkHash(), hard, "the share misses Nexus and Middle")
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: root), childDirectory: "Middle", fetcher: fetcher
        ).composing(hop: try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: middle), childDirectory: "Leaf", fetcher: fetcher
        ))
        return DepthTwo(
            fetcher: fetcher, nexusGenesis: nexusGenesis, middleGenesis: middleGenesis,
            leafGenesis: leafGenesis, middle: middle, leaf: leaf, root: root, proof: proof
        )
    }

    func testADepthTwoShareWeighsOnlyTheGrandchildItClears() async throws {
        let f = try await depthTwo()
        let evidence = try await f.proof.verifySecuringWork(child: f.leaf, chainPath: leafContext.path).get()
        var leafTree = try await TreeDriver.tree(genesis: f.leafGenesis, context: leafContext, fetcher: f.fetcher)
        let inserted = try await TreeDriver.insert(f.leaf, into: &leafTree, fetcher: f.fetcher, evidence: evidence)
        XCTAssertEqual(kinds(inserted.update?.batches), [["block", "work"]])
        XCTAssertEqual(leafTree.canonicalTip, try cid(f.leaf))

        let middleHop = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: f.root), childDirectory: "Middle", fetcher: f.fetcher
        )
        let middleEvidence = try await middleHop.verifySecuringWork(child: f.middle, chainPath: middleContext.path).get()
        XCTAssertNil(middleEvidence.contribution, "the share misses Middle")
        var middleTree = try await TreeDriver.tree(genesis: f.middleGenesis, context: middleContext, fetcher: f.fetcher)
        let middleInserted = try await TreeDriver.insert(f.middle, into: &middleTree, fetcher: f.fetcher, evidence: middleEvidence)
        XCTAssertEqual(middleInserted.failure, .proofOfWorkInvalid)
        XCTAssertFalse(middleTree.contains(blockHash: try cid(f.middle)))

        var nexus = try await TreeDriver.tree(genesis: f.nexusGenesis, context: rootContext, fetcher: f.fetcher)
        let rootInsert = try await TreeDriver.insert(f.root, into: &nexus, fetcher: f.fetcher)
        XCTAssertEqual(rootInsert.failure, .proofOfWorkInvalid)
        XCTAssertFalse(nexus.contains(blockHash: try cid(f.root)))
    }

    /// An intermediate carrier whose `parentState` is not its own carrier's
    /// `prevState` breaks the path structurally: a drop, not blame.
    func testAnIntermediateCarrierParentStateMismatchIsADropNotBlame() async throws {
        let f = try await depthTwo(middleParentState: LatticeStateHeader(rawCID: testCID("not-the-carrier-prev")))
        guard case .failure(let failure) = await f.proof.verifySecuringWork(
            child: f.leaf, chainPath: leafContext.path
        ) else {
            return XCTFail("a broken path secures nothing")
        }
        XCTAssertEqual(failure, .protocolInvalid)
        XCTAssertEqual(ChainTree.headerFailure(failure), .protocolInvalid, "dropped without blame")
        XCTAssertEqual(ChainTree.headerFailure(.malformedEvidence), .proofOfWorkInvalid, "a byte mismatch blames")
    }
}
