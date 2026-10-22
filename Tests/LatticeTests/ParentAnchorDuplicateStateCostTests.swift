import XCTest
import UInt256
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeBlockTree

/// What `executedSetAdvanced` costs when many executed blocks share one
/// post-state. Same post-state on many blocks is cheap to arrange (the same
/// transactions under different headers), so a per-pair test would make a
/// refusal cost |producers(from)| x |producers(to)| ancestry tests: about 7 s
/// at a million pairs. Over the outermost producer ranges it is near-linear,
/// tens of milliseconds there, and the bound sits far below the quadratic
/// cost so a regression to it fails.
final class ParentAnchorDuplicateStateCostTests: XCTestCase {
    private struct Builder {
        var batches: [BlockImportBatch] = []
        var next = 0
        mutating func add(parent: String?, height: UInt64, from: String, to: String) -> String {
            let hash = testCID("dup-cost-block-\(next)")
            batches.append(BlockImportBatch(facts: [
                .block(ChainBlockFact(
                    blockHash: hash, parentBlockHash: parent, blockHeight: height,
                    postStateCID: to, prevStateCID: from, specCID: AnchorCIDPool.spec,
                    target: UInt256.max.toHexString(), nextTarget: UInt256.max.toHexString(),
                    timestamp: Int64(next), stateDiff: .empty
                )),
                .work(ChainWorkFact(blockHash: hash, contribution: VerifiedWorkContribution(
                    id: testCID("dup-cost-grind-\(next)"), work: 1
                ))),
                .validation(ChainValidationFact(blockHash: hash)),
            ]))
            next += 1
            return hash
        }
    }

    private let r = AnchorCIDPool.states[0], s = AnchorCIDPool.states[1], t = AnchorCIDPool.states[2]
    private let a = AnchorCIDPool.states[3], b = AnchorCIDPool.states[4]
    private let c = AnchorCIDPool.states[5], d = AnchorCIDPool.states[6]

    private func measure(_ body: () -> Bool) -> (Bool, Double) {
        let clock = ContinuousClock()
        var result = false
        let elapsed = clock.measure { result = body() }
        let parts = elapsed.components
        return (result, Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)
    }

    private func report(
        _ name: String, _ tree: inout ChainTree, from: String, to: String, expected: Bool,
        boundMilliseconds: Double
    ) {
        let pairs = tree.frontier.anchoredProducers(of: from).count * tree.frontier.anchoredProducers(of: to).count
        let (answer, newMs) = measure { tree.executedSetAdvanced(from: from, to: to) }
        var copy = tree
        let (old, oldMs) = measure { copy.hasStateContinuity(from: from, to: to) }
        XCTAssertEqual(answer, expected, name)
        XCTAssertEqual(old, expected, "\(name): the graph search agrees")
        XCTAssertLessThan(newMs, boundMilliseconds, name)
        print(String(
            format: "[anchor-cost] %@: blocks %d, producer pairs %d, executedSetAdvanced %.2f ms (%.2f us/pair), old search %.2f ms",
            name, tree.graph.records.count, pairs, newMs, pairs > 0 ? newMs * 1_000 / Double(pairs) : 0, oldMs
        ))
    }

    /// genesis (empty -> r) with `k` children r -> s and `k` children r -> t:
    /// "did s advance to t" is a refusal that tries all k^2 pairs.
    func testSiblingsSharingAPostState() throws {
        for k in [50, 100, 200, 400, 800] {
            var builder = Builder()
            let genesis = builder.add(parent: nil, height: 0, from: AnchorCIDPool.empty, to: r)
            var firstS: String?
            for _ in 0..<k {
                let x = builder.add(parent: genesis, height: 1, from: r, to: s)
                firstS = firstS ?? x
            }
            for _ in 0..<k { _ = builder.add(parent: genesis, height: 1, from: r, to: t) }
            // One honest s -> t, so the true answer exists among k^2 pairs.
            _ = builder.add(parent: firstS, height: 2, from: s, to: t)
            var tree = try ChainTree.restoreWithoutContext(replaying: builder.batches)
            report("siblings k=\(k) s->t (one true pair)", &tree, from: s, to: t, expected: true, boundMilliseconds: 1_000)
            report("siblings k=\(k) t->s (refusal)", &tree, from: t, to: s, expected: false, boundMilliseconds: 1_000)
        }
    }

    /// Hundreds of no-op blocks (prevState == postState) after one producer:
    /// no-ops are not producers, so they add nothing to the pair count.
    func testNoOpRuns() throws {
        for run in [200, 800] {
            var builder = Builder()
            var tip = builder.add(parent: nil, height: 0, from: AnchorCIDPool.empty, to: r)
            tip = builder.add(parent: tip, height: 1, from: r, to: s)
            for h in 0..<run { tip = builder.add(parent: tip, height: UInt64(2 + h), from: s, to: s) }
            _ = builder.add(parent: tip, height: UInt64(2 + run), from: s, to: t)
            var tree = try ChainTree.restoreWithoutContext(replaying: builder.batches)
            XCTAssertEqual(tree.frontier.anchoredProducers(of: s).count, 1)
            report("no-op run \(run) s->t", &tree, from: s, to: t, expected: true, boundMilliseconds: 1_000)
            report("no-op run \(run) t->s", &tree, from: t, to: s, expected: false, boundMilliseconds: 1_000)
        }
    }

    /// Two branches off one genesis, each oscillating between two states
    /// (a deposit and its withdrawal, say): `n` producers of each state, and
    /// asking across branches is a refusal over (n/2)^2 pairs.
    func testOscillatingBranches() throws {
        for length in [200, 800, 2_000] {
            var builder = Builder()
            let genesis = builder.add(parent: nil, height: 0, from: AnchorCIDPool.empty, to: r)
            var left = genesis, right = genesis
            var leftState = r, rightState = r
            for h in 0..<length {
                let nextLeft = h.isMultiple(of: 2) ? a : b
                left = builder.add(parent: left, height: UInt64(h + 1), from: leftState, to: nextLeft)
                leftState = nextLeft
                let nextRight = h.isMultiple(of: 2) ? c : d
                right = builder.add(parent: right, height: UInt64(h + 1), from: rightState, to: nextRight)
                rightState = nextRight
            }
            var tree = try ChainTree.restoreWithoutContext(replaying: builder.batches)
            report("oscillating 2x\(length) a->b (forward)", &tree, from: a, to: b, expected: true, boundMilliseconds: 1_000)
            report("oscillating 2x\(length) a->c (sideways refusal)", &tree, from: a, to: c, expected: false, boundMilliseconds: 1_000)
        }
    }
}
