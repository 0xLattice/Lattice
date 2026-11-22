import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import UInt256

/// A parent chain attests state continuity so a child chain can validate
/// cross-chain withdrawals against a parent state. The attestation is only
/// meaningful if the attested state is one the parent chain actually PRODUCED
/// by executing its transition.
///
/// The weighed tier records a block's DECLARED `postState` without executing it
/// — `BlockImport` calls it "an unverified claim". A block that never
/// becomes canonical is never validated, so it is never excluded, and its
/// unverified claim stays in the graph permanently.
///
/// These tests pin the boundary: an unverified declared state MUST NOT be
/// attestable.
final class ParentStateAttestationTierTests: XCTestCase {
    private let easy = UInt256.max

    private func spec() -> ChainSpec {
        ChainSpec.test()
    }

    /// A genesis whose post-state is NOT `emptyHeader`.
    ///
    /// A transaction-free genesis produces the empty state, and anything
    /// anchored at it takes the `from == emptyHeader` short-circuit — so a test
    /// meaning to exercise the walk would quietly not.
    private func genesisWithState(
        fetcher: StorableFetcher, timestamp: Int64, nonce: UInt64, key: String
    ) async throws -> Block {
        let keyPair = CryptoUtils.generateKeyPair()
        let block = try await buildAndStoreGenesis(
            spec: spec(),
            transactions: [signedTestTransaction(
                TransactionBody(
                    accountActions: [],
                    actions: [Action(key: key, oldValue: nil, newValue: "v")],
                    depositActions: [], receiptActions: [],
                    withdrawalActions: [],
                    signers: [testAddress(publicKey: keyPair.publicKey)],
                    nonce: 0, chainPath: [DEFAULT_ROOT_DIRECTORY]
                ),
                by: keyPair
            )],
            timestamp: timestamp, target: easy, nonce: nonce, fetcher: fetcher
        )
        XCTAssertNotEqual(
            block.postState.rawCID, LatticeState.emptyHeader.rawCID,
            "fixture genesis must carry state or the walk is bypassed"
        )
        return block
    }

    /// A real, well-formed `LatticeState` that the chain under test never
    /// produced — built by executing a transition on an unrelated chain.
    private func stateFromAnUnrelatedChain(
        fetcher: StorableFetcher
    ) async throws -> LatticeStateHeader {
        let keyPair = CryptoUtils.generateKeyPair()
        let signer = testAddress(publicKey: keyPair.publicKey)
        let body = TransactionBody(
            accountActions: [],
            actions: [Action(key: "unrelated", oldValue: nil, newValue: "v")],
            depositActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [signer],
            nonce: 0,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        let unrelated = try await buildAndStoreGenesis(
            spec: spec(),
            transactions: [signedTestTransaction(body, by: keyPair)],
            timestamp: 9_000,
            target: easy,
            nonce: 99,
            fetcher: fetcher
        )
        return unrelated.postState
    }

    /// A sibling of `honest` that declares someone else's state as its own
    /// post-state. Every field the weighed tier checks — version, spec,
    /// `prevState == parent.postState`, height, timestamp, target schedule —
    /// is correct. Only `postState`, which the weighed tier does NOT check,
    /// is a lie.
    private func forgedSibling(
        of honest: Block,
        declaring forged: LatticeStateHeader,
        nonce: UInt64
    ) -> Block {
        Block(
            version: honest.version,
            parent: honest.parent,
            transactions: honest.transactions,
            target: honest.target,
            nextTarget: honest.nextTarget,
            spec: honest.spec,
            parentState: honest.parentState,
            prevState: honest.prevState,
            postState: forged,
            children: honest.children,
            height: honest.height,
            timestamp: honest.timestamp + 1,
            rewardRecipient: nil,
            nonce: nonce
        )
    }

    /// C2b: one weighed sibling makes an unproduced state attestable.
    ///
    /// The attacker mines a single block at current difficulty, declaring an
    /// arbitrary post-state. It is a sibling, so it never becomes canonical,
    /// so it is never validated, so it is never excluded — and the parent
    /// vouches for the declared state forever.
    func testWeighedDeclaredPostStateIsNotAttestable() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await genesisWithState(
            fetcher: fetcher, timestamp: 1_000, nonce: 0, key: "c2"
        )
        let honest = try await buildAndStoreBlock(
            previous: genesis, timestamp: 2_000, target: easy, nonce: 1,
            fetcher: fetcher
        )
        // The anchor is the honest sibling's prevState = the genesis post-state,
        // which is non-empty, so this exercises the walk.
        XCTAssertNotEqual(honest.prevState.rawCID, LatticeState.emptyHeader.rawCID)

        let forgedState = try await stateFromAnUnrelatedChain(fetcher: fetcher)
        let forged = forgedSibling(of: honest, declaring: forgedState, nonce: 7)
        _ = try await storeBuiltBlock(forged, in: fetcher)

        var chain = try AdmissionFixture.makeChain(genesis: genesis)
        let admitted = try await chain.admit(forged, mode: .header, fetcher: fetcher)
        guard let update = admitted.update, !update.excluded else {
            return XCTFail("weighed admission accepts a declared post-state; got \(admitted)")
        }

        // The anchor a child chain would hold: the honest sibling's prevState.
        let anchor = honest.prevState.rawCID

        let attested = chain.executedSetAdvanced(
            from: anchor,
            to: forgedState.rawCID
        )
        XCTAssertFalse(
            attested,
            """
            The parent attested a state it never produced. A child anchored at \
            \(anchor) could be moved to an attacker-authored parent state and \
            settle cross-chain withdrawals against its forged receiptState.
            """
        )
    }

    /// The upgrade path: executing a weighed block makes it attestable.
    ///
    /// Without this, the filter is not a narrowing but a wall — nothing is ever
    /// attestable, cross-chain settlement stops, and because the resulting
    /// failure is retriable it fails SILENTLY. A tier marker must therefore live
    /// somewhere both durable and mutable; folding it into a type whose equality
    /// is a graph-corruption predicate makes the upgrade throw instead.
    func testValidatingAWeighedBlockMakesItAttestable() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: spec(), timestamp: 1_000, target: easy, fetcher: fetcher
        )
        // A real transition: an identity transition would satisfy continuity via
        // the `from == to` short-circuit without ever consulting the filter.
        let keyPair = CryptoUtils.generateKeyPair()
        let block = try await buildAndStoreBlock(
            previous: genesis,
            transactions: [signedTestTransaction(
                TransactionBody(
                    accountActions: [], 
                    actions: [Action(key: "upgrade", oldValue: nil, newValue: "v")],
                    depositActions: [], receiptActions: [],
                    withdrawalActions: [],
                    signers: [testAddress(publicKey: keyPair.publicKey)],
                    nonce: 0, chainPath: [DEFAULT_ROOT_DIRECTORY]
                ),
                by: keyPair
            )],
            timestamp: 2_000, target: easy, nonce: 1, fetcher: fetcher
        )
        XCTAssertNotEqual(
            block.prevState.rawCID, block.postState.rawCID,
            "the block must change state or continuity short-circuits"
        )

        var chain = try AdmissionFixture.makeChain(genesis: genesis)

        let weighed = try await chain.admit(block, mode: .header, fetcher: fetcher)
        guard let update = weighed.update, !update.excluded else {
            return XCTFail("weighed admission must accept, got \(weighed)")
        }
        let beforeValidation = chain.executedSetAdvanced(
            from: block.prevState.rawCID, to: block.postState.rawCID
        )
        XCTAssertFalse(
            beforeValidation,
            "a weighed block's declared post-state is a claim, not a result"
        )

        // Executing it must promote the block, not throw.
        let validated = try await chain.admit(block, mode: .execution, fetcher: fetcher)
        if let failure = validated.failure {
            return XCTFail("validate tier must not reject an honest block: \(failure)")
        }
        XCTAssertEqual(validated.update?.excluded, false, "an honest block is not proven invalid")
        let afterValidation = chain.executedSetAdvanced(
            from: block.prevState.rawCID, to: block.postState.rawCID
        )
        XCTAssertTrue(
            afterValidation,
            """
            An executed block stayed unattestable. The filter is then a wall \
            rather than a narrowing: no child chain can admit block 1 and no \
            existing child can move its parentState, retriably and silently.
            """
        )
    }

    private func legacyBatch(
        _ block: String, parent: String?, height: UInt64,
        from: String, to: String, nonce: Int64
    ) -> BlockImportBatch {
        // The historical shape: a block fact and its work, and NO validation
        // fact — the record an upgraded store replays.
        BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: block, parentBlockHash: parent, blockHeight: height,
                postStateCID: to, prevStateCID: from,
                specCID: testCID("legacy-spec"),
                target: UInt256.max.toHexString(),
                nextTarget: UInt256.max.toHexString(),
                timestamp: nonce
            )),
            .work(ChainWorkFact(
                blockHash: block,
                contribution: VerifiedWorkContribution(
                    id: testCID("legacy-grind-\(nonce)"), work: 1
                )
            )),
        ])
    }

    /// Facts carrying no validation fact prove no execution, so they come
    /// back UNVERIFIED — fail-closed — a genesis included: a chain may hold
    /// several roots (§9.4), and restore executes none of them on its own.
    /// A root is executed only by its validation fact, which bootstrap
    /// always persists with it.
    func testReplayWithoutValidationFactsExecutesNothingNotEvenAGenesis() async throws {
        let empty = LatticeState.emptyHeader.rawCID
        let s1 = testCID("legacy-state-1")
        let s2 = testCID("legacy-state-2")
        let genesis = testCID("legacy-genesis")
        let one = testCID("legacy-one")

        let chain = try ChainTree.restoreWithoutContext(replaying: [
            legacyBatch(genesis, parent: nil, height: 0, from: empty, to: s1, nonce: 1),
            legacyBatch(one, parent: genesis, height: 1, from: s1, to: s2, nonce: 2),
        ])
        let genesisAttestable = chain.executedSetAdvanced(from: empty, to: s1)
        XCTAssertFalse(genesisAttestable, "an unexecuted root is not attestable")
        let replayedBlockAttestable = chain.executedSetAdvanced(from: s1, to: s2)
        XCTAssertFalse(replayedBlockAttestable)

        let validated = try ChainTree.restoreWithoutContext(replaying: [
            legacyBatch(genesis, parent: nil, height: 0, from: empty, to: s1, nonce: 1),
            legacyBatch(one, parent: genesis, height: 1, from: s1, to: s2, nonce: 2),
            .validation(blockHash: genesis),
        ])
        let executedGenesisAttestable = validated.executedSetAdvanced(from: empty, to: s1)
        XCTAssertTrue(executedGenesisAttestable, "its validation fact executes the root")
        let stillUnverified = validated.executedSetAdvanced(from: s1, to: s2)
        XCTAssertFalse(stillUnverified)
    }

    /// T1: executing a block must anchor descendants executed EARLIER.
    ///
    /// Possession and execution arrive independently, so a descendant can be
    /// executed before its ancestor. The frontier is therefore pushed downward
    /// until it stops moving — and without that cascade the descendant would
    /// stay unanchored forever while its whole ancestry is executed. Deleting
    /// the cascade previously left the entire suite green.
    func testValidationCascadesToDescendantsValidatedEarlier() async throws {
        let empty = LatticeState.emptyHeader.rawCID
        let g = testCID("cascade-genesis")
        let one = testCID("cascade-one")
        let two = testCID("cascade-two")
        let sg = testCID("cascade-state-g")
        let s1 = testCID("cascade-state-1")
        let s2 = testCID("cascade-state-2")

        func facts(
            _ block: String, parent: String?, height: UInt64,
            from: String, to: String, n: Int64, executed: Bool
        ) -> BlockImportBatch {
            var list: [ChainFact] = [
                .block(ChainBlockFact(
                    blockHash: block, parentBlockHash: parent,
                    blockHeight: height, postStateCID: to, prevStateCID: from,
                    specCID: testCID("cascade-spec"),
                    target: UInt256.max.toHexString(),
                    nextTarget: UInt256.max.toHexString(),
                    timestamp: n
                )),
                .work(ChainWorkFact(
                    blockHash: block,
                    contribution: VerifiedWorkContribution(
                        id: testCID("cascade-grind-\(n)"), work: 1
                    )
                )),
            ]
            if executed {
                list.append(.validation(ChainValidationFact(blockHash: block)))
            }
            return BlockImportBatch(facts: list)
        }

        // Block 2 is executed on arrival; block 1 is possessed but NOT executed
        // yet, so block 2 cannot be anchored through it.
        var chain = try ChainTree.restoreWithoutContext(replaying: [
            facts(g, parent: nil, height: 0, from: empty, to: sg, n: 1, executed: true),
            facts(one, parent: g, height: 1, from: sg, to: s1, n: 2, executed: false),
            facts(two, parent: one, height: 2, from: s1, to: s2, n: 3, executed: true),
        ])

        let beforeAncestor = chain.executedSetAdvanced(from: empty, to: s2)
        XCTAssertFalse(
            beforeAncestor,
            "a descendant must not anchor while an ancestor is still unexecuted"
        )

        // Executing the missing ancestor must carry the frontier past it and
        // pick up the descendant that was executed earlier.
        _ = try chain.applyStaged(BlockImportBatch(facts: [
            .validation(ChainValidationFact(blockHash: one)),
        ]))

        let afterAncestor = chain.executedSetAdvanced(from: empty, to: s2)
        XCTAssertTrue(
            afterAncestor,
            """
            Executing the ancestor did not carry the frontier to a descendant \
            executed earlier. Out-of-order arrival is the whole reason the \
            frontier is pushed rather than set.
            """
        )
    }

    private func executedBatch(
        _ block: String, parent: String?, height: UInt64,
        from: String, to: String, n: Int64
    ) -> BlockImportBatch {
        BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: block, parentBlockHash: parent, blockHeight: height,
                postStateCID: to, prevStateCID: from,
                specCID: testCID("excl-spec"),
                target: UInt256.max.toHexString(),
                nextTarget: UInt256.max.toHexString(),
                timestamp: n
            )),
            .work(ChainWorkFact(
                blockHash: block,
                contribution: VerifiedWorkContribution(
                    id: testCID("excl-grind-\(n)"), work: 1
                )
            )),
            .validation(ChainValidationFact(blockHash: block)),
        ])
    }

    /// A state stops being attestable once the block that produced it — or any
    /// ancestor — is proven invalid.
    ///
    /// The ordinary order is execute first, prove invalid later, so refusing to
    /// EXTEND the frontier through an already-excluded block is not enough: the
    /// subtree was anchored before the verdict arrived. Checked through both the
    /// live path and a wholesale restore of the same log, because the two build
    /// the frontier by different code and a node that disagrees with its own
    /// restart is a split waiting to happen.
    func testExclusionRemovesAttestabilityLiveAndAfterRestore() async throws {
        let empty = LatticeState.emptyHeader.rawCID
        let g = testCID("excl-genesis")
        let one = testCID("excl-one")
        let two = testCID("excl-two")
        let sg = testCID("excl-state-g")
        let s1 = testCID("excl-state-1")
        let s2 = testCID("excl-state-2")

        // Block 1 is weighed only; block 2 was executed ahead of it.
        let history = [
            executedBatch(g, parent: nil, height: 0, from: empty, to: sg, n: 1),
            legacyBatch(one, parent: g, height: 1, from: sg, to: s1, nonce: 2),
            executedBatch(two, parent: one, height: 2, from: s1, to: s2, n: 3),
        ]
        let exclusion = BlockImportBatch(facts: [
            .exclusion(ChainExclusionFact(blockHash: one)),
        ])

        var live = try ChainTree.restoreWithoutContext(replaying: history)
        _ = try live.applyStaged(exclusion)
        // Excluding block 1 keeps its executed descendant out of the frontier.
        let liveOne = live.executedSetAdvanced(from: empty, to: s1)
        let liveTwo = live.executedSetAdvanced(from: empty, to: s2)
        XCTAssertFalse(liveOne, "a proven-invalid block's state must not be attestable")
        XCTAssertFalse(liveTwo, "a descendant of a proven-invalid block must not be attestable either")

        // The same log restored wholesale must agree: the frontier is built by
        // different code on that path.
        let restored = try ChainTree.restoreWithoutContext(replaying: history + [exclusion])
        let restoredOne = restored.executedSetAdvanced(from: empty, to: s1)
        let restoredTwo = restored.executedSetAdvanced(from: empty, to: s2)
        XCTAssertEqual(liveOne, restoredOne, "live and restored must agree")
        XCTAssertEqual(liveTwo, restoredTwo, "live and restored must agree")

        // An EXECUTED block is never excluded: execution is never revoked.
        let executedExclusion = BlockImportBatch(facts: [
            .exclusion(ChainExclusionFact(blockHash: two)),
        ])
        do {
            _ = try live.applyStaged(executedExclusion)
            XCTFail("an executed block cannot be excluded")
        } catch {}
        do {
            _ = try ChainTree.restoreWithoutContext(replaying: history + [executedExclusion])
            XCTFail("a durable contradiction does not restore")
        } catch {}
    }

    /// A batch's validation fact must name that batch's own block.
    ///
    /// A batch is one block's durability unit. Admitting a validation for some
    /// other block would let one block's admission silently mark a different
    /// block executed — and execution is what gates attestation.
    func testValidationMustNameItsOwnBatchsBlock() async throws {
        let empty = LatticeState.emptyHeader.rawCID
        let g = testCID("naming-genesis")
        let other = testCID("naming-other")
        let sg = testCID("naming-state-g")

        let crossNamed = BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: g, parentBlockHash: nil, blockHeight: 0,
                postStateCID: sg, prevStateCID: empty,
                specCID: testCID("naming-spec"),
                target: UInt256.max.toHexString(),
                nextTarget: UInt256.max.toHexString(),
                timestamp: 1
            )),
            .work(ChainWorkFact(
                blockHash: g,
                contribution: VerifiedWorkContribution(
                    id: testCID("naming-grind"), work: 1
                )
            )),
            .validation(ChainValidationFact(blockHash: other)),
        ])

        do {
            _ = try ChainTree.restoreWithoutContext(replaying: [crossNamed])
            XCTFail("a validation naming another block must not be admitted")
        } catch {
            // Refused, as a malformed batch.
        }
    }


    private func weightedBatch(
        _ block: String, parent: String?, height: UInt64,
        from: String, to: String, n: Int64, work: UInt256
    ) -> BlockImportBatch {
        BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: block, parentBlockHash: parent, blockHeight: height,
                postStateCID: to, prevStateCID: from,
                specCID: testCID("reorg-spec"),
                target: UInt256.max.toHexString(),
                nextTarget: UInt256.max.toHexString(),
                timestamp: n
            )),
            .work(ChainWorkFact(
                blockHash: block,
                contribution: VerifiedWorkContribution(
                    id: testCID("reorg-grind-\(n)"), work: work
                )
            )),
            .validation(ChainValidationFact(blockHash: block)),
        ])
    }

    /// A parent reorg must not withdraw attestation for a state it produced.
    ///
    /// Canonicity is orthogonal to work and validity (§9.5). Attestation asks
    /// whether this chain EXECUTED a transition — a fact about immutable bytes,
    /// which a change of preferred tip cannot unmake — and whether the block is
    /// still connected and unexcluded, which a reorg also does not change. So a
    /// child anchored at a state that later falls off the canonical chain must
    /// keep its anchor: it was produced, and losing a popularity contest is not
    /// a proof of invalidity.
    func testParentReorgDoesNotWithdrawAttestation() async throws {
        let empty = LatticeState.emptyHeader.rawCID
        let g = testCID("reorg-genesis")
        let a = testCID("reorg-a")
        let b = testCID("reorg-b")
        let c = testCID("reorg-c")
        let sg = testCID("reorg-state-g")
        let sa = testCID("reorg-state-a")
        let sb = testCID("reorg-state-b")
        let sc = testCID("reorg-state-c")

        // `a` is canonical and executed; a child anchors at the state it made.
        var chain = try ChainTree.restoreWithoutContext(replaying: [
            weightedBatch(g, parent: nil, height: 0, from: empty, to: sg, n: 1, work: 1),
            weightedBatch(a, parent: g, height: 1, from: sg, to: sa, n: 2, work: 1),
        ])
        let beforeReorg = chain.executedSetAdvanced(from: empty, to: sa)
        XCTAssertTrue(beforeReorg, "the fixture must be attestable before the reorg")
        let tipBefore = chain.canonicalTip
        XCTAssertEqual(tipBefore, a)

        // A heavier sibling branch takes the tip. `a` is now off-canonical —
        // but nothing about it was disproven.
        _ = try chain.applyStaged(
            weightedBatch(b, parent: g, height: 1, from: sg, to: sb, n: 3, work: 8)
        )
        _ = try chain.applyStaged(
            weightedBatch(c, parent: b, height: 2, from: sb, to: sc, n: 4, work: 8)
        )
        let tipAfter = chain.canonicalTip
        XCTAssertEqual(tipAfter, c, "the heavier branch must take the tip")

        let afterReorg = chain.executedSetAdvanced(from: empty, to: sa)
        XCTAssertTrue(
            afterReorg,
            """
            A parent reorg withdrew attestation for a state the chain really \
            produced. Canonicity is orthogonal to work and validity, so every \
            child anchored there would be stranded by a contest it took no \
            part in.
            """
        )
    }

    /// C-1: a weighed predecessor must not vouch for its successor's anchor.
    ///
    /// Anchoring by comparing against the PREDECESSOR is an induction, and the
    /// induction has no base on the weighed tier — a weighed admission never
    /// runs the parent-fact checks, so a weighed predecessor proved nothing
    /// about its own `parentState`. A successor matching that unchecked claim
    /// would take the equality branch and be admitted with zero evidence,
    /// laundering a forged parent state through the tier that defers
    /// verification. The attacker needs no parent-chain work: carriers need not
    /// be admitted, connected, valid or canonical (§9.5).
    func testWeighedPredecessorCannotVouchForItsSuccessorsAnchor() async throws {
        let fetcher = StorableFetcher()
        let childGenesis = try await buildAndStoreGenesis(
            spec: spec(), timestamp: 1_000, target: easy, nonce: 1, fetcher: fetcher
        )
        // A state the child's real parent chain never produced.
        let unrelated = try await genesisWithState(
            fetcher: fetcher, timestamp: 500, nonce: 2, key: "induction"
        )
        let shell = try await buildAndStoreBlock(
            previous: unrelated, timestamp: 1_500, target: easy, nonce: 3,
            fetcher: fetcher
        )

        func carriedBlock(
            previous: Block, timestamp: Int64, nonce: UInt64
        ) async throws -> (Block, TestChildPackage) {
            let block = try await buildAndStoreBlock(
                previous: previous, parentChainBlock: shell,
                timestamp: timestamp, target: easy, nonce: nonce, fetcher: fetcher
            )
            let carrier = try await buildAndStoreBlock(
                previous: unrelated, children: ["Child": block],
                timestamp: timestamp + 1, target: easy, nonce: nonce + 40,
                fetcher: fetcher
            )
            let proof = try await ChildBlockProof.generate(
                rootHeader: try BlockHeader(node: carrier),
                childDirectory: "Child",
                fetcher: fetcher
            )
            return (block, TestChildPackage(proof: proof))
        }

        let (blockOne, packageOne) = try await carriedBlock(
            previous: childGenesis, timestamp: 2_000, nonce: 4
        )
        var level = try ChainTree.fromGenesis(
            block: childGenesis,
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"]),
            spec: spec()
        )

        // Weighed admission does not run the parent-fact checks, so block 1's
        // forged `parentState` is possessed but unproven. That is by design.
        let weighed = try await level.admit(
            blockOne, mode: .header, fetcher: fetcher, child: packageOne
        )
        guard let update = weighed.update, !update.excluded else {
            return XCTFail("weighed admission possesses without proving, got \(weighed)")
        }

        // The successor declares the SAME forged parent state, so an induction
        // anchored on the predecessor would admit it for free.
        let (blockTwo, packageTwo) = try await carriedBlock(
            previous: blockOne, timestamp: 3_000, nonce: 5
        )
        XCTAssertEqual(
            blockOne.parentState.rawCID, blockTwo.parentState.rawCID,
            "the fixture must exercise the equality branch"
        )

        let outcome = try await level.admit(blockTwo, fetcher: fetcher, child: packageTwo)
        guard case .rejected(let failure) = outcome else {
            return XCTFail(
                """
                A block inherited its anchor from an UNVERIFIED predecessor. \
                Cross-chain withdrawals settle against this state, so its \
                receiptState can be forged; got \(outcome)
                """
            )
        }
        guard case .crossChainEvidenceRequired(.parentStateContinuity) = failure
        else {
            return XCTFail("expected a demand for continuity evidence, got \(failure)")
        }
    }

    /// Block 1 anchors at ANY parent height.
    ///
    /// It anchors against `emptyHeader`, which is reachable only at the parent's
    /// genesis, so the equivalent walk is one visit per parent block. Answering
    /// that from the executed-from-genesis frontier keeps it O(1), which is what
    /// lets the query carry no visit budget: a budget would make the same
    /// question answerable on one node and unanswerable on another from
    /// identical data — serving RATE is a node's choice, the ANSWER is not.
    func testBlockOneAnchorsIndependentlyOfChainHeight() async throws {
        let empty = LatticeState.emptyHeader.rawCID

        func chain(ofHeight height: Int) throws -> (ChainTree, String) {
            var batches: [BlockImportBatch] = []
            var prev = empty
            var parent: String?
            var last = ""
            for i in 0...height {
                let block = testCID("depth-\(height)-\(i)")
                let post = testCID("depth-state-\(height)-\(i)")
                batches.append(BlockImportBatch(facts: [
                    .block(ChainBlockFact(
                        blockHash: block, parentBlockHash: parent,
                        blockHeight: UInt64(i), postStateCID: post,
                        prevStateCID: prev, specCID: testCID("depth-spec"),
                        target: UInt256.max.toHexString(),
                        nextTarget: UInt256.max.toHexString(),
                        timestamp: Int64(i + 1)
                    )),
                    .work(ChainWorkFact(
                        blockHash: block,
                        contribution: VerifiedWorkContribution(
                            id: testCID("depth-grind-\(height)-\(i)"), work: 1
                        )
                    )),
                    .validation(ChainValidationFact(blockHash: block)),
                ]))
                parent = block; prev = post; last = post
            }
            return (try ChainTree.restoreWithoutContext(replaying: batches), last)
        }

        for height in [8, 512] {
            let (parentChain, tip) = try chain(ofHeight: height)
            let anchors = parentChain.executedSetAdvanced(from: empty, to: tip)
            XCTAssertTrue(
                anchors,
                "a child must anchor block 1 against a parent of height \(height)"
            )
        }
    }

    /// An unexecuted state stays unanchorable no matter how deep the chain —
    /// the frontier short-circuit must not become a blanket yes.
    func testDeepChainStillRefusesAnUnexecutedState() async throws {
        let empty = LatticeState.emptyHeader.rawCID
        var batches: [BlockImportBatch] = []
        var prev = empty
        var parent: String?
        var declaredOnly = ""
        for i in 0...200 {
            let block = testCID("mix-\(i)")
            let post = testCID("mix-state-\(i)")
            // Every tenth block is weighed only: possessed, never executed.
            let executed = i % 10 != 0 || i == 0
            var facts: [ChainFact] = [
                .block(ChainBlockFact(
                    blockHash: block, parentBlockHash: parent,
                    blockHeight: UInt64(i), postStateCID: post,
                    prevStateCID: prev, specCID: testCID("mix-spec"),
                    target: UInt256.max.toHexString(),
                    nextTarget: UInt256.max.toHexString(),
                    timestamp: Int64(i + 1)
                )),
                .work(ChainWorkFact(
                    blockHash: block,
                    contribution: VerifiedWorkContribution(
                        id: testCID("mix-grind-\(i)"), work: 1
                    )
                )),
            ]
            if executed {
                facts.append(.validation(ChainValidationFact(blockHash: block)))
            } else if declaredOnly.isEmpty {
                declaredOnly = post
            }
            batches.append(BlockImportBatch(facts: facts))
            parent = block; prev = post
        }
        let parentChain = try ChainTree.restoreWithoutContext(replaying: batches)
        XCTAssertFalse(declaredOnly.isEmpty, "fixture must contain a weighed-only block")

        let anchors = parentChain.executedSetAdvanced(from: empty, to: declaredOnly)
        XCTAssertFalse(
            anchors,
            "a declared post-state must stay unanchorable however deep the chain"
        )
    }

    /// C1: block 1 must prove its `parentState` like every other height.
    ///
    /// Spec §5.3 step 6 has no height-1 exemption: "For non-genesis, compare
    /// the predecessor's `parentState` with `B.parentState`. Equality is
    /// sufficient; otherwise require an exact continuity link." A genesis's
    /// `parentState` is `emptyHeader`, and every genesis's `prevState` is
    /// `emptyHeader` too, so continuity from it terminates at the PARENT's own
    /// genesis — i.e. "reachable from real parent history", which is exactly
    /// the anchor block 1 needs.
    ///
    /// Without that requirement, block 1's `parentState` is checked only by the
    /// proof's terminal binding, which compares the child's declared value
    /// against a CARRIER the attacker authored — two attacker-chosen fields.
    func testBlockOneMustProveItsParentStateAnchor() async throws {
        let fetcher = StorableFetcher()
        let childGenesis = try await buildAndStoreGenesis(
            spec: spec(), timestamp: 1_000, target: easy, nonce: 1,
            fetcher: fetcher
        )

        // An unrelated chain, standing in for the carrier bytes an attacker
        // authors. §9.5 requires no carrier canonicity, so this need not be a
        // block of the child's actual parent chain.
        // It must carry real state: a genesis with no transactions has
        // `postState == emptyHeader`, which equals a child genesis's
        // `parentState` and would take the equality branch rather than
        // exercising the anchor requirement at all.
        let keyPair = CryptoUtils.generateKeyPair()
        let unrelatedGenesis = try await buildAndStoreGenesis(
            spec: spec(),
            transactions: [signedTestTransaction(
                TransactionBody(
                    accountActions: [],
                    actions: [Action(key: "k", oldValue: nil, newValue: "v")],
                    depositActions: [],
                    receiptActions: [],
                    withdrawalActions: [],
                    signers: [testAddress(publicKey: keyPair.publicKey)],
                    nonce: 0,
                    chainPath: [DEFAULT_ROOT_DIRECTORY]
                ),
                by: keyPair
            )],
            timestamp: 500, target: easy, nonce: 2, fetcher: fetcher
        )
        XCTAssertNotEqual(
            unrelatedGenesis.postState.rawCID,
            LatticeState.emptyHeader.rawCID,
            "the carrier chain must carry real state or the test is vacuous"
        )
        let shell = try await buildAndStoreBlock(
            previous: unrelatedGenesis, timestamp: 1_500, target: easy,
            nonce: 3, fetcher: fetcher
        )
        // Block 1, bound to the shell's pre-state rather than to anything the
        // child's real parent chain ever produced.
        let blockOne = try await buildAndStoreBlock(
            previous: childGenesis, parentChainBlock: shell,
            timestamp: 2_000, target: easy, nonce: 4, fetcher: fetcher
        )
        // A carrier sharing that pre-state and naming block 1, so the proof's
        // terminal binding is satisfied by construction.
        let carrier = try await buildAndStoreBlock(
            previous: unrelatedGenesis, children: ["Child": blockOne],
            timestamp: 1_600, target: easy, nonce: 5, fetcher: fetcher
        )

        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier),
            childDirectory: "Child",
            fetcher: fetcher
        )
        var level = try ChainTree.fromGenesis(
            block: childGenesis,
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"]),
            spec: spec()
        )

        let outcome = try await level.admit(
            blockOne, fetcher: fetcher, child: TestChildPackage(proof: proof)
        )

        // Block 1 must be made to prove its anchor. Demanding the continuity
        // evidence is retriable and correct; silently accepting an unanchored
        // parentState is not.
        guard case .rejected(let failure) = outcome else {
            return XCTFail(
                """
                Block 1 was admitted with a parentState anchored to nothing but \
                attacker-supplied carrier bytes. Cross-chain withdrawals settle \
                against this state, so its receiptState can be forged; got \
                \(outcome)
                """
            )
        }
        guard case .crossChainEvidenceRequired(.parentStateContinuity) = failure
        else {
            return XCTFail(
                "expected a retriable demand for continuity evidence, got \(failure)"
            )
        }
    }

    /// The same state, reached through a block the chain DID execute, must stay
    /// attestable — the filter must narrow to unverified claims and nothing
    /// more. Without this, the fix would be indistinguishable from breaking
    /// continuity outright.
    func testExecutedPostStateRemainsAttestable() async throws {
        let fetcher = StorableFetcher()
        // Genesis carries state, so `executed.prevState` is non-empty and this
        // goes through the WALK rather than the frontier short-circuit. This is
        // the file's only positive walk assertion: a test asserting `false`
        // cannot detect an over-restrictive filter, so without this one
        // `isAttestable -> false` passes the whole file.
        let genesis = try await genesisWithState(
            fetcher: fetcher, timestamp: 1_000, nonce: 0, key: "positive-walk"
        )
        // A transaction-free block is an IDENTITY transition here, which would
        // take the `from == to` short-circuit and never reach the walk.
        let keyPair = CryptoUtils.generateKeyPair()
        let executed = try await buildAndStoreBlock(
            previous: genesis,
            transactions: [signedTestTransaction(
                TransactionBody(
                    accountActions: [],
                    actions: [Action(key: "walked", oldValue: nil, newValue: "v")],
                    depositActions: [], receiptActions: [],
                    withdrawalActions: [],
                    signers: [testAddress(publicKey: keyPair.publicKey)],
                    nonce: 0, chainPath: [DEFAULT_ROOT_DIRECTORY]
                ),
                by: keyPair
            )],
            timestamp: 2_000, target: easy, nonce: 1, fetcher: fetcher
        )
        XCTAssertNotEqual(
            executed.prevState.rawCID, LatticeState.emptyHeader.rawCID,
            "must exercise the walk, not the empty-anchor short-circuit"
        )
        XCTAssertNotEqual(
            executed.prevState.rawCID, executed.postState.rawCID,
            "must exercise the walk, not the identity short-circuit"
        )

        var chain = try AdmissionFixture.makeChain(genesis: genesis)
        let admitted = try await chain.admit(executed, fetcher: fetcher)
        guard let update = admitted.update, !update.excluded else {
            return XCTFail("eager admission must accept, got \(admitted)")
        }

        let attested = chain.executedSetAdvanced(
            from: executed.prevState.rawCID,
            to: executed.postState.rawCID
        )
        XCTAssertTrue(
            attested,
            "an executed transition must remain attestable"
        )
    }
}
