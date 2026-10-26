import XCTest
import UInt256
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport

/// Parent-attributed run work (§9.10).
///
/// A parent partitions its connected graph into RUNS, one per commitment into
/// each child directory: a block belongs to the run of the nearest block at or
/// above it — by parent pointer — that commits into that directory. Runs
/// partition the graph, so every grind lands in exactly one run: no double
/// count under a parent fork, nothing missed. This is the property the earlier
/// "report the raw subtree" design lacked, and the fork test below is the one
/// that would have exposed it.
///
/// Two build paths, one truth: graphs are built both through `makeChain` (the
/// `init` rebuild) and through `replay` (the `insertBlock` reducer restore
/// uses), and every run must agree between them. The child's side derives
/// its attributed runs from the parent tree itself (`applyParentRun`).
final class ParentRunAttributionTests: XCTestCase {

    private let d = "Payments"

    // MARK: - Fixtures

    /// Every hash the chain sees must be a canonical CID: the reducer and the
    /// accessors canonicalize and refuse anything else. Tests speak in names.
    private func h(_ name: String) -> String { testCID("block:\(name)") }
    private func grind(_ name: String) -> String { testCID("work:\(name)") }

    private func meta(
        _ hash: String, parent: String?, height: UInt64,
        children: [String] = [], work: UInt64,
        commits: [String: String] = [:]
    ) -> BlockMeta {
        BlockMeta(
            blockHash: h(hash), parentBlockHash: parent.map(h), blockHeight: height,
            childHashes: children.map(h),
            workContributions: [VerifiedWorkContribution(id: grind(hash), work: UInt256(work))],
            childCommitments: commits
        )
    }

    /// A child block credited under a PARENT grind (the grind its carrier was
    /// mined with), holding `work` at the child's own price.
    private func childMeta(_ hash: String, parent: String?, height: UInt64,
                           children: [String] = [], grind: String, work: UInt256) -> BlockMeta {
        BlockMeta(
            blockHash: h(hash), parentBlockHash: parent.map(h), blockHeight: height,
            childHashes: children.map(h),
            workContributions: [VerifiedWorkContribution(id: grind, work: work)]
        )
    }

    /// A block+work batch built by hand, so the replay path can be driven one
    /// batch at a time in an arrival order of the test's choosing.
    private func batch(
        _ hash: String, parent: String?, height: UInt64, work: UInt64,
        commits: [String: String] = [:]
    ) -> BlockImportBatch {
        let fact = ChainBlockFact(
            blockHash: h(hash), parentBlockHash: parent.map(h), blockHeight: height,
            postStateCID: testCID("post:\(hash)"),
            prevStateCID: testCID("prev:\(hash)"),
            specCID: testCID("spec"),
            target: "1", nextTarget: "1",
            timestamp: Int64(1_000 + height),
            stateDiff: .empty,
            childCommitments: commits
        )
        return BlockImportBatch(facts: [
            .block(fact),
            .work(ChainWorkFact(
                blockHash: h(hash),
                contribution: VerifiedWorkContribution(id: grind(hash), work: UInt256(work))
            )),
        ])
    }

    private func sum(_ values: UInt64...) -> WorkSum {
        WorkSum(UInt256(values.reduce(0, +)))
    }

    /// The worked example: parent P1 ← P2 ← P3, P1 commits child C, P2 and P3
    /// commit nothing. Both build paths.
    /// Built wholesale, then served: the whole-graph settle path.
    private func linearByInit() async -> ChainState {
        let chain = makeChain(blocks: [
            meta("g", parent: nil, height: 0, children: ["p1"], work: 1),
            meta("p1", parent: "g", height: 1, children: ["p2"], work: 5, commits: [d: h("c")]),
            meta("p2", parent: "p1", height: 2, children: ["p3"], work: 3),
            meta("p3", parent: "p2", height: 3, work: 7),
        ])
        await chain.serveRuns(for: d)
        return chain
    }

    /// Served first, then built block by block: the live per-block path.
    private func linearByReplay() async throws -> ChainState {
        let chain = try await ChainState.restoreWithoutContext(replaying: [
            batch("g", parent: nil, height: 0, work: 1),
        ])
        await chain.serveRuns(for: d)
        _ = try await chain.replay(batch("p1", parent: "g", height: 1, work: 5, commits: [d: h("c")]))
        _ = try await chain.replay(batch("p2", parent: "p1", height: 2, work: 3))
        _ = try await chain.replay(batch("p3", parent: "p2", height: 3, work: 7))
        return chain
    }

    /// Child chain: genesis cg ← c, where c was committed by parent block p1
    /// and so is credited under p1's grind at the child's own price.
    private func childChain(existing: UInt256) -> ChainState {
        makeChain(blocks: [
            meta("cg", parent: nil, height: 0, children: ["c"], work: 1),
            childMeta("c", parent: "cg", height: 1, grind: grind("p1"), work: existing),
        ])
    }

    private func run(_ chain: ChainState, at hash: String, in directory: String? = nil) async -> WorkSum? {
        await chain.runWork(of: h(hash), directory: directory ?? d)
    }

    /// The credited work of a block's own grinds — what a child subtracts.
    private func own(_ chain: ChainState, at hash: String) async -> WorkSum? {
        await chain.grindWork(of: h(hash))
    }

    private func credited(_ chain: ChainState) async -> UInt256? {
        await chain.workContribution(id: grind("p1"), at: h("c"))?.work
    }

    // MARK: - Partition

    func testLinearRunIsTheCommitterPlusEveryDescendant() async throws {
        for (label, chain) in [("init", await linearByInit()), ("replay", try await linearByReplay())] {
            let runWork = await run(chain, at: "p1")
            let ownWork = await own(chain, at: "p1")
            let commitments = await chain.recordedChildCommitments(of: h("p1"))
            XCTAssertEqual(runWork, sum(5, 3, 7), "\(label): w(P1)+w(P2)+w(P3)")
            XCTAssertEqual(ownWork, sum(5), label)
            XCTAssertEqual(commitments, [d: h("c")], "\(label): the block it commits")
        }
    }

    func testInitAndReplayBuildsAgree() async throws {
        let a = await linearByInit()
        let b = try await linearByReplay()
        for hash in ["g", "p1", "p2", "p3"] {
            let ra = await run(a, at: hash)
            let rb = await run(b, at: hash)
            XCTAssertEqual(ra, rb, hash)
        }
    }

    /// The case that broke the raw-subtree design: a parent fork below the
    /// committer, with one branch re-committing into the same directory. Runs
    /// must partition — each grind in exactly one run, both branches present.
    func testParentForkPartitionsWithoutDoubleCountOrMiss() async throws {
        //        g
        //        |
        //       p1  (commits c1)
        //      /  \
        //    p2    x        p2 commits c2; x commits nothing
        //    |
        //    q              q commits nothing
        let byInit = makeChain(blocks: [
            meta("g", parent: nil, height: 0, children: ["p1"], work: 1),
            meta("p1", parent: "g", height: 1, children: ["p2", "x"], work: 5, commits: [d: testCID("c1")]),
            meta("p2", parent: "p1", height: 2, children: ["q"], work: 3, commits: [d: testCID("c2")]),
            meta("x", parent: "p1", height: 2, work: 11),
            meta("q", parent: "p2", height: 3, work: 7),
        ])
        await byInit.serveRuns(for: d)
        let byReplay = try await ChainState.restoreWithoutContext(replaying: [batch("g", parent: nil, height: 0, work: 1)])
        await byReplay.serveRuns(for: d)
        _ = try await byReplay.replay(batch("p1", parent: "g", height: 1, work: 5, commits: [d: testCID("c1")]))
        _ = try await byReplay.replay(batch("p2", parent: "p1", height: 2, work: 3, commits: [d: testCID("c2")]))
        _ = try await byReplay.replay(batch("x", parent: "p1", height: 2, work: 11))
        _ = try await byReplay.replay(batch("q", parent: "p2", height: 3, work: 7))

        for (label, chain) in [("init", byInit), ("replay", byReplay)] {
            let r1 = await run(chain, at: "p1")
            let r2 = await run(chain, at: "p2")
            XCTAssertEqual(r1, sum(5, 11), "\(label): p1's run is itself and the x branch, NOT p2's subtree")
            XCTAssertEqual(r2, sum(3, 7), "\(label): p2's run is itself and q")
            // Partition: the two runs together are exactly every non-genesis grind.
            XCTAssertEqual((r1 ?? .zero) + (r2 ?? .zero), sum(5, 11, 3, 7),
                           "\(label): runs partition the parent work — a raw subtree would count 3+7 twice")
            let rx = await run(chain, at: "x")
            let rq = await run(chain, at: "q")
            XCTAssertNil(rx, label)
            XCTAssertNil(rq, label)
        }
    }

    /// `nearestCarrier(of:directory:)` is the per-block pointer run attribution
    /// settles: each block names the nearest block at or above it that commits
    /// into the directory, and the blocks naming a carrier are exactly that
    /// carrier's run. Unserved directories and unconnected blocks answer nil.
    func testNearestCarrierIsTheBlocksRunCarrier() async throws {
        //        g
        //        |
        //       p1  (commits c1 into d, b1 into e)
        //      /  \
        //    p2    x        p2 commits c2 into d
        //    |
        //    q
        let e = "Markets"
        let work: [String: UInt64] = ["g": 1, "p1": 5, "p2": 3, "x": 11, "q": 7]
        let byInit = makeChain(blocks: [
            meta("g", parent: nil, height: 0, children: ["p1"], work: 1),
            meta("p1", parent: "g", height: 1, children: ["p2", "x"], work: 5,
                 commits: [d: testCID("c1"), e: testCID("b1")]),
            meta("p2", parent: "p1", height: 2, children: ["q"], work: 3, commits: [d: testCID("c2")]),
            meta("x", parent: "p1", height: 2, work: 11),
            meta("q", parent: "p2", height: 3, work: 7),
        ])
        await byInit.serveRuns(for: d)
        let byReplay = try await ChainState.restoreWithoutContext(replaying: [batch("g", parent: nil, height: 0, work: 1)])
        await byReplay.serveRuns(for: d)
        _ = try await byReplay.replay(batch("p1", parent: "g", height: 1, work: 5,
                                            commits: [d: testCID("c1"), e: testCID("b1")]))
        _ = try await byReplay.replay(batch("p2", parent: "p1", height: 2, work: 3, commits: [d: testCID("c2")]))
        _ = try await byReplay.replay(batch("x", parent: "p1", height: 2, work: 11))
        _ = try await byReplay.replay(batch("q", parent: "p2", height: 3, work: 7))

        let expected: [String: String?] = ["g": nil, "p1": "p1", "p2": "p2", "x": "p1", "q": "p2"]
        for (label, chain) in [("init", byInit), ("replay", byReplay)] {
            var runOf: [String: WorkSum] = [:]
            for (block, carrier) in expected {
                let actual = await chain.nearestCarrier(of: h(block), directory: d)
                XCTAssertEqual(actual, carrier.map(h), "\(label): carrier of \(block)")
                if let carrier {
                    runOf[carrier] = (runOf[carrier] ?? .zero) + sum(work[block]!)
                }
                let unserved = await chain.nearestCarrier(of: h(block), directory: e)
                XCTAssertNil(unserved, "\(label): \(block) in an unserved directory, though p1 commits into it")
            }
            // The blocks naming a carrier are exactly the run it serves.
            for (carrier, total) in runOf {
                let served = await run(chain, at: carrier)
                XCTAssertEqual(served, total, "\(label): \(carrier)'s run is the blocks naming it")
            }
            let unknown = await chain.nearestCarrier(of: h("nope"), directory: d)
            XCTAssertNil(unknown, "\(label): unknown block")
        }

        // An orphan has no carrier until it connects; then it inherits one.
        _ = try await byReplay.replay(batch("r2", parent: "r1", height: 5, work: 2))
        let orphaned = await byReplay.nearestCarrier(of: h("r2"), directory: d)
        XCTAssertNil(orphaned, "an unconnected block has no carrier yet")
        _ = try await byReplay.replay(batch("r1", parent: "q", height: 4, work: 2))
        let connected = await byReplay.nearestCarrier(of: h("r2"), directory: d)
        XCTAssertEqual(connected, h("p2"), "connecting through q inherits p2")

        // Serving a directory late settles the same pointers.
        await byReplay.serveRuns(for: e)
        let lateP2 = await byReplay.nearestCarrier(of: h("p2"), directory: e)
        let lateG = await byReplay.nearestCarrier(of: h("g"), directory: e)
        XCTAssertEqual(lateP2, h("p1"), "p2 commits nothing into e, so p1 carries it")
        XCTAssertNil(lateG)
    }

    func testDirectoriesAreIndependentPartitions() async throws {
        let e = "Markets"
        let chain = makeChain(blocks: [
            meta("g", parent: nil, height: 0, children: ["p1"], work: 1),
            meta("p1", parent: "g", height: 1, children: ["p2"], work: 5,
                 commits: [d: testCID("a"), e: testCID("b")]),
            meta("p2", parent: "p1", height: 2, work: 3, commits: [d: testCID("a2")]),
        ])
        await chain.serveRuns(for: d)
        await chain.serveRuns(for: e)
        let p1d = await run(chain, at: "p1", in: d)
        let p2d = await run(chain, at: "p2", in: d)
        let p1e = await run(chain, at: "p1", in: e)
        let p2e = await run(chain, at: "p2", in: e)
        XCTAssertEqual(p1d, sum(5), "p2 re-commits into d, so p1's d-run stops at p1")
        XCTAssertEqual(p2d, sum(3))
        XCTAssertEqual(p1e, sum(5, 3), "p2 commits nothing into e, so p1's e-run keeps it")
        XCTAssertNil(p2e, "p2 is not a committer into e")
    }

    func testRunIsNilForNonCommitterUnknownOrWrongDirectory() async throws {
        let chain = await linearByInit()
        let p2 = await run(chain, at: "p2")
        let g = await run(chain, at: "g")
        let unknown = await run(chain, at: "nope")
        let wrongDirectory = await run(chain, at: "p1", in: "Other")
        XCTAssertNil(p2, "p2 commits nothing")
        XCTAssertNil(g, "genesis commits nothing")
        XCTAssertNil(unknown, "unknown block")
        XCTAssertNil(wrongDirectory, "wrong directory")
    }

    /// Commitments are bound by the block CID, and a fact reaches the tree
    /// only after the node verified the block under it, so a re-delivered
    /// block's commitments are not compared: the block keeps those it was
    /// recorded with.
    func testRedeliveredBlockKeepsItsRecordedCommitments() async throws {
        let chain = try await linearByReplay()
        let same = try await chain.replay(batch("p1", parent: "g", height: 1, work: 5, commits: [d: h("c")]))
        XCTAssertNil(same, "same block, same map: a no-op replay")
        let other = try await chain.replay(batch("p1", parent: "g", height: 1, work: 5, commits: [d: testCID("other")]))
        XCTAssertNil(other, "re-delivery is a no-op")
        let recorded = await chain.getConsensusBlock(hash: h("p1"))?.childCommitments
        XCTAssertEqual(recorded, [d: h("c")])
    }

    /// Runs exist only for directories this node serves: a block committing
    /// into two hundred directories costs a node that serves one exactly one.
    func testUnservedDirectoriesCostNothingAndServeNothing() async throws {
        let chain = try await ChainState.restoreWithoutContext(replaying: [batch("g", parent: nil, height: 0, work: 1)])
        await chain.serveRuns(for: d)
        var commits = [d: testCID("c")]
        for i in 0..<200 { commits["junk-\(i)"] = testCID("j\(i)") }
        let start = await chain.runAttributionUpdateCount
        _ = try await chain.replay(batch("p1", parent: "g", height: 1, work: 5, commits: commits))
        _ = try await chain.replay(batch("p2", parent: "p1", height: 2, work: 3))
        let end = await chain.runAttributionUpdateCount
        XCTAssertEqual(end - start, 2, "one update per block for the ONE served directory, not 201")
        let junk = await run(chain, at: "p1", in: "junk-7")
        XCTAssertNil(junk, "an unserved directory keeps no run, even though the block commits into it")
        let served = await run(chain, at: "p1")
        XCTAssertEqual(served, sum(5, 3))
        let recorded = await chain.recordedChildCommitments(of: h("p1"))
        XCTAssertEqual(recorded, commits, "every commitment is held exactly, served or not")
    }

    /// Serving a directory late settles exactly the table serving it first
    /// would have built: the whole-graph settle and the per-block settle are
    /// one algorithm.
    func testServingLateEqualsServingFirst() async throws {
        func build(serveFirst: Bool) async throws -> ChainState {
            let chain = try await ChainState.restoreWithoutContext(replaying: [batch("g", parent: nil, height: 0, work: 1)])
            if serveFirst { await chain.serveRuns(for: d) }
            _ = try await chain.replay(batch("p1", parent: "g", height: 1, work: 5, commits: [d: testCID("c1")]))
            _ = try await chain.replay(batch("p2", parent: "p1", height: 2, work: 3, commits: [d: testCID("c2")]))
            _ = try await chain.replay(batch("x", parent: "p1", height: 2, work: 11))
            _ = try await chain.replay(batch("q", parent: "p2", height: 3, work: 7))
            _ = try await chain.replay(batch("orphan", parent: "missing", height: 9, work: 100, commits: [d: testCID("c9")]))
            if !serveFirst { await chain.serveRuns(for: d) }
            await chain.serveRuns(for: d) // idempotent
            return chain
        }
        let first = try await build(serveFirst: true)
        let late = try await build(serveFirst: false)
        for committer in ["p1", "p2", "x", "q", "orphan"] {
            let a = await run(first, at: committer)
            let b = await run(late, at: committer)
            XCTAssertEqual(a, b, committer)
        }
        let p1 = await run(late, at: "p1")
        XCTAssertEqual(p1, sum(5, 11))
        let orphan = await run(late, at: "orphan")
        XCTAssertNil(orphan, "an orphan committer has no run on either path")
    }

    /// A committer's run always contains its own work: the two numbers are
    /// ordered, which is what lets the child subtract.
    func testOwnWorkNeverExceedsRunWork() async throws {
        let chain = try await linearByReplay()
        let runValue = await run(chain, at: "p1")
        let ownValue = await own(chain, at: "p1")
        let runWork = try XCTUnwrap(runValue)
        let ownWork = try XCTUnwrap(ownValue)
        XCTAssertEqual(ownWork, sum(5))
        XCTAssertNotNil(runWork.subtracting(ownWork))
    }

    // MARK: - Maintenance

    func testStrengtheningARunMemberRaisesTheRunByExactlyTheDelta() async throws {
        let chain = try await linearByReplay()
        let before = await run(chain, at: "p1")
        // p2's grind observed stronger: 3 -> 10, delta 7.
        let result = await chain.addWorkContribution(
            VerifiedWorkContribution(id: grind("p2"), work: UInt256(10)), to: h("p2")
        )
        XCTAssertTrue(result.addedContribution, "fixture must actually strengthen")
        let after = await run(chain, at: "p1")
        XCTAssertEqual(after, (before ?? .zero) + sum(7))
        XCTAssertEqual(after, sum(5, 10, 7), "the run reflects the block's NEW work, once")
    }

    func testStrengtheningTheCommitterItselfRaisesItsOwnRun() async throws {
        let chain = try await linearByReplay()
        let result = await chain.addWorkContribution(
            VerifiedWorkContribution(id: grind("p1"), work: UInt256(50)), to: h("p1")
        )
        XCTAssertTrue(result.addedContribution)
        let ownWork = await own(chain, at: "p1")
        let runWork = await run(chain, at: "p1")
        XCTAssertEqual(ownWork, sum(50))
        XCTAssertEqual(runWork, sum(50, 3, 7))
    }

    func testWeakerObservationChangesNothing() async throws {
        let chain = try await linearByReplay()
        let before = await run(chain, at: "p1")
        let result = await chain.addWorkContribution(
            VerifiedWorkContribution(id: grind("p2"), work: UInt256(2)), to: h("p2")
        )
        XCTAssertFalse(result.addedContribution)
        let after = await run(chain, at: "p1")
        XCTAssertEqual(after, before)
    }

    func testOrphanIsCreditedWhenItConnectsNotBefore() async throws {
        let chain = try await ChainState.restoreWithoutContext(replaying: [batch("g", parent: nil, height: 0, work: 1)])
        await chain.serveRuns(for: d)
        _ = try await chain.replay(batch("p1", parent: "g", height: 1, work: 5, commits: [d: testCID("c")]))
        // p3 arrives before its parent p2, and so does a strengthening of it.
        _ = try await chain.replay(batch("p3", parent: "p2", height: 3, work: 7))
        let strengthened = await chain.addWorkContribution(
            VerifiedWorkContribution(id: grind("p3"), work: UInt256(9)), to: h("p3")
        )
        XCTAssertTrue(strengthened.addedContribution)
        let orphaned = await run(chain, at: "p1")
        XCTAssertEqual(orphaned, sum(5), "an orphan's work must not be credited before it is connected")
        _ = try await chain.replay(batch("p2", parent: "p1", height: 2, work: 3))
        let connected = await run(chain, at: "p1")
        XCTAssertEqual(connected, sum(5, 3, 9),
                       "connecting p2 connects p3 too, and credits p3 at its CURRENT work, once")
    }

    /// A committer that arrives as an orphan is not a committer yet: its run
    /// exists only once it is connected, and then holds its whole subtree.
    func testOrphanCommitterHasNoRunUntilConnected() async throws {
        let chain = try await ChainState.restoreWithoutContext(replaying: [batch("g", parent: nil, height: 0, work: 1)])
        await chain.serveRuns(for: d)
        _ = try await chain.replay(batch("p2", parent: "p1", height: 2, work: 3, commits: [d: testCID("c")]))
        _ = try await chain.replay(batch("p3", parent: "p2", height: 3, work: 7))
        let orphaned = await run(chain, at: "p2")
        XCTAssertNil(orphaned, "an unconnected committer has no run")
        _ = try await chain.replay(batch("p1", parent: "g", height: 1, work: 5))
        let connected = await run(chain, at: "p2")
        XCTAssertEqual(connected, sum(3, 7))
    }

    /// Never revoked (§9.10): excluding a run member on this chain leaves its
    /// run untouched, and a block descending from an excluded block is still
    /// connected and still credited.
    func testExclusionNeitherRevokesNorBlocksRunCredit() async throws {
        let chain = try await linearByReplay()
        let before = await run(chain, at: "p1")
        _ = try await chain.replay(BlockImportBatch(facts: [
            .exclusion(ChainExclusionFact(blockHash: h("p2"))),
        ]))
        // Fixture guard: the exclusion really took p2 out of THIS chain's
        // selection (work weighs, validity selects — §9.9), or the invariant
        // below is not being exercised.
        let path = await chain.canonicalHashes
        XCTAssertFalse(path.contains(h("p2")), "p2 must be unselectable")
        let tip = await chain.canonicalTip
        XCTAssertEqual(tip, h("p1"), "the descent stops above the excluded block")
        let afterExclusion = await run(chain, at: "p1")
        XCTAssertEqual(afterExclusion, before, "a run is never revoked by exclusion")
        // A new block under the excluded p2 is still connected and credited.
        _ = try await chain.replay(batch("p4", parent: "p2", height: 3, work: 13))
        let afterInsert = await run(chain, at: "p1")
        XCTAssertEqual(afterInsert, (before ?? .zero) + sum(13), "run credit is independent of exclusion")
        // And so is a strengthening of the excluded block itself.
        let strengthened = await chain.addWorkContribution(
            VerifiedWorkContribution(id: grind("p2"), work: UInt256(4)), to: h("p2")
        )
        XCTAssertTrue(strengthened.addedContribution)
        let afterStrengthen = await run(chain, at: "p1")
        XCTAssertEqual(afterStrengthen, (before ?? .zero) + sum(13, 1))
    }

    /// Restart equivalence: the run table a live sequence built equals the one
    /// a cold restore rebuilds from the same durable facts in ANY order.
    func testColdRestoreRebuildsTheSameRunsRegardlessOfOrder() async throws {
        let facts = [
            batch("g", parent: nil, height: 0, work: 1),
            batch("p1", parent: "g", height: 1, work: 5, commits: [d: testCID("c1")]),
            batch("p2", parent: "p1", height: 2, work: 3, commits: [d: testCID("c2")]),
            batch("x", parent: "p1", height: 2, work: 11),
            batch("q", parent: "p2", height: 3, work: 7),
            BlockImportBatch(facts: [.work(ChainWorkFact(
                blockHash: h("x"),
                contribution: VerifiedWorkContribution(id: grind("x"), work: UInt256(20))
            ))]),
        ]
        let live = try await ChainState.restoreWithoutContext(replaying: [facts[0]])
        await live.serveRuns(for: d)
        for fact in facts.dropFirst() { _ = try await live.replay(fact) }
        let liveP1 = await run(live, at: "p1")
        let liveP2 = await run(live, at: "p2")
        XCTAssertEqual(liveP1, sum(5, 20))
        XCTAssertEqual(liveP2, sum(3, 7))

        let seed = propertySeed()
        var generator = seed.generator()
        for _ in 0..<5 {
            let cold = try await ChainState.restoreWithoutContext(replaying: facts.shuffled(using: &generator))
            await cold.serveRuns(for: d) // served AFTER restore: the whole-graph settle
            let coldP1 = await run(cold, at: "p1")
            let coldP2 = await run(cold, at: "p2")
            XCTAssertEqual(coldP1, liveP1, seed.note)
            XCTAssertEqual(coldP2, liveP2, seed.note)
        }
    }

    // MARK: - The child's side: derivation

    private func attributed(_ chain: ChainState, committer: String = "p1", at child: String = "c",
                            directory: String? = nil) async -> UInt256? {
        let id = AttributedRunIdentity(carrierBlockHash: h(committer), directory: directory ?? d).contributionID!
        return await chain.workContribution(id: id, at: h(child))?.work
    }

    /// Derive `child`'s attributed runs from `parent`'s tree; the blocks raised.
    @discardableResult
    private func derive(_ child: ChainState, from parent: ChainState,
                        parentBlocks: Set<String>? = nil, held: Set<String> = []) async -> [String] {
        await child.applyParentRun(
            from: await parent.tree, directory: d,
            parentBlocks: parentBlocks.map { Set($0.map(h)) }, held: Set(held.map(h))
        ).raised
    }

    /// Child C is held under the committer's grind at the child's own price.
    /// p2 and p3 commit nothing: their work reaches C through p1's run, beside
    /// the grind, which is untouched.
    func testNonCommittingParentWorkReachesTheChild() async throws {
        let parent = try await linearByReplay()
        let child = childChain(existing: UInt256(5))
        let raised = await derive(child, from: parent)
        XCTAssertEqual(raised, [h("c")])
        let base = await credited(child)
        let extra = await attributed(child)
        XCTAssertEqual(base, UInt256(5), "the committer's own grind stays at the child's price, once")
        XCTAssertEqual(extra, UInt256(10), "3 + 7: the run minus the committer's grinds")
        let weight = await child.subtreeWeight(forHash: h("cg"))
        XCTAssertEqual(weight, sum(1, 5, 10), "the child's fork choice sees own + attributed")
    }

    func testDerivationKeepsTheChildsOwnRaise() async throws {
        // C's existing credit (9) exceeds the parent's price for the same grind (5).
        let child = childChain(existing: UInt256(9))
        await derive(child, from: try await linearByReplay())
        let base = await credited(child)
        let extra = await attributed(child)
        XCTAssertEqual(base, UInt256(9), "the terminal-target raise survives")
        XCTAssertEqual(extra, UInt256(10))
        let weight = await child.subtreeWeight(forHash: h("cg"))
        XCTAssertEqual(weight, sum(1, 9, 10))
    }

    /// A run with no blocks beyond the committer attributes nothing.
    func testDerivationNeverCountsTheCommittersOwnGrindTwice() async throws {
        let parent = try await ChainState.restoreWithoutContext(replaying: [batch("g", parent: nil, height: 0, work: 1)])
        await parent.serveRuns(for: d)
        _ = try await parent.replay(batch("p1", parent: "g", height: 1, work: 5, commits: [d: h("c")]))
        let child = childChain(existing: UInt256(5))
        let raised = await derive(child, from: parent)
        XCTAssertEqual(raised, [])
        let extra = await attributed(child)
        XCTAssertNil(extra)
    }

    /// Idempotent: deriving again from the same parent credits nothing more.
    func testRepeatedDerivationIsOneCredit() async throws {
        let parent = try await linearByReplay()
        let child = childChain(existing: UInt256(5))
        var raisedCounts: [Int] = []
        for _ in 0..<3 { raisedCounts.append(await derive(child, from: parent).count) }
        XCTAssertEqual(raisedCounts, [1, 0, 0])
        let extra = await attributed(child)
        XCTAssertEqual(extra, UInt256(10))
        let weight = await child.subtreeWeight(forHash: h("cg"))
        XCTAssertEqual(weight, sum(1, 5, 10))
    }

    /// A committer mined under TWO grinds is one run and is credited once —
    /// the identity is the committer's, not a grind's.
    func testCommitterWithTwoGrindsIsCreditedOnce() async throws {
        let parent = try await linearByReplay()
        _ = try await parent.replay(BlockImportBatch(facts: [.work(ChainWorkFact(
            blockHash: h("p1"), contribution: VerifiedWorkContribution(id: grind("p1-alt"), work: UInt256(4))
        ))]))
        let child = makeChain(blocks: [
            meta("cg", parent: nil, height: 0, children: ["c"], work: 1),
            BlockMeta(blockHash: h("c"), parentBlockHash: h("cg"), blockHeight: 1, childHashes: [],
                      workContributions: [
                          VerifiedWorkContribution(id: grind("p1"), work: UInt256(5)),
                          VerifiedWorkContribution(id: grind("p1-alt"), work: UInt256(4)),
                      ]),
        ])
        await derive(child, from: parent)
        await derive(child, from: parent)
        let extra = await attributed(child)
        XCTAssertEqual(extra, UInt256(10), "run (9+3+7) − own (5+4), once")
        let weight = await child.subtreeWeight(forHash: h("cg"))
        XCTAssertEqual(weight, sum(1, 5, 4, 10), "both grinds at the child's price, plus the run once")
    }

    /// The only binding is that the child holds C. A child block credited
    /// under none of its committer's grinds — an inverted hierarchy, where
    /// the committer's grind does not meet the child's target and C weighs
    /// through another carrier — still takes the committer's run.
    func testInvertedHierarchyIsCredited() async throws {
        let parent = try await linearByReplay()
        let child = makeChain(blocks: [
            meta("cg", parent: nil, height: 0, children: ["c"], work: 1),
            childMeta("c", parent: "cg", height: 1, grind: grind("elsewhere"), work: UInt256(2)),
        ])
        let raised = await derive(child, from: parent)
        XCTAssertEqual(raised, [h("c")])
        let extra = await attributed(child)
        XCTAssertEqual(extra, UInt256(10))
        let weight = await child.subtreeWeight(forHash: h("cg"))
        XCTAssertEqual(weight, sum(1, 2, 10))
    }

    /// A committed block this chain does not hold is credited the moment it
    /// is held and the derivation runs again — never before.
    func testUnheldChildBlockIsCreditedOnceHeld() async throws {
        let parent = try await linearByReplay()
        let child = try await ChainState.restoreWithoutContext(replaying: [batch("cg", parent: nil, height: 0, work: 1)])
        let before = await derive(child, from: parent)
        XCTAssertEqual(before, [], "C is not held: nothing to credit")
        _ = try await child.replay(batch("c", parent: "cg", height: 1, work: 5))
        let after = await derive(child, from: parent, parentBlocks: [], held: ["c"])
        XCTAssertEqual(after, [h("c")])
        let extra = await attributed(child)
        XCTAssertEqual(extra, UInt256(10))
    }

    /// Monotone: a parent reorg, a parent exclusion and a stronger grind at
    /// the committer never lower the child's credit; new work in the run
    /// raises it, excluded or not.
    func testDerivationIsMonotoneUnderParentReorgsAndExclusions() async throws {
        let parent = try await linearByReplay()
        let child = childChain(existing: UInt256(5))
        var seen: [UInt256] = []
        func step() async throws {
            await derive(child, from: parent)
            let value = await attributed(child)
            seen.append(try XCTUnwrap(value))
        }
        try await step()
        // A heavier rival branch reorgs the parent away from p1's run.
        _ = try await parent.replay(batch("r1", parent: "g", height: 1, work: 100))
        let parentTip = await parent.canonicalTip
        XCTAssertEqual(parentTip, h("r1"), "fixture: the parent reorged")
        try await step()
        // Excluding a run member on the parent revokes nothing.
        _ = try await parent.replay(BlockImportBatch(facts: [.exclusion(ChainExclusionFact(blockHash: h("p2")))]))
        try await step()
        // New work under the excluded block still joins the run.
        _ = try await parent.replay(batch("p4", parent: "p2", height: 3, work: 13))
        try await step()
        // A stronger grind at the committer raises both terms alike.
        _ = try await parent.replay(BlockImportBatch(facts: [.work(ChainWorkFact(
            blockHash: h("p1"), contribution: VerifiedWorkContribution(id: grind("p1"), work: UInt256(50))
        ))]))
        try await step()
        XCTAssertEqual(seen, [10, 10, 10, 23, 23].map { UInt256($0) })
    }

    /// The child's fork choice is what all of this is for: a child fork whose
    /// carrier gathered more parent descendants wins, even when the child
    /// blocks themselves are equal — whatever the parent's canonical chain.
    func testAttributedWorkMovesChildForkChoice() async throws {
        //   cg
        //  /  \
        // a    b     equal own work, different parent runs behind them
        let child = makeChain(blocks: [
            meta("cg", parent: nil, height: 0, children: ["a", "b"], work: 1),
            childMeta("a", parent: "cg", height: 1, grind: grind("pa"), work: UInt256(5)),
            childMeta("b", parent: "cg", height: 1, grind: grind("pb"), work: UInt256(5)),
        ], canonicalHashes: [h("cg"), h("a")])
        let tipBefore = await child.canonicalTip
        XCTAssertEqual(tipBefore, h("a"))
        // b's carrier gathered 40 of descendant parent work; a's gathered 0.
        let parent = try await ChainState.restoreWithoutContext(replaying: [batch("g", parent: nil, height: 0, work: 1)])
        await parent.serveRuns(for: d)
        _ = try await parent.replay(batch("pa", parent: "g", height: 1, work: 5, commits: [d: h("a")]))
        _ = try await parent.replay(batch("pb", parent: "g", height: 1, work: 5, commits: [d: h("b")]))
        _ = try await parent.replay(batch("pbx", parent: "pb", height: 2, work: 40))
        let applied = await child.applyParentRun(from: await parent.tree, directory: d)
        XCTAssertEqual(applied.raised, [h("b")])
        XCTAssertEqual(applied.commit?.tipHash, h("b"))
        let tipAfter = await child.canonicalTip
        XCTAssertEqual(tipAfter, h("b"), "parent work behind b's carrier moved the child's fork choice")
        let wa = await child.subtreeWeight(forHash: h("a"))
        let wb = await child.subtreeWeight(forHash: h("b"))
        XCTAssertEqual(wa, sum(5))
        XCTAssertEqual(wb, sum(45))
    }

    /// Live equals restore after EVERY step, whatever order either level's
    /// facts arrive in — parent committers arriving as orphans and grafted
    /// by a later ancestor, child blocks held after their committer's run
    /// closed (brought by another carrier), children before parents — when
    /// the host forwards only what each mutation reported
    /// (`SubmissionResult.weighed`), never a set of its own.
    func testLiveDerivationFromReportedResultsEqualsRestoreAfterEveryStep() throws {
        let parentFacts: [BlockImportBatch] = [
            batch("g", parent: nil, height: 0, work: 1),
            batch("p1", parent: "g", height: 1, work: 5, commits: [d: h("c")]),
            batch("p1x", parent: "p1", height: 2, work: 4),
            batch("p2", parent: "p1x", height: 3, work: 3, commits: [d: h("c2")]),
            batch("q", parent: "p2", height: 4, work: 6),
            batch("x", parent: "p1", height: 2, work: 9, commits: [d: h("c2")]),
            batch("x1", parent: "x", height: 3, work: 2),
        ]
        // c and c2 are credited under their own grinds: other carriers.
        let childFacts: [BlockImportBatch] = [
            batch("cg", parent: nil, height: 0, work: 1),
            batch("c", parent: "cg", height: 1, work: 2),
            batch("c2", parent: "c", height: 2, work: 2),
            batch("c3", parent: "c2", height: 3, work: 2),
        ]
        let childNames = ["cg", "c", "c2", "c3"]
        let context = testChainContext(path: [DEFAULT_ROOT_DIRECTORY, d])
        // Arrivals after each genesis: 0 = a parent fact, 1 = a child fact.
        // The pinned trigger first: the committer p1's descendants and the
        // re-committer p2 arrive BEFORE p1 (an orphan component p1 grafts),
        // then the child blocks after every run has closed.
        let pinned: [(Int, Int)] = [(0, 3), (0, 4), (0, 2), (0, 1), (0, 5), (0, 6),
                                    (1, 1), (1, 2), (1, 3)]
        var orders = [pinned]
        var rng = SeededRNG(seed: 0xC1_05ED)
        for _ in 0..<24 {
            let arrivals = (1..<parentFacts.count).map { (0, $0) } + (1..<childFacts.count).map { (1, $0) }
            orders.append(arrivals.shuffled(using: &rng))
        }
        for (trial, order) in orders.enumerated() {
            var parent = try ChainTree.restoreWithoutContext(replaying: [parentFacts[0]])
            parent.serveRuns(for: d)
            var child = try ChainTree.restoreWithoutContext(replaying: [childFacts[0]])
            var childSoFar = [childFacts[0]]
            for (step, (level, index)) in order.enumerated() {
                if level == 0 {
                    let reported = try parent.apply(parentFacts[index])?.weighed ?? []
                    child.applyParentRun(from: parent, directory: d, parentBlocks: Set(reported))
                } else {
                    childSoFar.append(childFacts[index])
                    let reported = try child.apply(childFacts[index])?.weighed ?? []
                    child.applyParentRun(from: parent, directory: d, parentBlocks: [], held: Set(reported))
                }
                let restored = try ChainTree.restore(replaying: childSoFar, context: context, parent: parent)
                for name in childNames {
                    XCTAssertEqual(weight(child, name), weight(restored, name),
                                   "trial \(trial) step \(step): \(name)")
                }
            }
        }
        // Fixture guard: the pinned order's final weights include both runs.
        var parent = try ChainTree.restoreWithoutContext(replaying: parentFacts)
        parent.serveRuns(for: d)
        let restored = try ChainTree.restore(replaying: childFacts, context: context, parent: parent)
        XCTAssertEqual(weight(restored, "c"), sum(2, 4, 2, 6, 2, 2),
                       "c + p1's run beyond p1 (p1x) + c2 + p2's (q) + x's (x1) + c3")
    }

    /// A genesis is just a block: a child-root genesis committing a
    /// grandchild records that commitment on every admission path — weighed
    /// and executed in one step (value and actor bootstraps) or weighed
    /// first — so the grandchild weighs the same whichever path its node
    /// took.
    func testAGenesisCommittingAGrandchildWeighsTheSameEagerOrWeighedFirst() async throws {
        let fetcher = StorableFetcher()
        let grandchild = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 21)
        let grandchildCID = try BlockHeader(node: grandchild).rawCID
        let anchor = try await testAnchorParentGenesis(fetcher: fetcher)
        let genesis = try await storeBuiltBlock(try await BlockBuilder.buildChildGenesis(
            spec: chainLocalSpec(), parentState: anchor.postState, children: [directoryB: grandchild],
            timestamp: 1_000, target: UInt256.max, nonce: 1, fetcher: fetcher
        ), in: fetcher)
        let genesisCID = try BlockHeader(node: genesis).rawCID
        let context = testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        let package = try await carriedGenesisPackage(genesis, fetcher: fetcher)
        let evidence = try await package.proof.verifySecuringWork(child: genesis, chainPath: context.path).get()

        let eager = try await ChainTree.bootstrap(
            genesis: try BlockHeader(node: genesis), evidence: evidence, fetcher: fetcher,
            context: context, parentFacts: try await testParentFacts(fetcher: fetcher)
        ).get().tree
        let actorResult = try await ChainLevel.bootstrap(
            context: context, genesisHeader: try BlockHeader(node: genesis), fetcher: fetcher,
            childPackage: package, validationContentStorer: fetcher, materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        guard case .accepted(let accepted) = actorResult else { return XCTFail("actor bootstrap: \(actorResult)") }
        let actor = await accepted.level.chain.tree
        var weighed = ChainTree.empty(context: context)
        let resolvedIndex = try await genesis.children.resolve(fetcher: fetcher).node
        XCTAssertNotNil(weighed.insertGenesis(
            genesis, spec: chainLocalSpec(), childIndex: try XCTUnwrap(resolvedIndex), evidence: evidence
        ).update)
        XCTAssertFalse(weighed.hasExecutedAncestry(blockHash: genesisCID), "weighed only")

        // One child-level block under the genesis, so its run exceeds its grind.
        let below = BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: h("a1"), parentBlockHash: genesisCID, blockHeight: 1,
                postStateCID: testCID("post:a1"), prevStateCID: testCID("prev:a1"),
                specCID: testCID("spec"), target: "1", nextTarget: "1",
                timestamp: 2_000, stateDiff: .empty
            )),
            .work(ChainWorkFact(blockHash: h("a1"), contribution: VerifiedWorkContribution(id: grind("a1"), work: UInt256(7)))),
        ])
        var weights: [WorkSum?] = []
        for (label, tree) in [("eager", eager), ("actor eager", actor), ("weighed first", weighed)] {
            XCTAssertEqual(tree.recordedChildCommitments(of: genesisCID), [directoryB: grandchildCID], label)
            var level = tree.detached()
            _ = try level.replay(below)
            level.serveRuns(for: directoryB)
            var lower = try ChainTree.restoreWithoutContext(replaying: [try testAdmissionBatch(for: grandchild)])
            let raised = lower.applyParentRun(from: level, directory: directoryB).raised
            XCTAssertEqual(raised, [grandchildCID], label)
            weights.append(lower.subtreeWeight(forHash: grandchildCID))
        }
        XCTAssertEqual(weights[0], weights[1], "eager value and actor paths agree")
        XCTAssertEqual(weights[0], weights[2], "eager and weighed-first agree")
    }

    // MARK: - Recursion: Nexus → A → B

    /// A strengthening A received raises the run A keeps for B, because the
    /// run is over A's own `work`.
    func testWorkAttributedToTheParentFlowsIntoItsRun() async throws {
        let a = try await linearByReplay() // A: g ← p1(commits into B's dir) ← p2 ← p3
        let up = await a.addWorkContribution(
            VerifiedWorkContribution(id: grind("p3"), work: UInt256(107)), to: h("p3")
        )
        XCTAssertTrue(up.addedContribution)
        let runWork = await run(a, at: "p1")
        XCTAssertEqual(runWork, sum(5, 3, 107), "B sees, through A, the work A was credited")
    }

    /// Three levels, merged-mined. Nexus block n1's ONE grind G secures A's
    /// a1 (n1 commits a1) and, through a1, B's b1; n2 commits nothing; a2 is
    /// A's own work under a1. Every grind must reach b1 exactly once:
    /// G (held at b1) + n2 (attributed to a1, then through a1's run) + a2.
    private struct Hierarchy {
        let nexus: [BlockImportBatch]
        let a: [BlockImportBatch]
        let b: [BlockImportBatch]
    }

    private let directoryA = "A"
    private let directoryB = "B"

    private func hierarchy() -> Hierarchy {
        func block(_ name: String, parent: String?, height: UInt64, grindID: String, work: UInt64,
                   commits: [String: String] = [:]) -> BlockImportBatch {
            BlockImportBatch(facts: [
                .block(ChainBlockFact(
                    blockHash: h(name), parentBlockHash: parent.map(h), blockHeight: height,
                    postStateCID: testCID("post:\(name)"), prevStateCID: testCID("prev:\(name)"),
                    specCID: testCID("spec"), target: "1", nextTarget: "1",
                    timestamp: Int64(1_000 + height), stateDiff: .empty, childCommitments: commits
                )),
                .work(ChainWorkFact(
                    blockHash: h(name), contribution: VerifiedWorkContribution(id: grindID, work: UInt256(work))
                )),
            ])
        }
        let g = grind("n1")
        return Hierarchy(
            nexus: [
                block("ng", parent: nil, height: 0, grindID: grind("ng"), work: 1),
                block("n1", parent: "ng", height: 1, grindID: g, work: 5, commits: [directoryA: h("a1")]),
                block("n2", parent: "n1", height: 2, grindID: grind("n2"), work: 100),
            ],
            a: [
                block("ag", parent: nil, height: 0, grindID: grind("ag"), work: 1),
                block("a1", parent: "ag", height: 1, grindID: g, work: 5, commits: [directoryB: h("b1")]),
                block("a2", parent: "a1", height: 2, grindID: grind("a2"), work: 3),
            ],
            b: [
                block("bg", parent: nil, height: 0, grindID: grind("bg"), work: 1),
                block("b1", parent: "bg", height: 1, grindID: g, work: 5),
            ]
        )
    }

    private let nexusContext = testChainContext(genesisCID: testCID("block:ng"))
    private let aContext = testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "A"])
    private let bContext = testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "A", "B"])

    /// The levels restored from their facts — observations only — parent
    /// first, each child re-deriving its runs before its projection.
    private func restoreLevels(_ facts: Hierarchy) throws -> (nexus: ChainTree, a: ChainTree, b: ChainTree) {
        var nexus = try ChainTree.restore(replaying: facts.nexus, context: nexusContext)
        nexus.serveRuns(for: directoryA)
        var a = try ChainTree.restore(replaying: facts.a, context: aContext, parent: nexus)
        a.serveRuns(for: directoryB)
        let b = try ChainTree.restore(replaying: facts.b, context: bContext, parent: a)
        return (nexus, a, b)
    }

    /// `subtreeWeight` rebuilds a diagnostic cache, so it reads a copy.
    private func weight(_ tree: ChainTree, _ name: String) -> WorkSum? {
        var copy = tree
        return copy.subtreeWeight(forHash: h(name))
    }

    private func attributedRun(_ tree: ChainTree, committer: String, directory: String, at child: String) -> UInt256? {
        let id = AttributedRunIdentity(carrierBlockHash: h(committer), directory: directory).contributionID!
        return tree.workContribution(id: id, at: h(child))?.work
    }

    func testRecursionNexusToAToBCountsEveryGrindOnce() throws {
        let levels = try restoreLevels(hierarchy())
        XCTAssertEqual(attributedRun(levels.a, committer: "n1", directory: directoryA, at: "a1"), UInt256(100),
                       "n2 reaches a1 through n1's run; n1's own grind G is A's already")
        XCTAssertEqual(levels.a.runWork(of: h("a1"), directory: directoryB), sum(5, 100, 3),
                       "a1's run holds what Nexus attributed to it")
        XCTAssertEqual(attributedRun(levels.b, committer: "a1", directory: directoryB, at: "b1"), UInt256(103),
                       "n2 + a2: two levels down, G subtracted at a1")
        XCTAssertEqual(weight(levels.b, "b1"), sum(5, 100, 3),
                       "G once, n2 once, a2 once: the work that secures b1, no grind twice")
    }

    /// The fixed point depends on neither weigh order nor replay order: every
    /// level's facts arrive in a random interleaving, each level deriving from
    /// its parent after EVERY arrival, in whatever level order — and the
    /// result equals the restore of the same facts.
    func testDerivationIsIndependentOfWeighAndReplayOrder() throws {
        let facts = hierarchy()
        let expected = try restoreLevels(facts)
        var rng = SeededRNG(seed: 0x0DE5_0DE5)
        for trial in 0..<12 {
            var nexus = try ChainTree.restore(replaying: [facts.nexus[0]], context: nexusContext)
            var a = try ChainTree.restore(replaying: [facts.a[0]], context: aContext)
            var b = try ChainTree.restore(replaying: [facts.b[0]], context: bContext)
            if trial % 2 == 0 { nexus.serveRuns(for: directoryA); a.serveRuns(for: directoryB) }
            var arrivals = facts.nexus.dropFirst().map { (0, $0) }
                + facts.a.dropFirst().map { (1, $0) } + facts.b.dropFirst().map { (2, $0) }
            arrivals.shuffle(using: &rng)
            for (level, fact) in arrivals {
                switch level {
                case 0: _ = try nexus.replay(fact)
                case 1: _ = try a.replay(fact)
                default: _ = try b.replay(fact)
                }
                // Child level before parent level half the time: a stale
                // derivation is only ever raised later, never wrong.
                if Bool.random(using: &rng) {
                    b.applyParentRun(from: a, directory: directoryB)
                    a.applyParentRun(from: nexus, directory: directoryA)
                } else {
                    a.applyParentRun(from: nexus, directory: directoryA)
                    b.applyParentRun(from: a, directory: directoryB)
                }
            }
            if trial % 2 == 1 { nexus.serveRuns(for: directoryA); a.serveRuns(for: directoryB) }
            a.applyParentRun(from: nexus, directory: directoryA)
            b.applyParentRun(from: a, directory: directoryB)
            for (name, live, cold) in [("a1", a, expected.a), ("b1", b, expected.b)] {
                XCTAssertEqual(weight(live, name), weight(cold, name),
                               "trial \(trial): \(name)")
            }
            XCTAssertEqual(b.canonicalTip, expected.b.canonicalTip, "trial \(trial)")
        }
    }

    /// Restore re-derives identical weights: attributed runs are never facts,
    /// and a restart rebuilds them from the parent level, in any fact order.
    func testRestoreReDerivesIdenticalWeights() throws {
        let facts = hierarchy()
        let live = try restoreLevels(facts)
        var rng = SeededRNG(seed: 0xC01D_57A7)
        for trial in 0..<6 {
            let shuffled = Hierarchy(
                nexus: facts.nexus.shuffled(using: &rng),
                a: facts.a.shuffled(using: &rng),
                b: facts.b.shuffled(using: &rng)
            )
            let cold = try restoreLevels(shuffled)
            for name in ["a1", "a2", "ag"] {
                XCTAssertEqual(weight(cold.a, name), weight(live.a, name),
                               "trial \(trial): \(name)")
            }
            for name in ["b1", "bg"] {
                XCTAssertEqual(weight(cold.b, name), weight(live.b, name),
                               "trial \(trial): \(name)")
            }
        }
        // Without the parent, a restore holds observations only.
        let bare = try ChainTree.restore(replaying: facts.b, context: bContext)
        XCTAssertEqual(weight(bare, "b1"), sum(5))
    }

    // MARK: - Cost, as counters

    /// Run bookkeeping is O(#directories with a nearest committer) per
    /// connected block — never O(height). Asserted exactly, and by ratio.
    func testRunUpdatesArePerDirectoryNotPerHeight() async throws {
        func build(depth: Int, directories: [String]) async throws -> UInt64 {
            let chain = try await ChainState.restoreWithoutContext(replaying: [batch("g", parent: nil, height: 0, work: 1)])
            for directory in directories { await chain.serveRuns(for: directory) }
            let commits = Dictionary(uniqueKeysWithValues: directories.map { ($0, testCID("c-\($0)")) })
            _ = try await chain.replay(batch("p1", parent: "g", height: 1, work: 2, commits: commits))
            let start = await chain.runAttributionUpdateCount
            var parent = "p1"
            for i in 2...depth {
                let h = "p\(i)"
                _ = try await chain.replay(batch(h, parent: parent, height: UInt64(i), work: 2))
                parent = h
            }
            let end = await chain.runAttributionUpdateCount
            return end - start
        }
        let oneDir64 = try await build(depth: 64, directories: [d])
        let oneDir512 = try await build(depth: 512, directories: [d])
        let threeDir64 = try await build(depth: 64, directories: [d, "A", "B"])
        XCTAssertEqual(oneDir64, 63, "one update per block after the committer")
        XCTAssertEqual(oneDir512, 511, "flat per block as height grows")
        XCTAssertEqual(threeDir64, 63 * 3, "three served directories: three updates per block")
        XCTAssertEqual(Double(oneDir512) / Double(oneDir64), 511.0 / 63.0, accuracy: 0.001,
                       "the per-block cost does not depend on height")
    }

    /// The Euler subtree query the child's fork choice reads: visits bounded
    /// by the sequence tree's height, asserted at two sizes so a
    /// slow-but-constant implementation cannot pass.
    func testEulerSubtreeQueryVisitsAreLogarithmic() {
        func visits(n: Int) -> Int {
            var events: [NamedEulerIndex.Event] = []
            for i in 0..<n { events.append(.open("b\(i)", WorkSum(UInt256(1)))) }
            for i in (0..<n).reversed() { events.append(.close("b\(i)")) }
            let index = NamedEulerIndex.build(events: events)
            let query = index.subtreeWorkVisiting("b0")
            XCTAssertEqual(query?.work, WorkSum(UInt256(UInt64(n))))
            return query?.visits ?? .max
        }
        let small = visits(n: 64), large = visits(n: 4_096)
        // Two prefix walks, each ≤ AVL height ≤ 1.45·log2(2n) + 2.
        XCTAssertLessThanOrEqual(small, 2 * 13)
        XCTAssertLessThanOrEqual(large, 2 * 22)
        XCTAssertLessThan(Double(large) / Double(small), 4.0,
                          "64× the blocks must cost far less than 4× the visits")
    }
}
