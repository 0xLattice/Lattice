import XCTest
import UInt256
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeBlockTree

/// A new block under a fork point weighs against the canonical child only:
/// its siblings did not move, so a flood of them costs each insert two weight
/// reads, and the tip is the one a full projection picks.
final class SiblingFloodProjectionTests: XCTestCase {
    private func h(_ name: String) -> String { testCID("block:\(name)") }

    private func batch(_ name: String, parent: String?, height: UInt64, work: UInt64) -> BlockImportBatch {
        BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: h(name), parentBlockHash: parent.map(h), blockHeight: height,
                postStateCID: testCID("post:\(name)"), prevStateCID: testCID("prev:\(name)"),
                specCID: testCID("spec"), target: "1", nextTarget: "1",
                timestamp: Int64(height), stateDiff: .empty
            )),
            .work(ChainWorkFact(
                blockHash: h(name),
                contribution: VerifiedWorkContribution(id: testCID("work:\(name)"), work: UInt256(work))
            )),
        ])
    }

    /// Random floods under random fork points, extensions and ties included:
    /// after every insert the live tip is the one a cold restore projects.
    func testLiveTipMatchesAFullProjectionUnderSiblingFloods() throws {
        let seed = propertySeed()
        var rng = seed.generator()
        for round in 0..<20 {
            var batches = [batch("r\(round)-g", parent: nil, height: 0, work: 1)]
            var names = ["r\(round)-g"]
            var heights: [UInt64] = [0]
            var tree = try ChainTree.restoreWithoutContext(replaying: batches)
            for i in 0..<150 {
                // Mostly siblings of a few hot fork points; some extensions.
                let parent = Int.random(in: 0..<4, using: &rng) == 0
                    ? Int.random(in: 0..<names.count, using: &rng)
                    : Int.random(in: 0..<min(names.count, 3), using: &rng)
                let name = "r\(round)-\(i)"
                let next = batch(name, parent: names[parent], height: heights[parent] + 1,
                                 work: UInt64.random(in: 1...4, using: &rng))
                _ = try tree.replay(next)
                batches.append(next)
                names.append(name)
                heights.append(heights[parent] + 1)
                let cold = try ChainTree.restoreWithoutContext(replaying: batches)
                XCTAssertEqual(tree.canonicalTip, cold.canonicalTip, "round \(round) insert \(i) \(seed.note)")
            }
        }
    }

    /// Every kind of mutation the truncated path serves — new blocks (mostly
    /// siblings), orphans grafting later, stronger and new grinds at held
    /// blocks, exclusions, rival roots, equal weights — against the
    /// whole-chain projection after every step and a cold restore every 25.
    func testEveryMutationKindMatchesAFullProjection() throws {
        let seed = propertySeed()
        var rng = seed.generator()
        for round in 0..<12 {
            let root = "m\(round)-g"
            var batches = [batch(root, parent: nil, height: 0, work: 2)]
            var tree = try ChainTree.restoreWithoutContext(replaying: batches)
            var held: [(name: String, height: UInt64)] = [(root, 0)]
            var orphans: [(child: BlockImportBatch, parent: String, height: UInt64)] = []
            var grinds: [String: UInt64] = [:]
            var excludedCount = 0
            for step in 0..<300 {
                let note = "round \(round) step \(step) \(seed.note)"
                let name = "m\(round)-\(step)"
                let next: BlockImportBatch
                switch Int.random(in: 0..<20, using: &rng) {
                case 0..<10:
                    // A sibling of a few hot points, or anywhere.
                    let pick = Int.random(in: 0..<3, using: &rng) == 0
                        ? held.randomElement(using: &rng)!
                        : held[Int.random(in: 0..<min(held.count, 4), using: &rng)]
                    next = batch(name, parent: pick.name, height: pick.height + 1,
                                 work: UInt64.random(in: 1...3, using: &rng))
                    held.append((name, pick.height + 1))
                case 10..<12:
                    // An orphan now, its parent later.
                    let pick = held.randomElement(using: &rng)!
                    let child = batch(name + "-c", parent: name, height: pick.height + 2,
                                      work: UInt64.random(in: 1...6, using: &rng))
                    _ = try tree.replay(child)
                    batches.append(child)
                    orphans.append((child, pick.name, pick.height + 1))
                    continue
                case 12..<14 where !orphans.isEmpty:
                    // A parent arrives: its orphan grafts.
                    let orphan = orphans.removeFirst()
                    let parentName = orphan.child.facts.compactMap { fact -> String? in
                        guard case .block(let block) = fact else { return nil }
                        return block.parentBlockHash
                    }[0]
                    next = BlockImportBatch(facts: [
                        .block(ChainBlockFact(
                            blockHash: parentName, parentBlockHash: h(orphan.parent), blockHeight: orphan.height,
                            postStateCID: testCID("post:\(parentName)"), prevStateCID: testCID("prev:\(parentName)"),
                            specCID: testCID("spec"), target: "1", nextTarget: "1",
                            timestamp: Int64(orphan.height), stateDiff: .empty
                        )),
                        .work(ChainWorkFact(
                            blockHash: parentName,
                            contribution: VerifiedWorkContribution(id: testCID("work:\(parentName)"), work: UInt256(UInt64.random(in: 1...3, using: &rng)))
                        )),
                    ])
                case 14..<16:
                    // A stronger observation of a block's own grind.
                    let pick = held.randomElement(using: &rng)!
                    let work = (grinds[pick.name] ?? 3) + UInt64.random(in: 1...4, using: &rng)
                    grinds[pick.name] = work
                    next = BlockImportBatch(facts: [.work(ChainWorkFact(
                        blockHash: h(pick.name),
                        contribution: VerifiedWorkContribution(id: testCID("work:\(pick.name)"), work: UInt256(work))
                    ))])
                case 16..<18:
                    // A new grind located at a held block.
                    let pick = held.randomElement(using: &rng)!
                    next = BlockImportBatch(facts: [.work(ChainWorkFact(
                        blockHash: h(pick.name),
                        contribution: VerifiedWorkContribution(id: testCID("extra:\(name)"), work: UInt256(UInt64.random(in: 1...5, using: &rng)))
                    ))])
                case 18 where held.contains(where: { $0.height > 0 }) && excludedCount < 6:
                    // Never a root: a chain keeps a root it can stand on.
                    let pick = held.filter { $0.height > 0 }.randomElement(using: &rng)!
                    excludedCount += 1
                    next = BlockImportBatch(facts: [.exclusion(ChainExclusionFact(blockHash: h(pick.name)))])
                default:
                    // A rival genesis.
                    next = batch(name, parent: nil, height: 0, work: UInt64.random(in: 1...3, using: &rng))
                    held.append((name, 0))
                }
                _ = try tree.replay(next)
                batches.append(next)
                let full = try XCTUnwrap(tree.debugFullCanonicalProjection(), note)
                XCTAssertEqual(tree.canonicalTip, full.canonicalTip, note)
                XCTAssertEqual(tree.canonicalHashes, full.canonicalHashes, note)
                if step % 25 == 24 {
                    let cold = try ChainTree.restoreWithoutContext(replaying: batches)
                    XCTAssertEqual(tree.canonicalTip, cold.canonicalTip, "cold \(note)")
                }
            }
        }
    }

    /// A flood under genesis never takes the whole-chain path.
    func testAFloodOfSiblingsStaysOnTheTruncatedPath() throws {
        var tree = try ChainTree.restoreWithoutContext(replaying: [
            batch("g", parent: nil, height: 0, work: 1),
            batch("a", parent: "g", height: 1, work: 1_000),
        ])
        tree.frontier.resetFullCanonicalProjectionCount()
        for i in 0..<2_000 { _ = try tree.replay(batch("s\(i)", parent: "g", height: 1, work: 1)) }
        XCTAssertEqual(tree.frontier.fullCanonicalProjectionCount, 0)
        XCTAssertEqual(tree.canonicalTip, h("a"))
    }
}
