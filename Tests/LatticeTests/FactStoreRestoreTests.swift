import XCTest
import UInt256
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticeBlockTree

/// `ChainTree.restore(facts:)` against `restore(replaying:)`, over random
/// journals as a node stages them, and a fact store that keeps each fact
/// once by its id at the sequence number of the batch that first staged it.
final class FactStoreRestoreTests: XCTestCase {
    private let context = try! ChainRuntimeContext(path: [DEFAULT_ROOT_DIRECTORY, "Fork"])

    /// The journal: the seeded graph's batches (two roots, forks, blocks
    /// before their parents, second grinds, stronger observations,
    /// exclusions, validations) in its scripted or a shuffled arrival order.
    /// A validation is sometimes staged as the node's execution batch,
    /// re-stating the block fact and one grind (sometimes
    /// stronger than any seen yet), and sometimes folded into the block's own
    /// batch (the eager tier).
    private struct Journal {
        var batches: [BlockImportBatch] = []
        var executionBatches = 0
        var eagerBatches = 0
        var raisedGrinds = 0
    }

    private func journal(_ graph: ForkChoiceGoldenGraph, random: inout GoldenRandom) -> Journal {
        let order = random.chance(50) ? graph.events : graph.alternateArrivalOrder(seed: random.next())
        let blocks = Dictionary(uniqueKeysWithValues: graph.events.flatMap(\.batch.facts).compactMap {
            fact -> (String, ChainBlockFact)? in
            guard case .block(let block) = fact else { return nil }
            return (block.blockHash, block)
        })
        var strongest: [String: VerifiedWorkContribution] = [:]
        var journal = Journal()
        for event in order {
            for case .work(let work) in event.batch.facts
            where work.contribution.work > strongest[work.blockHash]?.work ?? .zero {
                strongest[work.blockHash] = work.contribution
            }
            guard event.kind == .validation, random.chance(70),
                  case .validation(let validation) = event.batch.facts[0],
                  let block = blocks[validation.blockHash] else {
                journal.batches.append(event.batch)
                continue
            }
            let restatedBlock = ChainFact.block(block)
            if let last = journal.batches.last, last.facts.count == 2,
               case .block(let staged) = last.facts[0], staged.blockHash == block.blockHash,
               random.chance(50) {
                // Weighed and executed at once: one batch.
                journal.batches[journal.batches.count - 1] = BlockImportBatch(
                    facts: [restatedBlock, last.facts[1], event.batch.facts[0]]
                )
                journal.eagerBatches += 1
                continue
            }
            var grind = strongest[block.blockHash]!
            if random.chance(20) {
                grind = VerifiedWorkContribution(id: grind.id, work: grind.work + UInt256(1))
                strongest[block.blockHash] = grind
                journal.raisedGrinds += 1
            }
            journal.batches.append(BlockImportBatch(facts: [
                restatedBlock,
                .work(ChainWorkFact(blockHash: block.blockHash, contribution: grind)),
                event.batch.facts[0],
            ]))
            journal.executionBatches += 1
        }
        return journal
    }

    /// The node's fact store: each fact once by id, at the first-seen batch
    /// sequence number and its position in that batch. A re-stated block
    /// fact is updated in place and keeps its first-seen place.
    private struct FactStore {
        struct Row {
            let seq: Int
            let position: Int
            var fact: ChainFact
        }

        var rows: [ChainFactID: Row] = [:]

        init(_ journal: [BlockImportBatch]) {
            for (seq, batch) in journal.enumerated() {
                for (position, fact) in batch.facts.enumerated() {
                    if rows[fact.id] == nil {
                        rows[fact.id] = Row(seq: seq, position: position, fact: fact)
                    } else if case .block = fact {
                        rows[fact.id]!.fact = fact
                    }
                }
            }
        }

        /// In `(seq, position)` order, as the node reads them back.
        var facts: [ChainFact] {
            rows.values.sorted { ($0.seq, $0.position) < ($1.seq, $1.position) }.map(\.fact)
        }
    }

    private func capture(_ tree: ChainTree, _ graph: ForkChoiceGoldenGraph) async throws -> ForkChoiceGolden {
        var chain = tree.detached()
        chain.serveRuns(for: ForkChoiceGoldenGraph.directory)
        return try await ForkChoiceGolden.capture(chain, graph: graph)
    }

    func testRestoreFromFactsEqualsRestoreFromBatches() async throws {
        var executions = 0, eager = 0, raised = 0
        for seed in UInt64(1)...12 {
            var random = GoldenRandom(seed: seed &* 0x9E37_79B9_7F4A_7C15)
            let graph = ForkChoiceGoldenGraph.generate(seed: seed, blockCount: 40 + random.nextInt(120))
            let staged = journal(graph, random: &random)
            let journal = staged.batches
            let store = FactStore(journal)
            executions += staged.executionBatches
            eager += staged.eagerBatches
            raised += staged.raisedGrinds

            // Live: every batch through the reducer in journal order.
            var live = try ChainTree.restore(replaying: [journal[0]], context: context)
            for batch in journal.dropFirst() { _ = try live.replay(batch) }

            let fromBatches = try ChainTree.restore(replaying: journal, context: context)
            let expected = try await capture(fromBatches, graph)

            var shuffled = store.facts
            random.shuffle(&shuffled)
            for facts in [store.facts, shuffled] {
                let fromFacts = try ChainTree.restore(facts: facts, context: context)
                let actual = try await capture(fromFacts, graph)
                XCTAssertEqual(
                    ForkChoiceGolden.diff(expected: expected, actual: actual), [], "seed \(seed)"
                )
            }
        }
        XCTAssertGreaterThan(executions, 0, "execution batches must re-state block facts")
        XCTAssertGreaterThan(eager, 0, "some blocks must stage executed in one batch")
        XCTAssertGreaterThan(raised, 0, "some execution batches must carry a new grind quantity")
    }

    /// Tip, and per block subtree weight, canonical membership and executed
    /// status, for a graph `ForkChoiceGolden.capture` cannot take whole.
    private func assertSameTree(_ expected: ChainTree, _ actual: ChainTree, blocks: [String]) {
        XCTAssertEqual(actual.canonicalTip, expected.canonicalTip)
        for hash in blocks {
            XCTAssertEqual(actual.subtreeWeight(forHash: hash), expected.subtreeWeight(forHash: hash), hash)
            XCTAssertEqual(actual.isCanonical(hash: hash), expected.isCanonical(hash: hash), hash)
            XCTAssertEqual(
                actual.hasExecutedAncestry(blockHash: hash), expected.hasExecutedAncestry(blockHash: hash), hash
            )
        }
    }

    /// A block fact given twice (as staged and as re-stated) restores the
    /// same tree; a copy that conflicts is refused, as the batch path
    /// refuses it.
    func testDuplicatedBlockFactRestoresTheSameTreeAndConflictsAreRefused() async throws {
        let graph = ForkChoiceGoldenGraph.generate(seed: 5, blockCount: 60)
        let journal = graph.events.map(\.batch)
        let facts = FactStore(journal).facts
        var random = GoldenRandom(seed: 5)
        var duplicated = facts
        for case .block(let block) in facts where random.chance(40) {
            duplicated.insert(.block(block), at: random.nextInt(duplicated.count + 1))
        }
        XCTAssertGreaterThan(duplicated.count, facts.count)
        let expected = try await capture(ChainTree.restore(replaying: journal, context: context), graph)
        let actual = try await capture(ChainTree.restore(facts: duplicated, context: context), graph)
        XCTAssertEqual(ForkChoiceGolden.diff(expected: expected, actual: actual), [])

        guard case .block(let block) = facts.first(where: {
            if case .block(let block) = $0 { return block.parentBlockHash != nil } else { return false }
        }) else { return XCTFail("fixture: a non-root block fact") }
        let conflicting = ChainFact.block(ChainBlockFact(
            blockHash: block.blockHash, parentBlockHash: block.parentBlockHash,
            blockHeight: block.blockHeight, postStateCID: block.postStateCID,
            prevStateCID: block.prevStateCID, specCID: block.specCID, target: block.target,
            nextTarget: block.nextTarget, timestamp: block.timestamp + 1,
            childCommitments: block.childCommitments
        ))
        XCTAssertThrowsError(try ChainTree.restore(facts: facts + [conflicting], context: context)) {
            XCTAssertEqual($0 as? ChainTreeRestoreError, .corruptConsensusGraph)
        }
    }

    /// On a root chain the genesis pin holds on the facts path: a store
    /// holding another root is refused as the batch path refuses it, and the
    /// pinned root's own subtree restores the same tree.
    func testRootLevelKeepsTheGenesisPin() throws {
        let graph = ForkChoiceGoldenGraph.generate(seed: 7, blockCount: 80)
        let root = testChainContext(genesisCID: graph.blocks[0].hash)
        let journal = graph.events.map(\.batch)
        let facts = FactStore(journal).facts
        XCTAssertThrowsError(try ChainTree.restore(replaying: journal, context: root)) {
            XCTAssertEqual($0 as? ChainTreeRestoreError, .unpinnedRootGenesis)
        }
        XCTAssertThrowsError(try ChainTree.restore(facts: facts, context: root)) {
            XCTAssertEqual($0 as? ChainTreeRestoreError, .unpinnedRootGenesis)
        }

        var pinned = Set<String>()
        for block in graph.blocks where block.index == 0 || block.parentIndex.map({ pinned.contains(graph.blocks[$0].hash) }) == true {
            pinned.insert(block.hash)
        }
        func about(_ fact: ChainFact) -> String {
            switch fact {
            case .block(let fact): fact.blockHash
            case .work(let fact): fact.blockHash
            case .validation(let fact): fact.blockHash
            case .exclusion(let fact): fact.blockHash
            }
        }
        let pinnedJournal = journal.filter { pinned.contains(about($0.facts[0])) }
        let pinnedFacts = facts.filter { pinned.contains(about($0)) }
        XCTAssertLessThan(pinnedFacts.count, facts.count, "fixture: the rival root has a subtree")
        assertSameTree(
            try ChainTree.restore(replaying: pinnedJournal, context: root),
            try ChainTree.restore(facts: pinnedFacts, context: root),
            blocks: graph.blocks.map(\.hash).filter(pinned.contains)
        )
    }

    func testRestoreFromFactsRefusesWhatBatchRestoreRefuses() throws {
        let graph = ForkChoiceGoldenGraph.generate(seed: 3, blockCount: 40)
        let facts = FactStore(graph.events.map(\.batch)).facts
        let withoutWork = facts.filter {
            guard case .work(let work) = $0 else { return true }
            return work.blockHash != graph.blocks[5].hash
        }
        let withoutGenesis = facts.filter {
            guard case .block(let block) = $0 else { return true }
            return block.parentBlockHash != nil
        }
        for corrupt in [withoutWork, withoutGenesis] {
            XCTAssertThrowsError(try ChainTree.restore(facts: corrupt, context: context)) {
                XCTAssertEqual($0 as? ChainTreeRestoreError, .corruptConsensusGraph)
            }
        }
    }
}
