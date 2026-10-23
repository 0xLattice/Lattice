import UInt256
import LatticePrimitives
import LatticePoW

/// The immutable identity of one held block: what its PoW-bound content says
/// about its place in the tree. Nothing here changes once the block is held.
struct BlockRecord: Sendable, Equatable {
    let blockHash: String
    let parentBlockHash: String?
    let blockHeight: UInt64
    /// See `BlockMeta.childCommitments`.
    let childCommitments: [String: String]
}

/// One block's verified work facts: every contribution by ID, which of them
/// are a parent's attributed runs rather than grinds, and their credited total.
struct BlockWork: Sendable {
    private(set) var contributions: [String: VerifiedWorkContribution]
    /// The contribution IDs here that are a parent's attributed runs (§9.10),
    /// not grinds (see `BlockMeta.attributedRuns`).
    private(set) var attributedRuns: Set<String>
    private(set) var work: WorkSum

    static let empty = BlockWork(contributions: [:], attributedRuns: [], work: .zero)

    init(
        contributions: [String: VerifiedWorkContribution],
        attributedRuns: Set<String>,
        work: WorkSum
    ) {
        self.contributions = contributions
        self.attributedRuns = attributedRuns
        self.work = work
    }

    /// False when `contribution` is not strictly stronger than the one held
    /// under its ID.
    mutating func set(
        _ contribution: VerifiedWorkContribution,
        attributed: Bool
    ) -> Bool {
        if let existing = contributions[contribution.id],
           existing.work >= contribution.work {
            return false
        }
        if let existing = contributions[contribution.id] {
            work = work.subtracting(WorkSum(existing.work))!
        }
        contributions[contribution.id] = contribution
        work = work + contribution.work
        if attributed {
            attributedRuns.insert(contribution.id)
        }
        return true
    }

    /// This block's grinds: every contribution that is not an attributed run.
    var grinds: Set<String> {
        Set(contributions.keys.filter { !attributedRuns.contains($0) })
    }

    /// The credited work of this block's grinds alone. Derived from the
    /// contributions, never cached beside `work`, so it cannot drift from it.
    var grindWork: WorkSum {
        WorkMeasure(contributions.values.filter { !attributedRuns.contains($0.id) }).total
    }
}

/// One block's derived diagnostic totals (see `BlockMeta.cumulativeWork` and
/// `BlockMeta.subtreeWeight`): never fork-choice inputs, rebuilt on demand.
struct BlockDiagnostics: Sendable {
    var cumulativeWork: WorkSum
    var subtreeWeight: WorkSum
}

/// The block tree `ChainState` holds: every held block's record, its child
/// edges, its work facts, its difficulty anchor and the diagnostic prefix and
/// subtree totals. This is the ONE representation of the tree — fork choice,
/// the execution frontier and run attribution store no edge of their own and
/// read this one. Every held block has a record, a children entry, a work
/// entry and a diagnostics entry; an anchor only once it has one.
struct BlockGraph: Sendable {
    private var recordByHash: [String: BlockRecord] = [:]
    /// The held children of each held block, in the order they were recorded
    /// — `findChildren`'s order at insertion, then appends. Never re-sorted.
    private var childrenByHash: [String: [String]] = [:]
    private var workByHash: [String: BlockWork] = [:]
    private var anchorByHash: [String: DifficultyAnchor] = [:]
    private(set) var diagnosticsByHash: [String: BlockDiagnostics] = [:]

    /// Decompose restored or fixture blocks into the graph's tables.
    init(_ blocks: [String: BlockMeta] = [:]) {
        for (hash, meta) in blocks {
            recordByHash[hash] = BlockRecord(
                blockHash: meta.blockHash,
                parentBlockHash: meta.parentBlockHash,
                blockHeight: meta.blockHeight,
                childCommitments: meta.childCommitments
            )
            childrenByHash[hash] = meta.childHashes
            workByHash[hash] = BlockWork(
                contributions: meta.workContributions,
                attributedRuns: meta.attributedRuns,
                work: meta.work
            )
            anchorByHash[hash] = meta.difficultyAnchor
            diagnosticsByHash[hash] = BlockDiagnostics(
                cumulativeWork: meta.cumulativeWork,
                subtreeWeight: meta.subtreeWeight
            )
        }
    }

    // MARK: Queries

    func contains(_ hash: String) -> Bool {
        recordByHash[hash] != nil
    }

    subscript(hash: String) -> BlockRecord? {
        recordByHash[hash]
    }

    /// Every held block's record, in no particular order.
    var records: some Collection<BlockRecord> {
        recordByHash.values
    }

    func parent(of hash: String) -> String? {
        recordByHash[hash]?.parentBlockHash
    }

    func height(of hash: String) -> UInt64? {
        recordByHash[hash]?.blockHeight
    }

    /// The held children of `hash`, in the order they were recorded — never
    /// re-sorted. Empty for an unknown block.
    func children(of hash: String) -> [String] {
        childrenByHash[hash] ?? []
    }

    /// `hash` and every held descendant, parent before child.
    func subtree(of hash: String) -> [String] {
        var blocks: [String] = []
        var stack = [hash]
        while let next = stack.popLast() {
            blocks.append(next)
            stack.append(contentsOf: children(of: next))
        }
        return blocks
    }

    func work(of hash: String) -> BlockWork? {
        workByHash[hash]
    }

    func contribution(id: String, at hash: String) -> VerifiedWorkContribution? {
        workByHash[hash]?.contributions[id]
    }

    func difficultyAnchor(of hash: String) -> DifficultyAnchor? {
        anchorByHash[hash]
    }

    func cumulativeWork(of hash: String) -> WorkSum? {
        diagnosticsByHash[hash]?.cumulativeWork
    }

    func subtreeWeight(of hash: String) -> WorkSum? {
        diagnosticsByHash[hash]?.subtreeWeight
    }

    /// The public read view of one block, assembled from the tables.
    func meta(of hash: String) -> BlockMeta? {
        guard let record = recordByHash[hash],
              let work = workByHash[hash],
              let diagnostics = diagnosticsByHash[hash] else { return nil }
        return BlockMeta(
            record: record,
            childHashes: childrenByHash[hash] ?? [],
            work: work,
            difficultyAnchor: anchorByHash[hash],
            diagnostics: diagnostics
        )
    }

    /// Every held block's public read view. O(N): assembled on read.
    var metas: [String: BlockMeta] {
        var result: [String: BlockMeta] = [:]
        result.reserveCapacity(recordByHash.count)
        for hash in recordByHash.keys {
            result[hash] = meta(of: hash)
        }
        return result
    }

    // MARK: Mutations

    /// Hold a newly admitted block with no work yet, zero diagnostics and the
    /// children already held for it.
    mutating func insert(
        _ record: BlockRecord,
        children: [String],
        difficultyAnchor: DifficultyAnchor?
    ) {
        let hash = record.blockHash
        recordByHash[hash] = record
        childrenByHash[hash] = children
        workByHash[hash] = .empty
        anchorByHash[hash] = difficultyAnchor
        diagnosticsByHash[hash] = BlockDiagnostics(cumulativeWork: .zero, subtreeWeight: .zero)
    }

    /// Record `child` under a held `parent`, appended last, unless already
    /// recorded.
    mutating func appendChild(_ child: String, to parent: String) {
        if childrenByHash[parent]?.contains(child) == false {
            childrenByHash[parent]?.append(child)
        }
    }

    /// False when the block is unknown or `contribution` is not strictly
    /// stronger than the one held under its ID.
    mutating func setWorkContribution(
        _ contribution: VerifiedWorkContribution,
        attributed: Bool,
        at hash: String
    ) -> Bool {
        workByHash[hash]?.set(contribution, attributed: attributed) == true
    }

    /// Fill an anchor left absent by out-of-order admission. Write-once: the
    /// anchor is a function of ancestry, which never changes for a given block,
    /// so a second value would mean the ancestry was misread.
    mutating func adoptDifficultyAnchor(_ anchor: DifficultyAnchor, at hash: String) {
        guard contains(hash), anchorByHash[hash] == nil else { return }
        anchorByHash[hash] = anchor
    }

    /// Rebuild the diagnostic prefix and subtree totals; see
    /// `ChainTree.recomputeWorkCaches`.
    mutating func recomputeWorkCaches() {
        diagnosticsByHash = ChainTree.recomputeWorkCaches(in: self)
    }
}
