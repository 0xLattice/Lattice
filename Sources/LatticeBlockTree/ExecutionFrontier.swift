import CID
import UInt256
import LatticePrimitives

struct StateTransition: Hashable {
    let from: String
    let to: String
}

/// The canonical projection and the execution frontier as a value: the
/// selected path, which blocks were executed and which are executed all the
/// way from genesis, and the state-transition index behind continuity. It
/// stores no parent or child edge — every walk takes the block graph as a
/// parameter, and selection reads the fork choice it is handed — so it is
/// never a second representation of the tree, only facts over it.
struct ExecutionFrontier: Sendable {
    // MARK: Canonical projection (the selection result)

    private(set) var canonicalTip: String
    private(set) var canonicalHashes: Set<String>
    private(set) var canonicalHashByHeight: [UInt64: String]
    private(set) var tipSnapshot: TipBlockSnapshot?
    /// Generation at which the canonical projection was last brought current
    /// BY AN ACTUAL PROJECTION. Every graph/weight mutation flows through
    /// submitBlock or addWorkContribution, both of which advance
    /// `mutationGeneration`, so equality proves the projection is exact and
    /// re-projection is a no-op. `nil` = never verified: the package
    /// initializer can construct a deliberately stale projection (simulation
    /// and tests do), so currency is only ever established by projecting.
    private(set) var projectedGeneration: UInt64?

    // MARK: Execution facts

    /// Blocks whose transition this chain EXECUTED, so their `postState` is a
    /// reproduced result rather than a declared claim. Grows only: execution is
    /// a fact about immutable bytes, so it is never retracted, and a re-
    /// delivered weighed fact must never downgrade an executed block.
    ///
    /// Kept beside `snapshots` rather than inside it because snapshot
    /// equality is used as a corruption predicate: a block whose committed
    /// fields changed means a corrupt graph, whereas a block that has since
    /// been executed is ordinary progress.
    private(set) var validated: Set<String>

    /// Blocks reachable from this chain's genesis through an unbroken run of
    /// EXECUTED blocks — i.e. every state on the path was produced, not merely
    /// declared.
    ///
    /// This is what "the chain produced this state" means, and keeping it as an
    /// index makes answering it O(1) instead of a walk whose length grows with
    /// chain height. Block 1 of a child chain anchors against `emptyHeader`,
    /// which is reachable only at the parent's genesis, so without this the
    /// anchor cost would grow without bound and a deployment would eventually
    /// become unanswerable.
    ///
    /// Monotone, like `validated`: execution is a fact about immutable
    /// bytes and an ancestor never stops having been executed.
    private(set) var anchored: Set<String>

    // MARK: State-continuity index

    private(set) var snapshots: [String: TipBlockSnapshot]
    private var byTransition: [StateTransition: Set<String>]
    private var byPostState: [String: Set<String>]

#if DEBUG
    /// Test-visible diagnostic for a whole-block canonical materialization.
    private(set) var fullCanonicalProjectionCount: UInt64 = 0
    /// Projections that re-descended from the divergence point instead of the
    /// root. A truncation that silently never fired would still be CORRECT, so
    /// the cost tests assert this rises rather than only that the answers match.
    private(set) var truncatedCanonicalProjectionCount: UInt64 = 0
    /// Blocks materialized by canonical projections, and segments walked to
    /// select the canonical spine. The projection COUNT cannot show the cost
    /// PER projection, which is what live-sync admission actually pays.
    private(set) var canonicalProjectionBlockVisitCount: UInt64 = 0
    private(set) var canonicalProjectionSegmentVisitCount: UInt64 = 0
    private(set) var stateContinuityBlockVisitCount: UInt64 = 0
#endif

    /// Build from a restored graph: the snapshot index over the blocks held,
    /// the by-height canonical index, and the anchored frontier seeded once.
    init(
        canonicalTip: String,
        canonicalHashes: Set<String>,
        tipSnapshot: TipBlockSnapshot?,
        snapshots: [String: TipBlockSnapshot],
        validated: Set<String>,
        in blocks: BlockGraph,
        excluded: Set<String>
    ) throws {
        self.canonicalTip = canonicalTip
        self.canonicalHashes = canonicalHashes
        self.tipSnapshot = tipSnapshot
        self.snapshots = snapshots
        if let tipSnapshot {
            self.snapshots[canonicalTip] = tipSnapshot
        }
        self.validated = validated
        self.byTransition = [:]
        self.byPostState = [:]
        for (blockHash, snapshot) in self.snapshots
        where blocks.contains(blockHash) {
            self.byTransition[
                StateTransition(
                    from: snapshot.prevStateCID,
                    to: snapshot.postStateCID
                ),
                default: []
            ].insert(blockHash)
            if snapshot.prevStateCID != snapshot.postStateCID {
                self.byPostState[
                    snapshot.postStateCID,
                    default: []
                ].insert(blockHash)
            }
        }
        self.canonicalHashByHeight = [:]
        for hash in canonicalHashes {
            guard let height = blocks.height(of: hash),
                  self.canonicalHashByHeight[height] == nil else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            self.canonicalHashByHeight[height] = hash
        }
        self.anchored = Self.seedAnchored(
            in: blocks,
            validated: validated,
            excluded: excluded
        )
    }

    /// Blocks reachable from a genesis through an unbroken run of executed
    /// blocks. Computed downward so each block is settled once.
    static func seedAnchored(
        in graph: BlockGraph,
        validated: Set<String>,
        excluded: Set<String>
    ) -> Set<String> {
        var anchored: Set<String> = []
        // Roots keyed on the parent pointer, matching `propagateAnchored` and
        // the weight-index builder: the graph invariant ties it to height 0, and
        // three spellings of one predicate is how they drift apart.
        var pending = graph.records
            .filter { $0.parentBlockHash == nil && validated.contains($0.blockHash) }
            .map(\.blockHash)
        while let hash = pending.popLast() {
            guard graph.contains(hash),
                  validated.contains(hash),
                  !excluded.contains(hash),
                  anchored.insert(hash).inserted else { continue }
            pending.append(contentsOf: graph.children(of: hash))
        }
        return anchored
    }

    // MARK: Queries

    func snapshot(of blockHash: String) -> TipBlockSnapshot? {
        snapshots[blockHash]
    }

    func isAnchored(_ blockHash: String) -> Bool {
        anchored.contains(blockHash)
    }

    /// Whether this chain produced `stateCID` — i.e. some block whose declared
    /// post-state is `stateCID` was executed, and so was every block between it
    /// and the genesis.
    ///
    /// O(1): the equivalent walk grows with chain height, and it is the shape a
    /// child's block 1 asks for every time it anchors.
    /// The executed-from-genesis blocks whose post-state is `stateCID`.
    func anchoredProducers(of stateCID: String) -> [String] {
        (byPostState[stateCID] ?? []).filter { anchored.contains($0) }
    }

    func chainProduced(stateCID: String) -> Bool {
        guard let candidates = byPostState[stateCID] else { return false }
        // The frontier is the one authority: executed from genesis and not
        // under an excluded root. The weight index used to be a second defence
        // here, but it no longer says anything about validity (work weighs,
        // §9.9), so it is not consulted — a vacuous conjunct would only read as
        // a defence it is not.
        return candidates.contains { anchored.contains($0) }
    }

    /// The graph search behind `ChainState.stateContinuityPath`, for
    /// canonical, distinct state CIDs. `mutating` only for its DEBUG visit
    /// counter.
    mutating func continuityPath(
        from: String,
        to: String,
        in graph: BlockGraph
    ) -> [String]? {
        // Only a transition on the executed-from-genesis frontier may be
        // attested: executed, every ancestor executed, and not under an
        // excluded root. The weighed tier records a block's declared
        // post-state without running it, so an unverified claim would
        // otherwise stay attestable forever; and the weight index says nothing
        // about validity any more (work weighs, §9.9), so it is not a gate. A
        // child chain settles cross-chain withdrawals against an attested
        // parent state, so attesting a state the parent never produced lets a
        // forged `receiptState` settle a withdrawal that was never paid.
        let anchored = self.anchored
        func isAttestable(_ blockHash: String) -> Bool {
            anchored.contains(blockHash)
        }
        if let directCandidates = byTransition[
            StateTransition(from: from, to: to)
        ] {
            if let direct = directCandidates.lazy.filter({
                isAttestable($0)
            }).min() {
                return [direct]
            }
        }

        let targetCandidates = byPostState[to] ?? []
        var pending = Array(targetCandidates)
            .filter { isAttestable($0) }
            .sorted(by: >)
        var visited = Set<String>()
        var childTowardTarget: [String: String] = [:]
        while let blockHash = pending.popLast() {
            guard visited.insert(blockHash).inserted,
                  let block = graph[blockHash],
                  let snapshot = snapshots[blockHash] else {
                continue
            }
#if DEBUG
            stateContinuityBlockVisitCount &+= 1
#endif
            if snapshot.prevStateCID == from {
                var path = [blockHash]
                while let child = childTowardTarget[path.last!] {
                    path.append(child)
                }
                return path
            }
            guard let parentHash = block.parentBlockHash,
                  isAttestable(parentHash),
                  let parent = graph[parentHash],
                  let parentSnapshot = snapshots[parentHash],
                  parentSnapshot.postStateCID == snapshot.prevStateCID
            else { continue }
            childTowardTarget[parentHash] = blockHash
            pending.append(parent.blockHash)
        }
        return nil
    }

    // MARK: Execution-fact mutations

    /// Record that a possessed block's transition was executed. Monotone: the
    /// marker is a fact about immutable bytes, so it is never retracted, and a
    /// re-delivered weighed fact must never downgrade it. The caller holds
    /// `blockHash`.
    mutating func markValidated(
        _ blockHash: String,
        in graph: BlockGraph,
        excluded: Set<String>
    ) {
        validated.insert(blockHash)
        propagateAnchored(from: blockHash, in: graph, excluded: excluded)
    }

    /// Extend the executed-from-genesis frontier.
    ///
    /// A block is anchored once it is executed and its parent is anchored (a
    /// genesis anchors itself). Executing one block can therefore also anchor
    /// descendants that were executed earlier out of order, so the frontier is
    /// pushed down until it stops moving. Each block is anchored at most once
    /// for the life of the chain, so the total work is linear overall and the
    /// amortized cost per admission is constant.
    private mutating func propagateAnchored(
        from blockHash: String,
        in graph: BlockGraph,
        excluded: Set<String>
    ) {
        var pending = [blockHash]
        while let hash = pending.popLast() {
            guard let meta = graph[hash],
                  !anchored.contains(hash),
                  validated.contains(hash) else { continue }
            let parentAnchored = meta.parentBlockHash.map {
                anchored.contains($0)
            } ?? true
            // A proven-invalid block extends nothing: its subtree left fork
            // choice, and the states it declared are not states this chain
            // stands behind.
            guard parentAnchored, !excluded.contains(hash) else { continue }
            anchored.insert(hash)
            pending.append(contentsOf: graph.children(of: hash))
        }
    }

    mutating func indexTransition(
        _ snapshot: TipBlockSnapshot,
        blockHash: String
    ) {
        if let previous = snapshots[blockHash],
           previous != snapshot {
            byTransition[
                StateTransition(
                    from: previous.prevStateCID,
                    to: previous.postStateCID
                )
            ]?.remove(blockHash)
            if previous.prevStateCID != previous.postStateCID {
                byPostState[
                    previous.postStateCID
                ]?.remove(blockHash)
            }
        }
        snapshots[blockHash] = snapshot
        byTransition[
            StateTransition(
                from: snapshot.prevStateCID,
                to: snapshot.postStateCID
            ),
            default: []
        ].insert(blockHash)
        if snapshot.prevStateCID != snapshot.postStateCID {
            byPostState[
                snapshot.postStateCID,
                default: []
            ].insert(blockHash)
        }
    }

    // MARK: Selection

    /// Re-read the tip's snapshot after the tip or its snapshot changed.
    mutating func refreshTipSnapshot() {
        tipSnapshot = snapshots[canonicalTip]
    }

    /// A bump that carries no graph mutation keeps the projection exact.
    mutating func noteProjected(at generation: UInt64) {
        projectedGeneration = generation
    }

#if DEBUG
    mutating func resetFullCanonicalProjectionCount() {
        fullCanonicalProjectionCount = 0
    }
#endif

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
    ///
    /// `heightZero` is the by-height index at height 0; the parentless blocks
    /// in it are the roots.
    mutating func project(
        forkChoice: ForkChoice,
        in graph: BlockGraph,
        heightZero: Set<String>,
        generation: UInt64,
        forceFull: Bool = false,
        monotoneIncreaseAt mutatedAt: String? = nil
    ) -> ChainCommit? {
        defer { projectedGeneration = generation }
        // A never-projected state has no trustworthy canonical path to truncate
        // against, and `forceFull` means the caller knows it cannot be trusted.
        if !forceFull, projectedGeneration != nil, let mutatedAt,
           let outcome = truncatedProjection(
               forkChoice: forkChoice,
               in: graph,
               heightZero: heightZero,
               monotoneIncreaseAt: mutatedAt
           ) {
            return outcome.commit
        }

        // Whole-chain fallback. Weights are pure work, so ONE projection path
        // serves the exclusion-free and exclusion-present cases alike;
        // the excluded set is empty in the common case (zero cost) and otherwise
        // only steers the descent past excluded roots — no parallel path.
        let roots = Array(heightZero).filter {
            graph.parent(of: $0) == nil
        }
        guard let root = forkChoice.selectableRoot(among: roots)
        else { return nil }
#if DEBUG
        fullCanonicalProjectionCount += 1
#endif
        let descent = forkChoice.descend(from: root, in: graph)
#if DEBUG
        // Descent steps ARE blocks now: with no quotient there is no hop to
        // take, so this column and the block column converge by construction.
        // The name is kept unchanged so one test measures both sides of the
        // deletion; what it counts is a block step, not a segment step.
        canonicalProjectionSegmentVisitCount += UInt64(descent.blocks.count)
        canonicalProjectionBlockVisitCount += UInt64(descent.blocks.count)
#endif
        let projection = (
            canonicalTip: descent.tipHash,
            canonicalHashes: descent.blocks
        )
        let newHashes = projection.canonicalHashes
        let newTip = projection.canonicalTip
        guard newTip != canonicalTip || newHashes != canonicalHashes else { return nil }

        let removed = canonicalHashes.subtracting(newHashes)
        let added = newHashes.subtracting(canonicalHashes).reduce(
            into: [String: UInt64]()
        ) { result, hash in
            if let height = graph.height(of: hash) { result[hash] = height }
        }

        canonicalTip = newTip
        canonicalHashes = newHashes
        canonicalHashByHeight = [:]
        for hash in newHashes {
            if let height = graph.height(of: hash) {
                canonicalHashByHeight[height] = hash
            }
        }
        tipSnapshot = snapshots[newTip]
        return ChainCommit(
            tipHash: newTip,
            canonicalBlocksAdded: added,
            canonicalBlocksRemoved: removed
        )
    }

    /// Outcome of a mutation-point projection. A nil OUTCOME means truncation's
    /// assumptions could not be verified and the caller must re-materialize from
    /// the root; a nil `commit` inside one means the projection ran and nothing
    /// changed.
    private struct TruncatedProjectionOutcome {
        let commit: ChainCommit?
    }

    /// The deepest canonical block on the ancestor line of `mutatedAt`;
    /// `.otherRoot` when that line ends at a root without meeting the
    /// canonical path (a mutation under a different root), and `.malformed`
    /// at a missing parent or a non-descending height.
    ///
    /// This walk is UNCAPPED deliberately. A step budget here is a cliff, not a
    /// budget: past it the caller falls through to the whole-chain projection,
    /// which pays a spine walk AND a descent from the root before it can
    /// discover that nothing moved. So a cap does not bound the cost of a deep
    /// divergence, it relocates it to O(n) per admission — reintroducing the
    /// quadratic this change exists to remove, on precisely the shape it exists
    /// to make cheap, and skipping the O(1) winner-unchanged check below, which
    /// only runs once a divergence point has been found.
    ///
    /// Uncapped, the walk is bounded by the length of the branch below the
    /// mutated block, which the node has already paid to admit, and every step
    /// is an O(1) set membership test. Termination does not rest on a budget:
    /// each step moves to a strictly lower height, and a parent that does not is
    /// a malformed route that fails closed like every other guard here.
    private func canonicalDivergencePoint(
        from mutatedAt: String,
        in graph: BlockGraph
    ) -> Divergence {
        var current = mutatedAt
        while !canonicalHashes.contains(current) {
            guard let meta = graph[current] else { return .malformed }
            guard let parentHash = meta.parentBlockHash else {
                return meta.blockHeight == 0 ? .otherRoot : .malformed
            }
            guard let parent = graph[parentHash],
                  parent.blockHeight < meta.blockHeight else { return .malformed }
            current = parentHash
        }
        return .canonical(current)
    }

    /// Where the ancestor line of a mutated block meets the canonical path.
    private enum Divergence {
        case canonical(String)
        /// The line ends at a genesis root that is not the canonical one.
        case otherRoot
        case malformed
    }

    /// Re-descend from the divergence point instead of the root. Every guard
    /// here fails closed: the caller re-materializes whole rather than act on a
    /// partial answer.
    private mutating func truncatedProjection(
        forkChoice: ForkChoice,
        in graph: BlockGraph,
        heightZero: Set<String>,
        monotoneIncreaseAt mutatedAt: String
    ) -> TruncatedProjectionOutcome? {
        // A block that never routed into the quotient contributed no work and no
        // fork-choice edge — a routed parent always routes its child, so an
        // unrouted block's parent is unrouted or absent and no routed block's
        // visible children changed either. Nothing can have moved.
        guard forkChoice.isRouted(mutatedAt) else {
            return TruncatedProjectionOutcome(commit: nil)
        }
        // The increase landed inside the subtree that already wins at every one
        // of its ancestors, so every canonical decision is reinforced and none
        // flips. This is the ordinary "stronger observation on a canonical
        // block" event, and it is now O(1) instead of a walk from the root.
        guard !canonicalHashes.contains(mutatedAt) else {
            return TruncatedProjectionOutcome(commit: nil)
        }
        let divergence: String
        switch canonicalDivergencePoint(from: mutatedAt, in: graph) {
        case .canonical(let hash):
            divergence = hash
        case .otherRoot:
            // The increase landed under another genesis root, so nothing in
            // the canonical root's tree moved: if that root still wins among
            // the roots, the whole canonical path stands. O(#roots).
            guard let canonicalRoot = canonicalHashByHeight[0] else { return nil }
            let roots = Array(heightZero).filter { graph.parent(of: $0) == nil }
            guard forkChoice.selectableRoot(among: roots) == canonicalRoot else {
                return nil
            }
#if DEBUG
            truncatedCanonicalProjectionCount += 1
#endif
            return TruncatedProjectionOutcome(commit: nil)
        case .malformed:
            return nil
        }
        guard let divergenceHeight = graph.height(of: divergence) else { return nil }
        let (suffixHeight, overflow) = divergenceHeight.addingReportingOverflow(1)
        guard !overflow else { return nil }
        let excludedRoots = forkChoice.excludedRoots
        let children = excludedRoots.isEmpty
            ? graph.children(of: divergence)
            : graph.children(of: divergence).filter {
                !excludedRoots.contains($0)
            }
        // Every child of the divergence point is unselectable: the mutation
        // landed under an excluded root that is the only child of a canonical
        // block. The descent from the root provably ends at that block, so it
        // already is the tip and nothing moved. Decided in O(1) — this is the
        // steady state right after a canonical exclusion, when miners that have
        // not yet executed the block keep extending it, and it must not cost a
        // whole-chain projection per such block.
        guard !children.isEmpty else { return TruncatedProjectionOutcome(commit: nil) }
        // One GHOST step, taken exactly as the descent takes it: a lone child is
        // followed WITHOUT a weight lookup, matching `ForkChoice.descend`, so a
        // single-child step cannot depend on a weight comparison at all.
        let chosen = children.count == 1
            ? children[0]
            : forkChoice.preferred(among: children)
        guard let chosen else { return nil }
        // The COMMON admission on a merged-mining child is a losing sibling, and
        // it must cost nothing. This point is the deepest canonical ancestor of
        // the mutated block, so the child leading to that block is never the
        // canonical one, and the increase is confined to its subtree. If the
        // winner here is therefore still the block already on the canonical
        // path, no decision changed anywhere — not here, not below it, not above
        // it — and there is nothing to materialize.
        //
        // This is decided in O(1), before reading the path above and before any
        // descent. Without it a losing sibling deep in the chain would
        // re-materialize everything from the fork point to the tip only to
        // conclude nothing moved, which is worse than the whole-chain early-out
        // this change removes.
        if canonicalHashes.contains(chosen) {
#if DEBUG
            truncatedCanonicalProjectionCount += 1
#endif
            return TruncatedProjectionOutcome(commit: nil)
        }
        guard let replaced = canonicalPathAbove(suffixHeight, in: graph) else { return nil }
        // The suffix begins at a block taken straight from the divergence
        // point's own children, so the boundary below it holds by construction
        // rather than by assumption.
        let descent = forkChoice.descend(from: chosen, in: graph)
#if DEBUG
        canonicalProjectionSegmentVisitCount += UInt64(descent.blocks.count)
        canonicalProjectionBlockVisitCount += UInt64(descent.blocks.count)
        truncatedCanonicalProjectionCount += 1
#endif
        return TruncatedProjectionOutcome(commit: applyCanonicalDelta(
            tipHash: descent.tipHash,
            blocks: descent.blocks,
            replacing: replaced,
            in: graph
        ))
    }

    /// The canonical blocks at and above `height`. Returns nil when the
    /// by-height index is not contiguous to the tip, so the caller
    /// re-materializes instead of trusting a partial removal set.
    private func canonicalPathAbove(
        _ height: UInt64,
        in graph: BlockGraph
    ) -> Set<String>? {
        guard let tipHeight = graph.height(of: canonicalTip) else {
            return nil
        }
        var replaced = Set<String>()
        var current = height
        while current <= tipHeight {
            guard let hash = canonicalHashByHeight[current] else { return nil }
            replaced.insert(hash)
            current += 1
        }
        return replaced
    }

    /// Swap the canonical path `replaced` for the freshly materialized suffix.
    /// The prefix below it is unchanged, so membership and the by-height index
    /// are updated in place instead of rebuilt over the whole chain.
    private mutating func applyCanonicalDelta(
        tipHash: String,
        blocks: Set<String>,
        replacing replaced: Set<String>,
        in graph: BlockGraph
    ) -> ChainCommit? {
        // Both differences are unconditional, so they are correct whether or
        // not the replaced and suffix block sets overlap.
        let removed = replaced.subtracting(blocks)
        let added = blocks.subtracting(replaced).reduce(
            into: [String: UInt64]()
        ) { result, hash in
            if let height = graph.height(of: hash) { result[hash] = height }
        }
        guard tipHash != canonicalTip || !removed.isEmpty || !added.isEmpty else {
            return nil
        }

        canonicalTip = tipHash
        canonicalHashes.subtract(removed)
        canonicalHashes.formUnion(added.keys)
        for hash in removed {
            guard let height = graph.height(of: hash),
                  canonicalHashByHeight[height] == hash else { continue }
            canonicalHashByHeight.removeValue(forKey: height)
        }
        for (hash, height) in added {
            canonicalHashByHeight[height] = hash
        }
        tipSnapshot = snapshots[tipHash]
        return ChainCommit(
            tipHash: tipHash,
            canonicalBlocksAdded: added,
            canonicalBlocksRemoved: removed
        )
    }
}

extension ChainTree {
    // Forwarders onto `frontier`, kept so callers and tests read the actor
    // exactly as before.

    public var canonicalTip: String { frontier.canonicalTip }
    var canonicalHashes: Set<String> { frontier.canonicalHashes }
    var canonicalHashByHeight: [UInt64: String] { frontier.canonicalHashByHeight }
    public var tipSnapshot: TipBlockSnapshot? { frontier.tipSnapshot }

#if DEBUG
    var fullCanonicalProjectionCount: UInt64 { frontier.fullCanonicalProjectionCount }
    var truncatedCanonicalProjectionCount: UInt64 { frontier.truncatedCanonicalProjectionCount }
    var canonicalProjectionBlockVisitCount: UInt64 { frontier.canonicalProjectionBlockVisitCount }
    var canonicalProjectionSegmentVisitCount: UInt64 { frontier.canonicalProjectionSegmentVisitCount }
    var stateContinuityBlockVisitCount: UInt64 { frontier.stateContinuityBlockVisitCount }
#endif

    /// Recompute canonical projection after local simulation/test mutation.
    @discardableResult
    public mutating func reevaluateForkChoice() -> ChainCommit? {
        guard hasUnreservedMutationCapacity else { return nil }
        // No graph or weight fact has changed since the projection was last
        // brought current, so re-projection is provably a no-op: a duplicate
        // delivery that added nothing cannot promote anything.
        guard mutationGeneration != frontier.projectedGeneration else { return nil }
        let canonicalChange = projectCanonicalChain()
        guard canonicalChange != nil else { return nil }
        // This bump carries no graph mutation, so the projection just computed
        // stays exact for the new generation.
        mutationGeneration += 1
        frontier.noteProjected(at: mutationGeneration)
        return (canonicalChange ?? ChainCommit(tipHash: canonicalTip))
            .atRevision(mutationGeneration)
    }

    /// One coherent context for transaction preflight: the named block (the
    /// canonical tip when nil) and its snapshot. Keeping the two in one actor
    /// read lets callers reject a result if the tip changes while content is
    /// being resolved. The snapshot is nil unless the block is on the
    /// executed-from-genesis frontier: a weighed block's post-state is a
    /// declared claim, never a state to classify against.
    package func transactionPreflightTip(
        at blockHash: String? = nil
    ) -> (cid: String, snapshot: TipBlockSnapshot?) {
        let cid = blockHash ?? canonicalTip
        guard frontier.isAnchored(cid) else { return (cid, nil) }
        return (cid, frontier.snapshot(of: cid))
    }

    public func isCanonical(hash: String) -> Bool {
        guard let height = graph.height(of: hash) else { return false }
        return canonicalHashByHeight[height] == hash
    }

    public func canonicalBlockHash(atHeight height: UInt64) -> String? {
        canonicalHashByHeight[height]
    }

#if DEBUG
    /// Test-only seam for asserting that a no-reorg update did not materialize
    /// the unchanged unary canonical path.
    mutating func resetFullCanonicalProjectionCount() {
        frontier.resetFullCanonicalProjectionCount()
    }

    /// Read-only whole-chain projection over the LIVE index, with no counter and
    /// no state effects. Differential tests use it to separate a wrong
    /// truncation from a wrong index: a truncated projection must agree with
    /// this at every step, and when it does not, this says which half is at
    /// fault — something comparing only against the reference oracle cannot.
    func debugFullCanonicalProjection() -> (
        canonicalTip: String,
        canonicalHashes: Set<String>
    )? {
        let roots = Array(indexToBlockHash[0] ?? []).filter {
            graph.parent(of: $0) == nil
        }
        guard let root = forkChoice.selectableRoot(among: roots)
        else { return nil }
        let descent = forkChoice.descend(from: root, in: graph)
        return (descent.tipHash, descent.blocks)
    }
#endif

    /// Project the canonical path after one fork-choice mutation; see
    /// `ExecutionFrontier.project`.
    mutating func projectCanonicalChain(
        forceFull: Bool = false,
        monotoneIncreaseAt mutatedAt: String? = nil
    ) -> ChainCommit? {
        frontier.project(
            forkChoice: forkChoice,
            in: graph,
            heightZero: indexToBlockHash[0] ?? [],
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
        frontier.isAnchored(blockHash)
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
        // answers outright. The equivalent walk costs one visit per block of
        // chain height, which is the shape that used to need a budget.
        if from == LatticeState.emptyHeader.rawCID {
            return frontier.chainProduced(stateCID: to)
        }
        return stateContinuityPath(from: from, to: to) != nil
    }

    /// One deterministic accepted-block path proving forward state continuity.
    /// The returned CIDs are hints for acquiring ordinary block Volumes; a
    /// receiver must still validate those blocks before trusting the path.
    public mutating func stateContinuityPath(
        from fromStateCID: String,
        to toStateCID: String
    ) -> [String]? {
        guard let from = CIDIdentity.canonicalString(fromStateCID),
              let to = CIDIdentity.canonicalString(toStateCID) else {
            return nil
        }
        if from == to { return [] }
        return frontier.continuityPath(from: from, to: to, in: graph)
    }

    /// Record that a possessed block's transition was executed.
    mutating func markValidated(blockHash: String) {
        guard graph.contains(blockHash) else { return }
        frontier.markValidated(
            blockHash,
            in: graph,
            excluded: forkChoice.excludedRoots
        )
    }

    /// Whether some OTHER genesis root of this chain is on the executed
    /// frontier — "is there a chain to stand on", the test a producer runs
    /// before it may exclude a root (§9.9).
    package func hasExecutedRoot(besides blockHash: String) -> Bool {
        (indexToBlockHash[0] ?? []).contains {
            $0 != blockHash
                && graph.parent(of: $0) == nil
                && frontier.isAnchored($0)
        }
    }

    mutating func indexStateTransition(
        _ snapshot: TipBlockSnapshot,
        blockHash: String
    ) {
        frontier.indexTransition(snapshot, blockHash: blockHash)
    }
}
