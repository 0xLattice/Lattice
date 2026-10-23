import CID
import UInt256
import Lattice

// An independent fork-choice oracle, written from docs/spec.md and nothing
// else: §9.1 (one quantity per grind: the strongest observation), §9.2
// (`effectiveSubtree` = own measure unioned with every same-chain child's,
// measure union = max per grind, total = exact sum), §9.4 (GHOST descent:
// heaviest `trueCumWork` wins, equal work prefers the lexicographically
// smaller canonical CID bytes, the same rule picks among genesis roots) and
// §9.9 (work weighs, validity selects: exclusion removes no weight and the
// descent never steps into an excluded block).
//
// It deliberately shares nothing with `Chain.swift` — not the descent, not the
// weight index, not `WorkSum`, not `forkChoicePrefersBlock`. Its arithmetic is
// its own, its model is rebuilt from the durable facts, and it is slow on
// purpose: every query walks the graph.

/// Exact unsigned total of `UInt256` contributions. Little-endian 64-bit
/// limbs with no trailing zero limb, so equality and ordering are structural.
struct OracleWork: Equatable, Comparable {
    private(set) var limbs: [UInt64]

    static let zero = OracleWork(limbs: [])

    private init(limbs: [UInt64]) {
        self.limbs = limbs
        while self.limbs.last == 0 { self.limbs.removeLast() }
    }

    init(_ value: UInt256) {
        var parsed: [UInt64] = []
        var remaining = value
        for _ in 0..<4 {
            parsed.append(UInt64(truncatingIfNeeded: remaining))
            remaining >>= UInt256(64)
        }
        self.init(limbs: parsed)
    }

    static func < (lhs: OracleWork, rhs: OracleWork) -> Bool {
        if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
        for index in lhs.limbs.indices.reversed() where lhs.limbs[index] != rhs.limbs[index] {
            return lhs.limbs[index] < rhs.limbs[index]
        }
        return false
    }

    static func + (lhs: OracleWork, rhs: OracleWork) -> OracleWork {
        var result: [UInt64] = []
        var carry: UInt64 = 0
        for index in 0..<max(lhs.limbs.count, rhs.limbs.count) {
            let left = index < lhs.limbs.count ? lhs.limbs[index] : 0
            let right = index < rhs.limbs.count ? rhs.limbs[index] : 0
            let (partial, overflow1) = left.addingReportingOverflow(right)
            let (sum, overflow2) = partial.addingReportingOverflow(carry)
            result.append(sum)
            carry = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        if carry > 0 { result.append(carry) }
        return OracleWork(limbs: result)
    }

    /// Zero-padded to 64 hex digits, wider only when the value needs it — the
    /// same presentation the chain's own totals use, so goldens compare as text.
    var hex: String {
        guard let top = limbs.last else { return String(repeating: "0", count: 64) }
        var text = String(top, radix: 16)
        for limb in limbs.dropLast().reversed() {
            let encoded = String(limb, radix: 16)
            text += String(repeating: "0", count: 16 - encoded.count) + encoded
        }
        return text.count < 64 ? String(repeating: "0", count: 64 - text.count) + text : text
    }
}

struct OracleBlock {
    let hash: String
    let parent: String?
    let height: UInt64
    /// Grind id → the strongest quantity observed AT this block (§9.1).
    var observations: [String: UInt256]
}

struct ForkChoiceOracle {
    /// A grind offered at a second block (§9.1 refuses it). Production
    /// answers `.discarded` on the live path and `corruptConsensusGraph` on
    /// replay; the oracle records it so a test can assert on it — and the
    /// agreement check asserts there were none, so a conflict is never what
    /// silently makes the oracle and the chain agree.
    struct LocationConflict: Equatable {
        let grind: String
        let located: String
        let offered: String
    }

    private(set) var blocks: [String: OracleBlock] = [:]
    private(set) var excluded: Set<String> = []
    private(set) var conflicts: [LocationConflict] = []

    init() {}

    /// The oracle over the blocks a chain HOLDS, read from `hashToBlock`
    /// instead of rebuilt from fact batches, so a differential test can ask
    /// the spec what the live projection must be at any moment. A block's
    /// observations are the contributions it holds; §9.1's one location per
    /// grind is the chain's own invariant (`hasUniqueWorkLocations`) and is
    /// checked here so a conflict is never what makes the two agree.
    init(blocks: [String: BlockMeta], excluded: Set<String>) {
        for (hash, meta) in blocks {
            self.blocks[hash] = OracleBlock(
                hash: hash,
                parent: meta.parentBlockHash,
                height: meta.blockHeight,
                observations: meta.workContributions.mapValues(\.work)
            )
            for grind in meta.workContributions.keys {
                precondition(
                    locationByGrind.updateValue(hash, forKey: grind) == nil,
                    "a grind held at two blocks: \(grind)"
                )
            }
        }
        self.excluded = excluded
    }

    // MARK: Model construction from durable facts

    /// Record one batch's facts. Order-independent by construction: blocks are
    /// keyed by hash, observations keep their maximum, exclusions are a set.
    mutating func apply(_ batch: BlockImportBatch) {
        for fact in batch.facts {
            switch fact {
            case .block(let block):
                if blocks[block.blockHash] == nil {
                    blocks[block.blockHash] = OracleBlock(
                        hash: block.blockHash,
                        parent: block.parentBlockHash,
                        height: block.blockHeight,
                        observations: [:]
                    )
                }
            case .work(let work):
                observe(work.contribution.id, work.contribution.work, at: work.blockHash)
            case .exclusion(let exclusion):
                excluded.insert(exclusion.blockHash)
            case .validation:
                break // Execution never weighs and never selects (§9.9).
            case .fold(let fold):
                // Folded side branches weigh as one contribution at their
                // fork point (§9.7).
                observe(
                    FoldIdentity(foldedAtBlockHash: fold.blockHash).contributionID!,
                    fold.work, at: fold.blockHash
                )
            }
        }
        settlePending()
    }

    mutating func observe(_ grind: String, _ work: UInt256, at blockHash: String) {
        // §9.1: one grind has exactly one location per chain; a conflicting
        // location is rejected, never re-homed — and recorded, never silent.
        if let located = locationByGrind[grind], located != blockHash {
            conflicts.append(LocationConflict(grind: grind, located: located, offered: blockHash))
            return
        }
        guard var block = blocks[blockHash] else {
            // A work fact for a block whose fact has not arrived yet: keep it
            // pending on a placeholder that the block fact fills in.
            pendingObservations[blockHash, default: [:]][grind] = max(
                pendingObservations[blockHash]?[grind] ?? .zero, work
            )
            return
        }
        locationByGrind[grind] = blockHash
        block.observations[grind] = max(block.observations[grind] ?? .zero, work)
        blocks[blockHash] = block
    }

    private var pendingObservations: [String: [String: UInt256]] = [:]
    private var locationByGrind: [String: String] = [:]

    /// Fold work that arrived before its block into the block once it exists.
    private mutating func settlePending() {
        // Sorted, so two pending observations of one grind at two blocks
        // settle in a fixed order rather than by dictionary seed.
        for hash in pendingObservations.keys.sorted() where blocks[hash] != nil {
            for (grind, work) in (pendingObservations[hash] ?? [:]).sorted(by: { $0.key < $1.key }) {
                observe(grind, work, at: hash)
            }
            pendingObservations[hash] = nil
        }
    }

    /// A read-only view with the per-grind quantities and the child index
    /// settled once, so a sweep over every block costs O(n) per block instead
    /// of rebuilding both for every query. `ignoringExclusions` answers "what
    /// would be selected on weight alone" — the control that shows whether an
    /// exclusion was decisive (§9.9).
    func view(ignoringExclusions: Bool = false) -> ForkChoiceOracleView {
        var strongest: [String: UInt256] = [:]
        var childrenByParent: [String: [String]] = [:]
        for block in blocks.values {
            for (grind, work) in block.observations where work > (strongest[grind] ?? .zero) {
                strongest[grind] = work
            }
            if let parent = block.parent, let parentBlock = blocks[parent],
               block.height == parentBlock.height + 1 {
                childrenByParent[parent, default: []].append(block.hash)
            }
        }
        return ForkChoiceOracleView(
            blocks: blocks,
            excluded: ignoringExclusions ? [] : excluded,
            strongest: strongest,
            childrenByParent: childrenByParent.mapValues { $0.sorted() }
        )
    }
}

struct ForkChoiceOracleView {
    let blocks: [String: OracleBlock]
    let excluded: Set<String>
    /// One quantity per grind across the whole graph: the strongest observation (§9.1).
    let strongest: [String: UInt256]
    /// Same-chain children: parent pointer plus height continuity, sorted so
    /// nothing here depends on dictionary order.
    let childrenByParent: [String: [String]]

    // MARK: §9.2 weights

    func children(of hash: String) -> [String] {
        childrenByParent[hash] ?? []
    }

    /// Every block in the subtree rooted at `hash`, itself included.
    func subtree(of hash: String) -> [String] {
        var order: [String] = []
        var pending = [hash]
        var visited = Set<String>()
        while let current = pending.popLast() {
            guard visited.insert(current).inserted else { continue }
            order.append(current)
            pending.append(contentsOf: children(of: current))
        }
        return order
    }

    private func total(_ measure: [String: UInt256]) -> OracleWork {
        measure.values.reduce(OracleWork.zero) { $0 + OracleWork($1) }
    }

    /// `trueCumWork(B) = total(effectiveSubtree(B))`: union the measures of
    /// every block in the subtree (max per grind), then sum the distinct values.
    func trueCumWork(of hash: String) -> OracleWork {
        var measure: [String: UInt256] = [:]
        for member in subtree(of: hash) {
            for (grind, work) in blocks[member]?.observations ?? [:] {
                measure[grind] = max(measure[grind] ?? .zero, strongest[grind] ?? work)
            }
        }
        return total(measure)
    }

    /// `trueCumWork` of every block at once, in one pass from the leaves up.
    /// With one location per grind (§9.1, enforced by `observe` and by the
    /// `hashToBlock` initializer) the union over a subtree has no duplicate to
    /// collapse, so it is the plain sum of each member's own measure. Checked
    /// block by block against `trueCumWork` in `ForkChoiceOracleTests`, and
    /// available to a caller that needs a linear projection; the differential
    /// suites keep the walked projection.
    func subtreeTotals() -> [String: OracleWork] {
        var totals: [String: OracleWork] = [:]
        // A child is exactly one height above its parent, so deepest-first
        // settles every child before the parent that sums it.
        for block in blocks.values.sorted(by: { $0.height > $1.height }) {
            var total = OracleWork.zero
            for (grind, work) in block.observations {
                total = total + OracleWork(strongest[grind] ?? work)
            }
            for child in children(of: block.hash) {
                total = total + (totals[child] ?? .zero)
            }
            totals[block.hash] = total
        }
        return totals
    }

    /// `prefix(B)`: the same union along the ancestor line, root through `hash`.
    func cumulativeWork(of hash: String) -> OracleWork {
        var measure: [String: UInt256] = [:]
        var current: String? = hash
        while let step = current, let block = blocks[step] {
            for (grind, work) in block.observations {
                measure[grind] = max(measure[grind] ?? .zero, strongest[grind] ?? work)
            }
            current = block.parent
        }
        return total(measure)
    }

    // MARK: §9.4 selection

    /// Canonical CID bytes, decoded by the CID library, never by Lattice.
    static func canonicalBytes(_ cid: String) -> [UInt8] {
        guard let parsed = try? CID(cid) else {
            preconditionFailure("oracle fixtures use valid CIDs: \(cid)")
        }
        return parsed.rawBuffer
    }

    /// Heaviest `trueCumWork`; equal work prefers the lexicographically smaller
    /// canonical CID bytes. `totals`, when given, are `subtreeTotals()` read
    /// instead of walking each candidate's subtree again.
    func preferred(among candidates: [String], totals: [String: OracleWork]? = nil) -> String? {
        var best: (hash: String, work: OracleWork, bytes: [UInt8])?
        for candidate in candidates {
            let work = totals.map { $0[candidate] ?? .zero } ?? trueCumWork(of: candidate)
            let bytes = Self.canonicalBytes(candidate)
            guard let current = best else {
                best = (candidate, work, bytes)
                continue
            }
            if work > current.work || (work == current.work && bytes.lexicographicallyPrecedes(current.bytes)) {
                best = (candidate, work, bytes)
            }
        }
        return best?.hash
    }

    /// The canonical projection: the preferred selectable root, then the
    /// preferred selectable child at every step until none remains. Nil when
    /// no root is selectable (§9.9: an excluded root is never stepped into).
    /// `totals` as in `preferred(among:totals:)`.
    func canonicalProjection(totals: [String: OracleWork]? = nil) -> (tip: String, path: [String])? {
        let roots = blocks.values
            .filter { $0.parent == nil && $0.height == 0 && !excluded.contains($0.hash) }
            .map(\.hash)
        guard var current = preferred(among: roots, totals: totals) else { return nil }
        var path = [current]
        while true {
            let selectable = children(of: current).filter { !excluded.contains($0) }
            guard let next = preferred(among: selectable, totals: totals) else { return (current, path) }
            current = next
            path.append(next)
        }
    }
}
