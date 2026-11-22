import XCTest
import UInt256
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport

/// The invalidity-exclusion seam of deferred execution — work weighs, validity
/// selects (§9.9): a proven-invalid subtree keeps weighing for its ancestors
/// exactly as any work does, and fork choice never STEPS INTO it, so the tip
/// is the heaviest selectable path — while the excluded facts remain present in
/// `hashToBlock` (served/exported, never pruned) and untouched in the per-block
/// work evidence.
@MainActor
final class DeferredExecutionExclusionTests: XCTestCase {
    // MARK: - Fixtures

    private struct PlannedBlock {
        let hash: String
        let parentHash: String?
        let height: UInt64
        let work: UInt64
    }

    private func block(
        _ name: String,
        parent: PlannedBlock?,
        work: UInt64
    ) -> PlannedBlock {
        PlannedBlock(
            hash: testCID("exclusion-\(name)"),
            parentHash: parent?.hash,
            height: (parent?.height).map { $0 + 1 } ?? 0,
            work: work
        )
    }

    private func admission(for block: PlannedBlock) -> BlockImportBatch {
        let contribution = VerifiedWorkContribution(
            id: testCID("exclusion-work-\(block.hash)"),
            work: UInt256(block.work)
        )
        return BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: block.hash,
                parentBlockHash: block.parentHash,
                blockHeight: block.height,
                postStateCID: testCID("exclusion-post-\(block.hash)"),
                prevStateCID: testCID("exclusion-prev-\(block.hash)"),
                specCID: testCID("exclusion-spec-\(block.hash)"),
                target: "1",
                nextTarget: "1",
                timestamp: Int64(block.height),
                stateDiff: .empty
            )),
            .work(ChainWorkFact(blockHash: block.hash, contribution: contribution)),
        ])
    }

    private func exclusion(of block: PlannedBlock) -> BlockImportBatch {
        BlockImportBatch(facts: [
            .exclusion(ChainExclusionFact(blockHash: block.hash)),
        ])
    }

    /// Genesis G with a heavier chain H1→H2→H3 (work 5 each = 15) and a lighter
    /// chain L1→L2 (work 4 each = 8). Before exclusion the tip is H3.
    private func buildForkedChain() async throws -> (
        chain: ChainTree,
        g: PlannedBlock,
        h: [PlannedBlock],
        l: [PlannedBlock],
        batches: [BlockImportBatch]
    ) {
        let g = block("g", parent: nil, work: 3)
        let h1 = block("h1", parent: g, work: 5)
        let h2 = block("h2", parent: h1, work: 5)
        let h3 = block("h3", parent: h2, work: 5)
        let l1 = block("l1", parent: g, work: 4)
        let l2 = block("l2", parent: l1, work: 4)
        let h = [h1, h2, h3]
        let l = [l1, l2]
        var batches = [admission(for: g)]
        for b in h + l { batches.append(admission(for: b)) }

        var chain = try ChainTree.restoreWithoutContext(replaying: [admission(for: g)])
        for b in h + l {
            _ = try chain.applyStaged(admission(for: b))
        }
        let tip = chain.canonicalTip
        XCTAssertEqual(tip, h3.hash, "precondition: heaviest chain H is the tip")
        return (chain, g, h, l, batches)
    }

    // MARK: - Tests

    /// A heaviest chain whose block is proven invalid is EXCLUDED and the tip
    /// demotes to the heaviest VALID chain. Excluded blocks stay served.
    func testExcludedSubtreeDemotesTipToHeaviestValidChain() async throws {
        var (chain, g, h, l, _) = try await buildForkedChain()

        _ = try chain.applyStaged(exclusion(of: h[0]))

        let tip = chain.canonicalTip
        XCTAssertEqual(tip, l[1].hash, "tip demotes to heaviest valid chain L2")

        let path = chain.canonicalHashes
        XCTAssertEqual(path, [g.hash, l[0].hash, l[1].hash])

        // Excluded facts are NOT pruned: still present and served.
        for b in h {
            let present = chain.contains(blockHash: b.hash)
            XCTAssertTrue(present, "excluded block \(b.hash) remains served")
        }
    }

    /// The live projection under exclusion matches the reference oracle applied
    /// to the same exclusion — both descents skip the excluded subtree.
    func testLiveProjectionMatchesReferenceOracleUnderExclusion() async throws {
        var (chain, _, h, l, _) = try await buildForkedChain()
        _ = try chain.applyStaged(exclusion(of: h[0]))

        let blocks = chain.hashToBlock
        let excluded = chain.excludedRootsForTesting
        guard let expected = ForkChoiceOracle(blocks: blocks, excluded: excluded)
            .view().canonicalProjection()
        else {
            return XCTFail("reference oracle produced no projection")
        }
        let liveTip = chain.canonicalTip
        let livePath = chain.canonicalHashes
        XCTAssertEqual(liveTip, expected.tip)
        XCTAssertEqual(livePath, Set(expected.path))
        XCTAssertEqual(expected.tip, l[1].hash)
    }

    /// Exclusion survives restore: replaying all durable facts (including the
    /// exclusion) in an adversarial order reproduces the demoted tip.
    func testExclusionIsReplayInvariant() async throws {
        var (chain, _, h, l, batches) = try await buildForkedChain()
        _ = try chain.applyStaged(exclusion(of: h[0]))
        let expectedTip = chain.canonicalTip
        let expectedPath = chain.canonicalHashes
        XCTAssertEqual(expectedTip, l[1].hash)

        // Durable facts in an order that presents the exclusion before, between,
        // and after its subtree blocks. Genesis stays first so restore has a root.
        var durable = batches
        durable.insert(exclusion(of: h[0]), at: 2)

        let restored = try ChainTree.restoreWithoutContext(replaying: durable)
        let restoredTip = restored.canonicalTip
        let restoredPath = restored.canonicalHashes
        XCTAssertEqual(restoredTip, expectedTip)
        XCTAssertEqual(restoredPath, expectedPath)
    }

    /// Orphan admission under an exclusion: a descendant admitted BEFORE its
    /// excluded parent connects (child-before-parent via orphan attach) weighs
    /// for its ancestors like any block and is still never selected — with no
    /// per-descendant bookkeeping, because the descent never reaches it.
    func testOrphanDescendantOfExcludedRootWeighsButIsNeverSelected() async throws {
        // G → R (excluded) → B → C, plus a valid competing chain L1 → L2.
        let g = block("g", parent: nil, work: 3)
        let r = block("r", parent: g, work: 5)
        let b = block("b", parent: r, work: 5)
        let c = block("c", parent: b, work: 5)
        let l1 = block("l1", parent: g, work: 4)
        let l2 = block("l2", parent: l1, work: 4)

        var chain = try ChainTree.restoreWithoutContext(replaying: [admission(for: g)])
        // R and the valid chain exist; B and C do not yet.
        _ = try chain.applyStaged(admission(for: r))
        _ = try chain.applyStaged(admission(for: l1))
        _ = try chain.applyStaged(admission(for: l2))

        // Prove R invalid while B, C are still absent.
        _ = try chain.applyStaged(exclusion(of: r))

        // C arrives before its parent B — an orphan attach.
        _ = try chain.applyStaged(admission(for: c))
        // B connects under the excluded root R, grafting C with it. Nothing is
        // folded anywhere: descendants of an excluded root need no bookkeeping,
        // because the descent never reaches them.
        _ = try chain.applyStaged(admission(for: b))

        let roots = chain.excludedRootsForTesting
        XCTAssertEqual(roots, [r.hash], "only the proven-invalid root is recorded")

        // C weighs its work — validity never subtracts weight — and so does the
        // whole excluded subtree for its ancestors; yet nothing below R is ever
        // selected: the tip is the valid chain.
        let cWeight = chain.subtreeWeight(forHash: c.hash)
        XCTAssertEqual(cWeight, WorkSum(UInt256(c.work)))
        let gWeight = chain.subtreeWeight(forHash: g.hash)
        XCTAssertEqual(
            gWeight,
            [g, r, b, c, l1, l2].reduce(WorkSum.zero) { $0 + UInt256($1.work) },
            "the excluded subtree still weighs for its ancestors"
        )
        let path = chain.canonicalHashes
        XCTAssertFalse(path.contains(c.hash))
        XCTAssertFalse(path.contains(b.hash))
        let tip = chain.canonicalTip
        XCTAssertEqual(tip, l2.hash)

        // Matches the reference oracle over the same exclusion.
        let blocks = chain.hashToBlock
        let expected = ForkChoiceOracle(blocks: blocks, excluded: roots)
            .view().canonicalProjection()
        XCTAssertEqual(tip, expected?.tip)
        XCTAssertEqual(path, expected.map { Set($0.path) })
    }

    /// Complexity regression (the DoS the audit confirmed): with an exclusion
    /// active, spamming losing side blocks must NOT trigger a full canonical
    /// projection per insert — the single filtered segment index keeps the fast
    /// spine early-out working, so the full-projection counter stays bounded.
    func testSideBlockSpamUnderExclusionDoesNotFullyProjectPerInsert() async throws {
        var (chain, g, h, _, _) = try await buildForkedChain()
        _ = try chain.applyStaged(exclusion(of: h[0]))

        let baseline = chain.fullCanonicalProjectionCount
        // Many losing side blocks hung off genesis (height 1), none of which
        // changes the winning spine.
        for index in 0..<200 {
            let sibling = PlannedBlock(
                hash: testCID("exclusion-spam-\(index)"),
                parentHash: g.hash,
                height: 1,
                work: 1
            )
            _ = try chain.applyStaged(admission(for: sibling))
        }
        let after = chain.fullCanonicalProjectionCount
        XCTAssertLessThanOrEqual(
            after - baseline,
            5,
            "200 losing side blocks under an exclusion must not each force a full projection"
        )
    }

    /// Replay presenting an `.exclusion` batch STRICTLY BEFORE its block must
    /// defer-and-retry (not corrupt), then reproject identically to the live
    /// order. Exercises the missing-block defer path in `applyExclusion`.
    func testExclusionStrictlyBeforeBlockDefersAndReprojectsIdentically() async throws {
        var (chain, _, h, l, batches) = try await buildForkedChain()
        _ = try chain.applyStaged(exclusion(of: h[0]))
        let expectedTip = chain.canonicalTip
        let expectedPath = chain.canonicalHashes
        XCTAssertEqual(expectedTip, l[1].hash)

        // Durable order: genesis first (restore needs a root), then the exclusion
        // BEFORE any of H1/H2/H3/L1/L2 — so it must defer until H1 arrives.
        var durable = [batches[0]]
        durable.append(exclusion(of: h[0]))
        durable.append(contentsOf: batches.dropFirst())

        let restored = try ChainTree.restoreWithoutContext(replaying: durable)
        let restoredTip = restored.canonicalTip
        let restoredPath = restored.canonicalHashes
        XCTAssertEqual(restoredTip, expectedTip)
        XCTAssertEqual(restoredPath, expectedPath)

        // And the excluded root is genuinely recorded after recovery; its
        // descendants need no record, since the descent never reaches them.
        let roots = restored.excludedRootsForTesting
        XCTAssertEqual(roots, [h[0].hash])
        for excluded in h {
            XCTAssertFalse(restoredPath.contains(excluded.hash), "\(excluded.hash) is never canonical")
        }
    }

    /// A miner cannot resurrect an excluded subtree by piling on more work: a
    /// heavier extension of the excluded chain is still never acted on.
    func testHeavierExtensionOfExcludedChainNeverResurrectsTip() async throws {
        var (chain, _, h, l, _) = try await buildForkedChain()
        _ = try chain.applyStaged(exclusion(of: h[0]))
        let tipAfterExclusion = chain.canonicalTip
        XCTAssertEqual(tipAfterExclusion, l[1].hash)

        // H4 extends H3 with enormous work — the excluded subtree stays excluded.
        let h4 = block("h4", parent: h[2], work: 1_000_000)
        _ = try chain.applyStaged(admission(for: h4))

        let tipAfterExtension = chain.canonicalTip
        XCTAssertEqual(
            tipAfterExtension,
            l[1].hash,
            "excluded subtree extension is weighed-but-never-acted-on"
        )
        let extendedPath = chain.canonicalHashes
        XCTAssertEqual(extendedPath.contains(h4.hash), false)
    }

    // MARK: - Graft of a component carrying a durable exclusion

    /// Shape:  G -> V1                (valid competitor)
    ///         G -> P -> B0 -> B1     (P withheld; B1 proven invalid unrouted)
    ///
    /// A durable exclusion can exist on a block that is present but NOT routed:
    /// `applyExclusion` gates only on `hashToBlock[blockHash] != nil`, and a
    /// branch whose connecting ancestor is withheld never routes, because
    /// `routeBlock` returns early when the parent is absent. A completed
    /// execution verdict needs the block's CONTENT, not its CONNECTIVITY.
    ///
    /// Work comes from the fixture alone, chosen so the VALID part of the P
    /// branch (P + B0) is lighter than V1, while the P branch counted WITH the
    /// excluded B1 is heavier. Work weighs, validity selects (§9.9): B1's work
    /// votes for its valid ancestors P and B0, so the P branch wins at G — and
    /// the descent stops at B0, because B1 is never stepped into. What §9.9
    /// forbids is B1 itself, or anything below it, ever being selected.
    private func buildGraftedExclusionChain() async throws -> (
        chain: ChainTree,
        g: PlannedBlock,
        p: PlannedBlock,
        b0: PlannedBlock,
        b1: PlannedBlock,
        v1: PlannedBlock
    ) {
        let g = block("graft-g", parent: nil, work: 1)
        let p = block("graft-p", parent: g, work: 1)
        let b0 = block("graft-b0", parent: p, work: 1)
        let b1 = block("graft-b1", parent: b0, work: 10)
        let v1 = block("graft-v1", parent: g, work: 4)

        var chain = try ChainTree.restoreWithoutContext(replaying: [admission(for: g)])
        _ = try chain.applyStaged(admission(for: v1))

        // B0 and B1 arrive while their connecting ancestor P is withheld, so
        // neither routes: the work is held, fork choice never sees it.
        _ = try chain.applyStaged(admission(for: b0))
        _ = try chain.applyStaged(admission(for: b1))
        let b0Routed = chain.hasConnectedAncestry(blockHash: b0.hash)
        let b1Routed = chain.hasConnectedAncestry(blockHash: b1.hash)
        XCTAssertFalse(b0Routed, "precondition: B0 is weighed but unrouted")
        XCTAssertFalse(b1Routed, "precondition: B1 is weighed but unrouted")

        // The verdict lands on an unrouted block.
        _ = try chain.applyStaged(exclusion(of: b1))
        let roots = chain.excludedRootsForTesting
        XCTAssertTrue(
            roots.contains(b1.hash),
            "precondition: durable exclusion recorded on an unrouted block"
        )

        // The withheld ancestor arrives and grafts the whole component in.
        _ = try chain.applyStaged(admission(for: p))
        return (chain, g, p, b0, b1, v1)
    }

    /// The grafted component splices the excluded block into every ancestor's
    /// Euler range like any other block: `subtreeWork` is a pure-work RANGE
    /// SUM, and validity never subtracts from it. The live range sum and the
    /// independent recomputation must agree, with B1 in both.
    func testGraftSplicesExcludedWorkIntoAncestorRangesLikeAnyOther() async throws {
        let (chain, g, p, b0, b1, v1) = try await buildGraftedExclusionChain()

        // Every bound derives from the fixture's own planned work, not from a
        // constant.
        func plannedWork(_ blocks: [PlannedBlock]) -> WorkSum {
            blocks.reduce(WorkSum.zero) { $0 + UInt256($1.work) }
        }

        // Genesis range: G + P + B0 + B1 + V1. The excluded B1 weighs.
        let snapG = chain.forkChoiceSnapshot(startingAt: g.hash)
        let liveG = snapG?.subtreeWork
        let oracleG = chain.subtreeWeight(forHash: g.hash)
        XCTAssertEqual(
            liveG,
            plannedWork([g, p, b0, b1, v1]),
            "genesis range counts every block's work, excluded or not"
        )
        XCTAssertEqual(liveG, oracleG, "genesis: live index must match the recomputation")

        // The grafted component's own root: P + B0 + B1.
        let snapP = chain.forkChoiceSnapshot(startingAt: p.hash)
        let liveP = snapP?.subtreeWork
        let oracleP = chain.subtreeWeight(forHash: p.hash)
        XCTAssertEqual(liveP, plannedWork([p, b0, b1]), "grafted root counts its excluded descendant")
        XCTAssertEqual(liveP, oracleP, "grafted root: live index must match the recomputation")

        let held = chain.contains(blockHash: b1.hash)
        XCTAssertTrue(held, "excluded block remains served")
        let excludedWeight = chain.subtreeWeight(forHash: b1.hash)
        XCTAssertEqual(excludedWeight, plannedWork([b1]), "an excluded block weighs its own work")
        // ... and descends nowhere.
        let snapB1 = chain.forkChoiceSnapshot(startingAt: b1.hash)
        XCTAssertEqual(snapB1?.tipHash, b1.hash)
        XCTAssertEqual(snapB1?.subtreeWork, plannedWork([b1]))
    }

    /// The selection consequence: the excluded work carried in by the graft
    /// makes the P branch the heavier one at G, so the descent takes it — and
    /// stops at B0, the last selectable block above the exclusion. B1 is never
    /// the tip, however heavy; V1 loses because it is lighter, not because B1
    /// was discounted.
    func testExcludedWorkVotesForItsValidAncestorsButIsNeverSelected() async throws {
        let (chain, _, p, b0, b1, v1) = try await buildGraftedExclusionChain()

        let tip = chain.canonicalTip
        XCTAssertEqual(tip, b0.hash, "the descent stops at the last selectable block above the exclusion")
        let path = chain.canonicalHashes
        XCTAssertTrue(path.contains(p.hash))
        XCTAssertTrue(path.contains(b0.hash))
        XCTAssertFalse(path.contains(b1.hash), "an excluded block is never canonical")
        XCTAssertFalse(path.contains(v1.hash))

        // The live projection agrees with the reference oracle.
        let blocks = chain.hashToBlock
        let closure = chain.excludedRootsForTesting
        let expected = ForkChoiceOracle(blocks: blocks, excluded: closure)
            .view().canonicalProjection()
        XCTAssertEqual(tip, expected?.tip)
        XCTAssertEqual(path, expected.map { Set($0.path) })
    }

}
