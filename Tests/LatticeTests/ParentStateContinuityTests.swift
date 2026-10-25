import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import UInt256

final class ParentStateContinuityTests: XCTestCase {
    private func batch(
        _ block: String,
        parent: String?,
        height: UInt64,
        from: String,
        to: String,
        nonce: Int64
    ) -> BlockImportBatch {
        BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: block,
                parentBlockHash: parent,
                blockHeight: height,
                postStateCID: to,
                prevStateCID: from,
                specCID: testCID("continuity-spec"),
                target: UInt256.max.toHexString(),
                nextTarget: UInt256.max.toHexString(),
                timestamp: nonce,
                stateDiff: .empty
            )),
            .work(ChainWorkFact(
                blockHash: block,
                contribution: VerifiedWorkContribution(
                    id: testCID("continuity-grind-\(nonce)"),
                    work: 1
                )
            )),
            // These fixtures model EXECUTED blocks: continuity attests only
            // states the chain actually produced, so a fixture without this
            // fact describes a weighed claim and is correctly unattestable.
            .validation(ChainValidationFact(blockHash: block)),
        ])
    }

    func testContinuityIsReflexiveTransitiveAndCanonicityIndependent()
        async throws {
        let a = testCID("state-a")
        let b = testCID("state-b")
        let c = testCID("state-c")
        let d = testCID("state-d")
        let e = testCID("state-e")
        let z = testCID("state-z")
        let root = testCID("parent-root")
        let left = testCID("parent-left")
        let right = testCID("parent-right")
        let leftTip = testCID("parent-left-tip")
        let rightTip = testCID("parent-right-tip")
        let orphan = testCID("parent-orphan")
        let chain = try await ChainState.restoreWithoutContext(replaying: [
            batch(root, parent: nil, height: 0, from: a, to: b, nonce: 1),
            batch(left, parent: root, height: 1, from: b, to: c, nonce: 2),
            batch(right, parent: root, height: 1, from: b, to: d, nonce: 3),
            batch(leftTip, parent: left, height: 2, from: c, to: e, nonce: 4),
            batch(rightTip, parent: right, height: 2, from: d, to: e, nonce: 5),
            batch(
                orphan,
                parent: testCID("missing-parent"),
                height: 2,
                from: d,
                to: z,
                nonce: 6
            ),
        ])

        let reflexive = await chain.hasStateContinuity(from: b, to: b)
        let transitive = await chain.hasStateContinuity(from: a, to: c)
        let leftBranch = await chain.hasStateContinuity(from: b, to: c)
        let rightBranch = await chain.hasStateContinuity(from: b, to: d)
        let backward = await chain.hasStateContinuity(from: c, to: a)
        let sideways = await chain.hasStateContinuity(from: c, to: d)
        XCTAssertTrue(reflexive)
        XCTAssertTrue(transitive)
        XCTAssertTrue(leftBranch)
        XCTAssertTrue(rightBranch)
        XCTAssertFalse(backward)
        XCTAssertFalse(sideways)
        let repeatedLeft = await chain.hasStateContinuity(from: c, to: e)
        let repeatedRight = await chain.hasStateContinuity(from: d, to: e)
        let disconnected = await chain.hasStateContinuity(from: d, to: z)
        XCTAssertTrue(repeatedLeft)
        XCTAssertTrue(repeatedRight)
        XCTAssertFalse(disconnected)
        // Continuity carries no visit budget: the answer is a property of the
        // graph, not of how hard a node is willing to look. A budget would make
        // the same question answerable on one node and unanswerable on another
        // from identical data, splitting honest nodes by local policy.
        let unbudgeted = await chain.hasStateContinuity(from: a, to: c)
        XCTAssertTrue(unbudgeted)
#if DEBUG
        let visits = await chain.stateContinuityBlockVisitCount
        let absent = await chain.hasStateContinuity(
            from: a,
            to: testCID("absent-target")
        )
        let visitsAfterAbsent = await chain.stateContinuityBlockVisitCount
        XCTAssertFalse(absent)
        XCTAssertEqual(visitsAfterAbsent, visits)
#endif
    }

    func testContinuityReverseSearchSkipsNoOpStateTransitions() async throws {
        let a = testCID("state-a")
        let b = testCID("state-b")
        let root = testCID("parent-root")
        var batches = [
            batch(root, parent: nil, height: 0, from: a, to: b, nonce: 1)
        ]
        var parent = root
        for height in 1...100 {
            let block = testCID("parent-no-op-\(height)")
            batches.append(batch(
                block,
                parent: parent,
                height: UInt64(height),
                from: b,
                to: b,
                nonce: Int64(height + 1)
            ))
            parent = block
        }
        let chain = try await ChainState.restoreWithoutContext(replaying: batches)

        let reflexive = await chain.hasStateContinuity(from: b, to: b)
        XCTAssertTrue(reflexive)
#if DEBUG
        let visits = await chain.stateContinuityBlockVisitCount
#endif
        let unrelated = await chain.hasStateContinuity(
            from: testCID("unrelated-state"),
            to: b
        )
        XCTAssertFalse(unrelated)
#if DEBUG
        let visitsAfterQuery = await chain.stateContinuityBlockVisitCount
        XCTAssertEqual(visitsAfterQuery - visits, 1)
#endif
    }
}
