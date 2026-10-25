import XCTest
import UInt256
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport

// MARK: - Fixture: a seeded fact-batch script

/// One scripted arrival: a durable fact batch and what it is about, so a
/// failure can name the event and the oracle can rebuild its model from the
/// same facts.
struct ForkChoiceGoldenEvent {
    enum Kind: String {
        case block, secondGrind, strengthen, exclusion, validation
    }

    let index: Int
    let kind: Kind
    /// The block the batch is about, by fixture name (`b<n>`).
    let subject: String
    let batch: BlockImportBatch
}

/// A seeded single-chain graph of ~300 blocks: two competing genesis roots,
/// several competing branches (siblings near the tip and deep forks), blocks
/// arriving before their parents, second grinds and stronger observations on
/// blocks already held, exclusions (§9.9), validations, and commitments into
/// one child directory so this chain also keeps runs (§9.10). Attributed runs
/// are derived, never facts, so they are not in the script.
///
/// Every hash is a content id of a fixed seed string, every choice comes from
/// `GoldenRandom`, and nothing reads a clock — so the script, and therefore the
/// golden, is reproducible on any host.
struct ForkChoiceGoldenGraph {
    struct Block {
        let index: Int
        let name: String
        let hash: String
        let parentIndex: Int?
        let parentName: String?
        let parentHash: String?
        let height: UInt64
        let grind: String
        let commitsChild: Bool
    }

    static let directory = "Child"
    /// Exclusions the script plans ON the canonical selection: past the
    /// halfway and nine-tenths marks, and at the final arrival. Each must
    /// move the tip when it lands. The last one has nothing planned after
    /// it, so its subtree is never overtaken on weight and the FINAL state
    /// is exclusion-sensitive too, not only the trace.
    static let plannedDecisiveExclusions = 3

    /// Arrival counts past which each planned decisive exclusion fires.
    static func decisiveMarks(blockCount: Int) -> [Int] {
        let marks = [blockCount / 2, blockCount * 9 / 10, blockCount - 1]
        precondition(marks.count == plannedDecisiveExclusions)
        return marks
    }

    let seed: UInt64
    let blocks: [Block]
    let events: [ForkChoiceGoldenEvent]
    /// Event indices of the planned decisive exclusions, in script order.
    let decisiveExclusionEvents: [Int]

    var blocksByName: [String: Block] {
        Dictionary(uniqueKeysWithValues: blocks.map { ($0.name, $0) })
    }

    var nameByHash: [String: String] {
        Dictionary(uniqueKeysWithValues: blocks.map { ($0.hash, $0.name) })
    }

    private static func cid(_ seed: UInt64, _ role: String, _ index: Int) -> String {
        testCID("fork-choice-golden/\(seed)/\(role)/\(index)")
    }

    /// A second LIVE arrival order for the same facts: the seed root first,
    /// then a full seeded shuffle of the block arrivals — so most blocks are
    /// deep orphans grafted later — with each block's other facts (work,
    /// exclusion, validation) following its arrival in their shuffled order,
    /// since a node never applies a fact about a block it does not hold.
    func alternateArrivalOrder(seed: UInt64 = 0xA17E_0DE5) -> [ForkChoiceGoldenEvent] {
        var random = GoldenRandom(seed: seed)
        var shuffled = Array(events.dropFirst())
        random.shuffle(&shuffled)
        var ordered = [events[0]]
        var arrived: Set<String> = [events[0].subject]
        var waiting: [String: [ForkChoiceGoldenEvent]] = [:]
        for event in shuffled {
            if event.kind == .block {
                ordered.append(event)
                arrived.insert(event.subject)
                ordered += waiting.removeValue(forKey: event.subject) ?? []
            } else if arrived.contains(event.subject) {
                ordered.append(event)
            } else {
                waiting[event.subject, default: []].append(event)
            }
        }
        precondition(waiting.isEmpty && ordered.count == events.count)
        return ordered
    }

    static func generate(seed: UInt64 = 0x600D_F0C5, blockCount: Int = 300) -> ForkChoiceGoldenGraph {
        precondition(blockCount >= 16)
        var random = GoldenRandom(seed: seed)

        var blocks: [Block] = []
        var indexByHash: [String: Int] = [:]
        var primarySubtree = [0]
        var secondarySubtree = [1]
        var events: [ForkChoiceGoldenEvent] = []
        var arrived: [Int] = []
        var excluded = Set<Int>()
        var decisiveExclusionEvents: [Int] = []
        var validated = Set<Int>()
        var strength: [Int: UInt64] = [:]
        var extraCounter = 0
        // The spec oracle follows the script so exclusion targets can be
        // chosen against the CURRENT canonical selection, not a guess at it.
        var oracle = ForkChoiceOracle()

        /// Under an excluded root, itself included: nothing a node extends
        /// (§9.9), so nothing the generator builds on once the verdict is in.
        func underExcludedRoot(_ index: Int) -> Bool {
            var current: Int? = index
            while let step = current {
                if excluded.contains(step) { return true }
                current = blocks[step].parentIndex
            }
            return false
        }

        // 1. Blocks are planned in index order, each choosing a parent among
        // the blocks planned so far: the rival root's subtree occasionally,
        // a deep fork sometimes, mostly one of the highest blocks — competing
        // tips — and never a block under an excluded root AS KNOWN WHEN IT IS
        // PLANNED. Planning runs just ahead of arrival (step 3: at most three
        // blocks, the reach of the arrival swaps in step 2), so a block planned
        // in that window before a verdict lands may still extend the excluded
        // block — exactly a miner that had not yet heard the verdict. The
        // coverage test bounds that look-ahead.
        func plan(_ index: Int) {
            precondition(blocks.count == index, "blocks are planned in index order")
            let parent: Block?
            if index < 2 {
                parent = nil
            } else if random.chance(6) {
                let selectable = secondarySubtree.filter { !underExcludedRoot($0) }
                precondition(!selectable.isEmpty, "the rival root is never excluded")
                let parentIndex = selectable[random.nextInt(selectable.count)]
                secondarySubtree.append(index)
                parent = blocks[parentIndex]
            } else {
                let selectable = primarySubtree.filter { !underExcludedRoot($0) }
                precondition(!selectable.isEmpty, "the primary root is never excluded")
                let roll = random.nextInt(100)
                let parentIndex: Int
                if roll < 15 {
                    parentIndex = selectable[random.nextInt(selectable.count)]
                } else if roll < 25 {
                    parentIndex = selectable[selectable.count - 1]
                } else {
                    let highest = selectable.sorted {
                        blocks[$0].height != blocks[$1].height
                            ? blocks[$0].height > blocks[$1].height : $0 < $1
                    }
                    parentIndex = highest[random.nextInt(min(5, highest.count))]
                }
                primarySubtree.append(index)
                parent = blocks[parentIndex]
            }
            let block = Block(
                index: index,
                name: "b\(index)",
                hash: cid(seed, "block", index),
                parentIndex: parent?.index,
                parentName: parent?.name,
                parentHash: parent?.hash,
                height: parent.map { $0.height + 1 } ?? 0,
                grind: cid(seed, "grind", index),
                // Every ninth block commits into the served directory.
                commitsChild: index >= 2 && index % 9 == 0
            )
            blocks.append(block)
            indexByHash[block.hash] = index
        }

        // 2. Arrival order: mostly ascending, with local swaps so some blocks
        // arrive before their (recent) parents. The seed root arrives first.
        var order = Array(1..<blockCount)
        var position = 0
        while position + 3 < order.count {
            if random.chance(50) { order.swapAt(position, position + 2) }
            if random.chance(30) { order.swapAt(position + 1, position + 3) }
            position += 4
        }

        // 3. The scripted facts, interleaved with the arrivals.
        func blockBatch(_ block: Block) -> BlockImportBatch {
            let work = UInt64(1 + random.nextInt(5))
            strength[block.index] = work
            return BlockImportBatch(facts: [
                .block(ChainBlockFact(
                    blockHash: block.hash,
                    parentBlockHash: block.parentHash,
                    blockHeight: block.height,
                    postStateCID: cid(seed, "post", block.index),
                    prevStateCID: cid(seed, "prev", block.index),
                    specCID: cid(seed, "spec", 0),
                    target: UInt256(UInt64(1_000 + block.index)).toHexString(),
                    nextTarget: UInt256(UInt64(1_000 + block.index)).toHexString(),
                    timestamp: Int64(block.index) * 1_000,
                    stateDiff: .empty,
                    childCommitments: block.commitsChild
                        ? [directory: cid(seed, "child-block", block.index)]
                        : [:]
                )),
                .work(ChainWorkFact(
                    blockHash: block.hash,
                    contribution: VerifiedWorkContribution(id: block.grind, work: UInt256(work))
                )),
            ])
        }
        func add(_ kind: ForkChoiceGoldenEvent.Kind, _ block: Block, _ batch: BlockImportBatch) {
            events.append(ForkChoiceGoldenEvent(
                index: events.count, kind: kind, subject: block.name, batch: batch
            ))
            oracle.apply(batch)
        }
        func exclude(_ block: Block) {
            excluded.insert(block.index)
            add(.exclusion, block, BlockImportBatch(facts: [
                .exclusion(ChainExclusionFact(blockHash: block.hash)),
            ]))
        }
        /// Recent arrivals on (`onCanonical`) or off the oracle's current
        /// canonical selection, excluding roots, already-excluded blocks and
        /// executed blocks (execution is never revoked).
        func exclusionCandidates(onCanonical: Bool) -> [Int] {
            let canonical = Set(
                (oracle.view().canonicalProjection()?.path ?? []).compactMap { indexByHash[$0] }
            )
            return arrived.suffix(20).filter {
                blocks[$0].parentHash != nil && !excluded.contains($0) && !validated.contains($0)
                    && canonical.contains($0) == onCanonical
            }
        }
        func arrive(_ index: Int) {
            let block = blocks[index]
            add(.block, block, blockBatch(block))
            arrived.append(index)
            if block.parentHash == nil {
                // Both roots are executed explicitly so the executed frontier
                // does not depend on which root seeded the restore.
                validated.insert(index)
                add(.validation, block, BlockImportBatch.validation(blockHash: block.hash))
            }
            // A DECISIVE exclusion, planned past each mark: a block ON the
            // canonical selection, so the tip must move and the golden pins a
            // canonical retreat onto the heaviest selectable branch. Forced at
            // the first arrival past the mark that offers a candidate, so the
            // planned count is met; the last mark is the final arrival.
            let marks = Self.decisiveMarks(blockCount: blockCount)
            if decisiveExclusionEvents.count < plannedDecisiveExclusions,
               arrived.count > marks[decisiveExclusionEvents.count] {
                let candidates = exclusionCandidates(onCanonical: true)
                if !candidates.isEmpty {
                    decisiveExclusionEvents.append(events.count)
                    exclude(blocks[candidates[random.nextInt(candidates.count)]])
                }
            }
        }
        plan(0)
        plan(1)
        arrive(0)
        for index in order {
            while blocks.count <= index { plan(blocks.count) }
            arrive(index)
            while random.chance(30) {
                let target = blocks[arrived[random.nextInt(arrived.count)]]
                let roll = random.nextInt(100)
                if roll < 30 {
                    extraCounter += 1
                    add(.secondGrind, target, BlockImportBatch(facts: [
                        .work(ChainWorkFact(
                            blockHash: target.hash,
                            contribution: VerifiedWorkContribution(
                                id: cid(seed, "second-grind", extraCounter),
                                work: UInt256(UInt64(1 + random.nextInt(6)))
                            )
                        )),
                    ]))
                } else if roll < 65 {
                    let stronger = strength[target.index, default: 1] + UInt64(1 + random.nextInt(3))
                    strength[target.index] = stronger
                    add(.strengthen, target, BlockImportBatch(facts: [
                        .work(ChainWorkFact(
                            blockHash: target.hash,
                            contribution: VerifiedWorkContribution(
                                id: target.grind, work: UInt256(stronger)
                            )
                        )),
                    ]))
                } else if roll < 75 {
                    // Exclude a recent LOSING block — one off the current
                    // canonical selection — so these verdicts prune side
                    // branches; the decisive ones are planned in `arrive`.
                    let candidates = exclusionCandidates(onCanonical: false)
                    guard !candidates.isEmpty else { continue }
                    exclude(blocks[candidates[random.nextInt(candidates.count)]])
                } else {
                    // Mostly extend the executed frontier (a block whose parent
                    // is executed); sometimes validate out of order, which the
                    // frontier must absorb when the parent's turn comes.
                    // Never an excluded block: an executed block is never
                    // excluded, so the two facts must not meet in any order.
                    let frontier = arrived.filter { candidate in
                        guard !validated.contains(candidate), !excluded.contains(candidate),
                              let parentIndex = blocks[candidate].parentIndex else { return false }
                        return validated.contains(parentIndex) && !excluded.contains(parentIndex)
                    }
                    let chosen = !frontier.isEmpty && random.chance(80)
                        ? blocks[frontier[random.nextInt(frontier.count)]]
                        : target
                    guard !excluded.contains(chosen.index) else { continue }
                    validated.insert(chosen.index)
                    add(.validation, chosen, BlockImportBatch.validation(blockHash: chosen.hash))
                }
            }
        }
        precondition(blocks.count == blockCount)
        return ForkChoiceGoldenGraph(
            seed: seed, blocks: blocks, events: events,
            decisiveExclusionEvents: decisiveExclusionEvents
        )
    }
}

// MARK: - The observable

/// What the golden pins, per block and globally. Hashes appear once, in the
/// block table; everything else refers to blocks by fixture name.
struct ForkChoiceGolden: Codable, Equatable {
    struct BlockRecord: Codable, Equatable {
        let name: String
        let hash: String
        let parent: String?
        let height: UInt64
        /// On the canonical projection.
        let canonical: Bool
        /// On the executed-from-genesis frontier (`hasExecutedAncestry`).
        let executed: Bool
        /// Credited work located at this block.
        let work: String
        /// `trueCumWork`: the grind-deduplicated subtree total (§9.2).
        let subtreeWork: String
        /// Prefix total from the root through this block.
        let cumulativeWork: String
        /// Difficulty anchor inherited along the parent pointer (height 1).
        let anchorTimestamp: Int64?
    }

    struct RunRecord: Codable, Equatable {
        let committer: String
        let childBlock: String
        let grinds: [String]
        let runWork: String
        let ownWork: String
    }

    let seed: UInt64
    let eventCount: Int
    let tip: String
    let tipHeight: UInt64
    /// Canonical blocks by height, from the selected root to the tip.
    let canonicalChain: [String]
    let excludedRoots: [String]
    let blocks: [BlockRecord]
    /// Every §9.10 run this chain keeps for the fixture directory.
    let runs: [RunRecord]

    static func capture(
        _ chain: ChainState,
        graph: ForkChoiceGoldenGraph
    ) async throws -> ForkChoiceGolden {
        let names = graph.nameByHash
        func name(_ hash: String) -> String { names[hash] ?? hash }

        var records: [BlockRecord] = []
        for block in graph.blocks {
            let metaValue = await chain.getConsensusBlock(hash: block.hash)
            let meta = try XCTUnwrap(metaValue, "\(block.name) missing")
            let subtreeValue = await chain.subtreeWeight(forHash: block.hash)
            let subtree = try XCTUnwrap(subtreeValue)
            let cumulativeValue = await chain.getCumulativeWork(forHash: block.hash)
            let cumulative = try XCTUnwrap(cumulativeValue)
            let canonical = await chain.isCanonical(hash: block.hash)
            let executed = await chain.hasExecutedAncestry(blockHash: block.hash)
            let anchor = await chain.difficultyAnchor(forBlockHash: block.hash)
            records.append(BlockRecord(
                name: block.name,
                hash: block.hash,
                parent: block.parentName,
                height: block.height,
                canonical: canonical,
                executed: executed,
                work: meta.work.toHexString(),
                subtreeWork: subtree.toHexString(),
                cumulativeWork: cumulative.toHexString(),
                anchorTimestamp: anchor?.timestamp
            ))
        }

        let tipHeight = await chain.getHighestBlockHeight()
        var canonical: [String] = []
        for height in 0...tipHeight {
            let hash = await chain.canonicalBlockHash(atHeight: height)
            canonical.append(try XCTUnwrap(
                hash.map(name), "canonical index has a hole at \(height)"
            ))
        }

        var runs: [RunRecord] = []
        let directory = ForkChoiceGoldenGraph.directory
        for block in graph.blocks where block.commitsChild {
            let runValue = await chain.runWork(of: block.hash, directory: directory)
            let runWork = try XCTUnwrap(runValue, "\(block.name) commits into \(directory) but keeps no run")
            let metaValue = await chain.getConsensusBlock(hash: block.hash)
            let meta = try XCTUnwrap(metaValue)
            let ownValue = await chain.grindWork(of: block.hash)
            let ownWork = try XCTUnwrap(ownValue)
            let commitments = await chain.recordedChildCommitments(of: block.hash)
            runs.append(RunRecord(
                committer: block.name,
                childBlock: try XCTUnwrap(commitments?[directory]),
                grinds: Set(meta.workContributions.keys).subtracting(meta.attributedRuns).sorted(),
                runWork: runWork.toHexString(),
                ownWork: ownWork.toHexString()
            ))
        }

        let tip = await chain.canonicalTip
        let excluded = await chain.excludedRootsForTesting
        return ForkChoiceGolden(
            seed: graph.seed,
            eventCount: graph.events.count,
            tip: name(tip),
            tipHeight: tipHeight,
            canonicalChain: canonical,
            excludedRoots: excluded.map(name).sorted(),
            blocks: records,
            runs: runs
        )
    }

    static func diff(expected: ForkChoiceGolden, actual: ForkChoiceGolden) -> [String] {
        var lines = GoldenFile.fieldDiff("global", [
            ("seed", "\(expected.seed)", "\(actual.seed)"),
            ("eventCount", "\(expected.eventCount)", "\(actual.eventCount)"),
            ("tip", expected.tip, actual.tip),
            ("tipHeight", "\(expected.tipHeight)", "\(actual.tipHeight)"),
            ("canonicalChain", "\(expected.canonicalChain)", "\(actual.canonicalChain)"),
            ("excludedRoots", "\(expected.excludedRoots)", "\(actual.excludedRoots)"),
        ])
        let actualBlocks = Dictionary(uniqueKeysWithValues: actual.blocks.map { ($0.name, $0) })
        for block in expected.blocks {
            guard let other = actualBlocks[block.name] else {
                lines.append("\(block.name): missing from actual")
                continue
            }
            lines += GoldenFile.fieldDiff(block.name, [
                ("hash", block.hash, other.hash),
                ("parent", block.parent ?? "nil", other.parent ?? "nil"),
                ("height", "\(block.height)", "\(other.height)"),
                ("canonical", "\(block.canonical)", "\(other.canonical)"),
                ("executed", "\(block.executed)", "\(other.executed)"),
                ("work", block.work, other.work),
                ("subtreeWork", block.subtreeWork, other.subtreeWork),
                ("cumulativeWork", block.cumulativeWork, other.cumulativeWork),
                ("anchorTimestamp", "\(block.anchorTimestamp.map(String.init) ?? "nil")",
                 "\(other.anchorTimestamp.map(String.init) ?? "nil")"),
            ])
        }
        for name in Set(actualBlocks.keys).subtracting(expected.blocks.map(\.name)).sorted() {
            lines.append("\(name): unexpected in actual")
        }
        let actualReports = Dictionary(uniqueKeysWithValues: actual.runs.map { ($0.committer, $0) })
        for report in expected.runs {
            guard let other = actualReports[report.committer] else {
                lines.append("run \(report.committer): missing from actual")
                continue
            }
            lines += GoldenFile.fieldDiff("run \(report.committer)", [
                ("childBlock", report.childBlock, other.childBlock),
                ("grinds", "\(report.grinds)", "\(other.grinds)"),
                ("runWork", report.runWork, other.runWork),
                ("ownWork", report.ownWork, other.ownWork),
            ])
        }
        for name in Set(actualReports.keys).subtracting(expected.runs.map(\.committer)).sorted() {
            lines.append("run \(name): unexpected in actual")
        }
        return lines
    }
}

/// What only a LIVE order can show: the tip after each checkpoint and after
/// each exclusion, how many commits removed canonical blocks (reorgs), and
/// how many exclusions moved the tip (decisive, §9.9). Order-specific, so it
/// is pinned per arrival order in its own file; the final state is in
/// `fork-choice-replay.json`.
struct ForkChoiceTraceGolden: Codable, Equatable {
    struct Checkpoint: Codable, Equatable {
        let event: Int
        let kind: String
        let subject: String
        let tip: String
        let tipHeight: UInt64
        /// Canonical blocks the event's commit removed.
        let removed: [String]
    }

    struct OrderTrace: Codable, Equatable {
        let reorgCommits: Int
        /// Reorg commits after each decisive exclusion, up to the next one
        /// (or the end): selection must keep moving once a verdict has
        /// retreated it, or the rest of the script pins a frozen tip.
        let reorgCommitsAfterDecisiveExclusion: [Int]
        let decisiveExclusions: Int
        let checkpoints: [Checkpoint]
    }

    let arrival: OrderTrace
    let alternate: OrderTrace

    static func diff(expected: ForkChoiceTraceGolden, actual: ForkChoiceTraceGolden) -> [String] {
        var lines: [String] = []
        for (order, expectedTrace, actualTrace) in [
            ("arrival", expected.arrival, actual.arrival),
            ("alternate", expected.alternate, actual.alternate),
        ] {
            lines += GoldenFile.fieldDiff(order, [
                ("reorgCommits", "\(expectedTrace.reorgCommits)", "\(actualTrace.reorgCommits)"),
                ("reorgCommitsAfterDecisiveExclusion",
                 "\(expectedTrace.reorgCommitsAfterDecisiveExclusion)",
                 "\(actualTrace.reorgCommitsAfterDecisiveExclusion)"),
                ("decisiveExclusions", "\(expectedTrace.decisiveExclusions)", "\(actualTrace.decisiveExclusions)"),
                ("checkpointCount", "\(expectedTrace.checkpoints.count)", "\(actualTrace.checkpoints.count)"),
            ])
            let actualByEvent = Dictionary(uniqueKeysWithValues: actualTrace.checkpoints.map { ($0.event, $0) })
            for checkpoint in expectedTrace.checkpoints {
                guard let other = actualByEvent[checkpoint.event] else {
                    lines.append("\(order) event \(checkpoint.event): missing from actual")
                    continue
                }
                lines += GoldenFile.fieldDiff("\(order) event \(checkpoint.event)", [
                    ("kind", checkpoint.kind, other.kind),
                    ("subject", checkpoint.subject, other.subject),
                    ("tip", checkpoint.tip, other.tip),
                    ("tipHeight", "\(checkpoint.tipHeight)", "\(other.tipHeight)"),
                    ("removed", "\(checkpoint.removed)", "\(other.removed)"),
                ])
            }
        }
        return lines
    }
}

// MARK: - Tests

/// Pins the consensus outcome of one scripted graph as data: subtree work,
/// canonical membership and executed status per block; tip, canonical chain,
/// excluded roots and served run reports globally. Both the live incremental
/// path and restore-replay in a shuffled order must reproduce the file.
@MainActor
final class ForkChoiceReplayGoldenTests: XCTestCase {
    static let goldenName = "fork-choice-replay.json"
    static let traceGoldenName = "fork-choice-replay-trace.json"

    private let graph = ForkChoiceGoldenGraph.generate()

    /// Live admission through `replay` in the given order, run attribution
    /// served from the start so the per-block live path settles it. Returns
    /// the chain and the order's trace.
    private func admitLive(
        _ order: [ForkChoiceGoldenEvent]
    ) async throws -> (chain: ChainState, trace: ForkChoiceTraceGolden.OrderTrace) {
        let names = graph.nameByHash
        func name(_ hash: String) -> String { names[hash] ?? hash }
        let chain = try await ChainState.restoreWithoutContext(replaying: [order[0].batch])
        await chain.serveRuns(for: ForkChoiceGoldenGraph.directory)
        var reorgCommits = 0
        var reorgCommitsAfterDecisiveExclusion: [Int] = []
        var decisiveExclusions = 0
        var checkpoints: [ForkChoiceTraceGolden.Checkpoint] = []
        for (position, event) in order.enumerated().dropFirst() {
            let commit: ChainCommit?
            do {
                commit = try await chain.replay(event.batch)
            } catch {
                XCTFail("position \(position), event \(event.index) (\(event.kind.rawValue) \(event.subject)) threw \(error)")
                throw error
            }
            let removed = commit?.canonicalBlocksRemoved ?? []
            if event.kind == .exclusion, !removed.isEmpty {
                decisiveExclusions += 1
                reorgCommitsAfterDecisiveExclusion.append(0)
            } else if !removed.isEmpty, !reorgCommitsAfterDecisiveExclusion.isEmpty {
                reorgCommitsAfterDecisiveExclusion[reorgCommitsAfterDecisiveExclusion.count - 1] += 1
            }
            if !removed.isEmpty { reorgCommits += 1 }
            if position % 25 == 0 || event.kind == .exclusion {
                let tip = await chain.canonicalTip
                let tipHeight = await chain.getHighestBlockHeight()
                checkpoints.append(ForkChoiceTraceGolden.Checkpoint(
                    event: event.index,
                    kind: event.kind.rawValue,
                    subject: event.subject,
                    tip: name(tip),
                    tipHeight: tipHeight,
                    removed: removed.map(name).sorted()
                ))
            }
        }
        let unresolved = await chain.unresolvedSameChainPredecessors()
        XCTAssertTrue(unresolved.isEmpty, "every block must connect once all have arrived")
        return (chain, ForkChoiceTraceGolden.OrderTrace(
            reorgCommits: reorgCommits,
            reorgCommitsAfterDecisiveExclusion: reorgCommitsAfterDecisiveExclusion,
            decisiveExclusions: decisiveExclusions,
            checkpoints: checkpoints
        ))
    }

    /// Live admission in the scripted arrival order.
    func testIncrementalAdmissionInArrivalOrderMatchesGolden() async throws {
        let (chain, _) = try await admitLive(graph.events)
        let golden = try await ForkChoiceGolden.capture(chain, graph: graph)
        try GoldenFile.assert(golden, matches: Self.goldenName, diff: ForkChoiceGolden.diff)
    }

    /// Live admission in a second, fully shuffled arrival order — the live
    /// path (not restore's sorted replay) must reach the same final state.
    func testAlternateArrivalOrderMatchesGolden() async throws {
        let order = graph.alternateArrivalOrder()
        XCTAssertNotEqual(order.map(\.index), graph.events.map(\.index), "the alternate order must differ")
        let (chain, _) = try await admitLive(order)
        let golden = try await ForkChoiceGolden.capture(chain, graph: graph)
        try GoldenFile.assert(golden, matches: Self.goldenName, diff: ForkChoiceGolden.diff)
    }

    /// Recovery: the same durable facts handed to `restore` in a shuffled
    /// order (restore sorts them itself), run attribution served afterwards
    /// over the whole graph.
    func testShuffledRestoreReplayMatchesGolden() async throws {
        var batches = graph.events.map(\.batch)
        var random = GoldenRandom(seed: 0x5EED_5EED)
        random.shuffle(&batches)
        XCTAssertNotEqual(batches, graph.events.map(\.batch), "the shuffle must move something")

        let chain = try await ChainState.restoreWithoutContext(replaying: batches)
        await chain.serveRuns(for: ForkChoiceGoldenGraph.directory)

        let golden = try await ForkChoiceGolden.capture(chain, graph: graph)
        try GoldenFile.assert(golden, matches: Self.goldenName, diff: ForkChoiceGolden.diff)
    }

    /// The order-specific observables of both live orders: checkpoint tips,
    /// reorg commits, and decisive exclusions. Reorgs and at least one
    /// decisive exclusion must occur in the scripted order — otherwise the
    /// golden pins a graph in which fork choice never had to choose.
    func testLiveAdmissionTracesMatchGolden() async throws {
        let (_, arrival) = try await admitLive(graph.events)
        let (_, alternate) = try await admitLive(graph.alternateArrivalOrder())
        XCTAssertGreaterThan(arrival.reorgCommits, 0, "the scripted order must reorg")
        XCTAssertEqual(
            arrival.decisiveExclusions, ForkChoiceGoldenGraph.plannedDecisiveExclusions,
            "every planned decisive exclusion must move the tip"
        )
        XCTAssertEqual(
            arrival.checkpoints.filter { $0.kind == "exclusion" && !$0.removed.isEmpty }.map(\.event),
            graph.decisiveExclusionEvents,
            "the exclusions that moved the tip must be exactly the planned ones"
        )
        // Selection keeps moving after every decisive exclusion that blocks
        // still arrive after. The last one lands at the final arrival by
        // design (its subtree must not be overtaken), so only the trailing
        // fact-only events follow it and movement is not required there.
        let followedByArrivals = graph.decisiveExclusionEvents.filter { decisive in
            graph.events.contains { $0.index > decisive && $0.kind == .block }
        }
        XCTAssertEqual(followedByArrivals.count, ForkChoiceGoldenGraph.plannedDecisiveExclusions - 1)
        for (position, reorgs) in arrival.reorgCommitsAfterDecisiveExclusion.enumerated()
        where position < followedByArrivals.count {
            XCTAssertGreaterThan(
                reorgs, 0,
                "selection must keep moving after decisive exclusion \(position) (event \(followedByArrivals[position])), not freeze"
            )
        }
        try GoldenFile.assert(
            ForkChoiceTraceGolden(arrival: arrival, alternate: alternate),
            matches: Self.traceGoldenName,
            diff: ForkChoiceTraceGolden.diff
        )
    }

    /// The generator's coverage claims, so a later edit to it cannot quietly
    /// drop one of the shapes the golden exists to pin.
    func testScriptCoversEveryClaimedShape() async throws {
        let byName = graph.blocksByName
        let arrivalPosition = Dictionary(
            uniqueKeysWithValues: graph.events.filter { $0.kind == .block }
                .enumerated().map { ($0.element.subject, $0.offset) }
        )
        func position(_ name: String) throws -> Int {
            try XCTUnwrap(arrivalPosition[name], "\(name) never arrives")
        }
        XCTAssertGreaterThanOrEqual(graph.blocks.count, 300)
        XCTAssertEqual(graph.blocks.filter { $0.parentHash == nil }.count, 2, "two competing roots")

        var childCounts: [String: Int] = [:]
        for block in graph.blocks {
            if let parent = block.parentName { childCounts[parent, default: 0] += 1 }
        }
        XCTAssertGreaterThan(childCounts.values.filter { $0 >= 2 }.count, 20, "many forks")

        let outOfOrder = try graph.blocks.filter { block in
            guard let parent = block.parentName else { return false }
            return try position(block.name) < position(parent)
        }
        XCTAssertGreaterThan(outOfOrder.count, 10, "children arriving before parents")

        var kinds: [ForkChoiceGoldenEvent.Kind: Int] = [:]
        for event in graph.events { kinds[event.kind, default: 0] += 1 }
        for kind in [ForkChoiceGoldenEvent.Kind.secondGrind, .strengthen, .exclusion, .validation] {
            XCTAssertGreaterThan(kinds[kind, default: 0], 3, "\(kind.rawValue) events")
        }
        XCTAssertGreaterThan(graph.blocks.filter(\.commitsChild).count, 10, "committers")
        XCTAssertTrue(
            graph.events.contains { $0.kind == .strengthen && byName[$0.subject]?.commitsChild == true },
            "a committer is strengthened, so ownWork moves after settlement"
        )

        // Each planned decisive exclusion is decisive by the spec oracle,
        // independent of the chain: the selection just before the verdict
        // (earlier verdicts applied) runs through the block, and the verdict
        // moves the tip (§9.9).
        XCTAssertEqual(graph.decisiveExclusionEvents.count, ForkChoiceGoldenGraph.plannedDecisiveExclusions)
        var oracle = ForkChoiceOracle()
        for event in graph.events {
            guard graph.decisiveExclusionEvents.contains(event.index) else {
                oracle.apply(event.batch)
                continue
            }
            let excludedHash = try XCTUnwrap(byName[event.subject], "excluded \(event.subject) is not a block").hash
            let before = try XCTUnwrap(oracle.view().canonicalProjection(), "event \(event.index): no selection")
            XCTAssertTrue(
                before.path.contains(excludedHash),
                "event \(event.index): selection before the verdict must run through \(event.subject)"
            )
            oracle.apply(event.batch)
            let after = try XCTUnwrap(oracle.view().canonicalProjection(), "event \(event.index): no selection")
            XCTAssertNotEqual(before.tip, after.tip, "event \(event.index): excluding \(event.subject) must move the tip")
            XCTAssertFalse(after.path.contains(excludedHash), "event \(event.index): the descent stepped into an excluded block")
        }
        // And the FINAL state is exclusion-sensitive: weight alone would
        // select a different tip, through an excluded block — so the three
        // final-state comparisons (arrival, alternate, restore) each see an
        // exclusion change selection, not only the trace.
        let selected = try XCTUnwrap(oracle.view().canonicalProjection())
        let weightAlone = try XCTUnwrap(oracle.view(ignoringExclusions: true).canonicalProjection())
        XCTAssertNotEqual(selected.tip, weightAlone.tip, "the excluded set must change the final selection")
        XCTAssertTrue(
            weightAlone.path.contains { oracle.excluded.contains($0) },
            "weight alone must select through an excluded block"
        )

        // The planning look-ahead: a block planned before a verdict landed may
        // extend the excluded block, but only within the reach of the arrival
        // swaps — no descendant of an excluded block arrives more than three
        // arrivals after the verdict.
        var arrivalsBefore: [Int: Int] = [:]
        var arrivalsSoFar = 0
        for event in graph.events {
            arrivalsBefore[event.index] = arrivalsSoFar
            if event.kind == .block { arrivalsSoFar += 1 }
        }
        func descends(_ block: ForkChoiceGoldenGraph.Block, from ancestor: String) -> Bool {
            var current: ForkChoiceGoldenGraph.Block? = block
            while let step = current {
                if step.name == ancestor { return true }
                current = step.parentName.flatMap { byName[$0] }
            }
            return false
        }
        for event in graph.events where event.kind == .exclusion {
            let verdictAt = try XCTUnwrap(arrivalsBefore[event.index])
            for block in graph.blocks where block.name != event.subject && descends(block, from: event.subject) {
                XCTAssertLessThanOrEqual(
                    try position(block.name), verdictAt + 3,
                    "\(block.name) extends excluded \(event.subject) beyond the planning look-ahead"
                )
            }
        }

        // §9.1: one location per grind. The script never offers a second one,
        // so the oracle's conflict rule is never what makes the goldens agree.
        var locations: [String: Set<String>] = [:]
        for event in graph.events {
            for case .work(let fact) in event.batch.facts {
                locations[fact.contribution.id, default: []].insert(fact.blockHash)
            }
        }
        XCTAssertTrue(
            locations.values.allSatisfy { $0.count == 1 },
            "every grind must be located at exactly one block"
        )
    }
}
