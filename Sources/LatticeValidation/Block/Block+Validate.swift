import Foundation
import Crypto
import cashew
import UInt256
import CollectionConcurrencyKit
import LatticePrimitives
import LatticePoW

/// A validation result whose truth may change only as the supplied wall-clock
/// context advances. It is deliberately separate from a permanent protocol
/// violation and from unavailable evidence.
public enum BlockValidationError: Error, Sendable, Equatable {
    case notYetValid
}

/// Validation against chain state could not resolve the block's difficulty
/// anchor locally: neither the parent nor the grandparent is in the graph with
/// an anchor. It is unavailable evidence, never a verdict — the block parks on
/// its predecessor and is retried when that connects. Validation never walks
/// the missing ancestry over the network to find out: those hops are
/// attacker-served links with no work or height checked per hop.
public struct AnchorUnavailable: Error, Sendable, Equatable {
    public init() {}
}

/// What header admission decides for a block whose work verified and whose
/// parent is held (`Block.headerAdmission`, spec §9.9).
public enum HeaderAdmission: Sendable, Equatable {
    /// Weighed, and selectable as far as its header goes.
    case linked
    /// Weighed with its work, and excluded: never selected. Only
    /// `spec != parent.spec` and `prevState != parent.postState`.
    case excluded
    /// A structural fault (version, height): dropped, no weight, no blame.
    case malformed
    /// Off the schedule — `timestamp <= parent.timestamp`, `target >
    /// parent.nextTarget`, or a `nextTarget` that is not the ASERT schedule:
    /// a proof-of-work failure.
    case offSchedule
}

/// The fields of a parent block that header linkage reads. Resolved parent
/// content and a block tree's recorded entry both supply them, so the same
/// rules decide linkage whichever one the caller holds.
public struct HeaderLinkageParent: Sendable, Equatable {
    public let height: UInt64
    public let timestamp: Int64
    public let target: UInt256
    public let nextTarget: UInt256
    public let postStateCID: String
    public let specCID: String

    public init(
        height: UInt64,
        timestamp: Int64,
        target: UInt256,
        nextTarget: UInt256,
        postStateCID: String,
        specCID: String
    ) {
        self.height = height
        self.timestamp = timestamp
        self.target = target
        self.nextTarget = nextTarget
        self.postStateCID = postStateCID
        self.specCID = specCID
    }

    public init(_ block: Block) {
        self.init(
            height: block.height,
            timestamp: block.timestamp,
            target: block.target,
            nextTarget: block.nextTarget,
            postStateCID: block.postState.rawCID,
            specCID: block.spec.rawCID
        )
    }
}

public struct ValidationContext: Sendable, Equatable {
    public let nowMilliseconds: Int64

    public init(nowMilliseconds: Int64) {
        self.nowMilliseconds = nowMilliseconds
    }

    public static var current: ValidationContext {
        ValidationContext(nowMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000))
    }

    func permits(timestamp: Int64) -> Bool {
        // A node will not accept a block from its own future. This references
        // only the node's own clock — there is no protocol-imposed drift
        // constant — and it is retriable (see `notYetValid`): a block from a
        // slightly-fast miner is deferred until real time reaches its timestamp,
        // never permanently rejected, so honest blocks are never lost and the
        // valid-block set never forks on clock skew. An operator who wants slack
        // constructs the context with a shifted `nowMilliseconds`.
        timestamp <= nowMilliseconds
    }
}

public extension Block {
    func validateGenesis(
        fetcher: Fetcher,
        chainPath: [String],
        reportTemporalFailure: Bool = false,
        validationContext: ValidationContext = .current
    ) async throws -> (Bool, StateDiff) {
        let transition = try await validateGenesisTransition(
            fetcher: fetcher,
            chainPath: chainPath,
            reportTemporalFailure: reportTemporalFailure,
            validationContext: validationContext
        )
        return (transition.0, transition.1)
    }

    /// Internal genesis validation result for admission paths that must retain
    /// the verified post-state before exposing a consensus mutation.
    package func validateGenesisTransition(
        fetcher: Fetcher,
        chainPath: [String],
        reportTemporalFailure: Bool = false,
        validationContext: ValidationContext
    ) async throws -> (Bool, StateDiff, LatticeState?) {
        if !hasGenesisShape(isRoot: chainPath.count == 1) { return (false, .empty, nil) }
        if !validationContext.permits(timestamp: timestamp) {
            if reportTemporalFailure { throw BlockValidationError.notYetValid }
            return (false, .empty, nil)
        }
        // The spec comes before the transactions because it carries the limit
        // they are fetched under: without it nothing bounds that fetch. So a
        // genesis whose spec is unavailable gets no verdict even when its
        // transactions would prove it invalid, and an invalid spec is a
        // verdict whether or not the transactions can be had.
        guard let specNode = try await spec.resolve(fetcher: fetcher).node else { return (false, .empty, nil) }
        guard specNode.isValid else { return (false, .empty, nil) }
        guard let transactionBodies = try await resolveTransactionBodies(fetcher: fetcher, maxBlockSize: specNode.maxBlockSize, validator: { tx in
            try await tx.validateTransactionForGenesis(fetcher: fetcher)
        }) else { return (false, .empty, nil) }
        guard chainPath.first == DEFAULT_ROOT_DIRECTORY else {
            return (false, .empty, nil)
        }
        if !validateChainPaths(transactionBodies: transactionBodies, expectedPath: chainPath) {
            return (false, .empty, nil)
        }
        if !(try await TransactionBody.validateConfiguredPolicyModules(
            spec: specNode,
            fetcher: fetcher
        )) {
            return (false, .empty, nil)
        }
        if !(try await TransactionBody.batchVerifyPolicies(bodies: transactionBodies, spec: specNode, chainPath: chainPath, height: height, timestamp: timestamp, fetcher: fetcher)) { return (false, .empty, nil) }
        if !validateMaxTransactionCount(spec: specNode, transactionBodies: transactionBodies) { return (false, .empty, nil) }
        if try !validateStateGrowthFloor(spec: specNode, transactionBodies: transactionBodies) { return (false, .empty, nil) }
        if try await !validateBlockSize(spec: specNode, fetcher: fetcher) {
            return (false, .empty, nil)
        }
        let allAccountActions = transactionBodies.flatMap { $0.accountActions }
        // R4: the per-transaction gate above (validateTransactionForGenesis)
        // rejects any genesis transaction carrying deposit, withdrawal, or
        // receipt actions, so those lists are provably empty for every body
        // that reaches this point — pass empty literals instead of collecting.
        assert(transactionBodies.allSatisfy { $0.depositActions.isEmpty && $0.withdrawalActions.isEmpty && $0.receiptActions.isEmpty })
        if try !validateBalanceChangesForGenesis(spec: specNode, allAccountActions: allAccountActions) { return (false, .empty, nil) }
        let (postStateValid, diff, materializedPostState) = try await validatePostState(spec: specNode, transactionBodies: transactionBodies, allAccountActions: allAccountActions, allActions: transactionBodies.flatMap { $0.actions }, allDepositActions: [], allReceiptActions: [], allWithdrawalActions: [], fetcher: fetcher)
        if !postStateValid { return (false, .empty, nil) }
        return (true, diff, materializedPostState)
    }

    func validateTimestampAndNextTarget(
        spec: ChainSpec,
        parent: Block,
        fetcher: Fetcher,
        chain: (any DifficultyAnchorSource)? = nil,
        reportTemporalFailure: Bool = false,
        validationContext: ValidationContext
    ) async throws -> Bool {
        // No ancestor-timestamp walk: the schedule is a function of one anchor
        // and this block, so validating a target no longer requires reading a
        // window of ancestors. That walk was the dominant cost of
        // building a mining template — 120 sequential block resolutions per
        // request, redone every round for a list that changes by one entry per
        // block.
        let linkageParent = HeaderLinkageParent(parent)
        guard try validateTimestampLinkage(
            parent: linkageParent,
            reportTemporalFailure: reportTemporalFailure,
            validationContext: validationContext
        ) else { return false }
        // Resolve the schedule's origin: the height-1 ancestor of this block.
        // Chain state carries it, inherited at admission in O(1). With a chain,
        // it is answered from what is already in hand or in the graph, or not
        // at all (`AnchorUnavailable`); without a chain to ask, fall back to
        // the SAME walk the builder uses, so the two can never disagree about
        // which block anchors the schedule.
        let anchor: DifficultyAnchor?
        if let inHand = immediateDifficultyAnchor(parent: linkageParent) {
            anchor = inHand
        } else if let chain {
            // The anchor is inherited, so the parent's or the grandparent's is
            // this block's. The grandparent CID comes from the parent header
            // already fetched. Nothing is walked: a block whose nearest two
            // ancestors are unknown parks on its predecessor instead.
            if let parentHash = self.parent?.rawCID,
               let carried = await chain.difficultyAnchor(forBlockHash: parentHash) {
                anchor = carried
            } else if let grandparentHash = parent.parent?.rawCID,
                      let carried = await chain.difficultyAnchor(forBlockHash: grandparentHash) {
                anchor = carried
            } else {
                throw AnchorUnavailable()
            }
        } else {
            anchor = try await BlockBuilder.resolveDifficultyAnchor(
                from: parent, fetcher: fetcher
            )
        }
        guard let anchor else { return false }
        if !validateNextTarget(
            spec: spec, parent: parent, difficultyAnchor: anchor
        ) { return false }
        return true
    }

    /// `source:` overload of ``validateNexus(fetcher:chain:chainPath:reportTemporalFailure:)``.
    /// Wraps the batched cashew ``ContentSource`` in a single
    /// ``CoalescingFetcher`` and delegates to the `fetcher:` version unchanged,
    /// so validation is byte-identical to the per-CID path. Threading one
    /// coalescer through the whole call collapses each concurrent wave of
    /// content fetches (transaction bodies, ancestor walk, state resolution)
    /// into batched requests without altering the validation logic.
    func validateNexus(
        source: any ContentSource,
        chain: (any DifficultyAnchorSource)? = nil,
        chainPath: [String]? = nil,
        reportTemporalFailure: Bool = false,
        validationContext: ValidationContext = .current
    ) async throws -> (Bool, StateDiff, LatticeState?) {
        try await validateNexus(
            fetcher: CoalescingFetcher(source),
            chain: chain,
            chainPath: chainPath,
            reportTemporalFailure: reportTemporalFailure,
            validationContext: validationContext
        )
    }

    /// Header linkage: the structural rules a non-genesis block must satisfy
    /// against its parent before anything is executed — version, parent
    /// resolution, spec continuity, `prevState == parent.postState`, and
    /// height. Returns the resolved parent and spec, or nil when a rule fails.
    /// With `validateTimestampAndNextTarget` this is the whole header-linkage
    /// rule set (`validateHeaderLinkage` composes the two); `validateNexus`
    /// runs the same pieces before it touches a transaction body.
    func resolveHeaderLinkage(
        fetcher: Fetcher
    ) async throws -> (parent: Block, spec: ChainSpec)? {
        if version != Block.currentVersion { return nil }
        async let parentFuture = parent?.resolve(fetcher: fetcher)
        async let specFuture = spec.resolve(fetcher: fetcher)
        guard let previousBlockNode = try await parentFuture?.node else { return nil }
        if !validateSpec(parent: previousBlockNode) { return nil }
        if !validateState(parent: previousBlockNode) { return nil }
        if !validateHeight(parent: previousBlockNode) { return nil }

        guard let specNode = try await specFuture.node else { return nil }
        return (previousBlockNode, specNode)
    }

    /// The complete header-linkage check — `resolveHeaderLinkage` plus the
    /// timestamp and target schedule — and nothing else. This is what
    /// "structurally verify" means for a block that is possessed but not yet
    /// executed: exactly the checks `validateNexus` makes before execution.
    func validateHeaderLinkage(
        fetcher: Fetcher,
        chain: (any DifficultyAnchorSource)? = nil,
        reportTemporalFailure: Bool = false,
        validationContext: ValidationContext
    ) async throws -> Bool {
        guard let linkage = try await resolveHeaderLinkage(fetcher: fetcher) else {
            return false
        }
        return try await validateTimestampAndNextTarget(
            spec: linkage.spec,
            parent: linkage.parent,
            fetcher: fetcher,
            chain: chain,
            reportTemporalFailure: reportTemporalFailure,
            validationContext: validationContext
        )
    }

    /// The timestamp rules of header linkage, before the difficulty anchor is
    /// needed: the child height must be representable, a block from this
    /// node's future defers (`notYetValid` when `reportTemporalFailure`), and
    /// the timestamp must pass `validateTimestamp`.
    func validateTimestampLinkage(
        parent: HeaderLinkageParent,
        reportTemporalFailure: Bool,
        validationContext: ValidationContext
    ) throws -> Bool {
        let (_, heightOverflow) = parent.height.addingReportingOverflow(1)
        guard !heightOverflow else { return false }
        if !validationContext.permits(timestamp: timestamp) {
            if reportTemporalFailure { throw BlockValidationError.notYetValid }
            return false
        }
        return validateTimestamp(
            parent: parent,
            validationContext: validationContext
        )
    }

    /// The schedule's origin when it is in hand without a lookup: a height-1
    /// block anchors itself, and a height-1 parent is the anchor. Nil above
    /// that, where the anchor is inherited through the block graph.
    func immediateDifficultyAnchor(
        parent: HeaderLinkageParent
    ) -> DifficultyAnchor? {
        if parent.height == 0 {
            // This block is height 1: it anchors itself, and its own committed
            // target is where the schedule begins.
            return DifficultyAnchor(
                blockHeight: 1, timestamp: timestamp, target: target
            )
        }
        if parent.height == 1 {
            // The parent, already in hand, is the anchor.
            return DifficultyAnchor(
                blockHeight: 1, timestamp: parent.timestamp, target: parent.target
            )
        }
        return nil
    }

    /// Header admission (§9.9) against a parent the caller already holds (a
    /// block tree's recorded entry, excluded or not) and the chain's own spec.
    /// Work weighs and validity selects, so a header rule decides one of four
    /// things. Throws `BlockValidationError.notYetValid` for a block from this
    /// node's future and `AnchorUnavailable` when the difficulty anchor is not
    /// in hand: both are held and retried, never a verdict. `inheritedAnchor`
    /// answers the parent's inherited difficulty anchor and is asked only above
    /// height 2.
    func headerAdmission(
        parent: HeaderLinkageParent,
        spec: ChainSpec,
        inheritedAnchor: () -> DifficultyAnchor?,
        validationContext: ValidationContext
    ) throws -> HeaderAdmission {
        // Structural: the header cannot sit where it claims to.
        if version != Block.currentVersion { return .malformed }
        if !validateHeight(parent: parent) { return .malformed }
        // The schedule is part of the proof of work: a header whose target is
        // easier than scheduled, or whose committed `nextTarget` departs from
        // it, proves no work the chain asked for. The timestamp is the
        // schedule's input — height 1 anchors it — so a timestamp at or
        // before the parent's fails the same way: an old anchor would make
        // every descendant cheap. Block 1's anchor timestamp is bounded below
        // only by `genesis.timestamp`, so a genesis MUST carry its real
        // launch time.
        if parent.timestamp >= timestamp { return .offSchedule }
        guard let anchor = immediateDifficultyAnchor(parent: parent)
            ?? inheritedAnchor() else {
            throw AnchorUnavailable()
        }
        guard validateNextTarget(
            spec: spec, parent: parent, difficultyAnchor: anchor
        ) else { return .offSchedule }
        // Only now the node's clock: every schedule check above is a function
        // of the header and its parent, never of `now`, so a future-dated
        // header off the schedule is a proof-of-work failure, not a hold
        // (Bitcoin's ContextualCheckBlockHeader order: bits, then time).
        if !validationContext.permits(timestamp: timestamp) {
            throw BlockValidationError.notYetValid
        }
        // Validity: deterministic rules against the parent's agreed state.
        if !validateSpec(parent: parent) || !validateState(parent: parent) {
            return .excluded
        }
        return .linked
    }

    /// Validate block structure: parent linkage, spec, height, timestamp,
    /// target, transaction signatures, balance changes, and genesis
    /// transactions, and post-state root. Returns the state diff and the
    /// materialized post-state produced by the validated transition.
    func validateNexus(
        fetcher: Fetcher,
        chain: (any DifficultyAnchorSource)? = nil,
        chainPath: [String]? = nil,
        reportTemporalFailure: Bool = false,
        validationContext: ValidationContext = .current
    ) async throws -> (Bool, StateDiff, LatticeState?) {
        let expectedChainPath = chainPath ?? [DEFAULT_ROOT_DIRECTORY]
        guard expectedChainPath.first == DEFAULT_ROOT_DIRECTORY else {
            return (false, .empty, nil)
        }
        guard let (previousBlockNode, specNode) = try await resolveHeaderLinkage(
            fetcher: fetcher
        ) else { return (false, .empty, nil) }

        // Start transaction body resolution concurrently
        // with the ancestor-timestamp walk. The transaction CAS fetches and the
        // ancestor CAS walk are completely independent — overlapping them eliminates
        // one sequential wait from the block validation critical path.
        let txResolveFetcher = fetcher
        async let txBodiesFuture: [TransactionBody]? = {
            let validator: @Sendable (Transaction) async throws -> Bool = { tx in
                try await tx.validateTransactionForNexus(fetcher: txResolveFetcher)
            }
            return try await resolveTransactionBodies(fetcher: txResolveFetcher, maxBlockSize: specNode.maxBlockSize, validator: validator)
        }()

        if !(try await validateTimestampAndNextTarget(
            spec: specNode,
            parent: previousBlockNode,
            fetcher: fetcher,
            chain: chain,
            reportTemporalFailure: reportTemporalFailure,
            validationContext: validationContext
        )) { return (false, .empty, nil) }

        guard let transactionBodies = try await txBodiesFuture else { return (false, .empty, nil) }

        // Directory is positional (the anchor context / chainPath), not in the
        // spec; nil chainPath ⇒ root.
        if !validateMaxTransactionCount(spec: specNode, transactionBodies: transactionBodies) { return (false, .empty, nil) }
        if try !validateStateGrowthFloor(spec: specNode, transactionBodies: transactionBodies) { return (false, .empty, nil) }
        if try await !validateBlockSize(spec: specNode, fetcher: fetcher) {
            return (false, .empty, nil)
        }
        if !validateChainPaths(transactionBodies: transactionBodies, expectedPath: expectedChainPath) { return (false, .empty, nil) }
        if !validateNoDepositsOrWithdrawalsOnRoot(transactionBodies: transactionBodies, expectedPath: expectedChainPath) { return (false, .empty, nil) }
        // The policies after the block's own limits: a block over them costs
        // no policy evaluation.
        if !(try await TransactionBody.batchVerifyPolicies(bodies: transactionBodies, spec: specNode, chainPath: expectedChainPath, height: height, timestamp: timestamp, fetcher: fetcher)) { return (false, .empty, nil) }

        if try await !validateWithdrawals(
            transactionBodies: transactionBodies,
            fetcher: fetcher,
            chainPath: expectedChainPath
        ) { return (false, .empty, nil) }

        var allAccountActions = transactionBodies.flatMap { $0.accountActions }
        let allDepositActions = transactionBodies.flatMap { $0.depositActions }
        let allWithdrawalActions = transactionBodies.flatMap { $0.withdrawalActions }
        let allReceiptActions = transactionBodies.flatMap { $0.receiptActions }
        // The fee rule and the coinbase credit: the post-state must carry
        // exactly the credit `coinbaseCredit` derives, so it joins the
        // transactions' account actions before the transition is replayed.
        guard case .success(let coinbase) = Block.coinbaseCredit(
            spec: specNode,
            height: height,
            recipient: rewardRecipient,
            accountActions: allAccountActions,
            depositActions: allDepositActions,
            withdrawalActions: allWithdrawalActions
        ) else { return (false, .empty, nil) }
        if let coinbase { allAccountActions.append(coinbase) }

        let (postStateValid, diff, materializedPostState) = try await validatePostState(spec: specNode, transactionBodies: transactionBodies, allAccountActions: allAccountActions, allActions: transactionBodies.flatMap { $0.actions }, allDepositActions: allDepositActions, allReceiptActions: allReceiptActions, allWithdrawalActions: allWithdrawalActions, fetcher: fetcher)
        if !postStateValid { return (false, .empty, nil) }
        return (true, diff, materializedPostState)
    }

    /// Preflight the state-dependent withdrawal rule used by full validation.
    /// Mining uses this to omit transactions that cannot settle against the
    /// exact entering parent state without repeating unrelated block checks.
    func validateWithdrawals(
        fetcher: Fetcher,
        chainPath: [String]
    ) async throws -> Bool {
        guard chainPath.first == DEFAULT_ROOT_DIRECTORY,
              let transactionBodies = try await resolveTransactionBodies(
                fetcher: fetcher,
                validator: { transaction in
                    try await transaction.validateTransactionForNexus(fetcher: fetcher)
                }
              ) else { return false }
        return try await validateWithdrawals(
            transactionBodies: transactionBodies,
            fetcher: fetcher,
            chainPath: chainPath
        )
    }

    private func validateWithdrawals(
        transactionBodies: [TransactionBody],
        fetcher: Fetcher,
        chainPath: [String]
    ) async throws -> Bool {
        let withdrawalBodies = transactionBodies.filter {
            !$0.withdrawalActions.isEmpty
        }
        guard !withdrawalBodies.isEmpty else { return true }
        guard chainPath.count > 1 else { return false }
        guard let directory = chainPath.last,
              TransactionBody.withdrawalsHaveUniqueReceiptKeys(
                bodies: withdrawalBodies,
                directory: directory
              ) else { return false }

        async let prevStateFuture = prevState.resolve(fetcher: fetcher)
        async let parentStateFuture = parentState.resolve(fetcher: fetcher)
        let (resolvedPrevState, resolvedParentState) = try await (
            prevStateFuture,
            parentStateFuture
        )
        guard let prevStateNode = resolvedPrevState.node,
              let parentStateNode = resolvedParentState.node else { return false }
        return try await !withdrawalBodies.concurrentMap {
            try await $0.withdrawalsAreValid(
                directory: directory,
                prevState: prevStateNode,
                parentState: parentStateNode,
                fetcher: fetcher
            )
        }.contains(false)
    }


    func validatePostState(spec: ChainSpec, transactionBodies: [TransactionBody], allAccountActions: [AccountAction], allActions: [Action], allDepositActions: [DepositAction], allReceiptActions: [ReceiptAction], allWithdrawalActions: [WithdrawalAction], fetcher: Fetcher) async throws -> (Bool, StateDiff, LatticeState?) {
        guard let prevStateNode = try await prevState.resolve(fetcher: fetcher).node else {
            return (false, .empty, nil)
        }
        let (updatedState, diff, accountGrowth) = try await prevStateNode.proveAndUpdateStateMeasuringGrowth(allAccountActions: allAccountActions, allActions: allActions, allDepositActions: allDepositActions, allReceiptActions: allReceiptActions, allWithdrawalActions: allWithdrawalActions, transactionBodies: transactionBodies, fetcher: fetcher)
        // Growth is known only after the transition: account entries the
        // block creates or removes depend on the balances it starts from.
        if try !validateStateDeltaSize(spec: spec, transactionBodies: transactionBodies, accountGrowth: accountGrowth) {
            return (false, .empty, nil)
        }
        // Compare the expected postState CID (computed from prev state + TXs) against the
        // block's declared postState CID. Avoids a CAS fetch for the new postState — the
        // new state nodes are computed inline and may not yet be stored to DiskBroker.
        let expectedPostStateCID = try LatticeStateHeader(node: updatedState).rawCID
        let postStateValid = expectedPostStateCID == postState.rawCID
        return (postStateValid, diff, postStateValid ? updatedState : nil)
    }

    func validateBalanceChangesForGenesis(spec: ChainSpec, allAccountActions: [AccountAction]) throws -> Bool {
        let premineAmount = spec.premineAmount()
        var totalCredits = WorkSum.zero
        for action in allAccountActions {
            guard action.verify() else { return false }
            if action.isCredit { totalCredits = totalCredits + UInt256(action.absoluteAmount) }
        }
        return totalCredits <= WorkSum(UInt256(premineAmount))
    }

    func validateSpec(parent: Block) -> Bool {
        validateSpec(parent: HeaderLinkageParent(parent))
    }

    func validateSpec(parent: HeaderLinkageParent) -> Bool {
        return parent.specCID == spec.rawCID
    }

    /// Pure and synchronous on purpose: the caller does the I/O of resolving
    /// the anchor, and this decides. Keeping the decision free of lookups is
    /// what lets a test put the builder's anchor and the validator's anchor
    /// side by side and assert they produce the same target.
    func validateNextTarget(
        spec: ChainSpec,
        parent: Block,
        difficultyAnchor: DifficultyAnchor
    ) -> Bool {
        validateNextTarget(
            spec: spec,
            parent: HeaderLinkageParent(parent),
            difficultyAnchor: difficultyAnchor
        )
    }

    func validateNextTarget(
        spec: ChainSpec,
        parent: HeaderLinkageParent,
        difficultyAnchor: DifficultyAnchor
    ) -> Bool {
        // A block's target need not equal the scheduled `parent.nextTarget` — it
        // may be that or voluntarily HARDER (a smaller target = more work), never
        // easier. A larger (easier) target is rejected. Mining harder only adds
        // weight at proportional cost and cannot lower difficulty: `nextTarget` is
        // recomputed below from the anchor rather than from this block's target,
        // so overachieving buys weight without bending the schedule.
        if target > parent.nextTarget { return false }
        let (parentDepth, overflow) = parent.height.addingReportingOverflow(1)
        guard !overflow else { return false }
        let expected = spec.calculateAsertTarget(
            anchorTarget: difficultyAnchor.target,
            anchorTimestamp: difficultyAnchor.timestamp,
            anchorHeight: difficultyAnchor.blockHeight,
            blockTimestamp: timestamp,
            blockHeight: parentDepth
        )
        return nextTarget == expected
    }

    func validateState(parent: Block) -> Bool {
        validateState(parent: HeaderLinkageParent(parent))
    }

    func validateState(parent: HeaderLinkageParent) -> Bool {
        return parent.postStateCID == prevState.rawCID
    }

    func validateHeight(parent: Block) -> Bool {
        validateHeight(parent: HeaderLinkageParent(parent))
    }

    func validateHeight(parent: HeaderLinkageParent) -> Bool {
        let (expected, overflow) = parent.height.addingReportingOverflow(1)
        return !overflow && expected == height
    }

    /// Header-local rules shared by every path that can accept a genesis. A
    /// root genesis has no parent chain, so it commits the empty parent state;
    /// a child genesis commits a real one — its carrier's `prevState`, never
    /// the empty state — and proves it by continuity (§5.1 rule 4, §5.3).
    func hasGenesisShape(isRoot: Bool) -> Bool {
        version == Block.currentVersion
            && parent == nil
            && height == 0
            && prevState.rawCID == LatticeState.emptyHeader.rawCID
            && (parentState.rawCID == LatticeState.emptyHeader.rawCID) == isRoot
            && nextTarget == target
            // Genesis mints only its premine: there is no reward to pay.
            && rewardRecipient == nil
    }

    /// Consensus timestamp rules:
    ///   (1) timestamp strictly greater than the previous block — the sole
    ///       agreed-state rule; applied to every block it makes timestamps
    ///       strictly increasing along the chain, which subsumes Bitcoin's
    ///       MedianTimePast lower bound (a would-be predating block already
    ///       fails (1), so an MTP median check can never reject anything (1)
    ///       accepts — it was redundant and is gone).
    ///   (2) timestamp ≤ now — a node will not build on a block from its own
    ///       future. This is node-local, retriable admission (`notYetValid`),
    ///       not agreed state: it references the node's clock, defers rather than
    ///       rejects, and closes the far-future lock-out that (1) alone would
    ///       allow. No protocol-imposed drift constant.
    /// No lower bound against wall-clock: old blocks must still validate for cold
    /// sync, so only the future side is gated.
    func validateTimestamp(
        parent: Block,
        validationContext: ValidationContext = .current
    ) -> Bool {
        validateTimestamp(
            parent: HeaderLinkageParent(parent),
            validationContext: validationContext
        )
    }

    func validateTimestamp(
        parent: HeaderLinkageParent,
        validationContext: ValidationContext = .current
    ) -> Bool {
        if parent.timestamp >= timestamp { return false }
        if !validationContext.permits(timestamp: timestamp) { return false }
        return true
    }

    /// The early, transition-free reject: a block whose growth floor is over
    /// the limit is over it whatever balances it starts from. The exact check
    /// is `validateStateDeltaSize`, after the transition.
    func validateStateGrowthFloor(spec: ChainSpec, transactionBodies: [TransactionBody]) throws -> Bool {
        try TransactionBody.stateGrowthFloor(of: transactionBodies)
            .map { $0 <= spec.maxStateGrowth } ?? false
    }

    func validateStateDeltaSize(spec: ChainSpec, transactionBodies: [TransactionBody], accountGrowth: Int) throws -> Bool {
        try TransactionBody.stateGrowth(of: transactionBodies, accountGrowth: accountGrowth)
            .map { $0 <= spec.maxStateGrowth } ?? false
    }

    func validateMaxTransactionCount(spec: ChainSpec, transactionBodies: [TransactionBody]) -> Bool {
        return transactionBodies.count <= spec.maxNumberOfTransactionsPerBlock
    }

    func validateBlockSize(
        spec: ChainSpec,
        fetcher: any Fetcher
    ) async throws -> Bool {
        // Only the counter's own result is a verdict: an error a fetcher
        // throws, of whatever type, is thrown on and decides nothing.
        if case .success = try await measureLogicalContent(fetcher: fetcher, limit: spec.maxBlockSize) {
            return true
        }
        return false
    }

    /// Deposits and withdrawals are cross-chain constructs: a deposit
    /// escrows value for withdrawal on the PARENT chain, and a withdrawal
    /// requires a receipt in the parent chain's state. The root chain
    /// (chainPath length 1) has no parent, so a deposit there burns value with
    /// no withdrawal path and a withdrawal there has no receipt to settle
    /// against. Consensus rejects both so a producer cannot place them directly
    /// in a root-chain block.
    func validateNoDepositsOrWithdrawalsOnRoot(transactionBodies: [TransactionBody], expectedPath: [String]) -> Bool {
        guard expectedPath.count == 1 else { return true }
        for body in transactionBodies {
            if !body.depositActions.isEmpty { return false }
            if !body.withdrawalActions.isEmpty { return false }
        }
        return true
    }

    func validateChainPaths(transactionBodies: [TransactionBody], expectedPath: [String]) -> Bool {
        for body in transactionBodies {
            // Empty chainPath is rejected: it would allow a single signed transaction
            // to be included in any chain simultaneously, enabling cross-chain double-spend.
            if body.chainPath.isEmpty { return false }
            if body.chainPath != expectedPath { return false }
        }
        return true
    }

    /// The transactions are part of what `maxBlockSize` counts, so they are
    /// fetched under it: once their CID-verified unique bytes exceed the limit
    /// the block is invalid (nil) and nothing further is requested. The exact
    /// rule, over the whole counted content, is `validateBlockSize`.
    func resolveTransactionBodies(fetcher: Fetcher, maxBlockSize: Int = .max, validator: @escaping @Sendable (Transaction) async throws -> Bool) async throws -> [TransactionBody]? {
        let counter = BlockContentByteCounter(limit: maxBlockSize)
        let resolved: HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>>
        do {
            resolved = try await transactions.resolveRecursive(fetcher: fetcher, cache: counter)
        } catch {
            if await counter.failure != nil { return nil }
            throw error
        }
        guard let transactionsNode = resolved.node else { return nil }
        let txHeaders = try transactionsNode.allKeysAndValues().values
        if txHeaders.contains(where: { $0.node == nil }) { throw ValidationErrors.transactionNotResolved }
        let txs = txHeaders.map { $0.node! }
        if try await txs.concurrentMap({ try await validator($0) }).contains(false) { return nil }
        let transactionBodiesMaybe = txs.map { $0.body.node }
        if transactionBodiesMaybe.contains(where: { $0 == nil }) { throw ValidationErrors.transactionNotResolved }
        return transactionBodiesMaybe.map { $0! }
    }


}
