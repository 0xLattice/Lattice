import XCTest
import UInt256
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport

/// Live-sync projection cost on a merged-mining child. Two miners racing at the
/// same height make an ordinary canonical block arrive with a sibling already
/// present, so the O(1) tip-append guard (`parent.childHashes.count == 1`)
/// fails and every canonical admission falls through to a canonical
/// projection. What that projection materializes must scale with the CHANGE,
/// not with the chain length — otherwise live sync is Θ(n²) in blocks.
@MainActor
final class CanonicalProjectionDeltaTests: XCTestCase {
    private struct Node {
        let hash: String
        let parent: String?
        let height: UInt64
        let work: UInt64
        let name: String
    }

    private func node(
        _ name: String, parent: String?, height: UInt64, work: UInt64
    ) -> Node {
        Node(
            hash: testCID("projection-delta:\(name)"),
            parent: parent,
            height: height,
            work: work,
            name: name
        )
    }

    private func admission(_ n: Node) -> BlockImportBatch {
        BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: n.hash,
                parentBlockHash: n.parent,
                blockHeight: n.height,
                postStateCID: testCID("projection-delta:post:\(n.name)"),
                prevStateCID: testCID("projection-delta:prev:\(n.name)"),
                specCID: testCID("projection-delta:spec:\(n.name)"),
                target: "1",
                nextTarget: "1",
                timestamp: Int64(n.height),
                stateDiff: .empty
            )),
            .work(ChainWorkFact(
                blockHash: n.hash,
                contribution: VerifiedWorkContribution(
                    id: testCID("projection-delta:work:\(n.name)"),
                    work: UInt256(n.work)
                )
            )),
        ])
    }

    /// Sibling-before-canonical at every height, one block at a time — the
    /// live-sync path, not restore-replay.
    private func syncMergedMiningChild(
        length: Int
    ) async throws -> (
        blockVisits: UInt64,
        segmentVisits: UInt64,
        workCells: UInt64,
        truncations: UInt64,
        tip: String,
        chain: ChainState
    ) {
        let root = node("root", parent: nil, height: 0, work: 4)
        let chain = try await ChainState.restoreWithoutContext(replaying: [admission(root)])
        let blocksBefore = await chain.canonicalProjectionBlockVisitCount
        let segmentsBefore = await chain.canonicalProjectionSegmentVisitCount
        let cellsBefore = await chain.segmentWorkUpdateCellCount
        let truncationsBefore = await chain.truncatedCanonicalProjectionCount
        var previous = root
        for height in 1...length {
            let side = node(
                "side-\(height)",
                parent: previous.hash,
                height: UInt64(height),
                work: 1
            )
            _ = try await chain.applyStaged(admission(side))
            let canonical = node(
                "main-\(height)",
                parent: previous.hash,
                height: UInt64(height),
                work: 4
            )
            _ = try await chain.applyStaged(admission(canonical))
            previous = canonical
        }
        let blocksAfter = await chain.canonicalProjectionBlockVisitCount
        let segmentsAfter = await chain.canonicalProjectionSegmentVisitCount
        let cellsAfter = await chain.segmentWorkUpdateCellCount
        let truncationsAfter = await chain.truncatedCanonicalProjectionCount
        return (
            blocksAfter - blocksBefore,
            segmentsAfter - segmentsBefore,
            cellsAfter - cellsBefore,
            truncationsAfter - truncationsBefore,
            previous.hash,
            chain
        )
    }

    func testLiveSyncProjectsTheChangedSuffixNotTheWholeChain() async throws {
        var blockVisits: [Int: UInt64] = [:]
        var segmentVisits: [Int: UInt64] = [:]
        var workCells: [Int: UInt64] = [:]
        var truncations: [Int: UInt64] = [:]
        for length in [200, 400, 800] {
            let run = try await syncMergedMiningChild(length: length)
            // Cost-only: the projected consensus state must still equal the
            // independent slow walk over the same graph.
            let blocks = await run.chain.hashToBlock
            let reference = try XCTUnwrap(
                ForkChoiceOracle(blocks: blocks, excluded: []).view().canonicalProjection(),
                "length \(length)"
            )
            let tip = await run.chain.canonicalTip
            let mainChain = await run.chain.canonicalHashes
            XCTAssertEqual(tip, run.tip, "length \(length): tip")
            XCTAssertEqual(tip, reference.tip, "length \(length): reference tip")
            XCTAssertEqual(
                mainChain,
                Set(reference.path),
                "length \(length): reference path"
            )
            blockVisits[length] = run.blockVisits
            segmentVisits[length] = run.segmentVisits
            workCells[length] = run.workCells
            truncations[length] = run.truncations
        }

        // Assert the per-admission bound the projection actually guarantees,
        // not a growth ratio: a "must not quadruple for a doubled chain" bound
        // is vacuous here, since the whole-chain projection satisfies it too
        // (20,300 x 4 >= 80,600). Materializing the changed suffix is one block
        // per admission on this shape; the x2 leaves room for the first
        // projection, which is necessarily full.
        let measured = "blocks \(blockVisits), segments \(segmentVisits), workCells \(workCells), truncations \(truncations)"
        for length in [200, 400, 800] {
            XCTAssertLessThanOrEqual(
                blockVisits[length]!,
                UInt64(2 * length),
                "projection work must scale with the change, not the chain length: \(measured)"
            )
        }

        // The spine walk is no longer quadratic. The descent starts at the
        // divergence point — the deepest canonical ancestor of the block that
        // just changed — so it walks the segments that CHANGED rather than the
        // path from the root. The previous assertion on this column was an
        // XCTAssertGreaterThan pinning it as still quadratic; inverting it is
        // the entire point of this change, not a broken test.
        //
        // Measured, not guessed: one segment per admission, so 2 per height on
        // this shape (400/800/1600 at 200/400/800), against 20,300/80,600/
        // 321,200 before. The x3 is headroom over the measured 2, and still
        // leaves the bound two orders of magnitude below the quadratic value it
        // replaces — a planted bug that disables truncation turns it red.
        // NOTE: this is now a RESTATEMENT of the block bound above, not an
        // independent constraint. Both counters receive the same expression
        // since the quotient was deleted — with no hop to take, a descent step
        // IS a block — so this can only fail when that one does. It is kept
        // because the counter is still serving the cross-deletion measurement,
        // and it should collapse into a single bound when the two counters
        // collapse into a single name.
        for length in [200, 400, 800] {
            XCTAssertLessThanOrEqual(
                segmentVisits[length]!,
                UInt64(3 * length),
                "the descent must scale with the change, not the chain: \(measured)"
            )
        }
        // The truncation must also be shown to FIRE. One that silently never
        // fired would still be correct, and every parity test would still pass,
        // so the cost claim needs a witness of its own.
        for length in [200, 400, 800] {
            XCTAssertGreaterThanOrEqual(
                truncations[length]!,
                UInt64(2 * length),
                "every admission truncates, both per height: \(measured)"
            )
        }

        // The last of the three columns in 0xLattice/lattice-node#64, and the
        // one no change to the descent could reach: it is paid before any
        // projection runs. The ancestor walk is not faster here, it is GONE.
        // Subtree work is a range over an Euler order, so recording work walks
        // one root-ward path in the SEQUENCE tree and touches nothing above the
        // block in the BLOCK tree, and routing a block updates no ancestor at
        // all.
        //
        // Measured 3,619 at 200 and 18,894 at 800, against 40,800 and 643,200
        // before — 34x less at 800 blocks, and widening. Quadrupling the chain
        // multiplied this column by 5.2, which is n log n; quadratic would be
        // 16. The x8 bound separates those two and nothing finer.
        //
        // This was an XCTAssertGreaterThan pinning the column as quadratic.
        // Inverting it is the entire point of this change, not a broken test.
        XCTAssertLessThanOrEqual(
            workCells[800]!,
            workCells[200]! * 8,
            "the weight index must not scale with chain length: \(measured)"
        )
    }

    /// A LOSING sibling deep in the chain is the most common admission shape on
    /// a merged-mining child, and it changes no canonical decision at all, so it
    /// must cost nothing. The shape matters: the sibling-at-every-height case
    /// hangs its sibling off the current TIP, where a descent to the tip is one
    /// block and a regression here would be invisible. These siblings hang off
    /// blocks spread across the whole history, including just above genesis,
    /// where descending to the tip would materialize hundreds of blocks to
    /// conclude nothing moved.
    func testDeepLosingSiblingMaterializesNothing() async throws {
        let length = 400
        let root = node("deep-root", parent: nil, height: 0, work: 4)
        let chain = try await ChainState.restoreWithoutContext(replaying: [admission(root)])
        var canonical = [root]
        var previous = root
        for height in 1...length {
            let block = node(
                "deep-main-\(height)",
                parent: previous.hash,
                height: UInt64(height),
                work: 4
            )
            _ = try await chain.applyStaged(admission(block))
            canonical.append(block)
            previous = block
        }

        let blocksBefore = await chain.canonicalProjectionBlockVisitCount
        let segmentsBefore = await chain.canonicalProjectionSegmentVisitCount
        var siblings = 0
        for height in stride(from: 1, through: length - 1, by: 8) {
            let sibling = node(
                "deep-side-\(height)",
                parent: canonical[height - 1].hash,
                height: UInt64(height),
                work: 1
            )
            _ = try await chain.applyStaged(admission(sibling))
            siblings += 1
        }
        let blocks = await chain.canonicalProjectionBlockVisitCount - blocksBefore
        let segments = await chain.canonicalProjectionSegmentVisitCount
            - segmentsBefore
        let tip = await chain.canonicalTip

        XCTAssertGreaterThan(siblings, 40, "the shape must cover real depth")
        XCTAssertEqual(tip, previous.hash, "a losing sibling must not move the tip")
        XCTAssertEqual(
            blocks,
            0,
            "a losing sibling changes no decision, so nothing may be materialized"
        )
        XCTAssertEqual(
            segments,
            0,
            "and the winner at the fork point settles it without walking to the tip"
        )
    }

    /// Divergence deeper than any fixed walk budget.
    ///
    /// An earlier version of this change capped the ancestor walk at 64 steps
    /// and fell through to the whole-chain projection past it. That cap did not
    /// bound the cost of a deep divergence, it RELOCATED it: the fallback pays a
    /// spine walk and a descent from the root before it can discover that
    /// nothing moved, so a divergence past the cap cost O(n) per admission — the
    /// quadratic this change removes, on the shape it exists to make cheap.
    ///
    /// Every other shape in this file keeps the mutation one step off the
    /// canonical path, so not one of them can see that. The shape is the test
    /// here, not the bound.
    func testDivergenceDeeperThanAnyWalkBudgetMaterializesNothing() async throws {
        let length = 400
        let forkHeight = 10
        let branchLength = 160
        XCTAssertGreaterThan(
            branchLength,
            64,
            "the divergence must exceed any fixed step budget to be meaningful"
        )

        let root = node("budget-root", parent: nil, height: 0, work: 4)
        let chain = try await ChainState.restoreWithoutContext(replaying: [admission(root)])
        var canonical = [root]
        var previous = root
        for height in 1...length {
            let block = node(
                "budget-main-\(height)",
                parent: previous.hash,
                height: UInt64(height),
                work: 4
            )
            _ = try await chain.applyStaged(admission(block))
            canonical.append(block)
            previous = block
        }

        // A long LOSING branch off an early canonical block. Its total work
        // stays far under the canonical subtree above the fork, so the canonical
        // path never moves and everything admitted on it is a losing block.
        var branchTip = canonical[forkHeight]
        for step in 1...branchLength {
            let block = node(
                "budget-branch-\(step)",
                parent: branchTip.hash,
                height: UInt64(forkHeight + step),
                work: 1
            )
            _ = try await chain.applyStaged(admission(block))
            branchTip = block
        }
        let tipAfterBranch = await chain.canonicalTip
        XCTAssertEqual(
            tipAfterBranch,
            previous.hash,
            "the losing branch must not take the canonical path"
        )

        let blocksBefore = await chain.canonicalProjectionBlockVisitCount
        let segmentsBefore = await chain.canonicalProjectionSegmentVisitCount
        // One more block at the END of that branch: its ancestor line meets the
        // canonical path branchLength + 1 steps down, far past any budget.
        let deep = node(
            "budget-deep",
            parent: branchTip.hash,
            height: UInt64(forkHeight + branchLength + 1),
            work: 1
        )
        _ = try await chain.applyStaged(admission(deep))
        let blocks = await chain.canonicalProjectionBlockVisitCount - blocksBefore
        let segments = await chain.canonicalProjectionSegmentVisitCount
            - segmentsBefore

        let finalTip = await chain.canonicalTip
        XCTAssertEqual(
            finalTip,
            previous.hash,
            "a losing block on a deep branch must not move the tip"
        )
        XCTAssertEqual(
            blocks,
            0,
            "a deep divergence that changes nothing must materialize nothing"
        )
        XCTAssertEqual(
            segments,
            0,
            "and must not fall back to walking the path from the root"
        )
    }

    /// Build `length` heights of history with a LOSING sibling at every height,
    /// delivered before the canonical block, and return the canonical blocks.
    ///
    /// The SHAPE is the point, not the length. A fork-free chain collapses the
    /// segment quotient to one or two bases, so any cost measured per ancestor
    /// BASE is O(1) on it however long it gets — which would make the cost
    /// assertions below pass on the implementation they exist to discriminate
    /// against. A sibling at every height forces a split at every height, giving
    /// the quotient one base per block: the merged-mining shape, and the only
    /// one on which these costs can be measured at all.
    private func forkedHistory(
        _ chain: ChainState,
        prefix: String,
        length: Int,
        from root: Node
    ) async throws -> [Node] {
        var blocks = [root]
        var previous = root
        for height in 1...length {
            let sibling = node(
                "\(prefix)-side-\(height)",
                parent: previous.hash,
                height: UInt64(height),
                work: 1
            )
            _ = try await chain.applyStaged(admission(sibling))
            let block = node(
                "\(prefix)-main-\(height)",
                parent: previous.hash,
                height: UInt64(height),
                work: 4
            )
            _ = try await chain.applyStaged(admission(block))
            blocks.append(block)
            previous = block
        }
        return blocks
    }

    /// Grafting an orphan component must cost what the COMPONENT costs, never
    /// what the chain behind it costs. The old index added the component's total
    /// to every routed ancestor base, so this scaled with mature history; the
    /// range structure adds nothing above the graft point at all.
    ///
    /// Holding the component fixed and varying the history is the only shape
    /// that can witness that — a single-point count cannot.
    func testOrphanGraftCostDoesNotScaleWithMatureHistory() async throws {
        var cells: [Int: UInt64] = [:]
        // Small enough to stay a LOSING component against the canonical blocks
        // above the graft point, so this measures a graft and not a reorg. Its
        // size is fixed across both histories, which is what the ratio needs.
        let componentDepth = 4
        for history in [200, 800] {
            let root = node("graft-\(history)-root", parent: nil, height: 0, work: 4)
            let chain = try await ChainState.restoreWithoutContext(replaying: [admission(root)])
            let main = try await forkedHistory(
                chain, prefix: "graft-\(history)", length: history, from: root
            )

            // A component hanging off a block near the TIP, delivered
            // child-first so it stays unrouted until its connecting block
            // arrives.
            //
            // Deep on purpose. The cost this bounds was a walk from the mutation
            // point to the ROOT, so a graft near genesis has a short ancestor
            // path and cannot witness the regression however long the history
            // is — the Θ(n) bases sit ABOVE such a graft, where that walk never
            // goes. This is the same axis error as the fork-free history, one
            // level down.
            var component: [Node] = []
            var parentHash = main[history - 2].hash
            for step in 0...componentDepth {
                let block = node(
                    "graft-\(history)-orphan-\(step)",
                    parent: parentHash,
                    height: UInt64(history - 1 + step),
                    work: 1
                )
                component.append(block)
                parentHash = block.hash
            }
            for block in component.dropFirst().reversed() {
                _ = try await chain.applyStaged(admission(block))
            }

            let before = await chain.segmentWorkUpdateCellCount
            // The connecting block grafts the whole component at once.
            _ = try await chain.applyStaged(admission(component[0]))
            let after = await chain.segmentWorkUpdateCellCount
            cells[history] = after - before
        }

        let measured = "graft cells \(cells)"
        XCTAssertGreaterThan(cells[200]!, 0, measured)
        XCTAssertLessThanOrEqual(
            cells[800]!,
            cells[200]! * 2,
            "a graft must not scale with the history behind it: \(measured)"
        )
    }

    /// A deep WINNING sibling — a real reorg, not a losing one. The canonical
    /// path legitimately moves and many blocks are materialized, but recording
    /// the work that caused it must still not scale with chain length.
    func testDeepWinningSiblingWeightCostDoesNotScaleWithChainLength() async throws {
        var cells: [Int: UInt64] = [:]
        for length in [200, 800] {
            let root = node("win-\(length)-root", parent: nil, height: 0, work: 4)
            let chain = try await ChainState.restoreWithoutContext(replaying: [admission(root)])
            let main = try await forkedHistory(
                chain, prefix: "win-\(length)", length: length, from: root
            )

            let before = await chain.segmentWorkUpdateCellCount
            // Attached near the TIP, and heavy enough to outweigh the canonical
            // remainder above it, so the chain genuinely reorganizes onto it.
            //
            // Near the tip rather than near genesis because the cost this bounds
            // was a walk from the mutation point to the ROOT: a shallow mutation
            // has a short ancestor path and cannot witness the regression at any
            // chain length. The REORG's depth was never the measured axis — the
            // mutation point's depth is.
            let winner = node(
                "win-\(length)-sibling",
                parent: main[length - 3].hash,
                height: UInt64(length - 2),
                work: UInt64(length) * 16
            )
            _ = try await chain.applyStaged(admission(winner))
            let after = await chain.segmentWorkUpdateCellCount
            cells[length] = after - before

            let tip = await chain.canonicalTip
            XCTAssertEqual(tip, winner.hash, "length \(length): the reorg must happen")
        }

        let measured = "reorg weight cells \(cells)"
        XCTAssertLessThanOrEqual(
            cells[800]!,
            cells[200]! * 2,
            "recording a reorg's work must not scale with the chain: \(measured)"
        )
    }

    /// Exclusion rebuilds the index from the filtered graph. Admissions AFTER
    /// it must be as cheap as admissions before it — a rebuild that left the
    /// index in a shape where updates walk history would show up here and
    /// nowhere else.
    func testAdmissionAfterExclusionDoesNotScaleWithChainLength() async throws {
        var cells: [Int: UInt64] = [:]
        for length in [200, 800] {
            let root = node("excl-\(length)-root", parent: nil, height: 0, work: 4)
            let chain = try await ChainState.restoreWithoutContext(replaying: [admission(root)])
            let main = try await forkedHistory(
                chain, prefix: "excl-\(length)", length: length, from: root
            )
            let doomed = node(
                "excl-\(length)-doomed",
                parent: main[4].hash,
                height: 5,
                work: 1
            )
            _ = try await chain.applyStaged(admission(doomed))
            _ = try? await chain.applyStaged(BlockImportBatch(facts: [
                .exclusion(ChainExclusionFact(blockHash: doomed.hash)),
            ]))

            let before = await chain.segmentWorkUpdateCellCount
            var previous = main[length]
            for step in 1...8 {
                let block = node(
                    "excl-\(length)-after-\(step)",
                    parent: previous.hash,
                    height: UInt64(length + step),
                    work: 4
                )
                _ = try await chain.applyStaged(admission(block))
                previous = block
            }
            let after = await chain.segmentWorkUpdateCellCount
            cells[length] = after - before
        }

        let measured = "post-exclusion cells \(cells)"
        XCTAssertGreaterThan(cells[200]!, 0, measured)
        XCTAssertLessThanOrEqual(
            cells[800]!,
            cells[200]! * 2,
            "admissions after an exclusion must not scale with the chain: \(measured)"
        )
    }

    /// Subtree work is SUMMED by the live index but deduplicated by grind
    /// identity in the reference oracle, so the two agree only while each grind
    /// identity occupies exactly one block. That is what `acceptsLocation`
    /// enforces, and it is what makes summing — and every range-sum technique
    /// built on it — valid over this graph. Tested rather than assumed.
    func testAGrindIdentityCannotOccupyTwoBlocks() async throws {
        let root = node("dup-root", parent: nil, height: 0, work: 4)
        let a = node("dup-a", parent: root.hash, height: 1, work: 4)
        let b = node("dup-b", parent: root.hash, height: 1, work: 1)
        let chain = try await ChainState.restoreWithoutContext(replaying: [admission(root)])
        _ = try await chain.applyStaged(admission(a))
        _ = try await chain.applyStaged(admission(b))

        let shared = testCID("projection-delta:shared-grind")
        let first = try await chain.applyStaged(BlockImportBatch(facts: [
            .work(ChainWorkFact(
                blockHash: a.hash,
                contribution: VerifiedWorkContribution(id: shared, work: UInt256(9))
            )),
        ]))
        XCTAssertEqual(first?.addedContribution, true)

        // The same identity, stronger, at a different block: if this were
        // admitted the same work would be counted in two subtrees at once.
        do {
            _ = try await chain.applyStaged(BlockImportBatch(facts: [
                .work(ChainWorkFact(
                    blockHash: b.hash,
                    contribution: VerifiedWorkContribution(
                        id: shared,
                        work: UInt256(99)
                    )
                )),
            ]))
            XCTFail("a grind identity already located at another block was admitted")
        } catch {
            // Refused, as it must be.
        }

        let blocks = await chain.hashToBlock
        let reference = try XCTUnwrap(
            ForkChoiceOracle(blocks: blocks, excluded: []).view().canonicalProjection()
        )
        let tip = await chain.canonicalTip
        let path = await chain.canonicalHashes
        XCTAssertEqual(tip, reference.tip)
        XCTAssertEqual(path, Set(reference.path))
        XCTAssertEqual(tip, a.hash, "the relocated work must not have moved the tip")
    }
}
