import UInt256
import LatticePrimitives
import LatticePoW

/// The canonical projection and the execution frontier over the graph's
/// arrays: the selected path (`canonical`, root to tip), which blocks were
/// executed (`validated`) and which are executed all the way from genesis
/// (`anchored`), and the state-transition index behind continuity (each
/// state's producers).
///
/// `validated` grows only: execution is a fact about immutable bytes, so it
/// is never retracted, and a re-delivered weighed fact must never downgrade
/// an executed block. `anchored` marks the blocks reachable from this chain's
/// genesis through an unbroken run of EXECUTED blocks — every state on the
/// path produced, not merely declared — so "the chain produced this state" is
/// O(1) instead of a walk whose length grows with chain height. Block 1 of a
/// child chain anchors against `emptyHeader`, which is reachable only at the
/// parent's genesis, so without it the anchor cost would grow without bound.
/// Monotone too: an ancestor never stops having been executed.
extension BlockGraph {
    // MARK: Canonical path

    /// The index in `canonical` of the canonical block at `height`. The path
    /// holds one block per height in height order, so this is direct while
    /// the path is contiguous from height 0, and a binary search otherwise.
    func canonicalIndex(ofHeight height: UInt64) -> Int? {
        if height < UInt64(canonical.count), self[canonical[Int(height)]].height == height {
            return Int(height)
        }
        var low = 0, high = canonical.count
        while low < high {
            let middle = (low + high) / 2
            if self[canonical[middle]].height < height { low = middle + 1 } else { high = middle }
        }
        return low < canonical.count && self[canonical[low]].height == height ? low : nil
    }

    func canonicalBlock(atHeight height: UInt64) -> UInt32? {
        canonicalIndex(ofHeight: height).map { canonical[$0] }
    }

    func isCanonical(_ block: UInt32) -> Bool {
        isHeld(block) && canonicalBlock(atHeight: self[block].height) == block
    }

    /// The difficulty anchor a height-1 block sets: its own timestamp and
    /// target, read from its held header.
    func anchor(setBy block: UInt32) -> DifficultyAnchor? {
        let entry = self[block]
        guard entry.flags.contains(.hasSnapshot) else { return nil }
        return DifficultyAnchor(blockHeight: 1, timestamp: entry.timestamp, target: entry.target.uint256)
    }

    // MARK: Execution facts

    func isAnchored(_ block: UInt32) -> Bool {
        self[block].flags.contains(.anchored)
    }

    func isValidated(_ block: UInt32) -> Bool {
        self[block].flags.contains(.validated)
    }

    /// The executed-from-genesis blocks whose post-state is `state`.
    func anchoredProducers(of state: UInt32) -> [UInt32] {
        producers(of: state).filter(isAnchored)
    }

    /// Whether this chain produced `state`: some block declaring it as
    /// post-state is on the executed-from-genesis frontier. The frontier is
    /// the one authority — executed from genesis and not under an excluded
    /// root; the weight index says nothing about validity (work weighs, §9.9).
    func chainProduced(_ state: UInt32) -> Bool {
        producers(of: state).contains(where: isAnchored)
    }

    /// Mark every block reachable from a genesis through an unbroken run of
    /// executed blocks. Computed downward so each block is settled once.
    func seedAnchored() {
        var pending = roots.filter(isValidated)
        while let block = pending.popLast() {
            guard isValidated(block), !isExcludedRoot(block), !isAnchored(block) else { continue }
            self[block].flags.insert(.anchored)
            pending.append(contentsOf: children(of: block))
        }
    }

    /// Record that a held block's transition was executed. Monotone: the
    /// marker is a fact about immutable bytes, so it is never retracted.
    func markValidated(_ block: UInt32) {
        self[block].flags.insert(.validated)
        propagateAnchored(from: block)
    }

    /// Extend the executed-from-genesis frontier.
    ///
    /// A block is anchored once it is executed and its parent is anchored (a
    /// genesis anchors itself). Executing one block can therefore also anchor
    /// descendants that were executed earlier out of order, so the frontier is
    /// pushed down until it stops moving. Each block is anchored at most once
    /// for the life of the chain, so the total work is linear overall and the
    /// amortized cost per admission is constant.
    private func propagateAnchored(from block: UInt32) {
        var pending = [block]
        while let next = pending.popLast() {
            let entry = self[next]
            guard entry.flags.contains(.held), !entry.flags.contains(.anchored),
                  entry.flags.contains(.validated) else { continue }
            let parentAnchored = entry.parent == Self.none || isAnchored(entry.parent)
            // A proven-invalid block extends nothing: its subtree left fork
            // choice, and the states it declared are not states this chain
            // stands behind.
            guard parentAnchored, !entry.flags.contains(.excludedRoot) else { continue }
            self[next].flags.insert(.anchored)
            pending.append(contentsOf: children(of: next))
        }
    }

    /// Whether a run of executed-from-genesis blocks carries state `from` to
    /// state `to`, for distinct states: a block whose transition is
    /// `from → …` and, through anchored parents whose post-state is each
    /// block's pre-state, a block producing `to`. Only a transition on the
    /// executed-from-genesis frontier may be attested: the weighed tier records
    /// a block's declared post-state without running it, so an unverified
    /// claim would otherwise stay attestable forever; and a child chain
    /// settles cross-chain withdrawals against an attested parent state.
    /// `visits` counts the blocks the search read: the caller's own counter,
    /// so the search writes nothing a shared graph's other holders see.
    func continuity(from: UInt32, to: UInt32, visits: inout UInt64) -> Bool {
        let candidates = anchoredProducers(of: to)
        if candidates.contains(where: { self[$0].prevState == from }) {
            return true
        }
        var pending = candidates
        var visited = Set<UInt32>()
        while let block = pending.popLast() {
            guard visited.insert(block).inserted else { continue }
            let entry = self[block]
            visits &+= 1
            if entry.prevState == from { return true }
            let parent = entry.parent
            guard parent != Self.none, isAnchored(parent),
                  self[parent].flags.contains(.hasSnapshot),
                  self[parent].postState == entry.prevState else { continue }
            pending.append(parent)
        }
        return false
    }

    // MARK: Selection

    /// Project the canonical path after one fork-choice mutation.
    ///
    /// `monotoneIncreaseAt` names the single block a strictly-positive work
    /// increase landed on — a new leaf, a newly grafted component root, or a
    /// stronger observation on a block already held. ONLY a mutation of that
    /// shape may pass it. That is what makes truncation sound: such an increase
    /// raises the subtree work of exactly the blocks on the mutated block's
    /// ancestor line and of nothing else, so at every canonical block below the
    /// point where that line leaves the canonical path, the child that already
    /// wins is the child that gained — it cannot lose, not even a CID tie-break
    /// it previously won, since it now wins strictly. No decision below that
    /// point can flip, so the path below it needs no recomputation.
    ///
    /// Exclusion removes no weight but changes which child is selectable, so a
    /// canonical exclusion forces a whole-chain projection, as do restore-replay
    /// and a never-projected state.
    func project(
        generation: UInt64,
        forceFull: Bool = false,
        monotoneIncreaseAt mutatedAt: UInt32? = nil
    ) -> ChainCommit? {
        defer { projectedGeneration = generation }
        // A never-projected state has no trustworthy canonical path to truncate
        // against, and `forceFull` means the caller knows it cannot be trusted.
        if !forceFull, projectedGeneration != nil, let mutatedAt,
           let outcome = truncatedProjection(monotoneIncreaseAt: mutatedAt) {
            return outcome.commit
        }

        // Whole-chain fallback. Weights are pure work, so ONE projection path
        // serves the exclusion-free and exclusion-present cases alike.
        guard let root = selectableRoot() else { return nil }
#if DEBUG
        fullCanonicalProjectionCount += 1
#endif
        let path = descend(from: root)
#if DEBUG
        // Descent steps ARE blocks: with no quotient there is no hop to take,
        // so this column and the block column converge by construction.
        canonicalProjectionSegmentVisitCount += UInt64(path.count)
        canonicalProjectionBlockVisitCount += UInt64(path.count)
#endif
        let tip = path.last!
        guard tip != canonicalTip || path != canonical else { return nil }
        let commit = canonicalDelta(tip: tip, blocks: path, replacing: canonical)
        canonicalTip = tip
        canonical = path
        return commit
    }

    /// Outcome of a mutation-point projection. A nil OUTCOME means truncation's
    /// assumptions could not be verified and the caller must re-materialize from
    /// the root; a nil `commit` inside one means the projection ran and nothing
    /// changed.
    private struct TruncatedProjectionOutcome {
        let commit: ChainCommit?
    }

    /// Where the ancestor line of a mutated block meets the canonical path.
    private enum Divergence {
        /// The canonical block the line meets, and its child on the line.
        case canonical(UInt32, child: UInt32)
        /// The line ends at a genesis root that is not the canonical one.
        case otherRoot
        case malformed
    }

    /// The deepest canonical block on the ancestor line of `mutatedAt`.
    ///
    /// This walk is UNCAPPED deliberately. A step budget here is a cliff, not a
    /// budget: past it the caller falls through to the whole-chain projection,
    /// which pays a spine walk AND a descent from the root before it can
    /// discover that nothing moved — reintroducing the quadratic this exists to
    /// remove. Uncapped, the walk is bounded by the length of the branch below
    /// the mutated block, which the node has already paid to admit. Each step
    /// moves to a strictly lower height, and a parent that does not is a
    /// malformed route that fails closed.
    private func canonicalDivergencePoint(from mutatedAt: UInt32) -> Divergence {
        var current = mutatedAt
        var below = mutatedAt
        while !isCanonical(current) {
            let entry = self[current]
            guard entry.parent != Self.none else {
                return entry.height == 0 ? .otherRoot : .malformed
            }
            guard isHeld(entry.parent), self[entry.parent].height < entry.height else { return .malformed }
            below = current
            current = entry.parent
        }
        return .canonical(current, child: below)
    }

    /// Re-descend from the divergence point instead of the root. Every guard
    /// here fails closed: the caller re-materializes whole rather than act on a
    /// partial answer.
    private func truncatedProjection(monotoneIncreaseAt mutatedAt: UInt32) -> TruncatedProjectionOutcome? {
        // A block that never routed contributed no work and no fork-choice
        // edge, so nothing can have moved.
        guard isRouted(mutatedAt) else {
            return TruncatedProjectionOutcome(commit: nil)
        }
        // The increase landed inside the subtree that already wins at every one
        // of its ancestors, so every canonical decision is reinforced and none
        // flips: O(1).
        guard !isCanonical(mutatedAt) else {
            return TruncatedProjectionOutcome(commit: nil)
        }
        let divergence: UInt32
        let contender: UInt32
        switch canonicalDivergencePoint(from: mutatedAt) {
        case .canonical(let block, let child):
            divergence = block
            contender = child
        case .otherRoot:
            // The increase landed under another genesis root, so nothing in
            // the canonical root's tree moved: if that root still wins among
            // the roots, the whole canonical path stands. O(#roots).
            guard let canonicalRoot = canonicalBlock(atHeight: 0),
                  selectableRoot() == canonicalRoot else { return nil }
#if DEBUG
            truncatedCanonicalProjectionCount += 1
#endif
            return TruncatedProjectionOutcome(commit: nil)
        case .malformed:
            return nil
        }
        let (suffixHeight, overflow) = self[divergence].height.addingReportingOverflow(1)
        guard !overflow else { return nil }
        // The increase is confined to the subtree of `contender`, the
        // divergence point's child on the mutated line. Before it, the
        // canonical child already won against every sibling, and no other
        // sibling moved, so the winner now is one of those two: two weight
        // reads, however many siblings there are.
        let incumbent = canonicalBlock(atHeight: suffixHeight)
        // The canonical child must sit where the path says, and without one
        // the divergence point must be the tip; otherwise the index is not
        // what this step assumes, and the caller re-materializes.
        if let incumbent {
            guard self[incumbent].parent == divergence else { return nil }
        } else {
            guard divergence == canonicalTip else { return nil }
        }
        let chosen: UInt32?
        if isExcludedRoot(contender) {
            // The descent never steps into an excluded root.
            chosen = incumbent
        } else if let incumbent {
            chosen = preferred(among: [incumbent, contender])
        } else {
            // The divergence point is the tip: it had no selectable child, so
            // the contender is the only one.
            chosen = contender
        }
        // Every child of the divergence point is unselectable: the descent
        // from the root provably ends at it, so it already is the tip.
        guard let chosen else { return TruncatedProjectionOutcome(commit: nil) }
        // The COMMON admission on a merged-mining child is a losing sibling, and
        // it must cost nothing: if the winner here is still the block already
        // on the canonical path, no decision changed anywhere. O(1), before
        // reading the path above and before any descent.
        if isCanonical(chosen) {
#if DEBUG
            truncatedCanonicalProjectionCount += 1
#endif
            return TruncatedProjectionOutcome(commit: nil)
        }
        guard let replaced = canonicalPath(from: suffixHeight) else { return nil }
        let descent = descend(from: chosen)
#if DEBUG
        canonicalProjectionSegmentVisitCount += UInt64(descent.count)
        canonicalProjectionBlockVisitCount += UInt64(descent.count)
        truncatedCanonicalProjectionCount += 1
#endif
        let tip = descent.last!
        let commit = canonicalDelta(tip: tip, blocks: descent, replacing: replaced.blocks)
        guard commit != nil else { return TruncatedProjectionOutcome(commit: nil) }
        canonicalTip = tip
        canonical.removeSubrange(replaced.start...)
        canonical.append(contentsOf: descent)
        return TruncatedProjectionOutcome(commit: commit)
    }

    /// The canonical blocks at and above `height`, and where they start in
    /// the path. Nil when the path is not contiguous from `height` to the
    /// tip, so the caller re-materializes instead of trusting a partial
    /// removal set.
    private func canonicalPath(from height: UInt64) -> (start: Int, blocks: ArraySlice<UInt32>)? {
        guard canonicalTip != Self.none else { return nil }
        let tipHeight = self[canonicalTip].height
        guard height <= tipHeight else { return (canonical.count, []) }
        guard let start = canonicalIndex(ofHeight: height),
              let end = canonicalIndex(ofHeight: tipHeight),
              UInt64(end - start) == tipHeight - height else { return nil }
        return (start, canonical[start...end])
    }

    /// The commit swapping the canonical blocks `replaced` for `blocks`
    /// ending at `tip`, or nil when nothing moves.
    private func canonicalDelta(
        tip: UInt32,
        blocks: some Collection<UInt32>,
        replacing replaced: some Collection<UInt32>
    ) -> ChainCommit? {
        // Both differences are unconditional, so they are correct whether or
        // not the replaced and new block sets overlap.
        let new = Set(blocks), old = Set(replaced)
        let removed = old.subtracting(new)
        let added = new.subtracting(old)
        guard tip != canonicalTip || !removed.isEmpty || !added.isEmpty else { return nil }
        return ChainCommit(
            tipHash: hash(tip),
            canonicalBlocksAdded: Dictionary(uniqueKeysWithValues: added.map { (hash($0), self[$0].height) }),
            canonicalBlocksRemoved: Set(removed.map(hash))
        )
    }
}

extension ChainTree {
    // Forwarders onto the graph's frontier, kept so callers and tests read
    // the actor exactly as before.

    public var canonicalTip: String {
        graph.canonicalTip == BlockGraph.none ? "" : graph.hash(graph.canonicalTip)
    }

    /// The canonical path as a set. O(path): tests only.
    var canonicalHashes: Set<String> { Set(graph.canonical.map(graph.hash)) }

    /// The canonical path by height. O(path): tests only.
    var canonicalHashByHeight: [UInt64: String] {
        Dictionary(uniqueKeysWithValues: graph.canonical.map { (graph[$0].height, graph.hash($0)) })
    }

    /// The canonical tip's recorded header fields.
    public var tipSnapshot: TipBlockSnapshot? {
        graph.canonicalTip == BlockGraph.none ? nil : graph.snapshot(of: graph.canonicalTip)
    }

#if DEBUG
    var fullCanonicalProjectionCount: UInt64 { graph.fullCanonicalProjectionCount }
    var truncatedCanonicalProjectionCount: UInt64 { graph.truncatedCanonicalProjectionCount }
    var canonicalProjectionBlockVisitCount: UInt64 { graph.canonicalProjectionBlockVisitCount }
    var canonicalProjectionSegmentVisitCount: UInt64 { graph.canonicalProjectionSegmentVisitCount }
#endif

    /// Recompute canonical projection after local simulation/test mutation.
    @discardableResult
    public mutating func reevaluateForkChoice() -> ChainCommit? {
        guard hasUnreservedMutationCapacity else { return nil }
        // No graph or weight fact has changed since the projection was last
        // brought current, so re-projection is provably a no-op: a duplicate
        // delivery that added nothing cannot promote anything.
        guard mutationGeneration != graph.projectedGeneration else { return nil }
        let canonicalChange = projectCanonicalChain()
        guard canonicalChange != nil else { return nil }
        // This bump carries no graph mutation, so the projection just computed
        // stays exact for the new generation.
        mutationGeneration += 1
        mutableGraph.projectedGeneration = mutationGeneration
        return (canonicalChange ?? ChainCommit(tipHash: canonicalTip))
            .atRevision(mutationGeneration)
    }

    /// One coherent context for transaction preflight: the named block (the
    /// canonical tip when nil) and its snapshot. Keeping the two in one actor
    /// read lets callers reject a result if the tip changes while content is
    /// being resolved. The snapshot is nil unless the block is on the
    /// executed-from-genesis frontier: a weighed block's post-state is a
    /// declared claim, never a state to classify against.
    public func transactionPreflightTip(
        at blockHash: String? = nil
    ) -> (cid: String, snapshot: TipBlockSnapshot?) {
        let cid = blockHash ?? canonicalTip
        guard let block = graph.handle(cid), graph.isAnchored(block) else { return (cid, nil) }
        return (cid, graph.snapshot(of: block))
    }

    public func isCanonical(hash: String) -> Bool {
        graph.handle(hash).map(graph.isCanonical) ?? false
    }

    public func canonicalBlockHash(atHeight height: UInt64) -> String? {
        graph.canonicalBlock(atHeight: height).map(graph.hash)
    }

#if DEBUG
    /// Test-only seam for asserting that a no-reorg update did not materialize
    /// the unchanged unary canonical path.
    mutating func resetFullCanonicalProjectionCount() {
        mutableGraph.fullCanonicalProjectionCount = 0
    }

    /// Read-only whole-chain projection over the LIVE index, with no counter and
    /// no state effects. Differential tests use it to separate a wrong
    /// truncation from a wrong index.
    func debugFullCanonicalProjection() -> (
        canonicalTip: String,
        canonicalHashes: Set<String>
    )? {
        guard let root = graph.selectableRoot() else { return nil }
        let path = graph.descend(from: root)
        return (graph.hash(path.last!), Set(path.map(graph.hash)))
    }
#endif

    /// Project the canonical path after one fork-choice mutation; see
    /// `BlockGraph.project`.
    mutating func projectCanonicalChain(
        forceFull: Bool = false,
        monotoneIncreaseAt mutatedAt: String? = nil
    ) -> ChainCommit? {
        projectCanonicalChain(forceFull: forceFull, increasedAt: mutatedAt.flatMap(graph.handle))
    }

    mutating func projectCanonicalChain(
        forceFull: Bool = false,
        increasedAt mutatedAt: UInt32?
    ) -> ChainCommit? {
        mutableGraph.project(
            generation: mutationGeneration,
            forceFull: forceFull,
            monotoneIncreaseAt: mutatedAt
        )
    }

    /// Whether `blockHash` is reachable from this chain's genesis through an
    /// unbroken run of EXECUTED blocks — the honest form of the question the
    /// old `hasValidatedAncestry` name promised and did not answer.
    ///
    /// Use this, not `hasConnectedAncestry`, for anything a CHILD chain will
    /// bind to. A weighed block is connected from its header alone; issuing a
    /// cross-chain fact for one hands a child a commitment this chain has not
    /// verified and may yet prove invalid.
    public func hasExecutedAncestry(blockHash: String) -> Bool {
        graph.handle(blockHash).map(graph.isAnchored) ?? false
    }

    /// The tip a node acts on: the heaviest executed tip, or empty while no
    /// genesis root is executed. At each fork the heaviest child that is
    /// executed is the step taken — fork choice's own weight and tie-break —
    /// and the descent stops where no child is executed. The genesis roots
    /// are a fork like any other: the descent starts at the heaviest executed
    /// root that is not excluded, so a heavier root whose body is withheld
    /// weighs without stalling it (§9.4, §9.9). A block with no verdict is
    /// never stepped into: it weighs, and is taken once it executes. Up to the
    /// executed prefix of the canonical chain this is fork choice's own
    /// descent, so when the canonical root is executed the walk starts there.
    ///
    /// With `avoided` blocks, they and all they lead to are left out: from
    /// the parent of the deepest avoided block on the act-on chain, the
    /// heaviest executed step at each fork that is not avoided — at the
    /// genesis fork when that block is a root. The act-on tip when none of
    /// them is on its chain, or no other root is executed.
    public func heaviestExecutedTip(avoiding avoided: Set<String> = []) -> String {
        let graph = self.graph
        let skipped = Set(avoided.compactMap(graph.handle))
        func descend(from start: UInt32, skipping skipped: Set<UInt32>) -> UInt32 {
            var tip = start
            while let next = graph.preferred(among: graph.children(of: tip).filter {
                graph.isValidated($0) && !skipped.contains($0)
            }) {
                tip = next
            }
            return tip
        }
        // The genesis fork: a root is anchored when executed and not excluded.
        func root(skipping skipped: Set<UInt32>) -> UInt32? {
            graph.preferred(among: graph.roots.filter { graph.isAnchored($0) && !skipped.contains($0) })
        }
        guard let start = executedPrefix() ?? root(skipping: []) else { return "" }
        let tip = descend(from: start, skipping: [])
        guard let floor = skipped.map({ graph[$0].height }).min() else { return graph.hash(tip) }
        var deepest: UInt32?
        var block = tip
        while graph.isHeld(block), graph[block].height >= floor {
            if skipped.contains(block) { deepest = block }
            block = graph[block].parent
            guard block != BlockGraph.none else { break }
        }
        guard let deepest else { return graph.hash(tip) }
        let parent = graph[deepest].parent
        guard parent != BlockGraph.none else {
            return root(skipping: skipped).map { graph.hash(descend(from: $0, skipping: skipped)) } ?? graph.hash(tip)
        }
        return graph.hash(descend(from: parent, skipping: skipped))
    }

    /// The deepest block on the canonical chain whose ancestry is executed
    /// from genesis; nil while the canonical genesis root is not executed
    /// (the act-on descent then starts at another root, if one is).
    /// The executed blocks on one path are a prefix of it, so this is a
    /// binary search over heights.
    private func executedPrefix() -> UInt32? {
        guard let genesis = graph.canonicalBlock(atHeight: 0),
              graph.isValidated(genesis) else { return nil }
        var low: UInt64 = 0
        var high = highestBlockHeight
        while low < high {
            let middle = low + (high - low + 1) / 2
            if let block = graph.canonicalBlock(atHeight: middle), graph.isAnchored(block) {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return graph.canonicalBlock(atHeight: low) ?? genesis
    }

    /// Whether `toStateCID` is reachable from `fromStateCID` through the
    /// connected accepted state-transition graph. Fork choice is irrelevant.
    /// Continuity is a property of the graph, not of how hard a node is willing
    /// to look: a visit budget would make the same question answerable on one
    /// node and unanswerable on another from identical data, splitting honest
    /// nodes by local policy. Serving RATE is a node's choice; the ANSWER is
    /// not. The block-1 shape — the one whose cost grew with chain height — is
    /// answered from the anchored frontier in O(1).
    public mutating func hasStateContinuity(
        from fromStateCID: String,
        to toStateCID: String
    ) -> Bool {
        guard let from = CIDIdentity.canonicalString(fromStateCID),
              let to = CIDIdentity.canonicalString(toStateCID) else {
            return false
        }
        if from == to { return true }
        // A child's block 1 anchors against `emptyHeader`, which is reachable
        // only at this chain's genesis — so the question is exactly "did this
        // chain produce that state", which the executed-from-genesis frontier
        // answers outright.
        if from == LatticeState.emptyHeader.rawCID {
            return graph.stateHandle(to).map(graph.chainProduced) ?? false
        }
        // A state no block declares produces nothing; one no block declares
        // as pre-state matches none (`none` is no block's state).
        guard let toState = graph.stateHandle(to) else { return false }
        // A query: the graph is only read; the visit count is this tree's own.
        var visits: UInt64 = 0
        defer {
#if DEBUG
            stateContinuityBlockVisitCount &+= visits
#endif
        }
        return graph.continuity(from: graph.stateHandle(from) ?? BlockGraph.none, to: toState, visits: &visits)
    }

    /// Record that a held block's transition was executed.
    mutating func markValidated(blockHash: String) {
        // Already recorded: nothing to change (and nothing to write).
        guard let block = graph.handle(blockHash), !graph.isValidated(block) else { return }
        mutableGraph.markValidated(block)
    }

    /// Whether some OTHER genesis root of this chain is on the executed
    /// frontier — "is there a chain to stand on", the test a producer runs
    /// before it may exclude a root (§9.9).
    package func hasExecutedRoot(besides blockHash: String) -> Bool {
        let besides = graph.handle(blockHash)
        return graph.roots.contains { $0 != besides && graph.isAnchored($0) }
    }
}

extension ChainTree {
    /// The executed-from-genesis blocks whose post-state is `stateCID`.
    func anchoredProducers(of stateCID: String) -> [String] {
        guard let state = CIDIdentity.canonicalString(stateCID).flatMap(graph.stateHandle) else { return [] }
        return graph.anchoredProducers(of: state).map(graph.hash)
    }
}
