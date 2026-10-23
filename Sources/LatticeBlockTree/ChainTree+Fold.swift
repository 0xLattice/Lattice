import cashew
import UInt256
import LatticePrimitives
import LatticePoW

// Folding side branches (§9.7) and the deep-fork bar. Both measure age against
// the window an operator chose, from the timestamp of the best weighed tip:
// a block is beyond the window when it is more than `windowMilliseconds`
// older than that tip.

/// What one compaction changes: the blocks it deletes and the fold facts that
/// keep their work counted. The node rewrites its durable facts as every batch
/// `retains` accepts plus `batches`, then restores from them.
public struct ChainFoldPlan: Sendable {
    /// Every block the plan folds away.
    public let folded: Set<String>
    /// One fold batch per block that receives a fold, cumulative over every
    /// earlier fold there.
    public let batches: [BlockImportBatch]
    private let refolded: Set<String>

    init(folded: Set<String>, facts: [ChainFoldFact]) {
        self.folded = folded
        self.batches = facts.map { BlockImportBatch(facts: [.fold($0)]) }
        self.refolded = Set(facts.map(\.blockHash))
    }

    public var isEmpty: Bool { folded.isEmpty }

    /// Whether a durable batch survives this plan: false for any fact about a
    /// folded block, and for an earlier fold this plan's fold supersedes.
    public func retains(_ batch: BlockImportBatch) -> Bool {
        batch.facts.allSatisfy { fact in
            let hash = CIDIdentity.canonicalString(fact.blockHash) ?? fact.blockHash
            if folded.contains(hash) { return false }
            if case .fold = fact, refolded.contains(hash) { return false }
            return true
        }
    }
}

extension ChainTree {
    /// The oldest timestamp still inside the window, or nil before the tree
    /// holds a tip.
    public func windowStart(windowMilliseconds: Int64) -> Int64? {
        guard let tip = frontier.snapshot(of: canonicalTip) else { return nil }
        return tip.timestamp.subtractingReportingOverflow(max(windowMilliseconds, 0)).overflow
            ? Int64.min
            : tip.timestamp - max(windowMilliseconds, 0)
    }

    /// The side branches to fold: every subtree hanging off a kept block
    /// beyond the window whose blocks are all beyond it too. A branch with
    /// any block inside the window is still live and stays whole.
    ///
    /// Kept blocks are the canonical chain, every block of `pinned` and its
    /// ancestors, and every executed block until it is `executedWindowMilliseconds`
    /// old (nil keeps them for good). Executed blocks are what a child chain's
    /// parent-state continuity reads (§5.3), so a chain whose children this
    /// node hosts must keep them as long as a child may still anchor there.
    ///
    /// The plan only describes; the tree is unchanged.
    public func foldPlan(
        windowMilliseconds: Int64,
        executedWindowMilliseconds: Int64? = nil,
        pinned: Set<String> = []
    ) -> ChainFoldPlan {
        guard let start = windowStart(windowMilliseconds: windowMilliseconds) else {
            return ChainFoldPlan(folded: [], facts: [])
        }
        let executedStart = executedWindowMilliseconds.flatMap {
            windowStart(windowMilliseconds: $0)
        }
        func beyond(_ hash: String, _ start: Int64) -> Bool {
            frontier.snapshot(of: hash).map { $0.timestamp < start } ?? false
        }

        var kept = canonicalHashes
        func keep(_ hash: String) {
            var cursor: String? = hash
            while let step = cursor, graph.contains(step), kept.insert(step).inserted {
                cursor = graph.parent(of: step)
            }
        }
        pinned.forEach(keep)
        for hash in frontier.anchored where !kept.contains(hash) {
            if let executedStart, beyond(hash, executedStart) { continue }
            keep(hash)
        }

        var folded = Set<String>()
        var facts: [ChainFoldFact] = []
        for forkPoint in kept.sorted()
        where forkPoint != canonicalTip && beyond(forkPoint, start) && forkChoice.isRouted(forkPoint) {
            var work = WorkSum.zero
            var covered: [String: WorkSum] = [:]
            var frozen: [FrozenRun] = []
            for root in graph.children(of: forkPoint) where !kept.contains(root) {
                let subtree = graph.subtree(of: root)
                guard subtree.allSatisfy({ beyond($0, start) }),
                      let weight = forkChoice.weight(of: root) else { continue }
                let runs = foldedRuns(of: subtree, rootedAt: root)
                work = work + weight
                for (directory, value) in runs.covered {
                    covered[directory] = (covered[directory] ?? .zero) + value
                }
                frozen += runs.frozen
                // A folded block's own earlier fold goes with it: its frozen
                // runs move to the new fold, or they would be lost.
                frozen += subtree.flatMap { graph.fold(at: $0)?.frozenRuns ?? [] }
                folded.formUnion(subtree)
            }
            guard work > .zero else { continue }
            let earlier = graph.fold(at: forkPoint)
            if let earlier {
                work = work + earlier.work
                for (directory, value) in earlier.covered {
                    covered[directory] = (covered[directory] ?? .zero) + value
                }
            }
            guard let total = work.uint256Value else { continue }
            facts.append(ChainFoldFact(
                blockHash: forkPoint,
                work: total,
                covered: covered.compactMapValues(\.uint256Value),
                frozenRuns: (earlier?.frozenRuns ?? []) + frozen.sorted {
                    ($0.directory, $0.carrierBlockHash) < ($1.directory, $1.carrierBlockHash)
                }
            ))
        }
        return ChainFoldPlan(folded: folded, facts: facts)
    }

    /// One folded subtree's runs (§9.10), over every directory its blocks
    /// commit into or an earlier fold among them covered. A block credits its
    /// work, less what earlier folds there already froze for the directory, to
    /// its nearest carrier; a carrier inside the subtree freezes that run, and
    /// the rest falls to the fork point's own carrier. `covered` is what did
    /// not fall through.
    private func foldedRuns(
        of subtree: [String],
        rootedAt root: String
    ) -> (covered: [String: WorkSum], frozen: [FrozenRun]) {
        var directories = Set<String>()
        for hash in subtree {
            if let commitments = graph[hash]?.childCommitments {
                directories.formUnion(commitments.keys)
            }
            if let fold = graph.fold(at: hash) {
                directories.formUnion(fold.covered.keys)
            }
        }
        var covered: [String: WorkSum] = [:]
        var frozen: [FrozenRun] = []
        for directory in directories.sorted() {
            var carrierOf: [String: String] = [:]
            var runWork: [String: WorkSum] = [:]
            var total = WorkSum.zero
            // `subtree` lists a parent before its children.
            for hash in subtree {
                guard let work = graph.work(of: hash)?.work else { continue }
                let carrier = graph[hash]?.childCommitments[directory] != nil
                    ? hash
                    : (hash == root ? nil : graph.parent(of: hash).flatMap { carrierOf[$0] })
                carrierOf[hash] = carrier
                let earlier = WorkSum(graph.fold(at: hash)?.covered[directory] ?? .zero)
                if let carrier {
                    runWork[carrier] = (runWork[carrier] ?? .zero) + (work.subtracting(earlier) ?? .zero)
                    total = total + work
                } else {
                    total = total + earlier
                }
            }
            covered[directory] = total
            for (carrier, run) in runWork {
                guard let child = graph[carrier]?.childCommitments[directory],
                      let own = graph.work(of: carrier)?.grindWork,
                      let value = run.subtracting(own)?.uint256Value,
                      value > .zero else { continue }
                frozen.append(FrozenRun(
                    carrierBlockHash: carrier,
                    directory: directory,
                    childBlockHash: CIDIdentity.canonicalString(child) ?? child,
                    value: value
                ))
            }
        }
        return (covered, frozen)
    }

    /// The work a branch attaching under `parentHash` must prove, by its
    /// headers alone, before the node weighs it: nil when the attachment is
    /// inside the window (or is the tip), so the branch is admitted as any
    /// other. Otherwise the subtree work of the canonical child at the fork
    /// point, less what the attachment's own side of that fork already
    /// weighs — the comparison `preferred(among:)` will make there. A branch
    /// that proves at least this much may change the canonical choice; one
    /// that cannot never would.
    public func deepForkBar(attachingTo parentHash: String, windowMilliseconds: Int64) -> WorkSum? {
        guard graph.contains(parentHash),
              parentHash != canonicalTip,
              let start = windowStart(windowMilliseconds: windowMilliseconds),
              let attachment = frontier.snapshot(of: parentHash),
              attachment.timestamp < start else { return nil }
        var side: String?
        var forkPoint = parentHash
        while !canonicalHashes.contains(forkPoint) {
            guard let parent = graph.parent(of: forkPoint) else {
                // A root other than the canonical one: its whole tree is the
                // side, competing at the roots.
                guard let canonicalRoot = canonicalHashByHeight[0],
                      let rival = forkChoice.weight(of: canonicalRoot) else { return nil }
                return rival.subtracting(forkChoice.weight(of: forkPoint) ?? .zero) ?? .zero
            }
            side = forkPoint
            forkPoint = parent
        }
        guard let height = graph.height(of: forkPoint),
              let canonicalChild = canonicalHashByHeight[height + 1],
              let rival = forkChoice.weight(of: canonicalChild) else { return nil }
        guard let side else { return rival }
        return rival.subtracting(forkChoice.weight(of: side) ?? .zero) ?? .zero
    }
}
