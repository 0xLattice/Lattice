import CID
import LatticePrimitives
import LatticePoW

/// Stable tie-break for equal-work same-chain child blocks. Compare the CID
/// bytes rather than an encoded presentation string; malformed values remain
/// deterministic so persistence validation can reject them without
/// order-dependent behavior.
public func forkChoicePrefersBlock(
    _ candidateHash: String,
    over currentHash: String
) -> Bool {
    let candidateBytes = (try? CID(candidateHash))?.rawBuffer
    let currentBytes = (try? CID(currentHash))?.rawBuffer
    switch (candidateBytes, currentBytes) {
    case let (candidate?, current?):
        return candidate.lexicographicallyPrecedes(current)
    case (_?, nil):
        return true
    case (nil, _?):
        return false
    case (nil, nil):
        return candidateHash < currentHash
    }
}

struct WorkContributionRecord: Sendable, Equatable {
    let blockHash: String
    var contribution: VerifiedWorkContribution
    var isRouted: Bool

    init(
        blockHash: String,
        contribution: VerifiedWorkContribution,
        isRouted: Bool = false
    ) {
        self.blockHash = blockHash
        self.contribution = contribution
        self.isRouted = isRouted
    }
}

public struct ForkChoiceSnapshot: Sendable, Equatable {
    public let startingHash: String
    public let subtreeWork: WorkSum
    public let tipHash: String
    public let canonicalPath: Set<String>

    public init(startingHash: String, subtreeWork: WorkSum, tipHash: String, canonicalPath: Set<String>) {
        self.startingHash = startingHash
        self.subtreeWork = subtreeWork
        self.tipHash = tipHash
        self.canonicalPath = canonicalPath
    }
}

/// Fork choice over the graph's arrays: the GHOST weights (`weights`, one
/// Euler range per routed block, every routed block — not only those where a
/// choice can be made), each contribution's one location (`grinds`), and the
/// excluded roots (a flag on the block).
///
/// Excluded roots are the roots of proven-invalid subtrees (deferred-execution
/// validated tier: a block whose execution completed and FAILED). Rebuilt on
/// recovery from the durable `.exclusion` facts. Insert-only.
///
/// Work weighs; validity selects (§9.9). An excluded block's work — and its
/// descendants' — stays in every ancestor's weight exactly as any other work
/// does: proof-of-work is a physical fact and invalidity is a judgment about
/// state. What exclusion changes is SELECTION: the canonical descent never
/// steps into an excluded root, so nothing below one is ever the tip or
/// attested (§5.3). No weight is ever removed, so no index is ever rebuilt,
/// and a descendant of an excluded root needs no bookkeeping at all — the
/// descent cannot reach it.
extension BlockGraph {
    // MARK: Queries

    func isRouted(_ block: UInt32) -> Bool {
        weights.contains(block)
    }

    func weight(of block: UInt32) -> WorkSum? {
        weights.subtreeWork(block, in: self)
    }

    func isExcludedRoot(_ block: UInt32) -> Bool {
        self[block].flags.contains(.excludedRoot)
    }

    /// Whether the contribution `id` may be credited at `block`: it is new,
    /// or already located there.
    func acceptsLocation(of id: GrindID, at block: UInt32) -> Bool {
        grindIDs.firstIndex(of: id).map { grinds[$0].block == block } ?? true
    }

    /// The tie-break between two held blocks of equal weight: the smaller CID
    /// bytes. Every held block is a canonical CID, whose bytes are one shared
    /// prefix and the digest, so the digest decides.
    func prefers(_ candidate: UInt32, over current: UInt32) -> Bool {
        ids[Int(candidate)] < ids[Int(current)]
    }

    func preferred(among blocks: [UInt32]) -> UInt32? {
        var selected: UInt32?
        var selectedWork: WorkSum?
        for candidate in blocks {
            guard let candidateWork = weight(of: candidate) else { continue }
            guard let current = selected, let currentWork = selectedWork else {
                selected = candidate
                selectedWork = candidateWork
                continue
            }
            if candidateWork > currentWork
                || (candidateWork == currentWork && prefers(candidate, over: current)) {
                selected = candidate
                selectedWork = candidateWork
            }
        }
        return selected
    }

    /// The preferred genesis root that is not excluded.
    func selectableRoot() -> UInt32? {
        preferred(among: roots.filter { !isExcludedRoot($0) })
    }

    /// GHOST descent over blocks, with no quotient in between.
    ///
    /// The structure this replaces compressed unary runs so a walk could hop
    /// from a base to its tail. That only pays when runs are long, and on a
    /// merged-mining child they never are: a losing sibling is roughly 74% of
    /// admissions, so a split fired at nearly every height and every run
    /// collapsed to length one — segments walked exactly equalled blocks
    /// materialized, at every chain length measured. The accelerator compressed
    /// nothing on the workload it had to serve.
    ///
    /// A lone child is followed without a weight lookup. Every start point is
    /// routed and the routed set is closed under child edges — each routing
    /// site keeps it so, and `ForkChoiceInvariantTests` pins it — so a fork
    /// with no routed child is a broken invariant, never an input, and the
    /// descent fails closed on it rather than guessing. Weights are pure work;
    /// the excluded roots only steer the descent, which never steps into one.
    /// Returns the path from `start`, in height order.
    func descend(from start: UInt32) -> [UInt32] {
        var path = [start]
        var current = start
        while true {
            var children = self.children(of: current)
            children.removeAll { isExcludedRoot($0) }
            guard !children.isEmpty else { return path }
            guard let next = children.count == 1 ? children[0] : preferred(among: children) else {
                preconditionFailure("no routed child under \(hash(current))")
            }
            precondition(path.count <= heldCount, "cycle in child edges at \(hash(current))")
            path.append(next)
            current = next
        }
    }

    // MARK: Mutations

    /// Route a block with no children yet directly inside its routed parent's
    /// range. Nothing above the parent is touched.
    func routeLeaf(_ block: UInt32, under parent: UInt32) -> Bool {
        // The leaf arrives carrying its first grind: inserting it is that
        // work's update along the path.
        guard let touched = weights.insertLeaf(block, under: parent, in: self) else { return false }
#if DEBUG
        workUpdateCellCount += UInt64(touched)
#else
        _ = touched
#endif
        return true
    }

    func routeRoot(_ block: UInt32) -> Bool {
        weights.insertRoot(block, in: self)
    }

    /// The block's direct work rose: refresh its weight path.
    func directWorkChanged(at block: UInt32) {
        guard let touched = weights.directWorkChanged(at: block, in: self) else { return }
#if DEBUG
        workUpdateCellCount += UInt64(touched)
#else
        _ = touched
#endif
    }

    /// The Euler tour of `root`'s subtree over the children `includes`
    /// admits. Iterative: a chain is as deep as it is long.
    func tour(from root: UInt32, including includes: (UInt32) -> Bool) -> [EulerWorkIndex.Event] {
        var events: [EulerWorkIndex.Event] = [.open(root)]
        var stack: [(block: UInt32, children: [UInt32], next: Int)] = [
            (root, children(of: root).filter(includes), 0),
        ]
        while var frame = stack.popLast() {
            guard frame.next < frame.children.count else {
                events.append(.close(frame.block))
                continue
            }
            let child = frame.children[frame.next]
            frame.next += 1
            stack.append(frame)
            events.append(.open(child))
            stack.append((child, children(of: child).filter(includes), 0))
        }
        return events
    }

    /// Route one newly connected orphan component without touching unrelated
    /// history: toured once and spliced into the parent's range in one
    /// operation, so nothing above the graft point is updated. Its blocks'
    /// direct work is already on them, so the splice carries it.
    func graftComponent(rootedAt root: UInt32) -> Bool {
        let parent = self[root].parent
        if parent != Self.none {
            guard isRouted(parent) else { return false }
        } else if self[root].height != 0 || foreignParents[root] != nil {
            return false
        }
        // A member of a disconnected component cannot already be routed
        // (`routeBlock` refuses to route under an unrouted parent); if that
        // ever broke, the tour skips the block rather than splice it twice.
        let events = tour(from: root) { !self.isRouted($0) }
        var updatedCells = 0
        if parent != Self.none {
            guard let cells = weights.splice(events, under: parent, in: self) else { return false }
            updatedCells = cells
        } else {
            // A component rooted at genesis has no parent range to sit inside.
            guard weights.insertRoot(root, in: self) else { return false }
            let inner = Array(events.dropFirst().dropLast())
            if !inner.isEmpty {
                guard let cells = weights.splice(inner, under: root, in: self) else { return false }
                updatedCells = cells
            }
        }
#if DEBUG
        graftCount += 1
        graftBlockVisitCount += UInt64(events.count / 2)  // one open per block
        workUpdateCellCount += UInt64(updatedCells)
#else
        _ = updatedCells
#endif
        return true
    }

    /// Build the GHOST weights as one Euler tour of the routed graph —
    /// reachable from a genesis root through held blocks. Recovery uses this
    /// linear builder; every live mutation is incremental. The tour's order
    /// differs from the one live insertion produces, but a subtree is a
    /// contiguous range under either order, and the sum over a range does not
    /// depend on the order within it, which is the only thing fork choice
    /// reads.
    func buildWeights() {
        var events: [EulerWorkIndex.Event] = []
        events.reserveCapacity(heldCount * 2)
        for root in roots {
            events.append(contentsOf: tour(from: root) { _ in true })
        }
        weights = EulerWorkIndex.build(events: events, in: self)
    }
}

extension ChainTree {
    // Forwarders onto the graph's fork choice, kept so callers and tests read
    // the actor exactly as before.

    func workContribution(id: String) -> WorkContributionRecord? {
        guard let grind = graph.grindHandle(id) else { return nil }
        let block = graph.grinds[Int(grind)].block
        return WorkContributionRecord(
            blockHash: graph.hash(block),
            contribution: graph.contribution(grind),
            isRouted: graph.isRouted(block)
        )
    }

#if DEBUG
    var segmentWorkUpdateCellCount: UInt64 { graph.workUpdateCellCount }
    var segmentGraftCount: UInt64 { graph.graftCount }
    var segmentGraftBlockVisitCount: UInt64 { graph.graftBlockVisitCount }
#endif

    /// The grind `id` as credited at `blockHash`, or nil if it is not credited
    /// there. Reads the grind's one location, never the derived totals, so
    /// asking whether a proof is already credited costs nothing as the tree grows.
    public func workContribution(
        id: String,
        at blockHash: String
    ) -> VerifiedWorkContribution? {
        guard let block = graph.handle(blockHash),
              let grind = graph.grindHandle(id),
              graph.grinds[Int(grind)].block == block else { return nil }
        return graph.contribution(grind)
    }

    /// Whether `blockHash` belongs to a complete accepted path ending at one of
    /// this path-defined chain's admitted genesis roots — i.e. it is CONNECTED,
    /// so its work routes into fork choice (excluded or not: work weighs, §9.9).
    ///
    /// This says nothing about whether any block on that path was EXECUTED. The
    /// weighed tier connects a block from its header alone and records its
    /// declared `postState` as an unverified claim (§9.9). Anything that must
    /// distinguish a produced state from a declared one — parent-state
    /// attestation above all — must also test whether the block was validated;
    /// connectivity is not verification.
    package func hasConnectedAncestry(blockHash: String) -> Bool {
        graph.handle(blockHash).map(graph.isRouted) ?? false
    }

    /// Exact total proof-of-work from genesis to the current chain tip.
    public func getTipCumulativeWork() -> WorkSum {
        getCumulativeWork(forHash: canonicalTip) ?? .zero
    }

    /// Exact cumulative work at a specific block, or nil if the block is
    /// unknown: its own work plus every ancestor's, up the child edges to the
    /// root of its held component. A grind has one location in a chain
    /// (`acceptsLocation`), so no grind is on the path twice and the plain sum
    /// is the deduplicated one. A derived diagnostic, walked on demand in
    /// O(height) — never a fork-choice input.
    public func getCumulativeWork(forHash hash: String) -> WorkSum? {
        guard var current = graph.handle(hash) else { return nil }
        var total = WorkTotal()
        while true {
            graph.addDirectWork(of: current, to: &total)
            // A block held under a parent that never recorded it as a child
            // (a child at a height its parent cannot have) roots its own
            // component, as it does for the subtree measure.
            let parent = graph.linkedParent(of: current)
            guard parent != BlockGraph.none else { return total.exact }
            current = parent
        }
    }

    /// The same-chain subtree measure of `hash`, deduplicated by grind
    /// identity: fork choice's own weight once the block is connected, and the
    /// sum over its held subtree while it is not. Pure work, excluded subtrees
    /// included: validity never subtracts weight.
    public func subtreeWeight(forHash hash: String) -> WorkSum? {
        guard let block = graph.handle(hash) else { return nil }
        if let weight = graph.weight(of: block) { return weight }
        var total = WorkTotal()
        for member in graph.subtree(of: block) {
            graph.addDirectWork(of: member, to: &total)
        }
        return total.exact
    }

    /// The work fork choice weighs `hash`'s subtree by: what
    /// `forkChoiceSnapshot(startingAt:)` reports as `subtreeWork`, read from
    /// the weight index without descending the subtree.
    public func forkChoiceWeight(of hash: String) -> WorkSum? {
        graph.handle(hash).flatMap(graph.weight(of:))
    }

    /// Public simulator/test view of the real local fork-choice descent.
    public func forkChoiceSnapshot(startingAt hash: String) -> ForkChoiceSnapshot? {
        guard let block = graph.handle(hash), graph.isRouted(block) else { return nil }
        let choice = chainWithMostWork(startingAt: hash)
        return ForkChoiceSnapshot(
            startingHash: hash,
            subtreeWork: choice.subtreeWork,
            tipHash: choice.tipHash,
            canonicalPath: choice.blocks
        )
    }

    /// Whether `ancestor` is `descendant` or one of its ancestors, or nil when
    /// either is unknown or not routed. O(log n).
    func isAncestorOrSelf(_ ancestor: String, of descendant: String) -> Bool? {
        guard let ancestor = graph.handle(ancestor),
              let descendant = graph.handle(descendant) else { return nil }
        return graph.weights.encloses(ancestor, descendant)
    }

    /// The preferred block of `hashes`: fork choice's own weight and
    /// tie-break, unrouted blocks left out.
    func preferred(among hashes: [String]) -> String? {
        graph.preferred(among: hashes.compactMap(graph.handle)).map(graph.hash)
    }

    /// Route one newly admitted block into fork choice.
    ///
    /// The shape of the parent's existing children used to decide this: zero
    /// children extended the parent's run, one forced a split, more meant a new
    /// base. There are no runs any more, so none of that survives — a block is a
    /// leaf inside its parent's range either way, and the range structure needs
    /// nothing above the insertion point told about it.
    @discardableResult
    mutating func routeBlock(for blockHash: String) -> Bool {
        guard let block = graph.handle(blockHash) else { return false }
        return routeBlock(block)
    }

    mutating func routeBlock(_ block: UInt32) -> Bool {
        let graph = mutableGraph
        let entry = graph[block]
        guard entry.parent != BlockGraph.none else {
            // A parent that is not a canonical CID is never held: the block
            // waits forever, unrouted.
            guard graph.foreignParents[block] == nil else { return true }
            guard entry.height == 0 else { return false }
            return graph.routeRoot(block)
        }
        // A disconnected component stays unrouted until an admitted ancestor
        // grafts the whole component in.
        guard graph.isHeld(entry.parent), graph.isRouted(entry.parent) else { return true }
        return graph.routeLeaf(block, under: entry.parent)
    }

    /// Credit one contribution at a held block whose location the caller
    /// checked, and fold the rise into the weights when the block is routed.
    mutating func applyLocalContribution(
        _ contribution: VerifiedWorkContribution,
        to block: UInt32,
        attributed: Bool
    ) {
        guard let id = GrindID(contribution.id) else { return }
        let graph = mutableGraph
        graph.setWork(id, Fixed256(contribution.work), attributed: attributed, at: block)
        if graph.isRouted(block) {
            graph.directWorkChanged(at: block)
        }
    }

    /// GHOST descent chooses the child with greatest deduplicated verified
    /// work. Equal work prefers the child block with the lexicographically
    /// smaller canonical CID bytes (spec §9.4).
    func chainWithMostWork(
        startingBlock: BlockMeta
    ) -> (subtreeWork: WorkSum, tipHash: String, blocks: Set<String>) {
        chainWithMostWork(startingAt: startingBlock.blockHash)
    }

    func chainWithMostWork(
        startingAt startHash: String
    ) -> (subtreeWork: WorkSum, tipHash: String, blocks: Set<String>) {
        // Every caller starts at a routed block (`forkChoiceSnapshot` refuses
        // any other), and a routed block always has a weight.
        guard let start = graph.handle(startHash), let weight = graph.weight(of: start) else {
            preconditionFailure("fork choice from an unrouted block \(startHash)")
        }
        // An excluded start point weighs what its work weighs and descends
        // nowhere: nothing below a proven-invalid block is selectable.
        if graph.isExcludedRoot(start) {
            return (weight, startHash, [startHash])
        }
        // Weights are pure work; the descent only steers past excluded roots,
        // which are never stepped into.
        let path = graph.descend(from: start)
        return (weight, graph.hash(path.last!), Set(path.map(graph.hash)))
    }
}
