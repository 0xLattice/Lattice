import XCTest
import UInt256
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport

/// Parent-fork completeness for attributed run work (§9.10).
///
/// The failure being ruled out: a parent chain fork whose branches commit
/// into DIFFERENT blocks of one child subtree, where a naive "subtree under
/// the committer" formula misses a branch (an under-count), or a naive "raw
/// subtree" formula counts a branch twice (an over-count). The oracle below is
/// written from first principles — every connected parent block's work is
/// counted at exactly one child block, the one its nearest committer names —
/// and every scenario, hand-drawn and random, is checked against it at EVERY
/// child block, because every child block's subtree total is a fork-choice
/// input.
///
/// The child derives its attributed runs from the parent tree
/// (`applyParentRun`), one committer at a time, exactly as a host does.
final class ParentForkAttributionTests: XCTestCase {

    // MARK: - Scenario model

    private struct ParentBlock {
        let name: String
        let parent: String?
        let work: UInt64
        /// directory → child block name
        var commits: [String: String] = [:]
        /// The label of the state it was applied to (`prevState`).
        var state = "s"
    }

    private struct ChildBlock {
        let name: String
        let parent: String?
        /// The child's own price for every carrier grind credited here.
        let price: UInt64
        /// The label of the parent state it anchors to (`parentState`): only
        /// a committer applied to that state credits it its run (§9.10).
        var anchor = "s"
    }

    private struct Scenario {
        let directory: String
        let parent: [ParentBlock]
        let child: [ChildBlock]
    }

    private func h(_ name: String) -> String { testCID("block:\(name)") }
    private func grind(_ name: String) -> String { testCID("work:\(name)") }
    private func sum(_ v: UInt64) -> WorkSum { WorkSum(UInt256(v)) }

    // MARK: - Oracle (independent of Chain.swift)

    /// Expected subtree weight at every child block. For each child block Y:
    ///   own price × #committers of Y (each carrier grind, at the child's price;
    ///   an uncommitted block — genesis — carries one own grind at its price)
    /// + Σ work(Q) over connected parent blocks Q that are NOT themselves
    ///   committers into `d` and whose nearest committer into `d` commits Y
    ///   from the state Y anchors to.
    /// Then sum over the child subtree.
    private func oracle(_ s: Scenario) -> [String: WorkSum] {
        let parentByName = Dictionary(uniqueKeysWithValues: s.parent.map { ($0.name, $0) })
        func connected(_ name: String) -> Bool {
            var cursor: String? = name
            while let n = cursor {
                guard let b = parentByName[n] else { return false }
                cursor = b.parent
            }
            return true
        }
        func nearestCommitter(_ name: String) -> String? {
            var cursor: String? = name
            while let n = cursor, let b = parentByName[n] {
                if b.commits[s.directory] != nil { return n }
                cursor = b.parent
            }
            return nil
        }
        // Attributed work landing at each child block, by the committer's target.
        let childByName = Dictionary(uniqueKeysWithValues: s.child.map { ($0.name, $0) })
        var attributedAt: [String: UInt64] = [:]
        for q in s.parent where connected(q.name) && q.commits[s.directory] == nil {
            if let p = nearestCommitter(q.name), let committer = parentByName[p],
               let target = committer.commits[s.directory],
               childByName[target]?.anchor == committer.state {
                attributedAt[target, default: 0] += q.work
            }
        }
        var committerCount: [String: Int] = [:]
        for p in s.parent where connected(p.name) {
            if let target = p.commits[s.directory] { committerCount[target, default: 0] += 1 }
        }
        var ownAt: [String: UInt64] = [:]
        for c in s.child {
            let carriers = committerCount[c.name] ?? 0
            ownAt[c.name] = c.price * UInt64(max(carriers, 1)) + (attributedAt[c.name] ?? 0)
        }
        var childrenOf: [String: [String]] = [:]
        for c in s.child { if let p = c.parent { childrenOf[p, default: []].append(c.name) } }
        var out: [String: WorkSum] = [:]
        func total(_ name: String) -> UInt64 {
            (ownAt[name] ?? 0) + (childrenOf[name] ?? []).map(total).reduce(0, +)
        }
        for c in s.child { out[c.name] = sum(total(c.name)) }
        return out
    }

    // MARK: - Mechanism (what the node does)

    private func parentBatch(_ b: ParentBlock, height: UInt64) -> BlockImportBatch {
        BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: h(b.name), parentBlockHash: b.parent.map(h), blockHeight: height,
                postStateCID: testCID("post:\(b.name)"), prevStateCID: testCID("prev:\(b.state)"),
                specCID: testCID("spec"), target: "1", nextTarget: "1",
                timestamp: Int64(1_000 + height), stateDiff: .empty,
                childCommitments: b.commits.mapValues(h)
            )),
            .work(ChainWorkFact(
                blockHash: h(b.name),
                contribution: VerifiedWorkContribution(id: grind(b.name), work: UInt256(b.work))
            )),
        ])
    }

    private func heights<T>(_ blocks: [T], name: (T) -> String, parent: (T) -> String?) -> [String: UInt64] {
        let byName = Dictionary(uniqueKeysWithValues: blocks.map { (name($0), $0) })
        func height(_ n: String) -> UInt64 {
            guard let b = byName[n], let p = parent(b) else { return 0 }
            return height(p) + 1
        }
        return Dictionary(uniqueKeysWithValues: blocks.map { (name($0), height(name($0))) })
    }

    /// Build the parent by replay in `order`, the child by construction, then
    /// derive every committer's run at the child — each `passes` times, in
    /// `order`, so idempotence is exercised too.
    private func run(
        _ s: Scenario, order: [Int], passes: Int = 2
    ) async throws -> (parent: ChainState, child: ChainState, strengthened: Int) {
        let ph = heights(s.parent, name: \.name, parent: \.parent)
        let batches = s.parent.map { parentBatch($0, height: ph[$0.name]!) }
        // The genesis must seed the restore; everything else in the given order.
        let genesisIndex = s.parent.firstIndex { $0.parent == nil }!
        let parent = try await ChainState.restoreWithoutContext(replaying: [batches[genesisIndex]])
        // Serve the directory before OR after the graph exists — the two paths
        // (per-block settle, whole-graph settle) must agree, so alternate by
        // the order's shape and let the oracle judge both.
        let serveFirst = order.first.map { $0 % 2 == 0 } ?? true
        if serveFirst { await parent.serveRuns(for: s.directory) }
        for i in order where i != genesisIndex {
            _ = try await parent.replay(batches[i])
        }
        if !serveFirst { await parent.serveRuns(for: s.directory) }

        // Child: every committer's grind at the child's price; genesis its own.
        var carriers: [String: [String]] = [:]
        for p in s.parent { if let t = p.commits[s.directory] { carriers[t, default: []].append(p.name) } }
        let ch = heights(s.child, name: \.name, parent: \.parent)
        var childrenOf: [String: [String]] = [:]
        for c in s.child { if let p = c.parent { childrenOf[p, default: []].append(c.name) } }
        let child = makeChain(blocks: s.child.map { c in
            let grinds = (carriers[c.name] ?? []).map(grind)
            return BlockMeta(
                blockHash: h(c.name), parentBlockHash: c.parent.map(h), blockHeight: ch[c.name]!,
                childHashes: (childrenOf[c.name] ?? []).map(h),
                workContributions: (grinds.isEmpty ? [grind(c.name)] : grinds).map {
                    VerifiedWorkContribution(id: $0, work: UInt256(c.price))
                }
            )
        }, snapshots: Dictionary(uniqueKeysWithValues: s.child.map { c in
            (h(c.name), TipBlockSnapshot(
                postStateCID: testCID("cpost:\(c.name)"), prevStateCID: testCID("cprev:\(c.name)"),
                parentStateCID: testCID("prev:\(c.anchor)"), specCID: testCID("cspec"),
                target: UInt256(1), nextTarget: UInt256(1), tipHeight: ch[c.name]!, timestamp: Int64(ch[c.name]!)
            ))
        }))

        var strengthened = 0
        let parentTree = await parent.tree
        for _ in 0..<passes {
            for i in order where s.parent[i].commits[s.directory] != nil {
                strengthened += await child.applyParentRun(
                    from: parentTree, directory: s.directory, parentBlocks: [h(s.parent[i].name)]
                ).raised.count
            }
        }
        return (parent, child, strengthened)
    }

    private func assertMatchesOracle(_ s: Scenario, order: [Int]? = nil, _ label: String,
                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        let expected = oracle(s)
        let built = try await run(s, order: order ?? Array(s.parent.indices))
        XCTAssertGreaterThan(built.strengthened, 0, "\(label): the mechanism must actually have credited something",
                             file: file, line: line)
        for c in s.child {
            let weight = await built.child.subtreeWeight(forHash: h(c.name))
            XCTAssertEqual(weight, expected[c.name], "\(label): child block \(c.name)", file: file, line: line)
        }
    }

    // MARK: - Hand-drawn fork shapes

    private let d = "Payments"

    /// Fork ABOVE the committer: a sibling branch of the committer commits a
    /// DESCENDANT of the committed child block. "Subtree under the committer"
    /// misses the sibling branch entirely; the oracle includes it.
    func testForkAboveTheCommitterCommittingADescendant() async throws {
        //  parent:   g ─ p1 ─ p2 ─ p3        p1 commits c1
        //            └─ x1 ─ x2             x1 commits c2 (child of c1)
        //  child:    cg ─ c1 ─ c2
        let s = Scenario(directory: d, parent: [
            ParentBlock(name: "g", parent: nil, work: 1),
            ParentBlock(name: "p1", parent: "g", work: 5, commits: [d: "c1"]),
            ParentBlock(name: "p2", parent: "p1", work: 3),
            ParentBlock(name: "p3", parent: "p2", work: 7),
            ParentBlock(name: "x1", parent: "g", work: 4, commits: [d: "c2"]),
            ParentBlock(name: "x2", parent: "x1", work: 9),
        ], child: [
            ChildBlock(name: "cg", parent: nil, price: 1),
            ChildBlock(name: "c1", parent: "cg", price: 2),
            ChildBlock(name: "c2", parent: "c1", price: 2),
        ])
        try await assertMatchesOracle(s, "fork above")
        // Pin the number, so the oracle is not the only thing being trusted:
        // c1's subtree = c1(2) + p2(3) + p3(7) + c2(2) + x2(9) = 23.
        XCTAssertEqual(oracle(s)["c1"], sum(23))
        XCTAssertEqual(oracle(s)["c2"], sum(11))
    }

    /// Fork BELOW the committer: one branch re-commits into a descendant, the
    /// other commits nothing. Both branches land in c1's subtree exactly once.
    func testForkBelowTheCommitterOneBranchRecommitting() async throws {
        //  parent:   g ─ p1 ─ p2 ─ q        p1 commits c1; p2 commits c2
        //                 └─ x              x commits nothing
        //  child:    cg ─ c1 ─ c2
        let s = Scenario(directory: d, parent: [
            ParentBlock(name: "g", parent: nil, work: 1),
            ParentBlock(name: "p1", parent: "g", work: 5, commits: [d: "c1"]),
            ParentBlock(name: "p2", parent: "p1", work: 3, commits: [d: "c2"]),
            ParentBlock(name: "q", parent: "p2", work: 7),
            ParentBlock(name: "x", parent: "p1", work: 11),
        ], child: [
            ChildBlock(name: "cg", parent: nil, price: 1),
            ChildBlock(name: "c1", parent: "cg", price: 2),
            ChildBlock(name: "c2", parent: "c1", price: 2),
        ])
        try await assertMatchesOracle(s, "fork below")
        // c1 = 2 + x(11) + [c2 = 2 + q(7)] = 22; a raw subtree at p1 would add 3+7 again.
        XCTAssertEqual(oracle(s)["c1"], sum(22))
        XCTAssertEqual(oracle(s)["c2"], sum(9))
    }

    /// Fork below the committer whose branch commits a COMPETING child block:
    /// that branch's work belongs to the competitor, not to c1's subtree.
    func testForkBelowTheCommitterCommittingACompetitor() async throws {
        //  parent:   g ─ p1 ─ p2 ─ q        p1 commits c1; p2 commits c1' (sibling of c1)
        //  child:    cg ─ c1
        //            └─ c1'
        let s = Scenario(directory: d, parent: [
            ParentBlock(name: "g", parent: nil, work: 1),
            ParentBlock(name: "p1", parent: "g", work: 5, commits: [d: "c1"]),
            ParentBlock(name: "p2", parent: "p1", work: 3, commits: [d: "c1b"]),
            ParentBlock(name: "q", parent: "p2", work: 40),
        ], child: [
            ChildBlock(name: "cg", parent: nil, price: 1),
            ChildBlock(name: "c1", parent: "cg", price: 2),
            ChildBlock(name: "c1b", parent: "cg", price: 2),
        ])
        try await assertMatchesOracle(s, "competitor")
        XCTAssertEqual(oracle(s)["c1"], sum(2), "p2 and q are in p2's run, which names the competitor")
        XCTAssertEqual(oracle(s)["c1b"], sum(42))
        let built = try await run(s, order: Array(s.parent.indices))
        let tip = await built.child.canonicalTip
        XCTAssertEqual(tip, h("c1b"), "the branch with the parent work behind it wins the child's fork choice")
    }

    /// Two parent siblings carry the SAME child block: two carrier grinds at
    /// the child's price, two runs, both attributed, nothing shared.
    func testMultipleCommittersOfOneChildBlock() async throws {
        //  parent:   g ─ p1 ─ p2            p1 commits c1
        //            └─ x1 ─ x2 ─ x3        x1 commits c1 too
        let s = Scenario(directory: d, parent: [
            ParentBlock(name: "g", parent: nil, work: 1),
            ParentBlock(name: "p1", parent: "g", work: 5, commits: [d: "c1"]),
            ParentBlock(name: "p2", parent: "p1", work: 3),
            ParentBlock(name: "x1", parent: "g", work: 4, commits: [d: "c1"]),
            ParentBlock(name: "x2", parent: "x1", work: 9),
            ParentBlock(name: "x3", parent: "x2", work: 6),
        ], child: [
            ChildBlock(name: "cg", parent: nil, price: 1),
            ChildBlock(name: "c1", parent: "cg", price: 2),
        ])
        try await assertMatchesOracle(s, "two carriers")
        // 2 carriers × 2 + p2(3) + x2(9) + x3(6) = 22
        XCTAssertEqual(oracle(s)["c1"], sum(22))
    }

    /// Two carriers of one child block from different states: only the one
    /// applied to the state the block anchors to credits it its run. The
    /// other's run reaches no child block at all (§9.10).
    func testCommitterFromAnotherStateCreditsNothing() async throws {
        //  parent:   g ─ p1 ─ p2            p1 commits c1, from c1's anchor
        //            └─ x1 ─ x2 ─ x3        x1 commits c1 too, from another state
        let s = Scenario(directory: d, parent: [
            ParentBlock(name: "g", parent: nil, work: 1),
            ParentBlock(name: "p1", parent: "g", work: 5, commits: [d: "c1"]),
            ParentBlock(name: "p2", parent: "p1", work: 3),
            ParentBlock(name: "x1", parent: "g", work: 4, commits: [d: "c1"], state: "t"),
            ParentBlock(name: "x2", parent: "x1", work: 9),
            ParentBlock(name: "x3", parent: "x2", work: 6),
        ], child: [
            ChildBlock(name: "cg", parent: nil, price: 1),
            ChildBlock(name: "c1", parent: "cg", price: 2),
        ])
        try await assertMatchesOracle(s, "carrier from another state")
        // 2 carriers × 2 + p2(3); x2 and x3 sit in x1's run, which credits nothing.
        XCTAssertEqual(oracle(s)["c1"], sum(7))
    }

    /// The committer sits on the parent's LOSING branch. Canonicity is not an
    /// input: its run still counts in full.
    func testCommitterOnANonCanonicalParentBranchStillCounts() async throws {
        let s = Scenario(directory: d, parent: [
            ParentBlock(name: "g", parent: nil, work: 1),
            ParentBlock(name: "p1", parent: "g", work: 2, commits: [d: "c1"]),
            ParentBlock(name: "p2", parent: "p1", work: 2),
            ParentBlock(name: "w1", parent: "g", work: 50),
            ParentBlock(name: "w2", parent: "w1", work: 50),
            ParentBlock(name: "w3", parent: "w2", work: 50),
        ], child: [
            ChildBlock(name: "cg", parent: nil, price: 1),
            ChildBlock(name: "c1", parent: "cg", price: 2),
        ])
        let built = try await run(s, order: Array(s.parent.indices))
        let parentTip = await built.parent.canonicalTip
        XCTAssertEqual(parentTip, h("w3"), "fixture: the committer's branch must be the losing one")
        try await assertMatchesOracle(s, "losing branch")
        XCTAssertEqual(oracle(s)["c1"], sum(4))
    }

    /// Deep interleaving: commits alternate between two child branches down a
    /// single parent line, with parent forks hanging off both.
    func testInterleavedCommitsAcrossCompetingChildBranches() async throws {
        let s = Scenario(directory: d, parent: [
            ParentBlock(name: "g", parent: nil, work: 1),
            ParentBlock(name: "p1", parent: "g", work: 5, commits: [d: "a1"]),
            ParentBlock(name: "p2", parent: "p1", work: 3, commits: [d: "b1"]),
            ParentBlock(name: "p3", parent: "p2", work: 7, commits: [d: "a2"]),
            ParentBlock(name: "p4", parent: "p3", work: 2, commits: [d: "b2"]),
            ParentBlock(name: "p5", parent: "p4", work: 8),
            ParentBlock(name: "f1", parent: "p2", work: 6),      // in p2's run → b1
            ParentBlock(name: "f2", parent: "f1", work: 6),
            ParentBlock(name: "e1", parent: "p3", work: 10),     // in p3's run → a2
            ParentBlock(name: "z1", parent: "g", work: 20),      // no committer above → nobody
        ], child: [
            ChildBlock(name: "cg", parent: nil, price: 1),
            ChildBlock(name: "a1", parent: "cg", price: 2),
            ChildBlock(name: "a2", parent: "a1", price: 2),
            ChildBlock(name: "b1", parent: "cg", price: 2),
            ChildBlock(name: "b2", parent: "b1", price: 2),
        ])
        try await assertMatchesOracle(s, "interleaved")
        XCTAssertEqual(oracle(s)["a1"], sum(2 + 2 + 10))           // a1 own, a2 own, e1
        XCTAssertEqual(oracle(s)["b1"], sum(2 + 6 + 6 + 2 + 8))    // b1 own, f1, f2, b2 own, p5
    }

    /// A parent block that commits into ANOTHER directory only does not start
    /// a run in this one: it stays in its nearest `d`-committer's run.
    func testCommitsIntoOtherDirectoriesDoNotSplitThisRun() async throws {
        let s = Scenario(directory: d, parent: [
            ParentBlock(name: "g", parent: nil, work: 1),
            ParentBlock(name: "p1", parent: "g", work: 5, commits: [d: "c1"]),
            ParentBlock(name: "p2", parent: "p1", work: 3, commits: ["Markets": "elsewhere"]),
            ParentBlock(name: "p3", parent: "p2", work: 7),
        ], child: [
            ChildBlock(name: "cg", parent: nil, price: 1),
            ChildBlock(name: "c1", parent: "cg", price: 2),
        ])
        try await assertMatchesOracle(s, "other directory")
        XCTAssertEqual(oracle(s)["c1"], sum(2 + 3 + 7))
    }

    /// Arrival order is not an input: every hand-drawn shape, in several
    /// shuffled parent orders (orphans first, committers last, …), matches.
    func testArrivalOrderDoesNotChangeTheAnswer() async throws {
        let s = Scenario(directory: d, parent: [
            ParentBlock(name: "g", parent: nil, work: 1),
            ParentBlock(name: "p1", parent: "g", work: 5, commits: [d: "c1"]),
            ParentBlock(name: "p2", parent: "p1", work: 3, commits: [d: "c2"]),
            ParentBlock(name: "q", parent: "p2", work: 7),
            ParentBlock(name: "x", parent: "p1", work: 11),
            ParentBlock(name: "x1", parent: "g", work: 4, commits: [d: "c2"]),
            ParentBlock(name: "x2", parent: "x1", work: 9),
        ], child: [
            ChildBlock(name: "cg", parent: nil, price: 1),
            ChildBlock(name: "c1", parent: "cg", price: 2),
            ChildBlock(name: "c2", parent: "c1", price: 2),
        ])
        var rng = SeededRNG(seed: 0xF0_4C)
        try await assertMatchesOracle(s, order: Array(s.parent.indices).reversed(), "reversed")
        for trial in 0..<8 {
            try await assertMatchesOracle(s, order: Array(s.parent.indices).shuffled(using: &rng), "shuffle \(trial)")
        }
    }

    // MARK: - Randomized shapes

    /// Random parent trees with random forks, random commitments into random
    /// blocks of a random child tree (plus noise commitments into another
    /// directory), delivered in random order, each report applied twice.
    /// Every child block's subtree weight must equal the oracle.
    func testRandomForkShapesMatchTheOracle() async throws {
        var rng = SeededRNG(seed: 0x5EED_F04B)
        for trial in 0..<40 {
            let childCount = 2 + Int(rng.next() % 6)
            var child: [ChildBlock] = [ChildBlock(name: "cg", parent: nil, price: 1)]
            for i in 1..<childCount {
                let parent = child[Int(rng.next() % UInt64(child.count))].name
                child.append(ChildBlock(name: "c\(i)", parent: parent, price: 1 + rng.next() % 5,
                                        anchor: rng.next() % 4 == 0 ? "t" : "s"))
            }
            let parentCount = 4 + Int(rng.next() % 24)
            var parent: [ParentBlock] = [ParentBlock(name: "g", parent: nil, work: 1)]
            for i in 1..<parentCount {
                let up = parent[Int(rng.next() % UInt64(parent.count))].name
                var commits: [String: String] = [:]
                let roll = rng.next() % 10
                if roll < 3 { commits[d] = child[1 + Int(rng.next() % UInt64(child.count - 1))].name }
                if roll == 3 || roll == 4 { commits["Markets"] = "m\(i)" }
                parent.append(ParentBlock(name: "p\(i)", parent: up, work: 1 + rng.next() % 20, commits: commits,
                                          state: rng.next() % 4 == 0 ? "t" : "s"))
            }
            // A child block needs at least one carrier to exist; drop child
            // blocks nobody committed — but only leaves, so the tree stays a tree.
            let committed = Set(parent.compactMap { $0.commits[d] })
            var keep = child
            var pruned = true
            while pruned {
                pruned = false
                let parents = Set(keep.compactMap(\.parent))
                if let i = keep.firstIndex(where: { $0.parent != nil && !committed.contains($0.name) && !parents.contains($0.name) }) {
                    keep.remove(at: i); pruned = true
                }
            }
            let keptNames = Set(keep.map(\.name))
            let live = parent.map { p -> ParentBlock in
                var q = p
                if let t = q.commits[d], !keptNames.contains(t) { q.commits[d] = nil }
                return q
            }
            var s = Scenario(directory: d, parent: live, child: keep)
            // Never a vacuous trial: at least one committer into d, so the
            // mechanism is exercised every time the oracle is consulted.
            if !s.parent.contains(where: { $0.commits[d] != nil }) {
                var p = s.parent[1]
                p.commits[d] = "cg"
                s = Scenario(directory: d, parent: [s.parent[0], p] + s.parent.dropFirst(2), child: s.child)
            }
            // ... and at least one non-committing descendant under a committer,
            // so at least one run is larger than its committer's own work and
            // the credit path is exercised, not just refused.
            // Its committer is applied to the state its block anchors to, so
            // the run is credited; other committers may not be.
            let firstIndex = s.parent.firstIndex { $0.commits[d] != nil }!
            let firstCommitter = s.parent[firstIndex].name
            var anchored = s.parent
            anchored[firstIndex].state = s.child.first { $0.name == anchored[firstIndex].commits[d] }!.anchor
            s = Scenario(directory: d, parent: anchored + [
                ParentBlock(name: "tail", parent: firstCommitter, work: 1 + rng.next() % 20),
            ], child: s.child)
            let order = Array(s.parent.indices).shuffled(using: &rng)
            try await assertMatchesOracle(s, order: order, "trial \(trial) (\(live.count) parent, \(keep.count) child)")
        }
    }

    /// The child's own restart: its facts are observations only, and a cold
    /// restore in any order re-derives the same weights from the parent.
    func testChildColdRestoreReproducesAttributedWeights() async throws {
        let s = Scenario(directory: d, parent: [
            ParentBlock(name: "g", parent: nil, work: 1),
            ParentBlock(name: "p1", parent: "g", work: 5, commits: [d: "c1"]),
            ParentBlock(name: "p2", parent: "p1", work: 3, commits: [d: "c2"]),
            ParentBlock(name: "q", parent: "p2", work: 7),
            ParentBlock(name: "y", parent: "p1", work: 6),   // p1's run: p1 + y
            ParentBlock(name: "x1", parent: "g", work: 4, commits: [d: "c2"]),
            ParentBlock(name: "x2", parent: "x1", work: 9),
        ], child: [
            ChildBlock(name: "cg", parent: nil, price: 1),
            ChildBlock(name: "c1", parent: "cg", price: 2),
            ChildBlock(name: "c2", parent: "c1", price: 2),
        ])
        // Child facts: block batches (carrier grind at the child's price) —
        // observations only; no attributed run is ever a fact.
        let parent = await (try await run(s, order: Array(s.parent.indices)).parent).tree
        func childBatch(_ name: String, parentName: String?, height: UInt64, grindID: String, price: UInt64) -> BlockImportBatch {
            BlockImportBatch(facts: [
                .block(ChainBlockFact(
                    blockHash: h(name), parentBlockHash: parentName.map(h), blockHeight: height,
                    postStateCID: testCID("cpost:\(name)"), prevStateCID: testCID("cprev:\(name)"),
                    parentStateCID: testCID("prev:s"),
                    specCID: testCID("cspec"), target: "1", nextTarget: "1",
                    timestamp: Int64(height), stateDiff: .empty
                )),
                .work(ChainWorkFact(blockHash: h(name), contribution: VerifiedWorkContribution(id: grindID, work: UInt256(price)))),
            ])
        }
        let facts = [
            childBatch("cg", parentName: nil, height: 0, grindID: grind("cg"), price: 1),
            childBatch("c1", parentName: "cg", height: 1, grindID: grind("p1"), price: 2),
            childBatch("c2", parentName: "c1", height: 2, grindID: grind("p2"), price: 2),
            BlockImportBatch(facts: [.work(ChainWorkFact(
                blockHash: h("c2"), contribution: VerifiedWorkContribution(id: grind("x1"), work: UInt256(2))
            ))]),
        ]
        let live = try await ChainState.restoreWithoutContext(replaying: [facts[0]])
        for f in facts.dropFirst() { _ = try await live.replay(f) }
        let raised = await live.applyParentRun(from: parent, directory: d).raised
        XCTAssertEqual(Set(raised), [h("c1"), h("c2")])
        let expected = oracle(s)
        for c in s.child {
            let w = await live.subtreeWeight(forHash: h(c.name))
            XCTAssertEqual(w, expected[c.name], "live \(c.name)")
        }
        let context = testChainContext(path: [DEFAULT_ROOT_DIRECTORY, d])
        var rng = SeededRNG(seed: 0xC01D)
        for trial in 0..<6 {
            var cold = try ChainTree.restore(
                replaying: facts.shuffled(using: &rng), context: context, parent: parent
            )
            for c in s.child {
                XCTAssertEqual(cold.subtreeWeight(forHash: h(c.name)), expected[c.name], "cold \(trial) \(c.name)")
            }
        }
    }
}
