import cashew
import CID
import UInt256
import LatticePrimitives
import LatticePoW

public enum ChainStateRestoreError: Error, Sendable, Equatable {
    case corruptConsensusGraph
    case missingBlockFact
    /// The facts both execute and exclude one block. Execution and exclusion
    /// are never revoked, so the store holds a contradiction.
    case executedVerdictContradiction
    /// A root genesis other than the root chain's configured one.
    case unpinnedRootGenesis
}

// MARK: - Concrete Types

public struct BlockMeta: Sendable {
    public let blockHash: String
    public let parentBlockHash: String?
    public let blockHeight: UInt64
    /// Inherited from the parent, or self at height 1. Absent on genesis, which
    /// precedes the anchor and has no schedule to be measured against.
    ///
    /// Derived, like `cumulativeWork` and `subtreeWeight` beside it: a pure
    /// function of this block's ancestry, rebuildable by walking to height 1.
    /// Carried rather than walked only so reaching it is O(1) instead of O(chain).
    public let difficultyAnchor: DifficultyAnchor?
    public let work: WorkSum
    public var childHashes: [String]
    public let workContributions: [String: VerifiedWorkContribution]
    /// The contribution IDs here that are a parent's attributed runs (§9.10),
    /// not grinds. A child's derivation subtracts the committer's GRINDS —
    /// what the child already holds — so a run attributed AT the committer
    /// stays in its run and reaches the next level down. Derived, in memory.
    public let attributedRuns: Set<String>
    /// Directory → child block CID this block commits, read from its PoW-bound
    /// `children` index at admission and carried on the durable block fact, so
    /// live admission and replay see the same commitments (§9.10).
    public let childCommitments: [String: String]

    /// Backward cumulative proof-of-work prefix measure from genesis through
    /// this block. Each physical grind has one block location in this chain.
    ///
    /// This is a derived diagnostic, rebuilt on demand from durable block work
    /// facts after recovery. It is never a fork-choice input or persisted
    /// source of truth.
    public let cumulativeWork: WorkSum

    /// The forward same-chain subtree measure, deduplicated by physical grind.
    /// This derived diagnostic is rebuilt on demand from accepted work facts.
    public let subtreeWeight: WorkSum

    package init(
        blockHash: String,
        parentBlockHash: String?,
        blockHeight: UInt64,
        childHashes: [String],
        workContributions: [VerifiedWorkContribution],
        cumulativeWork: WorkSum = .zero,
        subtreeWeight: WorkSum? = nil,
        difficultyAnchor: DifficultyAnchor? = nil,
        childCommitments: [String: String] = [:]
    ) {
        let contributions = Dictionary(
            workContributions.map { ($0.id, $0) },
            uniquingKeysWith: { first, second in
                first.work >= second.work ? first : second
            }
        )
        let work = WorkMeasure(contributions.values).total
        self.blockHash = blockHash
        self.parentBlockHash = parentBlockHash
        self.blockHeight = blockHeight
        self.work = work
        self.childHashes = childHashes
        self.workContributions = contributions
        self.cumulativeWork = cumulativeWork
        self.subtreeWeight = subtreeWeight ?? work
        self.difficultyAnchor = difficultyAnchor
        self.childCommitments = childCommitments
        // Attributed runs are derived after the block (`applyParentRun`); a
        // block is built with its grinds alone.
        self.attributedRuns = []
    }

    /// The read view of one block the graph holds, assembled from its tables.
    init(
        record: BlockRecord,
        childHashes: [String],
        work: BlockWork,
        difficultyAnchor: DifficultyAnchor?,
        diagnostics: BlockDiagnostics
    ) {
        self.blockHash = record.blockHash
        self.parentBlockHash = record.parentBlockHash
        self.blockHeight = record.blockHeight
        self.childCommitments = record.childCommitments
        self.childHashes = childHashes
        self.workContributions = work.contributions
        self.attributedRuns = work.attributedRuns
        self.work = work.work
        self.difficultyAnchor = difficultyAnchor
        self.cumulativeWork = diagnostics.cumulativeWork
        self.subtreeWeight = diagnostics.subtreeWeight
    }
}

public struct SubmissionResult: Sendable {
    public let addedBlock: Bool
    public let addedContribution: Bool
    public let extendsCanonical: Bool
    public let commit: ChainCommit?
    /// Every block whose credited work this mutation added or raised, plus
    /// every block it CONNECTED: a block inserted under a connected parent
    /// connects with the whole orphan component it grafts. What a run
    /// (§9.10) can have moved by, reported by the code that moved it.
    public let weighed: [String]

    init(
        addedBlock: Bool,
        addedContribution: Bool = false,
        extendsCanonical: Bool,
        commit: ChainCommit? = nil,
        weighed: [String] = []
    ) {
        self.addedBlock = addedBlock
        self.addedContribution = addedContribution
        self.extendsCanonical = extendsCanonical
        self.commit = commit
        self.weighed = weighed
    }

    public static func discarded() -> Self {
        SubmissionResult(
            addedBlock: false,
            addedContribution: false,
            extendsCanonical: false
        )
    }
}

public struct ChainCommit: Sendable, Equatable {
    public let revision: UInt64
    public let tipHash: String
    public let canonicalBlocksAdded: [String: UInt64]
    public let canonicalBlocksRemoved: Set<String>

    public init(
        revision: UInt64 = 0,
        tipHash: String,
        canonicalBlocksAdded: [String: UInt64] = [:],
        canonicalBlocksRemoved: Set<String> = []
    ) {
        self.revision = revision
        self.tipHash = tipHash
        self.canonicalBlocksAdded = canonicalBlocksAdded
        self.canonicalBlocksRemoved = canonicalBlocksRemoved
    }

    public var canonicalChanged: Bool {
        !canonicalBlocksAdded.isEmpty || !canonicalBlocksRemoved.isEmpty
    }

    func atRevision(_ revision: UInt64) -> ChainCommit {
        ChainCommit(
            revision: revision,
            tipHash: tipHash,
            canonicalBlocksAdded: canonicalBlocksAdded,
            canonicalBlocksRemoved: canonicalBlocksRemoved
        )
    }
}

// MARK: - ChainState

public struct TipBlockSnapshot: Sendable, Equatable {
    public let postStateCID: String
    public let prevStateCID: String
    public let specCID: String
    public let target: UInt256
    public let nextTarget: UInt256
    public let tipHeight: UInt64
    public let timestamp: Int64

    public init(postStateCID: String, prevStateCID: String, specCID: String, target: UInt256, nextTarget: UInt256, tipHeight: UInt64, timestamp: Int64) {
        self.postStateCID = postStateCID
        self.prevStateCID = prevStateCID
        self.specCID = specCID
        self.target = target
        self.nextTarget = nextTarget
        self.tipHeight = tipHeight
        self.timestamp = timestamp
    }
}

/// The graph fields Lattice needs after admission has already authenticated a
/// block. This deliberately excludes the block body and node-owned state data.
private struct ConsensusBlockInput: Sendable {
    let blockHash: String
    let parentBlockHash: String?
    let blockHeight: UInt64
    let timestamp: Int64
    let snapshot: TipBlockSnapshot
    let childCommitments: [String: String]

    /// Requires an EXECUTED block.
    init(blockHeader: BlockHeader, block: Block) {
        blockHash = blockHeader.rawCID
        parentBlockHash = block.parent?.rawCID
        blockHeight = block.height
        timestamp = block.timestamp
        // Not enumerated on this test-only path: it records no commitments.
        childCommitments = [:]
        snapshot = TipBlockSnapshot(
            postStateCID: block.postState.rawCID,
            prevStateCID: block.prevState.rawCID,
            specCID: block.spec.rawCID,
            target: block.target,
            nextTarget: block.nextTarget,
            tipHeight: block.height,
            timestamp: block.timestamp
        )
    }

    init?(fact: ChainBlockFact) {
        guard let blockHash = CIDIdentity.canonicalString(fact.blockHash),
              let postStateCID = CIDIdentity.canonicalString(fact.postStateCID),
              let prevStateCID = CIDIdentity.canonicalString(fact.prevStateCID),
              let specCID = CIDIdentity.canonicalString(fact.specCID),
              let target = UInt256.fromHexDigits(fact.target),
              let nextTarget = UInt256.fromHexDigits(fact.nextTarget),
              // Every block, genesis included, commits a positive target and
              // nextTarget: a genesis's target is block 1's schedule input
              // (§5.1 rule 5), and a zero target is not admissible.
              target > .zero, nextTarget > .zero,
              (fact.parentBlockHash == nil) == (fact.blockHeight == 0) else {
            return nil
        }
        let normalizedParent = fact.parentBlockHash.flatMap(CIDIdentity.canonicalString)
        guard fact.parentBlockHash == nil || normalizedParent != nil else { return nil }
        self.blockHash = blockHash
        parentBlockHash = normalizedParent
        blockHeight = fact.blockHeight
        timestamp = fact.timestamp
        childCommitments = fact.childCommitments ?? [:]
        snapshot = TipBlockSnapshot(
            postStateCID: postStateCID,
            prevStateCID: prevStateCID,
            specCID: specCID,
            target: target,
            nextTarget: nextTarget,
            tipHeight: fact.blockHeight,
            timestamp: fact.timestamp
        )
    }
}

/// A node-durable admission batch after Lattice has authenticated it. Recovery
/// may replay this value, but must never use it as wire evidence.
private struct TrustedImportBatch {
    let block: ConsensusBlockInput?
    let workBlockHash: String
    let contribution: VerifiedWorkContribution

    init?(_ batch: BlockImportBatch) {
        guard !batch.facts.isEmpty,
              Set(batch.facts.map(\.id)).count == batch.facts.count else {
            return nil
        }
        let blockFacts = batch.facts.compactMap { fact -> ChainBlockFact? in
            guard case .block(let value) = fact else { return nil }
            return value
        }
        let workFacts = batch.facts.compactMap { fact -> ChainWorkFact? in
            guard case .work(let value) = fact else { return nil }
            return value
        }
        // Every block, genesis included, carries positive work: a root block
        // its own grind, a child block (its genesis too) a verified proof.
        guard workFacts.count == 1,
              let work = workFacts.first,
              work.contribution.work > .zero,
              let workBlockHash = CIDIdentity.canonicalString(work.blockHash),
              let contributionID = CIDIdentity.canonicalString(work.contribution.id) else {
            return nil
        }
        let contribution = VerifiedWorkContribution(
            id: contributionID,
            work: work.contribution.work
        )
        // The eager tier weighs and validates in one gate, so its batch may
        // carry one validation fact alongside the block and work. It must name
        // the batch's own block: a batch is one block's durability unit, and
        // admitting a validation for anything else would let one block's
        // admission silently mark another executed.
        let validationFacts = batch.facts.compactMap { fact -> ChainValidationFact? in
            guard case .validation(let value) = fact else { return nil }
            return value
        }
        guard validationFacts.count <= 1,
              validationFacts.allSatisfy({
                  CIDIdentity.canonicalString($0.blockHash) == workBlockHash
              }) else {
            return nil
        }
        let extra = validationFacts.count

        switch blockFacts.count {
        case 0:
            guard batch.facts.count == 1 + extra else { return nil }
            block = nil
        case 1:
            guard batch.facts.count == 2 + extra,
                  let input = ConsensusBlockInput(fact: blockFacts[0]),
                  workBlockHash == input.blockHash else {
                return nil
            }
            block = input
        default:
            return nil
        }
        self.workBlockHash = workBlockHash
        self.contribution = contribution
    }
}

/// One chain's block tree as a synchronous value: the weighed graph
/// (`BlockGraph`), GHOST weights and excluded roots (`ForkChoice`), the
/// canonical projection and executed set (`ExecutionFrontier`), and parent
/// run attribution (`RunAttribution`).
///
/// Every consensus mutation of a chain is a method on this value; the
/// `ChainState` actor only wraps one, so there is one implementation. The
/// four fact kinds are its durable form: `replay` rebuilds it from them, and
/// the admission operations (`insertHeader`, `addWork`, `applyConnect`) emit
/// exactly the facts they apply.
public struct ChainTree: Sendable {
    /// The chain this tree is, fixed when the tree is made: its path decides
    /// whether work is a root grind or a child proof and which parent facts
    /// its blocks need. Nil for a tree made without one (the actor path,
    /// which carries its context on `ChainLevel`).
    public private(set) var context: ChainRuntimeContext?
    /// The specs of this chain's genesis roots, keyed by spec CID: each bound
    /// by CID to the genesis that names it when that genesis is inserted.
    /// Header admission computes a block's target schedule from its ROOT's
    /// spec (`scheduleSpec(underParent:)`). Empty for a tree made without
    /// one, which admits no header.
    public private(set) var specs: [String: ChainSpec] = [:]
    /// Blocks whose declared spec CID is not their root's, mapped to their
    /// root's spec CID. Only a block weighed under a `spec != parent.spec`
    /// exclusion, or a descendant of one, lands here, so the map stays as
    /// small as those subtrees and every other block reads its root's spec
    /// from its own snapshot in O(1).
    private var offRootSpecCID: [String: String] = [:]
    var indexToBlockHash: [UInt64: Set<String>]
    /// The block tree: records, child edges, work facts, anchors and the
    /// diagnostic totals (BlockGraph.swift).
    var graph: BlockGraph
    /// GHOST weights, grind locations and excluded roots (ForkChoice.swift).
    var forkChoice: ForkChoice
    /// The canonical projection, the executed-from-genesis frontier and the
    /// state-transition index (ExecutionFrontier.swift).
    var frontier: ExecutionFrontier
    /// Parent-attributed run work (§9.10) for the served child directories
    /// (RunAttribution.swift).
    var runs: RunAttribution
    /// Diagnostic prefix/subtree totals are derived local views. They are not
    /// fork-choice inputs and are rebuilt only when an API exposes them.
    var localWorkCachesDirty: Bool
#if DEBUG
    /// Blocks visited by every rebuild of the diagnostic totals so far.
    var localWorkCacheBlockVisitCount: UInt64 = 0
#endif

    /// Restore-replay defers the derived canonical projection: batches are
    /// durable, already-admitted facts, their commits are discarded, and no
    /// replay step reads the projection — so it is computed exactly once at
    /// the end of replay instead of per event.
    var deferProjectionForReplay = false
    /// Advances for every successful consensus mutation.
    var mutationGeneration: UInt64
    /// Capacity held across the node's asynchronous stage boundary. These
    /// reservations are fungible and disappear on restart; staged facts replay
    /// against the same pre-stage revision floor.
    var reservedImportRevisions: UInt64

    // Restore validates this invariant; optional access keeps query paths fail-closed.
    var highestBlockHeight: UInt64 { graph.height(of: canonicalTip) ?? 0 }

    /// Every held block's public read view, keyed by hash. Test-facing and
    /// O(N) — assembled on read; production reads `graph`.
    var hashToBlock: [String: BlockMeta] { graph.metas }

    package init(
        canonicalTip: String,
        canonicalHashes: Set<String>,
        indexToBlockHash: [UInt64: Set<String>],
        hashToBlock: [String: BlockMeta],
        tipSnapshot: TipBlockSnapshot? = nil,
        tipSnapshotsByHash: [String: TipBlockSnapshot] = [:],
        validatedBlocks: Set<String> = [],
        mutationGeneration: UInt64 = 0
    ) throws {
        // Every graph read keys a block by its own hash, so a map entry filed
        // under any other key is a corrupt graph, not a second name.
        guard hashToBlock.allSatisfy({ $0.key == $0.value.blockHash }),
              hashToBlock.values.allSatisfy({ meta in
            guard Set(meta.childHashes).count == meta.childHashes.count,
                  (meta.parentBlockHash == nil) == (meta.blockHeight == 0)
            else { return false }

            for childHash in meta.childHashes {
                guard let child = hashToBlock[childHash],
                      child.parentBlockHash == meta.blockHash else { return false }
                let (expectedHeight, overflow) = meta.blockHeight.addingReportingOverflow(1)
                guard !overflow, child.blockHeight == expectedHeight else { return false }
            }

            guard let parentHash = meta.parentBlockHash,
                  let parent = hashToBlock[parentHash] else { return true }
            let (expectedHeight, overflow) = parent.blockHeight.addingReportingOverflow(1)
            return !overflow
                && meta.blockHeight == expectedHeight
                && parent.childHashes.contains(meta.blockHash)
        }) else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        self.context = nil
        self.graph = BlockGraph(hashToBlock)
        self.forkChoice = ForkChoice()
        self.localWorkCachesDirty = true
        var allByHeight = indexToBlockHash
        for meta in hashToBlock.values {
            allByHeight[meta.blockHeight, default: []].insert(meta.blockHash)
        }
        self.indexToBlockHash = allByHeight
        self.mutationGeneration = mutationGeneration
        self.reservedImportRevisions = 0
        for meta in hashToBlock.values {
            let contributions = meta.workContributions.values
            // Every block, genesis included, carries positive work.
            guard !contributions.isEmpty else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            guard contributions.allSatisfy({ $0.work > .zero }) else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
        }
        guard Self.hasUniqueWorkLocations(in: self.graph) else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        self.forkChoice = ForkChoice.build(from: self.graph)
        // Seed the executed-from-genesis frontier. Replay hands validations to
        // `markValidated` one at a time, but a graph restored wholesale needs
        // it computed once, downward from every genesis it holds.
        self.frontier = try ExecutionFrontier(
            canonicalTip: canonicalTip,
            canonicalHashes: canonicalHashes,
            tipSnapshot: tipSnapshot,
            snapshots: tipSnapshotsByHash,
            validated: validatedBlocks,
            in: self.graph,
            excluded: self.forkChoice.excludedRoots
        )
        // Runs (§9.10) are settled by `serveRuns(for:)`, one directory at a
        // time, through the same per-block step live admission uses — one
        // algorithm, not a rebuild twin. Connectivity IS the weight index:
        // every connected block routes, excluded or not (§9.9).
        self.runs = RunAttribution()
    }

    /// A tree made without a chain: it admits no header and executes nothing.
    package static func fromGenesis(block: Block) -> ChainTree {
        let blockHeader = try! BlockHeader(node: block)
        return fromVerifiedGenesis(
            block: block,
            contribution: VerifiedWorkContribution(
                id: blockHeader.rawCID,
                work: workForTarget(block.target)
            )
        )
    }

    /// A tree on `context`, holding the genesis's own `spec`: a mismatched
    /// spec fails, so a chain never runs deaf to its headers.
    package static func fromGenesis(
        block: Block,
        context: ChainRuntimeContext,
        spec: ChainSpec
    ) throws -> ChainTree {
        guard binds(spec, to: block.spec.rawCID) else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        var tree = fromGenesis(block: block)
        tree.context = context
        tree.specs[block.spec.rawCID] = spec
        return tree
    }

    /// A tree on `context` holding no block yet: `insertGenesis` adds its
    /// first root. Until then it has no canonical tip (`canonicalTip` is
    /// empty) and admits no header.
    public static func empty(context: ChainRuntimeContext) -> ChainTree {
        // An empty graph satisfies every invariant the initializer checks.
        var tree = try! ChainTree(
            canonicalTip: "",
            canonicalHashes: [],
            indexToBlockHash: [:],
            hashToBlock: [:]
        )
        tree.context = context
        return tree
    }

    /// Whether `spec` is the one `specCID` names.
    package static func binds(_ spec: ChainSpec, to specCID: String) -> Bool {
        (try? VolumeImpl<ChainSpec>(node: spec).rawCID) == specCID
    }

    /// The spec whose schedule a child of `parentHash` is measured against:
    /// its root's. Nil when the parent is not held or its root's spec is not.
    package func scheduleSpec(underParent parentHash: String) -> ChainSpec? {
        rootSpecCID(of: parentHash).flatMap { specs[$0] }
    }

    /// The spec CID of `blockHash`'s root: its own declared spec unless it
    /// sits under a spec mismatch (`offRootSpecCID`).
    private func rootSpecCID(of blockHash: String) -> String? {
        offRootSpecCID[blockHash] ?? frontier.snapshot(of: blockHash)?.specCID
    }

    /// Derive `offRootSpecCID` for a grafted component: its blocks arrived
    /// before this one, with no root to read a spec from. O(component), the
    /// graft's own cost.
    private mutating func settleRootSpecs(below rootHash: String) {
        var pending = [rootHash]
        while let hash = pending.popLast() {
            guard let rootSpec = rootSpecCID(of: hash) else { continue }
            for child in graph.children(of: hash) {
                if frontier.snapshot(of: child)?.specCID == rootSpec {
                    offRootSpecCID.removeValue(forKey: child)
                } else {
                    offRootSpecCID[child] = rootSpec
                }
                pending.append(child)
            }
        }
    }

    /// Hold `spec` as the spec of a root that names it. False when it is not
    /// the spec `specCID` names.
    package mutating func holdSpec(_ spec: ChainSpec, for specCID: String) -> Bool {
        guard Self.binds(spec, to: specCID) else { return false }
        specs[specCID] = spec
        return true
    }

    package static func fromVerifiedGenesis(
        block: Block,
        contribution: VerifiedWorkContribution
    ) -> ChainTree {
        // Known-valid local node; CID computation cannot fail (no Float/Double fields).
        let blockHash = try! BlockHeader(node: block).rawCID
        let meta = BlockMeta(
            blockHash: blockHash,
            parentBlockHash: nil,
            blockHeight: 0,
            childHashes: [],
            workContributions: [contribution],
            cumulativeWork: WorkSum(contribution.work)
        )
        return try! ChainTree(
            canonicalTip: blockHash,
            canonicalHashes: Set([blockHash]),
            indexToBlockHash: [0: Set([blockHash])],
            hashToBlock: [blockHash: meta],
            tipSnapshot: Self.snapshot(for: block),
            validatedBlocks: [blockHash]
        )
    }

    /// Rebuild a tree from its durable facts, in any order. Every root is
    /// inserted by its own genesis fact and is executed only if a validation
    /// fact says so. On a root chain (`context.genesisCID`) any other root is
    /// refused. The tree holds every spec in `specs` by its CID; a root whose
    /// spec is missing only refuses the headers beneath it. The durable
    /// revision is a final lower bound, applied after replay so restarts do
    /// not create revisions. `context` is required: on a root chain it
    /// carries the pin restore enforces.
    ///
    /// The facts are observations only: attributed runs (§9.10) are derived,
    /// never stored. A child chain passes its already-restored `parent` —
    /// parent levels first, serving this chain's directory — and its runs
    /// are re-derived (`applyParentRun`) before the one canonical projection.
    public static func restore(
        replaying batches: [BlockImportBatch],
        revisionFloor: UInt64 = 0,
        context: ChainRuntimeContext,
        specs: [ChainSpec] = [],
        parent: ChainTree? = nil
    ) throws -> ChainTree {
        try restoring(
            batches, revisionFloor: revisionFloor, context: context, specs: specs, parent: parent
        )
    }

    /// A tree with no chain context — tests and the superseded actor path's
    /// internals only; it pins nothing.
    package static func restoreWithoutContext(
        replaying batches: [BlockImportBatch],
        revisionFloor: UInt64 = 0,
        specs: [ChainSpec] = []
    ) throws -> ChainTree {
        try restoring(batches, revisionFloor: revisionFloor, context: nil, specs: specs, parent: nil)
    }

    private static func restoring(
        _ batches: [BlockImportBatch],
        revisionFloor: UInt64,
        context: ChainRuntimeContext?,
        specs: [ChainSpec],
        parent: ChainTree?
    ) throws -> ChainTree {
        guard batches.contains(where: decodesAsGenesis) else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        var chain = try ChainTree(
            canonicalTip: "",
            canonicalHashes: [],
            indexToBlockHash: [:],
            hashToBlock: [:]
        )
        // The node may enumerate its durable facts in any order. The
        // projection is a derived cache and no replay step reads it, so it
        // is deferred across the whole replay and computed exactly once —
        // replay is O(batches), not O(batches × chain length).
        // The context is set first so the reducer's pin check (`applyStaged`)
        // covers every replayed root.
        chain.context = context
        chain.beginReplayProjectionDeferral()
        try replay(batches[...], onto: &chain)
        if let parent, let directory = context?.path.last, context?.isRoot == false {
            chain.applyParentRun(from: parent, directory: directory)
        }
        chain.completeReplayProjectionDeferral()
        chain.sealRecovery(revisionFloor: revisionFloor)
        for spec in specs {
            guard let cid = try? VolumeImpl<ChainSpec>(node: spec).rawCID else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            chain.specs[cid] = spec
        }
        return chain
    }

    /// Whether `batch` is an authenticated batch carrying a genesis block.
    package static func decodesAsGenesis(_ batch: BlockImportBatch) -> Bool {
        guard let block = TrustedImportBatch(batch)?.block else { return false }
        return block.parentBlockHash == nil && block.blockHeight == 0
    }

    private mutating func sealRecovery(revisionFloor: UInt64) {
        mutationGeneration = max(mutationGeneration, revisionFloor)
    }

    private mutating func beginReplayProjectionDeferral() {
        deferProjectionForReplay = true
    }

    /// End of restore-replay: compute the deferred canonical projection once.
    /// `forceFull` because replay deliberately maintains no projection to
    /// truncate against — there is no trustworthy canonical path until this
    /// runs.
    private mutating func completeReplayProjectionDeferral() {
        deferProjectionForReplay = false
        _ = projectCanonicalChain(forceFull: true)
        frontier.refreshTipSnapshot()
    }

    private static func replay(
        _ batches: ArraySlice<BlockImportBatch>,
        onto chain: inout ChainTree
    ) throws {
        // Sort keys are derived from immutable batch content, so authenticate
        // each batch ONCE and sort ONCE: the old per-comparison
        // `TrustedImportBatch` construction re-decoded both operands' block
        // facts on every comparison, making a cold-start restore
        // O(N log N x decode) per round — hours of CPU on a long chain. A
        // sorted array's deferred subsequence keeps its relative order, so
        // later rounds never need re-sorting either. The authenticated key is
        // handed to the reducer too, so no batch is authenticated twice.
        var pending = batches.map(ReplayEntry.init)
        pending.sort { replayPrecedes($0, $1) }
        while !pending.isEmpty {
            var deferred: [ReplayEntry] = []
            var completed = false
            for entry in pending {
                do {
                    _ = try chain.applyStaged(entry.batch, authenticated: entry.key)
                    completed = true
                } catch ChainStateRestoreError.missingBlockFact {
                    deferred.append(entry)
                }
            }
            guard completed else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            pending = deferred
        }
    }

    /// A strict weak ordering over EVERY batch, fact-only ones included: block
    /// batches by height, then work-only batches, then exclusions and
    /// validations by their target. A batch with no key must still compare
    /// consistently — a key that compared "equal" to everything would let the
    /// sort leave it wherever enumeration put it.
    private static func replayPrecedes(_ left: ReplayEntry, _ right: ReplayEntry) -> Bool {
        switch (left.key, right.key) {
        case let (leftKey?, rightKey?):
            return replayPrecedes(leftKey, rightKey)
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            let l = left.factTarget, r = right.factTarget
            return l.0 != r.0 ? l.0 < r.0 : l.1 < r.1
        }
    }

    /// A batch with its sort keys, derived once: comparisons must not
    /// re-canonicalize CIDs, which dominates an O(N log N) sort.
    private struct ReplayEntry {
        let batch: BlockImportBatch
        let key: TrustedImportBatch?
        /// The order of a batch with no key. Validations before exclusions: a
        /// root exclusion waits on the other root's validation, so this order
        /// settles it in the same round.
        let factTarget: (String, String)

        init(_ batch: BlockImportBatch) {
            self.batch = batch
            key = TrustedImportBatch(batch)
            factTarget = ChainTree.exclusionTarget(of: batch).map { ("x", $0) }
                ?? ChainTree.validationTarget(of: batch).map { ("v", $0) } ?? ("z", "")
        }
    }

    private static func replayPrecedes(
        _ left: TrustedImportBatch,
        _ right: TrustedImportBatch
    ) -> Bool {
        switch (left.block, right.block) {
        case let (leftBlock?, rightBlock?)
        where leftBlock.blockHeight != rightBlock.blockHeight:
            return leftBlock.blockHeight < rightBlock.blockHeight
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        if left.contribution.work != right.contribution.work {
            return left.contribution.work < right.contribution.work
        }
        if left.workBlockHash != right.workBlockHash {
            return left.workBlockHash < right.workBlockHash
        }
        return left.contribution.id < right.contribution.id
    }

    private static func snapshot(for block: Block) -> TipBlockSnapshot {
        TipBlockSnapshot(
            postStateCID: block.postState.rawCID,
            prevStateCID: block.prevState.rawCID,
            specCID: block.spec.rawCID,
            target: block.target,
            nextTarget: block.nextTarget,
            tipHeight: block.height,
            timestamp: block.timestamp
        )
    }

    // MARK: - Queries

    public func contains(blockHash: String) -> Bool {
        graph.contains(blockHash)
    }

    public func currentRevision() -> UInt64 {
        mutationGeneration
    }

    /// Same-chain acquisition needs are every unresolved immediate edge:
    /// absent predecessors and accepted-but-unconnected predecessors alike.
    /// Height order makes this linear after the deterministic sort, rather
    /// than walking the same orphan suffix once per descendant.
    public func unresolvedSameChainPredecessors() -> [SameChainPredecessorRequirement] {
        let ordered = graph.records.sorted {
            if $0.blockHeight != $1.blockHeight {
                return $0.blockHeight < $1.blockHeight
            }
            return $0.blockHash < $1.blockHash
        }
        var connected = Set<String>()
        connected.reserveCapacity(ordered.count)
        for block in ordered {
            let key = block.blockHash
            guard let predecessor = block.parentBlockHash else {
                if block.blockHeight == 0 {
                    connected.insert(key)
                }
                continue
            }
            guard let parent = graph[predecessor] else { continue }
            let (expectedHeight, overflow) = parent.blockHeight
                .addingReportingOverflow(1)
            if !overflow,
               expectedHeight == block.blockHeight,
               connected.contains(predecessor)
            {
                connected.insert(key)
            }
        }
        return graph.records.compactMap { block in
            guard let predecessor = block.parentBlockHash,
                  !connected.contains(predecessor) else { return nil }
            return SameChainPredecessorRequirement(
                descendantCID: block.blockHash,
                predecessorCID: predecessor
            )
        }.sorted {
            if $0.descendantCID != $1.descendantCID {
                return $0.descendantCID < $1.descendantCID
            }
            return $0.predecessorCID < $1.predecessorCID
        }
    }

    package func sameChainPredecessorRequirement(
        for descendantCID: String
    ) -> SameChainPredecessorRequirement? {
        graph[descendantCID].flatMap(sameChainPredecessorRequirement(for:))
    }

    private func sameChainPredecessorRequirement(
        for block: BlockRecord
    ) -> SameChainPredecessorRequirement? {
        guard let parent = block.parentBlockHash,
              !hasConnectedAncestry(blockHash: parent) else { return nil }
        return SameChainPredecessorRequirement(
            descendantCID: block.blockHash,
            predecessorCID: parent
        )
    }

    /// The public read view of one block, with its diagnostic totals: after any
    /// block or work mutation this rebuilds them over the whole tree. To ask
    /// only whether a grind is credited, use `workContribution(id:at:)`.
    public mutating func getConsensusBlock(hash: String) -> BlockMeta? {
        guard graph.contains(hash) else { return nil }
        materializeLocalWorkCachesIfNeeded()
        return graph.meta(of: hash)
    }

    public func getHighestBlockHeight() -> UInt64 {
        highestBlockHeight
    }

#if DEBUG
    /// Test-only view of the excluded roots so a differential test can drive
    /// the reference oracle with the same unselectable set.
    var excludedRootsForTesting: Set<String> {
        forkChoice.excludedRoots
    }
#endif

    /// The difficulty anchor for a block, filling any gap and caching the
    /// result along the way.
    ///
    /// Admission normally inherits the anchor from the parent, which is O(1).
    /// A block can arrive before its parent though, and it has no anchor to
    /// inherit at that moment — so rather than leave a hole its descendants
    /// would inherit, this walks up to the nearest ancestor that does have one
    /// and writes it back down the path it walked. Height 1 always has an
    /// anchor from its own admission, so the walk always terminates.
    ///
    /// The result is a pure function of the block's ancestry either way; the
    /// cache only decides how much of that ancestry has to be re-read.
    public mutating func difficultyAnchor(forBlockHash hash: String) -> DifficultyAnchor? {
        var unresolved: [String] = []
        var current: String? = hash
        var resolved: DifficultyAnchor?
        while let step = current, let meta = graph[step] {
            if let anchor = graph.difficultyAnchor(of: step) {
                resolved = anchor
                break
            }
            unresolved.append(step)
            guard meta.blockHeight > 1 else { break }
            current = meta.parentBlockHash
        }
        guard let anchor = resolved else { return nil }
        for step in unresolved {
            graph.adoptDifficultyAnchor(anchor, at: step)
        }
        return anchor
    }

    // MARK: - Block Submission

    mutating func submitBlock(
        blockHeader: BlockHeader,
        block: Block,
        contribution: VerifiedWorkContribution
    ) -> SubmissionResult {
        submitBlock(
            input: ConsensusBlockInput(blockHeader: blockHeader, block: block),
            contribution: contribution
        )
    }

    private mutating func submitBlock(
        input: ConsensusBlockInput,
        contribution: VerifiedWorkContribution
    ) -> SubmissionResult {
        let blockHash = input.blockHash
        let isRoot = input.parentBlockHash == nil
        let oldTip = canonicalTip

        if contribution.work == .zero || (isRoot && input.blockHeight != 0) {
            return .discarded()
        }

        guard forkChoice.acceptsLocation(of: contribution.id, at: blockHash) else {
            return .discarded()
        }

        if graph.contains(blockHash) {
            return addWorkContribution(contribution, to: blockHash)
        }

        guard hasUnreservedMutationCapacity else { return .discarded() }
        let graftsExistingComponent = connectsExistingSubtree(input)

        let result = insertBlock(
            input: input,
            contributions: [contribution],
            addedContribution: true,
            graftsExistingComponent: graftsExistingComponent
        )
        if !result.addedBlock { return result }
        mutationGeneration += 1

        let canonicalChange: ChainCommit?
        if deferProjectionForReplay {
            canonicalChange = nil
        } else {
            // A validated insert either adds one leaf or grafts one component
            // rooted at this block, and every block carries strictly positive
            // work: a positive increase confined to one point of the graph.
            // The canonical tip append is not a special case any more — it is
            // the cheapest instance of this one, a descent of a single step.
            canonicalChange = projectCanonicalChain(monotoneIncreaseAt: blockHash)
        }
        let extendsCanonical = input.parentBlockHash == oldTip
            && canonicalHashes.contains(blockHash)
        return SubmissionResult(
            addedBlock: true,
            addedContribution: result.addedContribution,
            extendsCanonical: extendsCanonical,
            commit: (canonicalChange ?? ChainCommit(tipHash: canonicalTip))
                .atRevision(mutationGeneration),
            weighed: result.weighed
        )
    }

    // MARK: - Insert

    private mutating func insertBlock(
        input: ConsensusBlockInput,
        contributions: [VerifiedWorkContribution],
        addedContribution: Bool,
        graftsExistingComponent: Bool
    ) -> SubmissionResult {
        let blockHash = input.blockHash
        // Every block, genesis included, carries positive work.
        guard !contributions.isEmpty,
              Set(contributions.map(\.id)).count == contributions.count,
              contributions.allSatisfy({ $0.work > .zero }),
              !(input.parentBlockHash == nil && input.blockHeight != 0)
        else {
            return .discarded()
        }
        addToBlockIndex(hash: blockHash, blockHeight: input.blockHeight)

        let childHashes = findChildren(hash: blockHash, blockHeight: input.blockHeight)
        // Height 1 is its own anchor; everything above inherits its parent's.
        // Following the PARENT rather than the canonical chain is what makes
        // this reorg-safe: a block admitted onto a competing branch takes that
        // branch's anchor, so two branches forking at height 1 never borrow each
        // other's schedule. A block whose parent is not yet known carries none
        // and acquires one when it connects.
        let anchor: DifficultyAnchor?
        if input.blockHeight == 1 {
            anchor = DifficultyAnchor(
                blockHeight: 1,
                timestamp: input.timestamp,
                target: input.snapshot.target
            )
        } else if let parentHash = input.parentBlockHash {
            anchor = graph.difficultyAnchor(of: parentHash)
        } else {
            anchor = nil
        }
        graph.insert(
            BlockRecord(
                blockHash: blockHash,
                parentBlockHash: input.parentBlockHash,
                blockHeight: input.blockHeight,
                childCommitments: input.childCommitments
            ),
            children: childHashes,
            difficultyAnchor: anchor
        )
        indexStateTransition(input.snapshot, blockHash: blockHash)
        if let prevHash = input.parentBlockHash {
            graph.appendChild(blockHash, to: prevHash)
            // A block declaring a spec other than its root's (a `spec !=
            // parent.spec` exclusion, or below one) keeps its root's spec for
            // the schedule of its own children. Header admission always holds
            // the parent, so every header-admitted block is settled here.
            if let rootSpec = rootSpecCID(of: prevHash),
               rootSpec != input.snapshot.specCID {
                offRootSpecCID[blockHash] = rootSpec
            }
        }
        for contribution in contributions {
            // A block arrives with its grinds; attributed runs are derived
            // later (`applyParentRun`).
            applyLocalContribution(contribution, to: blockHash, attributed: false)
        }
        // Every connected block routes, a descendant of an excluded root
        // included: work weighs unconditionally, and validity is applied by the
        // descent, which never steps into an excluded root (§9.9).
        if graftsExistingComponent {
            // These graph and work-location invariants were validated before
            // this private reducer. Never continue with a partial consensus
            // index if an internal invariant is broken.
            precondition(
                graftConnectedComponent(rootedAt: blockHash),
                "validated orphan component could not be routed"
            )
            settleRootSpecs(below: blockHash)
        } else if childHashes.isEmpty {
            precondition(
                routeBlock(for: blockHash),
                "validated leaf could not be routed"
            )
        }
        // Runs (§9.10): a block that just routed — alone, or as the root of a
        // grafted orphan component — is connected, and so is every descendant
        // it grafted in. Unfiltered: an excluded descendant routes and is
        // credited like any other. An orphan is not routed and is settled the
        // moment its component grafts.
        // Nothing to settle while no directory is served: skip the walk, which
        // on a graft would otherwise be a third pass over the component.
        if !runs.served.isEmpty, forkChoice.isRouted(blockHash) {
            connectForRunAttribution(rootedAt: blockHash)
        }

        for contribution in contributions {
            forkChoice.applyContribution(contribution, at: blockHash)
        }

        return SubmissionResult(
            addedBlock: true,
            addedContribution: addedContribution,
            extendsCanonical: false,
            weighed: forkChoice.isRouted(blockHash) ? graph.subtree(of: blockHash) : [blockHash]
        )
    }

    private static func hasUniqueWorkLocations(
        in blocks: BlockGraph
    ) -> Bool {
        var locationByGrind: [String: String] = [:]
        func observe(_ grindID: String, at blockHash: String) -> Bool {
            guard locationByGrind[grindID].map({ $0 == blockHash }) ?? true else {
                return false
            }
            locationByGrind[grindID] = blockHash
            return true
        }
        for block in blocks.records {
            let blockHash = block.blockHash
            for grindID in (blocks.work(of: blockHash)?.contributions ?? [:]).keys
            where !observe(grindID, at: blockHash) {
                return false
            }
        }
        return true
    }

    // MARK: - Additional proof facts

    mutating func addWorkContribution(
        _ contribution: VerifiedWorkContribution,
        to blockHash: String,
        attributed: Bool = false
    ) -> SubmissionResult {
        guard graph.contains(blockHash),
              forkChoice.acceptsLocation(of: contribution.id, at: blockHash) else {
            return .discarded()
        }
        if let existing = workContribution(id: contribution.id, at: blockHash),
           existing.work >= contribution.work {
            return .discarded()
        }
        guard hasUnreservedMutationCapacity else { return .discarded() }
        let workBefore = graph.work(of: blockHash)?.work ?? .zero
        applyLocalContribution(contribution, to: blockHash, attributed: attributed)
        // A strengthening raises this block's own work, so its run (§9.10)
        // rises by exactly that delta — once the block is connected. An
        // orphan's work is credited in full at the moment it connects.
        if forkChoice.isRouted(blockHash),
           let workAfter = graph.work(of: blockHash)?.work,
           let delta = workAfter.subtracting(workBefore) {
            runs.credit(delta, at: blockHash)
        }
        // A stronger observation on an excluded block weighs like any other: it
        // raises every ancestor, and the descent still never steps into the
        // excluded root, so no invalid block is resurrected by piling on work.
        forkChoice.applyContribution(contribution, at: blockHash)
        mutationGeneration += 1

        // A contribution only reaches here when it is strictly stronger than what
        // this block already held, so fork choice saw a positive increase at
        // exactly one point.
        let canonicalChange = deferProjectionForReplay
            ? nil
            : projectCanonicalChain(monotoneIncreaseAt: blockHash)
        if canonicalChange != nil {
            frontier.refreshTipSnapshot()
        }
        return SubmissionResult(
            addedBlock: false,
            addedContribution: true,
            extendsCanonical: false,
            commit: (canonicalChange ?? ChainCommit(tipHash: canonicalTip))
                .atRevision(mutationGeneration),
            weighed: [blockHash]
        )
    }

    /// Apply one already-durable, locally authenticated admission batch. Live
    /// admission and recovery share this reducer so staging is the only
    /// linearization point.
    mutating func applyStaged(_ batch: BlockImportBatch) throws -> SubmissionResult? {
        try applyStaged(batch, authenticated: TrustedImportBatch(batch))
    }

    /// `authenticated` is `TrustedImportBatch(batch)`, which replay derives
    /// once for sorting and passes in rather than re-deriving.
    private mutating func applyStaged(
        _ batch: BlockImportBatch,
        authenticated: @autoclosure () -> TrustedImportBatch?
    ) throws -> SubmissionResult? {
        if let excluded = Self.exclusionTarget(of: batch) {
            return try applyExclusion(blockHash: excluded)
        }
        // A proven-invalid block is never executed: a validation for one is
        // the twin of excluding an executed block (`applyExclusion`).
        for fact in batch.facts {
            guard case .validation(let validation) = fact,
                  let hash = CIDIdentity.canonicalString(validation.blockHash),
                  forkChoice.excludedRoots.contains(hash) else { continue }
            throw ChainStateRestoreError.executedVerdictContradiction
        }
        if let validated = Self.validationTarget(of: batch) {
            // A validation for a block this chain does not hold is deferred by
            // the caller's replay loop exactly as a work fact would be, not an
            // error: possession and execution arrive independently.
            guard graph.contains(validated) else {
                throw ChainStateRestoreError.missingBlockFact
            }
            markValidated(blockHash: validated)
            return nil
        }
        guard let trusted = authenticated() else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        // Applied only once the batch has landed: `defer` would also run on the
        // throw paths, marking a block executed out of a batch that was rejected
        // as graph-inconsistent.
        func applyValidations() {
            for fact in batch.facts {
                guard case .validation(let validation) = fact,
                      let hash = CIDIdentity.canonicalString(validation.blockHash)
                else { continue }
                markValidated(blockHash: hash)
            }
        }
        if let input = trusted.block {
            // The root chain's pin, at the one reducer every fact passes
            // through: no root genesis but the configured one, live or replayed.
            if input.parentBlockHash == nil, let context,
               !context.admitsGenesis(input.blockHash) {
                throw ChainStateRestoreError.unpinnedRootGenesis
            }
            if let existing = graph[input.blockHash] {
                guard matchesGraph(existing, input: input),
                      frontier.snapshot(of: input.blockHash).map({
                          $0 == input.snapshot
                      }) ?? true else {
                    throw ChainStateRestoreError.corruptConsensusGraph
                }
                let contribution = trusted.contribution
                if let existing = workContribution(
                    id: contribution.id,
                    at: input.blockHash
                ), existing.work >= contribution.work {
                    hydrateMetadata(from: input)
                    applyValidations()
                    return nil
                }
                guard hasUnreservedMutationCapacity else {
                    throw ChainStateRestoreError.corruptConsensusGraph
                }
                hydrateMetadata(from: input)
                let submission = addWorkContribution(contribution, to: input.blockHash)
                guard submission.addedContribution else {
                    throw ChainStateRestoreError.corruptConsensusGraph
                }
                applyValidations()
                return submission
            }
            let submission = submitBlock(input: input, contribution: trusted.contribution)
            guard submission.addedBlock, submission.addedContribution else {
                throw ChainStateRestoreError.corruptConsensusGraph
            }
            applyValidations()
            return submission
        }

        let blockHash = trusted.workBlockHash
        let contribution = trusted.contribution
        guard graph.contains(blockHash) else {
            throw ChainStateRestoreError.missingBlockFact
        }
        if let existing = workContribution(
            id: contribution.id,
            at: blockHash
        ), existing.work >= contribution.work {
            return nil
        }
        let submission = addWorkContribution(contribution, to: blockHash)
        guard submission.addedContribution else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        return submission
    }

    /// A validation batch is exactly one `.validation` fact: the deferred
    /// upgrade of an already-possessed block, carrying no new block or work.
    private static func validationTarget(of batch: BlockImportBatch) -> String? {
        guard batch.facts.count == 1,
              case .validation(let fact) = batch.facts[0] else { return nil }
        return CIDIdentity.canonicalString(fact.blockHash)
    }

    /// An exclusion batch is exactly one `.exclusion` fact. Any other shape is
    /// handled by the block/work reducer.
    private static func exclusionTarget(of batch: BlockImportBatch) -> String? {
        guard batch.facts.count == 1,
              case .exclusion(let fact) = batch.facts[0] else { return nil }
        return CIDIdentity.canonicalString(fact.blockHash)
    }

    /// Record a proven-invalid subtree root. The block must already be present:
    /// a not-yet-connected exclusion defers exactly like a work fact whose block
    /// has not arrived, so replay retries it once the subtree exists.
    private mutating func applyExclusion(blockHash: String) throws -> SubmissionResult? {
        guard graph.contains(blockHash) else {
            throw ChainStateRestoreError.missingBlockFact
        }
        // Idempotent: a duplicate exclusion adds nothing and cannot reorg.
        if forkChoice.excludedRoots.contains(blockHash) { return nil }
        // Execution is never revoked: an executed block is never excluded.
        // `applyConnect` refuses such a verdict before any fact is written;
        // this reducer is the fail-closed twin, and replay orders validations
        // first, so the contradiction is found whatever the enumeration order.
        guard !frontier.validated.contains(blockHash) else {
            throw ChainStateRestoreError.executedVerdictContradiction
        }
        guard hasUnreservedMutationCapacity else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        // A chain whose every root is proven invalid has no history to stand
        // on, so a root may be excluded only while another root this chain has
        // EXECUTED remains. The producer (`prepareValidatedTier`) refuses
        // before any fact is written; this reducer is the fail-closed twin.
        // During replay the other root's validation may simply not have
        // replayed yet, so the exclusion defers like any fact whose
        // prerequisites are missing — order-independent — and only a live
        // exclusion with nothing to stand on is a corrupt graph.
        if graph.parent(of: blockHash) == nil,
           !hasExecutedRoot(besides: blockHash) {
            throw deferProjectionForReplay
                ? ChainStateRestoreError.missingBlockFact
                : ChainStateRestoreError.corruptConsensusGraph
        }
        // The block is not executed (above), so nothing at or below it is
        // anchored: the executed set is untouched.
        forkChoice.exclude(blockHash)
        // No weight moves — work weighs regardless of validity — so nothing is
        // rebuilt. Selection moves only if the excluded block was on the
        // canonical path; otherwise the descent never reached it and every
        // decision stands.
        let wasCanonical = canonicalHashes.contains(blockHash)
        mutationGeneration += 1
        let canonicalChange = (deferProjectionForReplay || !wasCanonical)
            ? nil
            : projectCanonicalChain(forceFull: true)
        if canonicalChange != nil {
            frontier.refreshTipSnapshot()
        }
        return SubmissionResult(
            addedBlock: false,
            addedContribution: false,
            extendsCanonical: false,
            commit: (canonicalChange ?? ChainCommit(tipHash: canonicalTip))
                .atRevision(mutationGeneration)
        )
    }

    /// Rebuild one already-durable admission fact during recovery. Callers must
    /// authenticate and persist the fact before invoking this public seam.
    public mutating func replay(_ batch: BlockImportBatch) throws -> ChainCommit? {
        try applyStaged(batch)?.commit
    }

    /// Reserve one distinct U64 commit revision before the node stages a batch.
    /// Other actor mutations must leave this capacity available until the batch
    /// either fails staging or consumes the reservation synchronously.
    package mutating func reserveImportRevision() -> Bool {
        guard hasUnreservedMutationCapacity else { return false }
        reservedImportRevisions += 1
        return true
    }

    package mutating func releaseImportRevision() {
        precondition(reservedImportRevisions > 0)
        reservedImportRevisions -= 1
    }

    package mutating func applyReservedStaged(
        _ batch: BlockImportBatch
    ) throws -> SubmissionResult? {
        guard reservedImportRevisions > 0 else {
            throw ChainStateRestoreError.corruptConsensusGraph
        }
        reservedImportRevisions -= 1
        return try applyStaged(batch)
    }

    var hasUnreservedMutationCapacity: Bool {
        hasMutationCapacity(for: 1)
    }

    /// Whether `count` more consensus mutations fit before revisions run out.
    package func hasMutationCapacity(for count: UInt64) -> Bool {
        let (needed, overflow) = reservedImportRevisions.addingReportingOverflow(count)
        return !overflow && needed <= UInt64.max - mutationGeneration
    }

    private func matchesGraph(_ meta: BlockRecord, input: ConsensusBlockInput) -> Bool {
        meta.blockHash == input.blockHash
            && meta.parentBlockHash == input.parentBlockHash
            && meta.blockHeight == input.blockHeight
            // Commitments are PoW-bound content, so two honest facts for one
            // block agree; a disagreement is a graph conflict, rejected — never
            // resolved by whichever fact happened to replay first.
            && meta.childCommitments == input.childCommitments
    }

    private mutating func hydrateMetadata(from input: ConsensusBlockInput) {
        indexStateTransition(input.snapshot, blockHash: input.blockHash)
        // The index above just recorded `input.snapshot` for this block.
        if canonicalTip == input.blockHash {
            frontier.refreshTipSnapshot()
        }
    }

    // MARK: - Index Management

    private func connectsExistingSubtree(
        _ input: ConsensusBlockInput
    ) -> Bool {
        guard !findChildren(
            hash: input.blockHash,
            blockHeight: input.blockHeight
        ).isEmpty else { return false }
        guard let parentHash = input.parentBlockHash else {
            return input.blockHeight == 0
        }
        return forkChoice.isRouted(parentHash)
    }

    mutating func addToBlockIndex(hash: String, blockHeight: UInt64) {
        indexToBlockHash[blockHeight, default: []].insert(hash)
    }

    func findChildren(hash: String, blockHeight: UInt64) -> [String] {
        let (childHeight, overflow) = blockHeight.addingReportingOverflow(1)
        guard !overflow, let hashes = indexToBlockHash[childHeight] else { return [] }
        return hashes.filter { graph.parent(of: $0) == hash }
    }

}

