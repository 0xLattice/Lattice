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

/// One block's verified work facts: every contribution's work by ID, and
/// which of them are a parent's attributed runs rather than grinds. The
/// credited total is derived from them, never stored beside them.
struct BlockWork: Sendable {
    private(set) var workByID: [String: Fixed256]
    /// The contribution IDs here that are a parent's attributed runs (§9.10),
    /// not grinds (see `BlockMeta.attributedRuns`).
    private(set) var attributedRuns: Set<String>

    static let empty = BlockWork(contributions: [:], attributedRuns: [])

    init(
        contributions: [String: VerifiedWorkContribution],
        attributedRuns: Set<String>
    ) {
        self.workByID = contributions.mapValues { Fixed256($0.work) }
        self.attributedRuns = attributedRuns
    }

    /// Every contribution, by ID.
    var contributions: [String: VerifiedWorkContribution] {
        Dictionary(uniqueKeysWithValues: workByID.map {
            ($0.key, VerifiedWorkContribution(id: $0.key, work: $0.value.uint256))
        })
    }

    func contribution(id: String) -> VerifiedWorkContribution? {
        workByID[id].map { VerifiedWorkContribution(id: id, work: $0.uint256) }
    }

    /// The block's credited work: every contribution, exactly.
    var work: WorkSum {
        var total = WorkTotal()
        for work in workByID.values { total.add(work) }
        return total.exact
    }

    /// False when `contribution` is not strictly stronger than the one held
    /// under its ID.
    mutating func set(
        _ contribution: VerifiedWorkContribution,
        attributed: Bool
    ) -> Bool {
        let work = Fixed256(contribution.work)
        if let existing = workByID[contribution.id], existing >= work {
            return false
        }
        workByID[contribution.id] = work
        if attributed {
            attributedRuns.insert(contribution.id)
        }
        return true
    }

    /// This block's grinds: every contribution that is not an attributed run.
    var grinds: Set<String> {
        Set(workByID.keys.filter { !attributedRuns.contains($0) })
    }

    /// The credited work of this block's grinds alone.
    var grindWork: WorkSum {
        var total = WorkTotal()
        for (id, work) in workByID where !attributedRuns.contains(id) { total.add(work) }
        return total.exact
    }
}

/// The block tree `ChainState` holds: every held block's record, its child
/// edges, its work facts and its difficulty anchor. This is the ONE
/// representation of the tree — fork choice, the execution frontier and run
/// attribution store no edge of their own and read this one. Every held block
/// has a record, a children entry and a work entry; an anchor only once it
/// has one.
struct BlockGraph: Sendable {
    private var recordByHash: [String: BlockRecord] = [:]
    /// The held children of each held block, in the order they were recorded
    /// — `findChildren`'s order at insertion, then appends. Never re-sorted.
    private var childrenByHash: [String: [String]] = [:]
    private var workByHash: [String: BlockWork] = [:]
    /// Each block's difficulty anchor, as the height-1 block it is read
    /// from: a reference, not a copy of that block's timestamp and target.
    private var anchorBlockByHash: [String: String] = [:]

    /// Decompose restored or fixture blocks into the graph's tables. A
    /// fixture carries no anchors: each is derived from ancestry on demand
    /// (`ChainTree.difficultyAnchor(forBlockHash:)`).
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
                attributedRuns: meta.attributedRuns
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
        workByHash[hash]?.contribution(id: id)
    }

    /// The height-1 block `hash`'s difficulty anchor is read from.
    func anchorBlock(of hash: String) -> String? {
        anchorBlockByHash[hash]
    }

    /// The public read view of one block, assembled from the tables. The
    /// anchor's value lives on its height-1 block, so the caller supplies it.
    func meta(of hash: String, difficultyAnchor: DifficultyAnchor?) -> BlockMeta? {
        guard let record = recordByHash[hash],
              let work = workByHash[hash] else { return nil }
        return BlockMeta(
            record: record,
            childHashes: childrenByHash[hash] ?? [],
            work: work,
            difficultyAnchor: difficultyAnchor
        )
    }

    // MARK: Mutations

    /// Hold a newly admitted block with no work yet and the children already
    /// held for it.
    mutating func insert(
        _ record: BlockRecord,
        children: [String],
        anchorBlock: String?
    ) {
        let hash = record.blockHash
        recordByHash[hash] = record
        childrenByHash[hash] = children
        workByHash[hash] = .empty
        anchorBlockByHash[hash] = anchorBlock
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
    mutating func adoptAnchorBlock(_ anchorBlock: String, at hash: String) {
        guard contains(hash), anchorBlockByHash[hash] == nil else { return }
        anchorBlockByHash[hash] = anchorBlock
    }
}
