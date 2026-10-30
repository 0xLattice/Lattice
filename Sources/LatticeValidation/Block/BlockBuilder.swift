import Foundation
import cashew
import UInt256
import LatticePrimitives
import LatticePoW

public enum BlockBuilderError: Error {
    case missingPrevState
    case missingSpec
    case heightOverflow
    case invalidTransactionContent
    /// The height-1 ancestor could not be reached, so the difficulty schedule
    /// has no origin to measure from. Refusing beats inventing one: a guessed
    /// anchor produces a target no validator would agree with.
    case missingDifficultyAnchor
    /// The transactions and `rewardRecipient` admit no valid coinbase
    /// (see `Block.coinbaseCredit`), so no block built from them would validate.
    case invalidCoinbase(CoinbaseError)
    /// A child is carried under a name that is not a directory atom.
    case invalidChildDirectory(String)
    /// A transaction commits `child/<directory>` to a child the block does
    /// not carry there (see `Block.validateChildCommitments`).
    case unmatchedChildCommitment(String)
}

public struct BlockBuildResult: Sendable {
    public let block: Block
    public let stateDiff: StateDiff
    public let materializedPostState: LatticeState?

    public init(block: Block, stateDiff: StateDiff, materializedPostState: LatticeState?) {
        self.block = block
        self.stateDiff = stateDiff
        self.materializedPostState = materializedPostState
    }
}

public struct BlockBuilder {

    // MARK: - Build Genesis Block

    public static func buildGenesis(
        spec: ChainSpec,
        transactions: [Transaction] = [],
        children: [String: Block] = [:],
        timestamp: Int64,
        target: UInt256,
        nonce: UInt64 = 0,
        version: UInt16 = Block.currentVersion,
        fetcher: Fetcher
    ) async throws -> Block {
        try await buildGenesisWithTransition(
            spec: spec,
            transactions: transactions,
            children: children,
            timestamp: timestamp,
            target: target,
            nonce: nonce,
            version: version,
            fetcher: fetcher
        ).block
    }

    public static func buildGenesisWithTransition(
        spec: ChainSpec,
        transactions: [Transaction] = [],
        children: [String: Block] = [:],
        timestamp: Int64,
        target: UInt256,
        nonce: UInt64 = 0,
        version: UInt16 = Block.currentVersion,
        fetcher: Fetcher
    ) async throws -> BlockBuildResult {
        try await buildGenesisWithTransition(
            spec: spec,
            transactions: transactions,
            children: children,
            parentState: LatticeState.emptyHeader,
            timestamp: timestamp,
            target: target,
            nonce: nonce,
            version: version,
            fetcher: fetcher
        )
    }

    /// Build a child-chain genesis that commits the entering state of the
    /// parent carrier which will contain it. The child's own `prevState` remains
    /// empty; `parentState` is the vertical binding verified by
    /// `ChildBlockProof`.
    public static func buildChildGenesis(
        spec: ChainSpec,
        parentState: LatticeStateHeader,
        transactions: [Transaction] = [],
        children: [String: Block] = [:],
        timestamp: Int64,
        target: UInt256,
        nonce: UInt64 = 0,
        version: UInt16 = Block.currentVersion,
        fetcher: Fetcher
    ) async throws -> Block {
        try await buildChildGenesisWithTransition(
            spec: spec,
            parentState: parentState,
            transactions: transactions,
            children: children,
            timestamp: timestamp,
            target: target,
            nonce: nonce,
            version: version,
            fetcher: fetcher
        ).block
    }

    public static func buildChildGenesisWithTransition(
        spec: ChainSpec,
        parentState: LatticeStateHeader,
        transactions: [Transaction] = [],
        children: [String: Block] = [:],
        timestamp: Int64,
        target: UInt256,
        nonce: UInt64 = 0,
        version: UInt16 = Block.currentVersion,
        fetcher: Fetcher
    ) async throws -> BlockBuildResult {
        try await buildGenesisWithTransition(
            spec: spec,
            transactions: transactions,
            children: children,
            parentState: parentState,
            timestamp: timestamp,
            target: target,
            nonce: nonce,
            version: version,
            fetcher: fetcher
        )
    }

    private static func buildGenesisWithTransition(
        spec: ChainSpec,
        transactions: [Transaction],
        children: [String: Block],
        parentState: LatticeStateHeader,
        timestamp: Int64,
        target: UInt256,
        nonce: UInt64,
        version: UInt16,
        fetcher: Fetcher
    ) async throws -> BlockBuildResult {
        let emptyState = LatticeState.emptyState()
        let prevState = try LatticeStateHeader(node: emptyState)

        let transactionBodies = try await validatedTransactionBodies(
            transactions,
            fetcher: fetcher
        )
        try requireChildCommitmentsMatch(transactionBodies, children: children)
        let (postState, stateDiff) = try await computePostState(
            prevState: prevState,
            transactionBodies: transactionBodies,
            coinbase: nil,
            maxStateGrowth: spec.maxStateGrowth,
            fetcher: fetcher
        )

        let block = Block(
            version: version,
            parent: nil,
            transactions: try buildTransactionsDictionary(transactions),
            target: target,
            nextTarget: target,
            spec: try VolumeImpl<ChainSpec>(node: spec),
            parentState: parentState.removingNode(),
            prevState: prevState.removingNode(),
            postState: postState,
            children: try buildChildren(children),
            height: 0,
            timestamp: timestamp,
            rewardRecipient: nil,
            nonce: nonce
        )
        return BlockBuildResult(
            block: block,
            stateDiff: stateDiff,
            materializedPostState: postState.node
        )
    }

    // MARK: - Build Next Block (extends a chain)

    public static func buildBlock(
        previous: Block,
        transactions: [Transaction] = [],
        children: [String: Block] = [:],
        parentChainBlock: Block? = nil,
        timestamp: Int64,
        target: UInt256? = nil,
        nextTarget: UInt256? = nil,
        nonce: UInt64 = 0,
        difficultyAnchor: DifficultyAnchor? = nil,
        rewardRecipient: String? = nil,
        fetcher: Fetcher
    ) async throws -> Block {
        try await buildBlockWithTransition(
            previous: previous,
            transactions: transactions,
            children: children,
            parentChainBlock: parentChainBlock,
            timestamp: timestamp,
            target: target,
            nextTarget: nextTarget,
            nonce: nonce,
            difficultyAnchor: difficultyAnchor,
            rewardRecipient: rewardRecipient,
            fetcher: fetcher
        ).block
    }

    public static func buildBlockWithTransition(
        previous: Block,
        transactions: [Transaction] = [],
        children: [String: Block] = [:],
        parentChainBlock: Block? = nil,
        timestamp: Int64,
        target: UInt256? = nil,
        nextTarget: UInt256? = nil,
        nonce: UInt64 = 0,
        difficultyAnchor: DifficultyAnchor? = nil,
        rewardRecipient: String? = nil,
        fetcher: Fetcher
    ) async throws -> BlockBuildResult {
        let (height, heightOverflow) = previous.height.addingReportingOverflow(1)
        guard !heightOverflow else { throw BlockBuilderError.heightOverflow }
        let prevState = previous.postState
        let parentState: LatticeStateHeader
        if let parentChainBlock = parentChainBlock {
            parentState = parentChainBlock.prevState.removingNode()
        } else {
            parentState = previous.parentState
        }

        let blockTarget = target ?? previous.nextTarget
        let specNode: ChainSpec
        if let node = previous.spec.node {
            specNode = node
        } else {
            guard let node = try await previous.spec.resolve(fetcher: fetcher).node else {
                throw BlockBuilderError.missingSpec
            }
            specNode = node
        }
        let blockNextTarget: UInt256
        if let nextTarget {
            blockNextTarget = nextTarget
        } else {
            // The schedule is measured from the height-1 ancestor. Building
            // block 1 itself, that ancestor is this block: its own target
            // becomes the anchor and the schedule starts here.
            let anchor: DifficultyAnchor?
            if height == 1 {
                anchor = DifficultyAnchor(
                    blockHeight: 1,
                    timestamp: timestamp, target: blockTarget
                )
            } else if let supplied = difficultyAnchor {
                anchor = supplied
            } else {
                anchor = try await Self.resolveDifficultyAnchor(
                    from: previous, fetcher: fetcher
                )
            }
            guard let anchor else { throw BlockBuilderError.missingDifficultyAnchor }
            blockNextTarget = specNode.calculateAsertTarget(
                anchorTarget: anchor.target,
                anchorTimestamp: anchor.timestamp,
                anchorHeight: anchor.blockHeight,
                blockTimestamp: timestamp,
                blockHeight: height
            )
        }
        let previousCID = try BlockHeader(node: previous).rawCID

        let transactionBodies = try await validatedTransactionBodies(
            transactions,
            fetcher: fetcher
        )
        try requireChildCommitmentsMatch(transactionBodies, children: children)
        // The same rule the validator applies: the fee rule always holds, and
        // a recipient is credited exactly the reward plus fees (nil burns it).
        let coinbase: AccountAction?
        switch Block.coinbaseCredit(
            spec: specNode,
            height: height,
            recipient: rewardRecipient,
            accountActions: transactionBodies.flatMap(\.accountActions),
            depositActions: transactionBodies.flatMap(\.depositActions),
            withdrawalActions: transactionBodies.flatMap(\.withdrawalActions)
        ) {
        case .success(let credit): coinbase = credit
        case .failure(let error): throw BlockBuilderError.invalidCoinbase(error)
        }
        let (postState, stateDiff) = try await computePostState(
            prevState: prevState,
            transactionBodies: transactionBodies,
            coinbase: coinbase,
            maxStateGrowth: specNode.maxStateGrowth,
            fetcher: fetcher
        )

        let block = Block(
            version: previous.version,
            parent: VolumeImpl<Block>(rawCID: previousCID),
            transactions: try buildTransactionsDictionary(transactions),
            target: blockTarget,
            nextTarget: blockNextTarget,
            spec: previous.spec,
            parentState: parentState,
            prevState: prevState.removingNode(),
            postState: postState,
            children: try buildChildren(children),
            height: height,
            timestamp: timestamp,
            rewardRecipient: rewardRecipient,
            nonce: nonce
        )
        return BlockBuildResult(
            block: block,
            stateDiff: stateDiff,
            materializedPostState: postState.node
        )
    }

    /// Builds only what validation accepts: every `child/X` = C commitment
    /// needs C at `children[X]`.
    private static func requireChildCommitmentsMatch(_ bodies: [TransactionBody], children: [String: Block]) throws {
        for commitment in Block.childCommitments(in: bodies) {
            guard let child = children[commitment.directory],
                  try BlockHeader(node: child).rawCID.utf8.elementsEqual(commitment.child.utf8) else {
                throw BlockBuilderError.unmatchedChildCommitment(commitment.directory)
            }
        }
    }

    private static func validatedTransactionBodies(
        _ transactions: [Transaction],
        fetcher: Fetcher
    ) async throws -> [TransactionBody] {
        var bodies: [TransactionBody] = []
        bodies.reserveCapacity(transactions.count)
        for transaction in transactions {
            guard let body = try await transaction.body.resolve(
                fetcher: fetcher
            ).node, body.stateAtomsAreValid() else {
                throw BlockBuilderError.invalidTransactionContent
            }
            bodies.append(body)
        }
        return bodies
    }

    /// Walk to the height-1 ancestor, which is the block the difficulty
    /// schedule is measured from.
    ///
    /// ONE implementation, called by both the builder and the chain-less
    /// validator on purpose. The anchor decides every target, so a builder and
    /// a validator that resolved it differently would disagree about whether a
    /// block is valid, which is a chain split rather than a bug in one of them.
    ///
    /// Only for callers without chain state: a validator holding a chain takes
    /// the inherited anchor from the graph and never walks. Both produce the
    /// same answer, because both are the same pure function of a valid
    /// ancestry. Every hop must be a valid link — height exactly one below and
    /// the same spec — or there is no anchor (nil): an ancestry that breaks
    /// either rule is invalid, and following its links would let a forger
    /// steer the walk.
    /// Throws rather than returning nil when an ancestor cannot be FETCHED.
    /// That distinction is the whole point: a block whose ancestry we merely
    /// cannot reach yet is unavailable evidence and must stay retriable, while
    /// nil means the chain structurally has no anchor. Collapsing the two would
    /// permanently reject a perfectly valid block for a transient fetch failure.
    static func resolveDifficultyAnchor(
        from block: Block,
        fetcher: Fetcher
    ) async throws -> DifficultyAnchor? {
        var current = block
        // Genesis precedes the anchor and has no schedule to measure against.
        guard current.height > 0 else { return nil }
        while current.height > 1 {
            guard let parentRef = current.parent else { return nil }
            // Prefer a node already carried in memory over fetching it, as the
            // spec lookup above this does. A caller assembling blocks without
            // backing storage still has the whole ancestry attached, and a walk
            // that insisted on the fetcher would fail on chains that are
            // perfectly well formed.
            let next: Block
            if let attached = parentRef.node {
                next = attached
            } else {
                guard let resolved = try await parentRef.resolve(fetcher: fetcher).node else {
                    return nil
                }
                next = resolved
            }
            guard next.height == current.height - 1,
                  next.spec.rawCID == current.spec.rawCID else { return nil }
            current = next
        }
        guard current.height == 1 else { return nil }
        return DifficultyAnchor(
            blockHeight: 1,
            timestamp: current.timestamp,
            target: current.target
        )
    }

    // MARK: - Mining (find valid nonce)

    public static func mine(
        block: Block,
        target: UInt256,
        maxAttempts: UInt64 = UInt64.max
    ) -> Block? {
        for nonce in 0..<maxAttempts {
            let data = Block.makeProofOfWorkPreimage(block: block, nonce: nonce)
            let hash = UInt256.hash(data)
            if target >= hash {
                return Block(
                    version: block.version,
                    parent: block.parent,
                    transactions: block.transactions,
                    target: block.target,
                    nextTarget: block.nextTarget,
                    spec: block.spec,
                    parentState: block.parentState,
                    prevState: block.prevState,
                    postState: block.postState,
                    children: block.children,
                    height: block.height,
                    timestamp: block.timestamp,
                    rewardRecipient: block.rewardRecipient,
                    nonce: nonce
                )
            }
        }
        return nil
    }

    // MARK: - Post State Computation

    /// With `maxStateGrowth`, a transition that would grow state past it
    /// throws `StateErrors.stateGrowthExceeded`, as validation would refuse it.
    static func computePostState(
        prevState: LatticeStateHeader,
        transactionBodies: [TransactionBody],
        coinbase: AccountAction?,
        maxStateGrowth: Int? = nil,
        fetcher: Fetcher
    ) async throws -> (LatticeStateHeader, StateDiff) {
        if transactionBodies.isEmpty && coinbase == nil {
            return (prevState, .empty)
        }

        guard let prevStateNode = prevState.node else {
            let resolved = try await prevState.resolve(fetcher: fetcher)
            guard let resolvedNode = resolved.node else {
                throw BlockBuilderError.missingPrevState
            }
            return try await computePostStateFromState(
                state: resolvedNode,
                transactionBodies: transactionBodies,
                coinbase: coinbase,
                maxStateGrowth: maxStateGrowth,
                fetcher: fetcher
            )
        }

        return try await computePostStateFromState(
            state: prevStateNode,
            transactionBodies: transactionBodies,
            coinbase: coinbase,
            maxStateGrowth: maxStateGrowth,
            fetcher: fetcher
        )
    }

    static func computePostStateFromState(
        state: LatticeState,
        transactionBodies: [TransactionBody],
        coinbase: AccountAction?,
        maxStateGrowth: Int? = nil,
        fetcher: Fetcher
    ) async throws -> (LatticeStateHeader, StateDiff) {
        // Collect each action family in one pass.
        var allAccountActions: [AccountAction] = []
        var allActions: [Action] = []
        var allDepositActions: [DepositAction] = []
        var allReceiptActions: [ReceiptAction] = []
        var allWithdrawalActions: [WithdrawalAction] = []
        for body in transactionBodies {
            allAccountActions.append(contentsOf: body.accountActions)
            allActions.append(contentsOf: body.actions)
            allDepositActions.append(contentsOf: body.depositActions)
            allReceiptActions.append(contentsOf: body.receiptActions)
            allWithdrawalActions.append(contentsOf: body.withdrawalActions)
        }
        if let coinbase { allAccountActions.append(coinbase) }

        let (updatedState, stateDiff, accountGrowth) = try await state.proveAndUpdateStateMeasuringGrowth(
            allAccountActions: allAccountActions,
            allActions: allActions,
            allDepositActions: allDepositActions,
            allReceiptActions: allReceiptActions,
            allWithdrawalActions: allWithdrawalActions,
            transactionBodies: transactionBodies,
            fetcher: fetcher
        )
        if let maxStateGrowth {
            guard let growth = try TransactionBody.stateGrowth(of: transactionBodies, accountGrowth: accountGrowth),
                  growth <= maxStateGrowth else {
                throw StateErrors.stateGrowthExceeded
            }
        }

        return (try LatticeStateHeader(node: updatedState), stateDiff)
    }

    // MARK: - Merkle Dictionary Construction

    static func buildTransactionsDictionary(
        _ transactions: [Transaction]
    ) throws -> HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>> {
        if transactions.isEmpty {
            return try HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>>(
                node: MerkleDictionaryImpl<VolumeImpl<Transaction>>()
            )
        }

        var dict = MerkleDictionaryImpl<VolumeImpl<Transaction>>()
        for (i, tx) in transactions.enumerated() {
            let txHeader = try VolumeImpl<Transaction>(node: tx)
            dict = try dict.inserting(key: String(i), value: txHeader)
        }
        return try HeaderImpl(node: dict)
    }

    /// The block's `children`: every key a valid child directory. The count needs no
    /// check here: the DAG-CBOR encoder refuses a map longer than
    /// `DagCBOR.maxCollectionCount`, so no CID names one no node could decode.
    static func buildChildren(
        _ children: [String: Block]
    ) throws -> HeaderImpl<FlatDictionary<BlockHeader>> {
        if let invalid = children.keys.first(where: { !isValidChildDirectory($0) }) {
            throw BlockBuilderError.invalidChildDirectory(invalid)
        }
        return try HeaderImpl(node: FlatDictionary(
            try children.mapValues { try BlockHeader(node: $0) }
        ))
    }
}
