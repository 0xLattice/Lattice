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

/// One grind's location as held: its block, its strongest work inline, and
/// whether that work is already in the weights. `WorkContributionRecord` is
/// its read view.
struct GrindLocation: Sendable, Equatable {
    let blockHash: String
    var work: Fixed256
    var isRouted: Bool
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

/// Fork choice as a value: the GHOST weights, each grind's one location, and
/// the excluded roots. It stores no parent or child edge — every traversal
/// takes the block graph as a parameter — so it is never a second
/// representation of the tree, only the weights over it.
struct ForkChoice: Sendable {
    struct Descent: Sendable {
        let tipHash: String
        let blocks: Set<String>
    }

    /// Derived GHOST weights, as one Euler range per routed block — every routed
    /// block, not only those where a choice can be made. That was true while
    /// weights were stored per segment base; a range structure answers for any
    /// block at the same cost, and fork choice reads it only at forks.
    /// Per-block facts remain the source of truth because scalar weights cannot
    /// preserve grind identity.
    private(set) var weights: EulerWorkIndex = .empty
    /// Each grind's one location, its strongest observation, and whether that
    /// work is already in `weights`.
    private(set) var locations: [String: GrindLocation] = [:]
    /// Roots of proven-invalid subtrees (deferred-execution validated tier: a
    /// block whose execution completed and FAILED). Rebuilt on recovery from the
    /// durable `.exclusion` facts. Insert-only.
    ///
    /// Work weighs; validity selects (§9.9). An excluded block's work — and its
    /// descendants' — stays in every ancestor's weight exactly as any other
    /// work does: proof-of-work is a physical fact and invalidity is a judgment
    /// about state. What exclusion changes is SELECTION: the canonical descent
    /// never steps into an excluded root, so nothing below one is ever the tip
    /// or attested (§5.3). No weight is ever removed, so no index is ever
    /// rebuilt, and a descendant of an excluded root needs no bookkeeping at
    /// all — the descent cannot reach it.
    private(set) var excludedRoots: Set<String> = []
#if DEBUG
    private(set) var workUpdateCellCount: UInt64 = 0
    private(set) var graftCount: UInt64 = 0
    private(set) var graftBlockVisitCount: UInt64 = 0
#endif

    /// Recovery's linear builder: locations from the blocks' own work facts,
    /// then the weights as one Euler tour of the routed graph.
    static func build(from blocks: BlockGraph) -> ForkChoice {
        var forkChoice = ForkChoice()
        forkChoice.locations = locations(
            of: blocks.records.lazy.map(\.blockHash),
            in: blocks
        )
        forkChoice.weights = buildWeights(
            in: blocks,
            workByGrind: &forkChoice.locations
        )
        return forkChoice
    }

    /// Each grind's location and strongest observation among the blocks
    /// `hashes` of `blocks`.
    static func locations(
        of hashes: some Sequence<String>,
        in blocks: BlockGraph
    ) -> [String: GrindLocation] {
        var result: [String: GrindLocation] = [:]
        func observe(_ id: String, _ work: Fixed256, at hash: String) {
            var record = result[id] ?? GrindLocation(blockHash: hash, work: work, isRouted: false)
            if work > record.work {
                record.work = work
            }
            result[id] = record
        }

        for hash in hashes {
            guard let work = blocks.work(of: hash) else { continue }
            for (id, value) in work.workByID {
                observe(id, value, at: hash)
            }
        }
        return result
    }

    // MARK: Queries

    func isRouted(_ hash: String) -> Bool {
        weights.contains(hash)
    }

    func weight(of hash: String) -> WorkSum? {
        weights.subtreeWork(hash)
    }

    func location(of grindID: String) -> WorkContributionRecord? {
        locations[grindID].map {
            WorkContributionRecord(
                blockHash: $0.blockHash,
                contribution: VerifiedWorkContribution(id: grindID, work: $0.work.uint256),
                isRouted: $0.isRouted
            )
        }
    }

    func acceptsLocation(of grindID: String, at blockHash: String) -> Bool {
        return locations[grindID]
            .map { $0.blockHash == blockHash } ?? true
    }

    func preferred(among hashes: [String]) -> String? {
        var selected: String?
        for candidate in hashes {
            guard let candidateWork = weights.subtreeWork(candidate)
            else { continue }
            guard let current = selected,
                  let selectedWork = weights.subtreeWork(current) else {
                selected = candidate
                continue
            }
            if candidateWork > selectedWork
                || (candidateWork == selectedWork
                    && forkChoicePrefersBlock(candidate, over: current)) {
                selected = candidate
            }
        }
        return selected
    }

    /// The preferred root that is not excluded. `roots` are the graph's
    /// parentless height-0 blocks — a tree fact the caller supplies.
    func selectableRoot(among roots: [String]) -> String? {
        preferred(among: roots.filter { !excludedRoots.contains($0) })
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
    /// site keeps it so, and `ForkChoiceInvariantTests` pins it — so a revisit
    /// or a fork with no routed child is a broken invariant, never an input,
    /// and the descent fails closed on either rather than guessing. Weights are
    /// pure work; the excluded roots only steer the descent, which never steps
    /// into one.
    func descend(
        from startHash: String,
        in graph: BlockGraph
    ) -> Descent {
        var currentHash = startHash
        var blocks = Set<String>()
        while true {
            precondition(
                blocks.insert(currentHash).inserted,
                "cycle in child edges at \(currentHash)"
            )
            let all = graph.children(of: currentHash)
            let children = excludedRoots.isEmpty
                ? all
                : all.filter { !excludedRoots.contains($0) }
            guard !children.isEmpty else {
                return Descent(tipHash: currentHash, blocks: blocks)
            }
            let next = children.count == 1
                ? children[0]
                : preferred(among: children)
            guard let next else {
                preconditionFailure("no routed child under \(currentHash)")
            }
            currentHash = next
        }
    }

    // MARK: Mutations

    /// Insert-only; false when `hash` was already excluded.
    @discardableResult
    mutating func exclude(_ hash: String) -> Bool {
        excludedRoots.insert(hash).inserted
    }

    /// Route a block with no children yet directly inside its routed parent's
    /// range. Nothing above the parent is touched.
    mutating func routeLeaf(_ hash: String, under parentHash: String) -> Bool {
        weights.insertLeaf(hash, under: parentHash) != nil
    }

    mutating func routeRoot(_ hash: String) -> Bool {
        weights.insertRoot(hash)
    }

    /// Whether `descendant` is `ancestor` or descends from it, or nil when
    /// either is not routed. O(log n).
    func isAncestorOrSelf(_ ancestor: String, of descendant: String) -> Bool? {
        weights.encloses(ancestor, descendant)
    }

    /// Whether some block of `ancestors` is, or is an ancestor of, some block
    /// of `descendants`; unrouted blocks are left out (`EulerWorkIndex.anyEncloses`).
    func anyIsAncestorOrSelf(_ ancestors: [String], of descendants: [String]) -> Bool {
        weights.anyEncloses(ancestors, descendants)
    }

    /// Splice one toured component — `events`, opening at `rootHash` — into
    /// the weights in one operation, under `parentHash` or, with none, as a
    /// new genesis root; then record the component's grind locations, already
    /// marked routed.
    mutating func graft(
        events: [EulerWorkIndex.Event],
        rootedAt rootHash: String,
        under parentHash: String?,
        locations component: [String: GrindLocation]
    ) -> Bool {
        var updatedCells = 0
        if let parentHash {
            guard let cells = weights.splice(events, under: parentHash)
            else { return false }
            updatedCells = cells
        } else {
            // A component rooted at genesis has no parent range to sit inside.
            guard weights.insertRoot(rootHash) else { return false }
            if case let .open(_, rootWork)? = events.first, rootWork != .zero {
                _ = weights.add(rootWork, at: rootHash)
            }
            let inner = Array(events.dropFirst().dropLast())
            if !inner.isEmpty {
                guard let cells = weights.splice(inner, under: rootHash)
                else { return false }
                updatedCells = cells
            }
        }

        for (grindID, record) in component {
            locations[grindID] = record
        }
#if DEBUG
        graftCount += 1
        graftBlockVisitCount += UInt64(events.count / 2)  // one open per block
        workUpdateCellCount += UInt64(updatedCells)
#endif
        return true
    }

    /// Fold one verified observation into the weights. The caller holds the
    /// block `blockHash`.
    mutating func applyContribution(
        _ contribution: VerifiedWorkContribution,
        at blockHash: String
    ) {
        let id = contribution.id
        let work = Fixed256(contribution.work)
        if locations[id] == nil {
            locations[id] = GrindLocation(blockHash: blockHash, work: work, isRouted: false)
        }
        guard let existing = locations[id],
              existing.blockHash == blockHash else { return }
        if work > existing.work {
            if existing.isRouted {
                let delta = WorkSum(contribution.work)
                    .subtracting(WorkSum(existing.work))!
                guard let updatedCells = weights.add(
                        delta,
                        at: blockHash
                      ) else { return }
#if DEBUG
                workUpdateCellCount += UInt64(updatedCells)
#endif
            }
            locations[id]?.work = work
        }

        guard locations[id]?.isRouted == false,
              let strongest = locations[id]?.work else { return }
        guard let updatedCells = weights.add(
                WorkSum(strongest),
                at: blockHash
              ) else {
            return
        }
#if DEBUG
        workUpdateCellCount += UInt64(updatedCells)
#endif
        locations[id]?.isRouted = true
    }

    /// Build the derived GHOST weight index as one Euler tour of the routed
    /// graph. Recovery uses this linear builder; every live mutation is
    /// incremental.
    ///
    /// The tour visits routed blocks only, children sorted, so a rebuild is
    /// deterministic. Its ORDER differs from the one live insertion produces,
    /// which appends each new child last — but a subtree is a contiguous range
    /// under either order, and the sum over a range does not depend on the order
    /// within it, which is the only thing fork choice reads.
    private static func buildWeights(
        in blocks: BlockGraph,
        workByGrind: inout [String: GrindLocation]
    ) -> EulerWorkIndex {
        // Routed-ness was a lookup into the quotient; it is now exactly what it
        // always meant — reachable from a genesis root through blocks that are
        // present. The tour below already walks that set, so it is computed once
        // here rather than kept in a second structure that has to be maintained
        // in step with this one.
        var routedBlocks = Set<String>()
        var reachable = blocks.records
            .filter { $0.parentBlockHash == nil && $0.blockHeight == 0 }
            .map(\.blockHash)
        while let hash = reachable.popLast() {
            guard routedBlocks.insert(hash).inserted,
                  blocks.contains(hash) else { continue }
            reachable.append(contentsOf: blocks.children(of: hash).filter {
                blocks.contains($0)
            })
        }

        var directWorkByBlock: [String: WorkTotal] = [:]
        for grindID in workByGrind.keys {
            guard var record = workByGrind[grindID] else { continue }
            let routed = routedBlocks.contains(record.blockHash)
            record.isRouted = routed
            workByGrind[grindID] = record
            if routed {
                directWorkByBlock[record.blockHash, default: WorkTotal()].add(record.work)
            }
        }

        // Iterative because a chain is as deep as it is long, and recursion
        // here would be bounded by the stack.
        func routedChildren(_ hash: String) -> [String] {
            blocks.children(of: hash)
                .filter { routedBlocks.contains($0) }
                .sorted()
        }
        var events: [EulerWorkIndex.Event] = []
        events.reserveCapacity(routedBlocks.count * 2)
        let roots = blocks.records
            .filter {
                $0.parentBlockHash == nil
                    && $0.blockHeight == 0
                    && routedBlocks.contains($0.blockHash)
            }
            .map(\.blockHash)
            .sorted()
        for root in roots {
            var tourStack: [(hash: String, children: [String], next: Int)] = []
            events.append(.open(root, directWorkByBlock[root]?.exact ?? .zero))
            tourStack.append((root, routedChildren(root), 0))
            while var frame = tourStack.popLast() {
                guard frame.next < frame.children.count else {
                    events.append(.close(frame.hash))
                    continue
                }
                let child = frame.children[frame.next]
                frame.next += 1
                tourStack.append(frame)
                events.append(.open(child, directWorkByBlock[child]?.exact ?? .zero))
                tourStack.append((child, routedChildren(child), 0))
            }
        }
        return EulerWorkIndex.build(events: events)
    }
}

extension ChainTree {
    // Forwarders onto `forkChoice`, kept so callers and tests read the actor
    // exactly as before.

    func workContribution(id: String) -> WorkContributionRecord? {
        forkChoice.location(of: id)
    }

#if DEBUG
    var segmentWorkUpdateCellCount: UInt64 { forkChoice.workUpdateCellCount }
    var segmentGraftCount: UInt64 { forkChoice.graftCount }
    var segmentGraftBlockVisitCount: UInt64 { forkChoice.graftBlockVisitCount }
#endif

    /// The grind `id` as credited at `blockHash`, or nil if it is not credited
    /// there. Reads the block's own work fact, never the derived totals, so
    /// asking whether a proof is already credited costs nothing as the tree grows.
    public func workContribution(
        id: String,
        at blockHash: String
    ) -> VerifiedWorkContribution? {
        graph.contribution(id: id, at: blockHash)
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
        forkChoice.isRouted(blockHash)
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
        guard graph.contains(hash) else { return nil }
        var total = WorkSum.zero
        var current = hash
        while true {
            total = total + (graph.work(of: current)?.work ?? .zero)
            // A block held under a parent that never recorded it as a child
            // (a child at a height its parent cannot have) roots its own
            // component, as it does for the subtree measure.
            guard let parent = graph.parent(of: current),
                  graph.children(of: parent).contains(current) else { return total }
            current = parent
        }
    }

    /// The same-chain subtree measure of `hash`, deduplicated by grind
    /// identity: fork choice's own weight once the block is connected, and the
    /// sum over its held subtree while it is not. Pure work, excluded subtrees
    /// included: validity never subtracts weight.
    public func subtreeWeight(forHash hash: String) -> WorkSum? {
        guard graph.contains(hash) else { return nil }
        if let weight = forkChoice.weight(of: hash) { return weight }
        return graph.subtree(of: hash).reduce(.zero) {
            $0 + (graph.work(of: $1)?.work ?? .zero)
        }
    }

    /// The work fork choice weighs `hash`'s subtree by: what
    /// `forkChoiceSnapshot(startingAt:)` reports as `subtreeWork`, read from
    /// the weight index without descending the subtree.
    public func forkChoiceWeight(of hash: String) -> WorkSum? {
        guard graph.contains(hash), forkChoice.isRouted(hash) else { return nil }
        return forkChoice.weight(of: hash)
    }

    /// Public simulator/test view of the real local fork-choice descent.
    public func forkChoiceSnapshot(startingAt hash: String) -> ForkChoiceSnapshot? {
        guard graph.contains(hash),
              forkChoice.isRouted(hash) else { return nil }
        let choice = chainWithMostWork(startingAt: hash)
        return ForkChoiceSnapshot(
            startingHash: hash,
            subtreeWork: choice.subtreeWork,
            tipHash: choice.tipHash,
            canonicalPath: choice.blocks
        )
    }

    @discardableResult
    /// Route one newly admitted block into fork choice.
    ///
    /// The shape of the parent's existing children used to decide this: zero
    /// children extended the parent's run, one forced a split, more meant a new
    /// base. There are no runs any more, so none of that survives — a block is a
    /// leaf inside its parent's range either way, and the range structure needs
    /// nothing above the insertion point told about it.
    mutating func routeBlock(for blockHash: String) -> Bool {
        guard let block = graph[blockHash] else { return false }
        guard let parentHash = block.parentBlockHash else {
            guard block.blockHeight == 0 else { return false }
            return forkChoice.routeRoot(blockHash)
        }
        // A disconnected component stays unrouted until an admitted ancestor
        // grafts the whole component in.
        guard graph.contains(parentHash),
              forkChoice.isRouted(parentHash) else { return true }
        return forkChoice.routeLeaf(blockHash, under: parentHash)
    }

    /// Route one newly connected orphan component without touching unrelated
    /// history. Its blocks are toured once and spliced into the parent's range
    /// in one operation, so nothing above the graft point is updated.
    mutating func graftConnectedComponent(rootedAt rootHash: String) -> Bool {
        var pending = [rootHash]
        var componentHashes = Set<String>()
        while let hash = pending.popLast() {
            // Defensive: a member of a disconnected component cannot already be
            // routed (`routeBlock` refuses to route under an unrouted parent),
            // so this guard never fires; if an invariant ever broke, skipping
            // also strips the block from the spliced events, since the tour
            // below only follows children that are in componentHashes.
            guard !forkChoice.isRouted(hash),
                  componentHashes.insert(hash).inserted,
                  graph.contains(hash) else { continue }
            pending.append(contentsOf: graph.children(of: hash))
        }
        guard !componentHashes.isEmpty else { return false }

        for hash in componentHashes {
            guard graph.contains(hash) else { return false }
        }
        var componentWorkByGrind = ForkChoice.locations(of: componentHashes, in: graph)
        // Direct work per block, which is all the Euler tour carries. No subtree
        // total is computed for the component and none is added to any ancestor:
        // splicing its elements inside the parent's range makes every enclosing
        // range correct by construction.
        //
        // `isRouted` is set here because the build call that used to set it as a
        // side effect is gone. Leaving it false would let the contribution path
        // add this same work a second time.
        var componentDirectWork: [String: WorkTotal] = [:]
        for grindID in componentWorkByGrind.keys {
            guard var record = componentWorkByGrind[grindID] else { continue }
            record.isRouted = true
            componentWorkByGrind[grindID] = record
            componentDirectWork[record.blockHash, default: WorkTotal()].add(record.work)
        }

        if let parentHash = graph.parent(of: rootHash) {
            guard forkChoice.isRouted(parentHash) else {
                return false
            }
        } else if graph.height(of: rootHash) != 0 {
            return false
        }

        // One splice, and nothing above it. The walk that used to add this
        // component's total to every routed base above the graft point is gone,
        // because there are no stored ancestor totals left to update.
        // Iterative on purpose: a connected component can be a long orphan run,
        // and a recursive tour would put its length on the call stack.
        var events: [EulerWorkIndex.Event] = []
        events.reserveCapacity(componentHashes.count * 2)
        func componentChildren(_ hash: String) -> [String] {
            graph.children(of: hash)
                .filter { componentHashes.contains($0) }
                .sorted()
        }
        var tourStack: [(hash: String, children: [String], next: Int)] = []
        events.append(.open(rootHash, componentDirectWork[rootHash]?.exact ?? .zero))
        tourStack.append((rootHash, componentChildren(rootHash), 0))
        while var frame = tourStack.popLast() {
            guard frame.next < frame.children.count else {
                events.append(.close(frame.hash))
                continue
            }
            let child = frame.children[frame.next]
            frame.next += 1
            tourStack.append(frame)
            events.append(.open(child, componentDirectWork[child]?.exact ?? .zero))
            tourStack.append((child, componentChildren(child), 0))
        }

        return forkChoice.graft(
            events: events,
            rootedAt: rootHash,
            under: graph.parent(of: rootHash),
            locations: componentWorkByGrind
        )
    }

    mutating func applyLocalContribution(
        _ contribution: VerifiedWorkContribution,
        to blockHash: String,
        attributed: Bool
    ) {
        _ = graph.setWorkContribution(
            contribution, attributed: attributed, at: blockHash
        )
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
        guard let weight = forkChoice.weight(of: startHash) else {
            preconditionFailure("fork choice from an unrouted block \(startHash)")
        }
        // An excluded start point weighs what its work weighs and descends
        // nowhere: nothing below a proven-invalid block is selectable.
        if forkChoice.excludedRoots.contains(startHash) {
            return (weight, startHash, [startHash])
        }
        // Weights are pure work; the descent only steers past excluded roots,
        // which are never stepped into. No-op when nothing is excluded — the
        // steady-state path is unchanged.
        let descent = forkChoice.descend(from: startHash, in: graph)
        return (weight, descent.tipHash, descent.blocks)
    }
}
