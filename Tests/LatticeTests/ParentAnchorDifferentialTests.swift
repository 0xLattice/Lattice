import XCTest
import UInt256
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeBlockTree

/// `executedSetAdvanced` (an ancestry test over producers) against the
/// graph search it replaced (`hasStateContinuity`) and against an independent
/// model of §5.3 step 6, on thousands of random parent trees: several roots,
/// forks, the same state produced on many blocks, no-op transitions, weighed
/// (unexecuted) blocks, permanent orphans, orphan components that graft late,
/// and excluded subtrees.
///
/// The two definitions coincide when every block's `prevState` is its
/// parent's `postState` (§12.1) and every genesis starts from the empty state
/// (§5.1 rule 4): the search succeeds at a block `B` with `B.prevState ==
/// from`, and walking up from `B` through no-op blocks reaches a non-no-op
/// producer of `from` — an ancestor of the producer of `to` — unless it reaches
/// a genesis, whose pre-state is the empty state, which both special-case.
/// Where those premises fail the definitions part; see the two documented
/// divergence tests below.
final class ParentAnchorDifferentialTests: XCTestCase {
    private var empty: String { AnchorCIDPool.empty }

    /// The old answer, with the new rule for equal states: the search treats
    /// `from == to` as continuity without asking whether `to` was produced.
    private func oracle(_ tree: inout ChainTree, from: String, to: String) -> Bool {
        if from == to || from == empty {
            return tree.frontier.chainProduced(stateCID: to)
        }
        return tree.hasStateContinuity(from: from, to: to)
    }

    func testAdvancedMatchesTheGraphSearchOnRandomTrees() throws {
        let trials = 2_500
        var pairs = 0, positives = 0, trees = 0
        var equalStateSearchSaysYesButUnproduced = 0
        var noOpBlocks = 0, unexecuted = 0, excluded = 0, orphans = 0, duplicateProducers = 0
        var failures = 0, grafts = 0
        for seed in 1...UInt64(trials) {
            let model = AnchorModelGenerator.make(seed: seed)
            var rng = AnchorRandom(seed: seed ^ 0xA11CE)
            let anchored = model.anchored()
            var live = try model.liveTree(model.liveOrder(&rng, topological: rng.chance(30)))
            var allBatches = model.allBatches()
            rng.shuffle(&allBatches)
            var restored = try ChainTree.restoreWithoutContext(replaying: allBatches)
            trees += 2
            grafts += Int(live.segmentGraftCount)

            noOpBlocks += model.delivered.filter { $0.prev == $0.post }.count
            unexecuted += model.delivered.filter { !$0.executed }.count
            excluded += model.delivered.filter(\.excluded).count
            orphans += model.delivered.filter { $0.parent.map { model[$0]?.phantom == true } ?? false }.count
            let producedBy = Dictionary(grouping: model.blocks.filter { anchored.contains($0.hash) && $0.prev != $0.post }, by: \.post)
            duplicateProducers += producedBy.values.filter { $0.count > 1 }.count

            XCTAssertEqual(live.frontier.anchored, anchored, "seed \(seed): live anchored set")
            XCTAssertEqual(restored.frontier.anchored, anchored, "seed \(seed): restored anchored set")

            let states = model.queryStates
            for from in states {
                for to in states {
                    let expected = model.advanced(from: from, to: to, anchored: anchored)
                    let liveNew = live.executedSetAdvanced(from: from, to: to)
                    let restoredNew = restored.executedSetAdvanced(from: from, to: to)
                    let liveOld = oracle(&live, from: from, to: to)
                    let restoredOld = oracle(&restored, from: from, to: to)
                    pairs += 1
                    if expected { positives += 1 }
                    if from == to, !expected, live.hasStateContinuity(from: from, to: to) {
                        equalStateSearchSaysYesButUnproduced += 1
                    }
                    if liveNew != expected || restoredNew != expected || liveOld != expected || restoredOld != expected {
                        failures += 1
                        if failures <= 10 {
                            XCTFail("""
                            seed \(seed) from \(label(from)) to \(label(to)): model \(expected) \
                            live new \(liveNew) restored new \(restoredNew) live old \(liveOld) restored old \(restoredOld)
                            \(describe(model))
                            """)
                        }
                    }
                }
            }
        }
        print("""
        [anchor-differential] trees \(trees) (\(trials) models x live+restored), pairs \(pairs) \
        (true \(positives)), mismatches \(failures); blocks: no-op \(noOpBlocks), unexecuted \(unexecuted), \
        excluded \(excluded), orphan \(orphans), live orphan grafts \(grafts); states with >1 producer \(duplicateProducers); \
        equal-state pairs the old search alone would pass unproduced \(equalStateSearchSaysYesButUnproduced)
        """)
        XCTAssertEqual(failures, 0)
        XCTAssertGreaterThan(grafts, 0, "orphan components grafted")
    }

    /// The wholesale graph initializer (`ForkChoice.build` + `seedAnchored`)
    /// answers like live admission and like replay, on trees without
    /// exclusions (the initializer carries none).
    func testWholesaleLiveAndReplayedTreesAgree() throws {
        var shape = AnchorModelGenerator.Shape()
        shape.excludePercent = 0
        shape.maxBlocks = 80
        var pairs = 0, ancestryPairs = 0
        for seed in 1...UInt64(600) {
            let model = AnchorModelGenerator.make(seed: seed &* 7_919, shape: shape)
            var rng = AnchorRandom(seed: seed)
            let live = try model.liveTree(model.liveOrder(&rng, topological: false))
            var batches = model.allBatches()
            rng.shuffle(&batches)
            let restored = try ChainTree.restoreWithoutContext(replaying: batches)
            let wholesale = try model.wholesaleTree()
            let anchored = model.anchored()
            for from in model.queryStates {
                for to in model.queryStates {
                    let expected = model.advanced(from: from, to: to, anchored: anchored)
                    pairs += 1
                    guard live.executedSetAdvanced(from: from, to: to) == expected,
                          restored.executedSetAdvanced(from: from, to: to) == expected,
                          wholesale.executedSetAdvanced(from: from, to: to) == expected else {
                        XCTFail("seed \(seed) from \(label(from)) to \(label(to)) expected \(expected)\n\(describe(model))")
                        return
                    }
                }
            }
            // Ancestry itself, over every pair of delivered blocks: routed
            // blocks answer the model, orphan components are unrouted (nil).
            let routed = Self.routed(model)
            for a in model.delivered {
                for b in model.delivered {
                    let expected: Bool? = routed.contains(a.hash) && routed.contains(b.hash)
                        ? model.isAncestorOrSelf(a.hash, b.hash) : nil
                    ancestryPairs += 1
                    for (name, tree) in [("live", live), ("restored", restored), ("wholesale", wholesale)] {
                        if tree.forkChoice.isAncestorOrSelf(a.hash, of: b.hash) != expected {
                            XCTFail("seed \(seed) \(name): \(model.byHash[a.hash]!) encloses \(model.byHash[b.hash]!) expected \(String(describing: expected))")
                            return
                        }
                    }
                }
            }
        }
        print("[anchor-construction] 600 models x live/restored/wholesale: advanced pairs \(pairs), ancestry pairs \(ancestryPairs)")
    }

    /// Delivered blocks connected to a delivered genesis.
    static func routed(_ model: AnchorModel) -> Set<String> {
        var result = Set<String>()
        for block in model.blocks where !block.phantom {
            var cursor: AnchorModelBlock? = block
            var connected = false
            while let current = cursor, !current.phantom {
                guard let parent = current.parent else { connected = true; break }
                cursor = model[parent]
            }
            if connected { result.insert(block.hash) }
        }
        return result
    }

    // MARK: - Where the definitions part (unreachable for valid blocks)

    private func batch(_ block: String, parent: String?, height: UInt64, from: String, to: String, grind: Int) -> BlockImportBatch {
        BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: block, parentBlockHash: parent, blockHeight: height,
                postStateCID: to, prevStateCID: from, specCID: AnchorCIDPool.spec,
                target: UInt256.max.toHexString(), nextTarget: UInt256.max.toHexString(),
                timestamp: Int64(height), stateDiff: .empty
            )),
            .work(ChainWorkFact(blockHash: block, contribution: VerifiedWorkContribution(id: AnchorCIDPool.grinds[grind], work: 1))),
            .validation(ChainValidationFact(blockHash: block)),
        ])
    }

    /// A genesis whose pre-state is not the empty state (§5.1 rule 4 forbids
    /// it). The search proves `a -> c` from the genesis' own `prevState`; the
    /// ancestry test finds no block that PRODUCED `a`, so it refuses. The
    /// ancestry test is the one §5.3 step 6 describes ("is or descends from a
    /// block that produced" the predecessor's anchor).
    func testAGenesisPreStateIsNotProducedByAnyBlock() throws {
        let a = AnchorCIDPool.states[0], b = AnchorCIDPool.states[1], c = AnchorCIDPool.states[2]
        let g = AnchorCIDPool.blocks[0], x = AnchorCIDPool.blocks[1]
        var tree = try ChainTree.restoreWithoutContext(replaying: [
            batch(g, parent: nil, height: 0, from: a, to: b, grind: 0),
            batch(x, parent: g, height: 1, from: b, to: c, grind: 1),
        ])
        XCTAssertTrue(tree.hasStateContinuity(from: a, to: c))
        XCTAssertFalse(tree.executedSetAdvanced(from: a, to: c))
    }

    /// A block whose `prevState` is not its parent's `postState` (§12.1, §5.2
    /// rule 3 forbid it; an executed block cannot have it). The search follows
    /// state links and the ancestry test follows block links, so each answers
    /// a pair the other refuses.
    func testABrokenStateLinkIsWhereTheDefinitionsPart() throws {
        let a = AnchorCIDPool.states[0], b = AnchorCIDPool.states[1]
        let c = AnchorCIDPool.states[2], d = AnchorCIDPool.states[3]
        let g = AnchorCIDPool.blocks[0], p = AnchorCIDPool.blocks[1], q = AnchorCIDPool.blocks[2]
        var tree = try ChainTree.restoreWithoutContext(replaying: [
            batch(g, parent: nil, height: 0, from: empty, to: a, grind: 0),
            batch(p, parent: g, height: 1, from: a, to: b, grind: 1),
            batch(q, parent: p, height: 2, from: c, to: d, grind: 2),
        ])
        XCTAssertFalse(tree.hasStateContinuity(from: b, to: d), "the state link b -> c is broken")
        XCTAssertTrue(tree.executedSetAdvanced(from: b, to: d), "q descends from b's producer")
        XCTAssertTrue(tree.hasStateContinuity(from: c, to: d), "q's own transition")
        XCTAssertFalse(tree.executedSetAdvanced(from: c, to: d), "nothing produced c")
    }

    // MARK: - Diagnostics

    private func label(_ state: String) -> String {
        if state == empty { return "empty" }
        if state == AnchorCIDPool.neverSeen { return "never" }
        return AnchorCIDPool.states.firstIndex(of: state).map { "s\($0)" } ?? state
    }

    private func describe(_ model: AnchorModel) -> String {
        func name(_ hash: String?) -> String {
            guard let hash else { return "nil" }
            return AnchorCIDPool.blocks.firstIndex(of: hash).map { "b\($0)" } ?? hash
        }
        return model.blocks.map { block in
            "\(name(block.hash)) parent \(name(block.parent)) h\(block.height) \(label(block.prev))->\(label(block.post))"
                + (block.phantom ? " phantom" : "") + (block.executed ? " executed" : "")
                + (block.separateValidation ? "(late)" : "") + (block.excluded ? " excluded" : "")
        }.joined(separator: "\n")
    }
}
