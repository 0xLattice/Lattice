import UInt256
import LatticePrimitives
import LatticePoW

/// The actor form of one chain's `ChainTree`. It holds exactly one tree and
/// forwards to it: every rule lives on the value, so the actor and the value
/// can never disagree. Kept for the existing admission API (`ChainLevel`,
/// preflight/commit, `restore(replaying:)`).
public actor ChainState {
    /// The wrapped value. Reading it takes a snapshot; the actor stays the
    /// only mutator of its own copy.
    public private(set) var tree: ChainTree

    public init(tree: ChainTree) {
        self.tree = tree
    }

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
        self.tree = try ChainTree(
            canonicalTip: canonicalTip,
            canonicalHashes: canonicalHashes,
            indexToBlockHash: indexToBlockHash,
            hashToBlock: hashToBlock,
            tipSnapshot: tipSnapshot,
            tipSnapshotsByHash: tipSnapshotsByHash,
            validatedBlocks: validatedBlocks,
            mutationGeneration: mutationGeneration
        )
    }

    package static func fromGenesis(block: Block) -> ChainState {
        ChainState(tree: ChainTree.fromGenesis(block: block))
    }

    package static func fromVerifiedGenesis(
        block: Block,
        contribution: VerifiedWorkContribution
    ) -> ChainState {
        ChainState(tree: ChainTree.fromVerifiedGenesis(
            block: block, contribution: contribution
        ))
    }

    /// See `ChainTree.restore(replaying:revisionFloor:context:specs:)`:
    /// `context` is required, and on a root chain restore refuses any root
    /// genesis but the pinned one.
    public static func restore(
        replaying batches: [BlockImportBatch],
        revisionFloor: UInt64 = 0,
        context: ChainRuntimeContext,
        specs: [ChainSpec] = []
    ) async throws -> ChainState {
        ChainState(tree: try ChainTree.restore(
            replaying: batches, revisionFloor: revisionFloor, context: context, specs: specs
        ))
    }

    /// See `ChainTree.restoreWithoutContext`: tests only; pins nothing.
    package static func restoreWithoutContext(
        replaying batches: [BlockImportBatch],
        revisionFloor: UInt64 = 0
    ) async throws -> ChainState {
        ChainState(tree: try ChainTree.restoreWithoutContext(
            replaying: batches, revisionFloor: revisionFloor
        ))
    }

    // MARK: - Stored state (forwarded)

    var indexToBlockHash: [UInt64: Set<String>] { tree.indexToBlockHash }
    var graph: BlockGraph {
        get { tree.graph }
        set { tree.graph = newValue }
    }
    var forkChoice: ForkChoice { tree.forkChoice }
    var frontier: ExecutionFrontier { tree.frontier }
    var runs: RunAttribution { tree.runs }
    var localWorkCachesDirty: Bool { tree.localWorkCachesDirty }
    var mutationGeneration: UInt64 {
        get { tree.mutationGeneration }
        set { tree.mutationGeneration = newValue }
    }
    var reservedImportRevisions: UInt64 { tree.reservedImportRevisions }
    var highestBlockHeight: UInt64 { tree.highestBlockHeight }
    var hashToBlock: [String: BlockMeta] { tree.hashToBlock }
    var hasUnreservedMutationCapacity: Bool { tree.hasUnreservedMutationCapacity }
    public var canonicalTip: String { tree.canonicalTip }
    var canonicalHashes: Set<String> { tree.canonicalHashes }
    var canonicalHashByHeight: [UInt64: String] { tree.canonicalHashByHeight }
    public var tipSnapshot: TipBlockSnapshot? { tree.tipSnapshot }

#if DEBUG
    var excludedRootsForTesting: Set<String> { tree.excludedRootsForTesting }
    var segmentWorkUpdateCellCount: UInt64 { tree.segmentWorkUpdateCellCount }
    var localWorkCacheBlockVisitCount: UInt64 { tree.localWorkCacheBlockVisitCount }
    var segmentGraftCount: UInt64 { tree.segmentGraftCount }
    var segmentGraftBlockVisitCount: UInt64 { tree.segmentGraftBlockVisitCount }
    var fullCanonicalProjectionCount: UInt64 { tree.fullCanonicalProjectionCount }
    var truncatedCanonicalProjectionCount: UInt64 { tree.truncatedCanonicalProjectionCount }
    var canonicalProjectionBlockVisitCount: UInt64 { tree.canonicalProjectionBlockVisitCount }
    var canonicalProjectionSegmentVisitCount: UInt64 { tree.canonicalProjectionSegmentVisitCount }
    var stateContinuityBlockVisitCount: UInt64 { tree.stateContinuityBlockVisitCount }
    var runAttributionUpdateCount: UInt64 { tree.runAttributionUpdateCount }

    func resetFullCanonicalProjectionCount() {
        tree.resetFullCanonicalProjectionCount()
    }

    func debugFullCanonicalProjection() -> (
        canonicalTip: String,
        canonicalHashes: Set<String>
    )? {
        tree.debugFullCanonicalProjection()
    }
#endif

    // MARK: - Queries

    public func contains(blockHash: String) -> Bool {
        tree.contains(blockHash: blockHash)
    }

    public func currentRevision() -> UInt64 {
        tree.currentRevision()
    }

    public func unresolvedSameChainPredecessors() -> [SameChainPredecessorRequirement] {
        tree.unresolvedSameChainPredecessors()
    }

    package func sameChainPredecessorRequirement(
        for descendantCID: String
    ) -> SameChainPredecessorRequirement? {
        tree.sameChainPredecessorRequirement(for: descendantCID)
    }

    public func getConsensusBlock(hash: String) -> BlockMeta? {
        tree.getConsensusBlock(hash: hash)
    }

    public func getHighestBlockHeight() -> UInt64 {
        tree.getHighestBlockHeight()
    }

    public func difficultyAnchor(forBlockHash hash: String) -> DifficultyAnchor? {
        tree.difficultyAnchor(forBlockHash: hash)
    }

    func workContribution(id: String) -> WorkContributionRecord? {
        tree.workContribution(id: id)
    }

    package func workContribution(
        id: String,
        at blockHash: String
    ) -> VerifiedWorkContribution? {
        tree.workContribution(id: id, at: blockHash)
    }

    package func hasConnectedAncestry(blockHash: String) -> Bool {
        tree.hasConnectedAncestry(blockHash: blockHash)
    }

    public func getTipCumulativeWork() -> WorkSum {
        tree.getTipCumulativeWork()
    }

    public func getCumulativeWork(forHash hash: String) -> WorkSum? {
        tree.getCumulativeWork(forHash: hash)
    }

    public func subtreeWeight(forHash hash: String) -> WorkSum? {
        tree.subtreeWeight(forHash: hash)
    }

    public func forkChoiceSnapshot(startingAt hash: String) -> ForkChoiceSnapshot? {
        tree.forkChoiceSnapshot(startingAt: hash)
    }

    public func forkChoiceWeight(of hash: String) -> WorkSum? {
        tree.forkChoiceWeight(of: hash)
    }

    func chainWithMostWork(
        startingBlock: BlockMeta
    ) -> (subtreeWork: WorkSum, tipHash: String, blocks: Set<String>) {
        tree.chainWithMostWork(startingBlock: startingBlock)
    }

    func chainWithMostWork(
        startingAt startHash: String
    ) -> (subtreeWork: WorkSum, tipHash: String, blocks: Set<String>) {
        tree.chainWithMostWork(startingAt: startHash)
    }

    package func transactionPreflightTip(
        at blockHash: String? = nil
    ) -> (cid: String, snapshot: TipBlockSnapshot?) {
        tree.transactionPreflightTip(at: blockHash)
    }

    public func isCanonical(hash: String) -> Bool {
        tree.isCanonical(hash: hash)
    }

    public func canonicalBlockHash(atHeight height: UInt64) -> String? {
        tree.canonicalBlockHash(atHeight: height)
    }

    public func isExecuted(blockHash: String) -> Bool {
        tree.isExecuted(blockHash: blockHash)
    }

    public func isExcludedRoot(_ blockHash: String) -> Bool {
        tree.isExcludedRoot(blockHash)
    }

    package func holdSpec(_ spec: ChainSpec, for specCID: String) {
        _ = tree.holdSpec(spec, for: specCID)
    }

    public func hasExecutedAncestry(blockHash: String) -> Bool {
        tree.hasExecutedAncestry(blockHash: blockHash)
    }

    public func hasStateContinuity(
        from fromStateCID: String,
        to toStateCID: String
    ) -> Bool {
        tree.hasStateContinuity(from: fromStateCID, to: toStateCID)
    }

    public func stateContinuityPath(
        from fromStateCID: String,
        to toStateCID: String
    ) -> [String]? {
        tree.stateContinuityPath(from: fromStateCID, to: toStateCID)
    }

    package func hasExecutedRoot(besides blockHash: String) -> Bool {
        tree.hasExecutedRoot(besides: blockHash)
    }

    func findChildren(hash: String, blockHeight: UInt64) -> [String] {
        tree.findChildren(hash: hash, blockHeight: blockHeight)
    }

    public func nearestCarrier(of blockHash: String, directory: String) -> String? {
        tree.nearestCarrier(of: blockHash, directory: directory)
    }

    @discardableResult
    public func applyParentRun(
        from parent: ChainTree,
        directory: String,
        parentBlocks: Set<String>? = nil,
        held: Set<String> = []
    ) -> (raised: [String], commit: ChainCommit?) {
        tree.applyParentRun(from: parent, directory: directory, parentBlocks: parentBlocks, held: held)
    }

    public func recordedChildCommitments(of blockHash: String) -> [String: String]? {
        tree.recordedChildCommitments(of: blockHash)
    }

    // MARK: - Mutations

    public func serveRuns(for directory: String) {
        tree.serveRuns(for: directory)
    }

    func submitBlock(
        blockHeader: BlockHeader,
        block: Block,
        contribution: VerifiedWorkContribution
    ) -> SubmissionResult {
        tree.submitBlock(blockHeader: blockHeader, block: block, contribution: contribution)
    }

    func addWorkContribution(
        _ contribution: VerifiedWorkContribution,
        to blockHash: String,
        attributed: Bool = false
    ) -> SubmissionResult {
        tree.addWorkContribution(contribution, to: blockHash, attributed: attributed)
    }

    func applyStaged(_ batch: BlockImportBatch) throws -> SubmissionResult? {
        try tree.applyStaged(batch)
    }

    /// Rebuild one already-durable admission fact during recovery. Callers must
    /// authenticate and persist the fact before invoking this public seam.
    public func replay(_ batch: BlockImportBatch) throws -> ChainCommit? {
        try tree.replay(batch)
    }

    package func reserveImportRevision() -> Bool {
        tree.reserveImportRevision()
    }

    package func releaseImportRevision() {
        tree.releaseImportRevision()
    }

    package func applyReservedStaged(
        _ batch: BlockImportBatch
    ) throws -> SubmissionResult? {
        try tree.applyReservedStaged(batch)
    }

    @discardableResult
    public func reevaluateForkChoice() -> ChainCommit? {
        tree.reevaluateForkChoice()
    }

    func markValidated(blockHash: String) {
        tree.markValidated(blockHash: blockHash)
    }

    func projectCanonicalChain(
        forceFull: Bool = false,
        monotoneIncreaseAt mutatedAt: String? = nil
    ) -> ChainCommit? {
        tree.projectCanonicalChain(forceFull: forceFull, monotoneIncreaseAt: mutatedAt)
    }

    func materializeLocalWorkCachesIfNeeded() {
        tree.materializeLocalWorkCachesIfNeeded()
    }

    func addToBlockIndex(hash: String, blockHeight: UInt64) {
        tree.addToBlockIndex(hash: hash, blockHeight: blockHeight)
    }

    @discardableResult
    func routeBlock(for blockHash: String) -> Bool {
        tree.routeBlock(for: blockHash)
    }
}

extension ChainState: DifficultyAnchorSource {}
