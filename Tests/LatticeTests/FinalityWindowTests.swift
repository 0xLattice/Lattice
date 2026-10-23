import XCTest
import UInt256
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeBlockTree

/// Node-local finality (§9.11): which attachments land beyond a window, and
/// the work a deep branch must prove there.
final class FinalityWindowTests: XCTestCase {
    private let window: Int64 = 10_000

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

    ///     g ── a ── b ── c ── t        canonical
    ///          │         └── live      inside the window
    ///          └── x                   an old side branch
    private func tree() throws -> ChainTree {
        try ChainTree.restoreWithoutContext(replaying: [
            batch("g", parent: nil, height: 0, work: 1, time: 0),
            batch("a", parent: "g", height: 1, work: 50, time: 1_000),
            batch("b", parent: "a", height: 2, work: 50, time: 2_000),
            batch("c", parent: "b", height: 3, work: 50, time: 20_000),
            batch("t", parent: "c", height: 4, work: 50, time: 30_000),
            batch("x", parent: "a", height: 2, work: 7, time: 1_500),
            batch("live", parent: "c", height: 4, work: 3, time: 25_000),
        ])
    }

    func testWindowIsMeasuredFromTheTip() throws {
        let tree = try tree()
        XCTAssertEqual(tree.windowStart(windowMilliseconds: window), 20_000)
        XCTAssertTrue(tree.isBeyondWindow(h("g"), windowMilliseconds: window))
        XCTAssertTrue(tree.isBeyondWindow(h("x"), windowMilliseconds: window))
        XCTAssertFalse(tree.isBeyondWindow(h("c"), windowMilliseconds: window), "at the start is inside")
        XCTAssertFalse(tree.isBeyondWindow(h("live"), windowMilliseconds: window))
        XCTAssertFalse(tree.isBeyondWindow(h("nowhere"), windowMilliseconds: window), "not held")
        XCTAssertFalse(tree.isBeyondWindow(h("b"), windowMilliseconds: 1_000_000), "a long window")
    }

    func testTheTipIsNeverBeyond() throws {
        let tree = try ChainTree.restoreWithoutContext(replaying: [
            batch("g", parent: nil, height: 0, work: 1, time: 0),
            batch("a", parent: "g", height: 1, work: 50, time: 1_000),
        ])
        XCTAssertFalse(tree.isBeyondWindow(h("a"), windowMilliseconds: 0), "a stalled chain stays extendable")
        XCTAssertTrue(tree.isBeyondWindow(h("g"), windowMilliseconds: 0))
    }

    func testDeepForkBar() throws {
        let tree = try tree()
        XCTAssertNil(tree.deepForkBar(attachingTo: h("t"), windowMilliseconds: window), "the tip")
        XCTAssertNil(tree.deepForkBar(attachingTo: h("c"), windowMilliseconds: window), "inside the window")
        XCTAssertNil(tree.deepForkBar(attachingTo: h("nowhere"), windowMilliseconds: window), "not held")
        XCTAssertEqual(tree.deepForkBar(attachingTo: h("g"), windowMilliseconds: window),
                       tree.forkChoiceWeight(of: h("a")),
                       "a new height-1 sibling must outweigh the whole canonical chain")
        XCTAssertEqual(tree.deepForkBar(attachingTo: h("b"), windowMilliseconds: window),
                       tree.forkChoiceWeight(of: h("c")))
        // b's subtree (b, c, t, live) against x's own weight.
        XCTAssertEqual(tree.deepForkBar(attachingTo: h("x"), windowMilliseconds: window),
                       WorkSum(UInt256(50 + 50 + 50 + 3 - 7)))
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
