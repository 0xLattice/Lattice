import XCTest
import UInt256
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeBlockTree

/// Children are found through the graph's by-parent index.
final class ChildrenByParentTests: XCTestCase {
    private func h(_ name: String) -> String { testCID("block:\(name)") }

    private func batch(_ name: String, parent: String?, height: UInt64, work: UInt64, time: Int64) -> BlockImportBatch {
        BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: h(name), parentBlockHash: parent.map(h), blockHeight: height,
                postStateCID: testCID("post:\(name)"), prevStateCID: testCID("prev:\(name)"),
                specCID: testCID("spec"), target: "1", nextTarget: "1",
                timestamp: time, stateDiff: .empty
            )),
            .work(ChainWorkFact(
                blockHash: h(name),
                contribution: VerifiedWorkContribution(id: testCID("work:\(name)"), work: UInt256(work))
            )),
        ])
    }

    /// Children are found by parent, whatever else sits at their height.
    func testOrphansGraftByParentAmongManySiblings() throws {
        var batches = [batch("g", parent: nil, height: 0, work: 1, time: 0)]
        for i in 0..<200 { batches.append(batch("s\(i)", parent: "g", height: 1, work: 1, time: Int64(10 + i))) }
        batches.append(batch("orphan", parent: "late", height: 2, work: 5, time: 500))
        var tree = try ChainTree.restoreWithoutContext(replaying: batches)
        XCTAssertNil(tree.forkChoiceWeight(of: h("orphan")), "not connected yet")
        _ = try tree.replay(batch("late", parent: "g", height: 1, work: 9, time: 400))
        XCTAssertEqual(tree.forkChoiceWeight(of: h("late")), WorkSum(UInt256(14)))
        XCTAssertEqual(tree.canonicalTip, h("orphan"))
    }
}
