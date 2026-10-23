import XCTest
import UInt256
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeBlockTree

/// Folding side branches (§9.7): a tree restored from compacted facts makes
/// every fork-choice comparison the archive tree makes, keeps every held
/// run, and hands child chains the same attributed weight.
final class FoldSideBranchTests: XCTestCase {

    private let d = "Payments"
    private let window: Int64 = 10_000

    private func h(_ name: String) -> String { testCID("block:\(name)") }
    private func grind(_ name: String) -> String { testCID("work:\(name)") }

    private func batch(
        _ hash: String, parent: String?, height: UInt64, work: UInt64,
        time: Int64, commits: [String: String] = [:]
    ) -> BlockImportBatch {
        BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: h(hash), parentBlockHash: parent.map(h), blockHeight: height,
                postStateCID: testCID("post:\(hash)"), prevStateCID: testCID("prev:\(hash)"),
                specCID: testCID("spec"), target: "1", nextTarget: "1",
                timestamp: time, stateDiff: .empty, childCommitments: commits
            )),
            .work(ChainWorkFact(
                blockHash: h(hash),
                contribution: VerifiedWorkContribution(id: grind(hash), work: UInt256(work))
            )),
        ])
    }

    /// A child block credited under the grind of the parent block that
    /// committed it.
    private func childBatch(_ hash: String, parent: String?, height: UInt64, carrier: String) -> BlockImportBatch {
        BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: hash, parentBlockHash: parent, blockHeight: height,
                postStateCID: testCID("cpost:\(hash)"), prevStateCID: testCID("cprev:\(hash)"),
                specCID: testCID("cspec"), target: "1", nextTarget: "1",
                timestamp: Int64(height), stateDiff: .empty
            )),
            .work(ChainWorkFact(
                blockHash: hash,
                contribution: VerifiedWorkContribution(id: grind(carrier), work: UInt256(1))
            )),
        ])
    }

    private func restore(_ batches: [BlockImportBatch]) throws -> ChainTree {
        var tree = try ChainTree.restoreWithoutContext(replaying: batches)
        tree.serveRuns(for: d)
        return tree
    }

    private func compacted(
        _ batches: [BlockImportBatch], plan: ChainFoldPlan
    ) -> [BlockImportBatch] {
        batches.filter(plan.retains) + plan.batches
    }

    /// Every comparison the compacted tree can still make, made the same way.
    private func assertSameChoices(
        _ archive: ChainTree, _ folded: ChainTree, _ note: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(folded.canonicalTip, archive.canonicalTip, note, file: file, line: line)
        for record in folded.graph.records {
            let hash = record.blockHash
            XCTAssertEqual(
                folded.forkChoiceWeight(of: hash), archive.forkChoiceWeight(of: hash),
                "weight at \(hash) \(note)", file: file, line: line
            )
            XCTAssertEqual(
                folded.runs.runWork[d]?[hash], archive.runs.runWork[d]?[hash],
                "run at \(hash) \(note)", file: file, line: line
            )
        }
    }

    // MARK: - Fixtures

    /// g ← a ← b ← c ← t (canonical, heavy), with dead branches off g, a and
    /// b, a carrier inside one of them, and a live branch off c.
    ///
    ///     g ── a ── b ── c ── t
    ///     │    │    │    └── live (inside the window)
    ///     │    │    └── s1 (commits cs1) ── s2
    ///     │    └── x
    ///     └── junk1, junk2   (free height-1 siblings)
    private func scenario() -> [BlockImportBatch] {
        [
            batch("g", parent: nil, height: 0, work: 1, time: 0),
            batch("a", parent: "g", height: 1, work: 50, time: 1_000, commits: [d: testCID("ca")]),
            batch("b", parent: "a", height: 2, work: 50, time: 2_000),
            batch("c", parent: "b", height: 3, work: 50, time: 20_000),
            batch("t", parent: "c", height: 4, work: 50, time: 30_000),
            batch("junk1", parent: "g", height: 1, work: 1, time: 1),
            batch("junk2", parent: "g", height: 1, work: 1, time: 2),
            batch("x", parent: "a", height: 2, work: 7, time: 1_500),
            batch("s1", parent: "b", height: 3, work: 9, time: 2_500, commits: [d: testCID("cs1")]),
            batch("s2", parent: "s1", height: 4, work: 4, time: 2_600),
            batch("live", parent: "c", height: 4, work: 3, time: 25_000),
        ]
    }

    // MARK: - Plan

    func testFoldsOnlyBranchesWhollyBeyondTheWindow() throws {
        let tree = try restore(scenario())
        let plan = tree.foldPlan(windowMilliseconds: window)
        XCTAssertEqual(plan.folded, Set(["junk1", "junk2", "x", "s1", "s2"].map(h)))
        XCTAssertEqual(Set(plan.batches.flatMap { $0.facts.map(\.blockHash) }), Set(["g", "a", "b"].map(h)))
        let none = tree.foldPlan(windowMilliseconds: 100_000)
        XCTAssertTrue(none.isEmpty, "everything is inside a long window")
    }

    func testFoldWorkIsTheFoldedSubtreeWeight() throws {
        let tree = try restore(scenario())
        let plan = tree.foldPlan(windowMilliseconds: window)
        let facts = Dictionary(uniqueKeysWithValues: plan.batches.compactMap { batch -> (String, ChainFoldFact)? in
            guard case .fold(let fact) = batch.facts[0] else { return nil }
            return (fact.blockHash, fact)
        })
        XCTAssertEqual(facts[h("g")]?.work, UInt256(2))
        XCTAssertEqual(facts[h("a")]?.work, UInt256(7))
        XCTAssertEqual(facts[h("b")]?.work, UInt256(13))
        XCTAssertEqual(facts[h("b")]?.covered[d], UInt256(13), "s1 carries all of its branch")
        XCTAssertEqual(facts[h("b")]?.frozenRuns, [FrozenRun(
            carrierBlockHash: h("s1"), directory: d, childBlockHash: testCID("cs1"), value: UInt256(4)
        )])
    }

    func testPinnedAndExecutedBranchesAreKept() throws {
        var batches = scenario()
        let pinned = try restore(batches).foldPlan(windowMilliseconds: window, pinned: [h("s2")])
        XCTAssertFalse(pinned.folded.contains(h("s1")))
        XCTAssertFalse(pinned.folded.contains(h("s2")))

        batches.append(.validation(blockHash: h("g")))
        batches.append(.validation(blockHash: h("x")))
        batches.append(.validation(blockHash: h("a")))
        let tree = try restore(batches)
        XCTAssertFalse(tree.foldPlan(windowMilliseconds: window).folded.contains(h("x")),
                       "an executed block is kept for child continuity")
        XCTAssertTrue(tree.foldPlan(windowMilliseconds: window, executedWindowMilliseconds: window)
            .folded.contains(h("x")), "until the executed window passes it")
    }

    // MARK: - Equivalence

    func testCompactedTreeMakesTheArchivesChoices() throws {
        let batches = scenario()
        let archive = try restore(batches)
        let plan = archive.foldPlan(windowMilliseconds: window)
        let folded = try restore(compacted(batches, plan: plan))
        assertSameChoices(archive, folded, "after one fold")
        XCTAssertEqual(folded.graph.records.count, archive.graph.records.count - plan.folded.count)
    }

    func testFoldingTwiceAccumulates() throws {
        var batches = scenario()
        let first = try restore(batches).foldPlan(windowMilliseconds: window)
        var durable = compacted(batches, plan: first)
        let more = [
            batch("u", parent: "t", height: 5, work: 50, time: 60_000),
            batch("y", parent: "a", height: 2, work: 5, time: 1_700),
        ]
        batches += more
        durable += more
        let archive = try restore(batches)
        let second = try restore(durable).foldPlan(windowMilliseconds: window)
        let folded = try restore(compacted(durable, plan: second))
        assertSameChoices(archive, folded, "after two folds")
        XCTAssertEqual(durable.filter(second.retains).filter {
            if case .fold = $0.facts[0] { return true } else { return false }
        }.count, 2, "the second plan supersedes a's fold; g's and b's stand")
    }

    /// A random tree, folded at a random window, against its archive — and
    /// against a child chain deriving runs from each.
    func testRandomTreesFoldEquivalently() throws {
        let seed = propertySeed()
        var rng = seed.generator()
        var foldedBlocks = 0, frozenRuns = 0, refoldedBlocks = 0
        for round in 0..<40 {
            var batches = [batch("r\(round)-0", parent: nil, height: 0, work: 1, time: 0)]
            var heights = [UInt64(0)]
            var times = [Int64(0)]
            var names = ["r\(round)-0"]
            var childBatches = [childBatch(testCID("child-g-\(round)"), parent: nil, height: 0, carrier: "none-\(round)")]
            var lastChild = testCID("child-g-\(round)")
            var childHeight: UInt64 = 0
            for i in 1..<60 {
                let parentIndex = Bool.random(using: &rng)
                    ? names.count - 1
                    : Int.random(in: 0..<names.count, using: &rng)
                let name = "r\(round)-\(i)"
                let commits = Int.random(in: 0..<4, using: &rng) == 0
                    ? [d: testCID("child-\(name)")] : [:]
                batches.append(batch(
                    name, parent: names[parentIndex], height: heights[parentIndex] + 1,
                    work: UInt64.random(in: 1...20, using: &rng),
                    time: times[parentIndex] + Int64.random(in: 1...2_000, using: &rng),
                    commits: commits
                ))
                names.append(name)
                heights.append(heights[parentIndex] + 1)
                times.append(times[parentIndex] + 1)
                times[times.count - 1] = {
                    if case .block(let fact) = batches.last!.facts[0] { return fact.timestamp }
                    return 0
                }()
                if !commits.isEmpty {
                    childHeight += 1
                    let child = testCID("child-\(name)")
                    childBatches.append(childBatch(child, parent: lastChild, height: childHeight, carrier: name))
                    lastChild = child
                }
            }
            let window = Int64.random(in: 0...20_000, using: &rng)
            let note = "round \(round) window \(window) \(seed.note)"
            let archive = try restore(batches)
            // First with some side blocks pinned, then with the pins
            // released: a block holding a fold is itself folded.
            let pins = Set(names.filter { _ in Int.random(in: 0..<5, using: &rng) == 0 }.map(h))
            let first = archive.foldPlan(windowMilliseconds: window, pinned: pins)
            var durable = compacted(batches, plan: first)
            let pinnedTree = try restore(durable.shuffled(using: &rng))
            assertSameChoices(archive, pinnedTree, "pinned \(note)")
            let second = pinnedTree.foldPlan(windowMilliseconds: window)
            durable = compacted(durable, plan: second)
            let folded = try restore(durable.shuffled(using: &rng))
            assertSameChoices(archive, folded, note)
            foldedBlocks += first.folded.count + second.folded.count
            frozenRuns += folded.runs.frozen[d]?.count ?? 0
            refoldedBlocks += second.folded.filter { pinnedTree.graph.fold(at: $0) != nil }.count

            var fromArchive = try ChainTree.restoreWithoutContext(replaying: childBatches)
            var fromFolded = try ChainTree.restoreWithoutContext(replaying: childBatches)
            fromArchive.applyParentRun(from: archive, directory: d)
            fromFolded.applyParentRun(from: folded, directory: d)
            for record in fromArchive.graph.records {
                XCTAssertEqual(
                    fromFolded.graph.work(of: record.blockHash)?.contributions,
                    fromArchive.graph.work(of: record.blockHash)?.contributions,
                    "child credit at \(record.blockHash) \(note)"
                )
            }
            XCTAssertEqual(fromFolded.canonicalTip, fromArchive.canonicalTip, note)
        }
        // The property only means something if the generator reaches the cases.
        XCTAssertGreaterThan(foldedBlocks, 100, seed.note)
        XCTAssertGreaterThan(frozenRuns, 5, seed.note)
        XCTAssertGreaterThan(refoldedBlocks, 0, seed.note)
    }

    /// Live work after a compaction lands the same way it would have.
    func testLiveInsertAfterFoldingMatches() throws {
        let batches = scenario()
        var archive = try restore(batches)
        var folded = try restore(compacted(batches, plan: archive.foldPlan(windowMilliseconds: window)))
        let next = batch("v", parent: "live", height: 5, work: 200, time: 31_000)
        _ = try archive.replay(next)
        _ = try folded.replay(next)
        assertSameChoices(archive, folded, "after a heavy block on the live branch")
        XCTAssertEqual(folded.canonicalTip, h("v"))
    }

    // MARK: - Deep-fork bar

    func testDeepForkBar() throws {
        let tree = try restore(scenario())
        XCTAssertNil(tree.deepForkBar(attachingTo: h("t"), windowMilliseconds: window), "the tip")
        XCTAssertNil(tree.deepForkBar(attachingTo: h("c"), windowMilliseconds: window), "inside the window")
        XCTAssertNil(tree.deepForkBar(attachingTo: h("nowhere"), windowMilliseconds: window), "not held")
        let underGenesis = try XCTUnwrap(tree.deepForkBar(attachingTo: h("g"), windowMilliseconds: window))
        XCTAssertEqual(underGenesis, tree.forkChoiceWeight(of: h("a")),
                       "a new height-1 sibling must outweigh the whole canonical chain")
        let underX = try XCTUnwrap(tree.deepForkBar(attachingTo: h("x"), windowMilliseconds: window))
        // b's subtree (b, c, t, s1, s2, live) against x's own weight.
        XCTAssertEqual(underX, WorkSum(UInt256(50 + 50 + 50 + 9 + 4 + 3 - 7)),
                       "the side's own weight counts toward the bar")
    }

    /// A folded block sent again attaches beyond the window, where its work
    /// can never clear the bar: the gate is the dedup a tombstone would be.
    func testRedeliveredFoldedBlockCannotClearTheBar() throws {
        let batches = scenario()
        let archive = try restore(batches)
        let folded = try restore(compacted(batches, plan: archive.foldPlan(windowMilliseconds: window)))
        let bar = try XCTUnwrap(folded.deepForkBar(attachingTo: h("b"), windowMilliseconds: window))
        XCTAssertGreaterThan(bar, WorkSum(UInt256(9 + 4)))
    }

    // MARK: - Reducer

    func testFoldFactRatchetsAndIgnoresWeaker() throws {
        let batches = scenario()
        var tree = try restore(batches)
        let fact = ChainFoldFact(blockHash: h("a"), work: UInt256(10), covered: [:], frozenRuns: [])
        let weaker = ChainFoldFact(blockHash: h("a"), work: UInt256(5), covered: [:], frozenRuns: [])
        let before = try XCTUnwrap(tree.forkChoiceWeight(of: h("a")))
        _ = try tree.replay(BlockImportBatch(facts: [.fold(fact)]))
        XCTAssertNil(try tree.replay(BlockImportBatch(facts: [.fold(weaker)])))
        XCTAssertEqual(tree.forkChoiceWeight(of: h("a")), before + UInt256(10))
        XCTAssertEqual(tree.graph.work(of: h("a"))?.grindWork, WorkSum(UInt256(50)), "a fold is not a grind")
    }

    func testFoldForAMissingBlockDefersThenApplies() throws {
        let fold = BlockImportBatch(facts: [.fold(
            ChainFoldFact(blockHash: h("b"), work: UInt256(3), covered: [:], frozenRuns: [])
        )])
        let tree = try restore([fold] + scenario())
        XCTAssertEqual(tree.graph.fold(at: h("b"))?.work, UInt256(3))
    }

    func testMalformedFoldIsCorrupt() {
        let over = BlockImportBatch(facts: [.fold(
            ChainFoldFact(blockHash: h("b"), work: UInt256(3), covered: [d: UInt256(4)], frozenRuns: [])
        )])
        XCTAssertThrowsError(try restore(scenario() + [over]))
    }
}
