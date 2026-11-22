import XCTest
import UInt256
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport

/// The shape the segment quotient was BUILT for: a long fork-free run, where
/// one segment spans the whole chain and a hop replaces a per-block walk.
///
/// Deleting a structure makes "nothing got slower" trivially true on any shape
/// that never built it, so a merged-mining shape cannot answer whether the
/// deletion cost anything — there the quotient was already degenerate, one
/// segment per block. This is the shape where it was doing real work, and it is
/// measured on the code BEFORE the deletion and again after, so the comparison
/// is a number rather than an argument.
///
/// Two costs are separated because they behave differently:
///   - steady state, where every admission extends the tip and the projection
///     descends only from the divergence point;
///   - the forced whole-chain projection, reached here through an exclusion,
///     which is the one path that still walks from the root and therefore the
///     only place a quotient hop was load-bearing.
@MainActor
final class QuotientDeletionCostTests: XCTestCase {
    private func admission(
        _ name: String,
        parent: String?,
        height: UInt64,
        work: UInt64
    ) -> (hash: String, batch: BlockImportBatch) {
        let hash = testCID("quotient-cost:\(name)")
        let batch = BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: hash,
                parentBlockHash: parent,
                blockHeight: height,
                postStateCID: testCID("quotient-cost:post:\(name)"),
                prevStateCID: testCID("quotient-cost:prev:\(name)"),
                specCID: testCID("quotient-cost:spec:\(name)"),
                target: "1",
                nextTarget: "1",
                timestamp: Int64(height)
            )),
            .work(ChainWorkFact(
                blockHash: hash,
                contribution: VerifiedWorkContribution(
                    id: testCID("quotient-cost:work:\(name)"),
                    work: UInt256(work)
                )
            )),
        ])
        return (hash, batch)
    }

    func testForkFreeRunCostAcrossTheDeletion() async throws {
        var steadyBlocks: [Int: UInt64] = [:]
        var steadySteps: [Int: UInt64] = [:]
        var fullBlocks: [Int: UInt64] = [:]
        var fullSteps: [Int: UInt64] = [:]

        for length in [200, 800] {
            let root = admission("root-\(length)", parent: nil, height: 0, work: 4)
            var chain = try ChainTree.restoreWithoutContext(replaying: [root.batch])

            let blocksBefore = chain.canonicalProjectionBlockVisitCount
            let stepsBefore = chain.canonicalProjectionSegmentVisitCount
            var previousHash = root.hash
            for height in 1...length {
                let next = admission(
                    "b-\(length)-\(height)",
                    parent: previousHash,
                    height: UInt64(height),
                    work: 4
                )
                _ = try chain.applyStaged(next.batch)
                previousHash = next.hash
            }
            steadyBlocks[length] = chain.canonicalProjectionBlockVisitCount
                - blocksBefore
            steadySteps[length] = chain.canonicalProjectionSegmentVisitCount
                - stepsBefore

            // An exclusion rebuilds the fork-choice index and reprojects with
            // `forceFull`, so this is the whole-chain descent over a run that
            // used to be a single segment.
            let blocksAtFull = chain.canonicalProjectionBlockVisitCount
            let stepsAtFull = chain.canonicalProjectionSegmentVisitCount
            _ = try? chain.applyStaged(BlockImportBatch(facts: [
                .exclusion(ChainExclusionFact(blockHash: previousHash)),
            ]))
            fullBlocks[length] = chain.canonicalProjectionBlockVisitCount
                - blocksAtFull
            fullSteps[length] = chain.canonicalProjectionSegmentVisitCount
                - stepsAtFull
        }

        // The SAME two costs on the shape Lattice actually has: a losing sibling
        // at every height. There the quotient was already degenerate — one
        // segment per block, segments walked exactly equalling blocks
        // materialized — so removing it should change nothing at all. Measuring
        // only the fork-free shape would report the quotient's best case as if
        // it were the workload.
        var mergedSteadySteps: [Int: UInt64] = [:]
        var mergedFullSteps: [Int: UInt64] = [:]
        for length in [200, 800] {
            let root = admission("m-root-\(length)", parent: nil, height: 0, work: 4)
            var chain = try ChainTree.restoreWithoutContext(replaying: [root.batch])
            let stepsBefore = chain.canonicalProjectionSegmentVisitCount
            var previousHash = root.hash
            for height in 1...length {
                let side = admission(
                    "m-side-\(length)-\(height)",
                    parent: previousHash,
                    height: UInt64(height),
                    work: 1
                )
                _ = try chain.applyStaged(side.batch)
                let next = admission(
                    "m-main-\(length)-\(height)",
                    parent: previousHash,
                    height: UInt64(height),
                    work: 4
                )
                _ = try chain.applyStaged(next.batch)
                previousHash = next.hash
            }
            mergedSteadySteps[length] = chain
                .canonicalProjectionSegmentVisitCount - stepsBefore

            let stepsAtFull = chain.canonicalProjectionSegmentVisitCount
            _ = try? chain.applyStaged(BlockImportBatch(facts: [
                .exclusion(ChainExclusionFact(blockHash: previousHash)),
            ]))
            mergedFullSteps[length] = chain
                .canonicalProjectionSegmentVisitCount - stepsAtFull
        }

        let measured = "steadyBlocks \(steadyBlocks) steadySteps \(steadySteps)"
            + " fullBlocks \(fullBlocks) fullSteps \(fullSteps)"
            + " mergedSteadySteps \(mergedSteadySteps)"
            + " mergedFullSteps \(mergedFullSteps)"
        // Measured on BOTH sides of the deletion, at lengths 200 and 800:
        //
        //                                  with quotient     without
        //   fork-free steady blocks          200 /  800     200 /  800
        //   fork-free steady steps           200 /  800     200 /  800
        //   fork-free full-projection blocks 200 /  800     200 /  800
        //   fork-free full-projection steps    1 /    1     200 /  800
        //   merged steady steps              400 / 1600     400 / 1600
        //   merged full-projection steps     200 /  800     201 /  801
        //
        // Steady state is identical on both shapes: nothing on the admission
        // path changed. The one cost is the forced whole-chain projection on a
        // fork-free run, where steps go 1 -> n. Blocks on that path were already
        // n on both sides, so an already-linear path gains a second linear term
        // — a 2x constant, not a complexity change — and it is reached only by
        // an exclusion, a never-projected state, or a failed guard, never by an
        // admission. On the merged-mining shape, which is the workload, the cost
        // of the deletion is one extra step in 801: the quotient was already one
        // segment per block there and compressed nothing.
        //
        // NOTE ON WHAT THESE ASSERTIONS ARE. The bounds below are FORWARD
        // guards, not discriminators: every one of them also passes on the code
        // this PR deletes, because that code's numbers are smaller everywhere.
        // Deleting a structure makes "nothing got slower" trivially true, so the
        // load-bearing assertion here is the steady-state one — a descent that
        // went back to walking from the root would blow it, which is the
        // regression this deletion could actually cause.
        for length in [200, 800] {
            XCTAssertLessThanOrEqual(
                steadySteps[length]!,
                UInt64(2 * length),
                "steady descent must stay one step per admission: \(measured)"
            )
            XCTAssertLessThanOrEqual(
                mergedSteadySteps[length]!,
                UInt64(4 * length),
                "merged steady descent must stay per-admission: \(measured)"
            )
        }
        XCTAssertLessThanOrEqual(
            fullSteps[800]!,
            fullSteps[200]! * 8,
            "the whole-chain projection must stay linear: \(measured)"
        )
        XCTAssertLessThanOrEqual(
            mergedFullSteps[800]!,
            mergedFullSteps[200]! * 8,
            "and stay linear on the merged shape too: \(measured)"
        )
    }
}
