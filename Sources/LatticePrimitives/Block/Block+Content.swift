import Foundation
import cashew

public enum BlockContentSizeError: Error, Sendable, Equatable {
    case conflictingCID(String)
    case overflow
    /// The unique content counted so far already exceeds the limit.
    case exceedsLimit
}

/// Sums the canonical bytes of each unique CID it is given and throws
/// `exceedsLimit` once the sum passes `limit`. The sum only grows, so a limit
/// passed on part of a block's content is passed on all of it.
///
/// `failure` is the counter's own result. Callers read the verdict from it,
/// never from the type of a thrown error, which a fetcher could also throw.
package actor BlockContentByteCounter: VolumeStorer, Storer {
    private let limit: Int
    private var dataByCID: [String: Data] = [:]
    private var byteCount = 0
    package private(set) var failure: BlockContentSizeError?

    package init(limit: Int = .max) {
        self.limit = limit
    }

    package func store(volume: SerializedVolume) throws {
        try store(entries: volume.entries)
    }

    package func store(entries: [String: Data]) throws {
        if failure == nil { failure = add(entries) }
        if let failure { throw failure }
    }

    private func add(_ entries: [String: Data]) -> BlockContentSizeError? {
        for (cid, data) in entries {
            if let existing = dataByCID[cid] {
                guard existing == data else { return .conflictingCID(cid) }
                continue
            }
            let next = byteCount.addingReportingOverflow(data.count)
            guard !next.overflow else { return .overflow }
            dataByCID[cid] = data
            byteCount = next.partialValue
        }
        return byteCount <= limit ? nil : .exceedsLimit
    }

    func total() -> Int { byteCount }
}

public extension Block {
    /// Cashew resolution policy for the content carried by this block.
    /// State roots, parents, and child blocks remain independent Volumes.
    static var contentResolutionPaths: [[String]: ResolutionStrategy] {
        [
            [SPEC_PROPERTY]: .targeted,
            [TRANSACTIONS_PROPERTY]: .recursive,
        ]
    }

    /// What the block carries: `contentResolutionPaths` and its child index,
    /// one node, without the child block Volumes it names. No state, parent
    /// or child block.
    static var carriedContentPaths: [[String]: ResolutionStrategy] {
        var paths = contentResolutionPaths
        paths[[CHILDREN_PROPERTY]] = .targeted
        return paths
    }

    /// Exact content needed to validate these transactions and the block's
    /// coinbase credit to `rewardRecipient`. The child index is one node,
    /// fetched without resolving its independently stored child block Volumes.
    static func validationPaths(
        transactionBodies: [TransactionBody],
        rewardRecipient: String?
    ) -> [[String]: ResolutionStrategy] {
        var paths = contentResolutionPaths
        paths[[PREV_STATE_PROPERTY]] = .targeted
        paths[[CHILDREN_PROPERTY]] = .targeted

        func setPrevStatePath(_ path: [String]) {
            paths[[PREV_STATE_PROPERTY] + path] = .targeted
        }

        if let rewardRecipient {
            setPrevStatePath([ACCOUNT_STATE_PROPERTY, rewardRecipient])
        }

        for body in transactionBodies {
            for action in body.accountActions {
                setPrevStatePath([ACCOUNT_STATE_PROPERTY, action.owner])
            }
            if let signer = body.signers.first {
                setPrevStatePath([ACCOUNT_STATE_PROPERTY, AccountStateHeader.nonceTrackingKey(signer)])
            }
            for action in body.actions {
                setPrevStatePath([GENERAL_STATE_PROPERTY, action.key])
            }
            for action in body.depositActions {
                setPrevStatePath([DEPOSIT_STATE_PROPERTY, DepositKey(depositAction: action).description])
            }
            for action in body.withdrawalActions {
                setPrevStatePath([DEPOSIT_STATE_PROPERTY, DepositKey(withdrawalAction: action).description])
            }
            for action in body.receiptActions {
                setPrevStatePath([
                    RECEIPT_STATE_PROPERTY,
                    ReceiptKey(receiptAction: action).storageKey,
                ])
                setPrevStatePath([ACCOUNT_STATE_PROPERTY, action.withdrawer])
                setPrevStatePath([ACCOUNT_STATE_PROPERTY, action.demander])
            }
        }

        paths.merge(parentReceiptWitnessPaths(transactionBodies: transactionBodies)) { $1 }
        return paths
    }

    /// The parent-receipt witness of these transactions' withdrawals (§3.5):
    /// for each, the path to its receipt in the block's
    /// `parentState.receiptState`, which its execution proves (§8). None for
    /// transactions with no withdrawal. The witness is validation data
    /// outside `maxBlockSize`, bounded through the withdrawals a block of
    /// that size can carry: one trie path each, every edge of the receipt
    /// trie a Volume boundary. Its nodes are bound by CID to the block's
    /// `parentState`, so whoever holds it can execute the block without the
    /// rest of that parent state.
    static func parentReceiptWitnessPaths(
        transactionBodies: [TransactionBody]
    ) -> [[String]: ResolutionStrategy] {
        var paths: [[String]: ResolutionStrategy] = [:]
        for body in transactionBodies {
            guard let directory = body.chainPath.last else { continue }
            for action in body.withdrawalActions {
                let receiptKey = ReceiptKey(withdrawalAction: action, directory: directory)
                paths[[PARENT_STATE_PROPERTY, RECEIPT_STATE_PROPERTY, receiptKey.storageKey]] = .targeted
            }
        }
        return paths
    }

    /// Canonical byte size owned by this logical block: its complete root
    /// Volume boundary plus every transaction Volume below the transaction
    /// index. CIDs shared across those boundaries are counted once. Independent
    /// spec, policy, state, parent-block, child-block, and evidence Volumes are
    /// deliberately excluded.
    ///
    /// Throws `BlockContentSizeError.exceedsLimit` when the size exceeds
    /// `limit`, as soon as the content resolved so far proves it: everything
    /// fetched here is CID-verified content this size counts, so its unique
    /// bytes exceeding `limit` means the whole does, and nothing further is
    /// requested.
    func logicalContentByteSize(fetcher: any Fetcher, limit: Int = .max) async throws -> Int {
        try await measureLogicalContent(fetcher: fetcher, limit: limit).get()
    }

    /// `logicalContentByteSize`, with the counter's own failure returned
    /// rather than thrown: whatever this throws came from the fetcher or the
    /// content and is not a size result.
    package func measureLogicalContent(
        fetcher: any Fetcher,
        limit: Int
    ) async throws -> Result<Int, BlockContentSizeError> {
        let counter = BlockContentByteCounter(limit: limit)
        do {
            let resolved = try await VolumeImpl<Block>(node: self).resolve(
                paths: [
                    [TRANSACTIONS_PROPERTY]: .recursive,
                    [CHILDREN_PROPERTY]: .targeted,
                ],
                fetcher: fetcher,
                cache: counter
            )
            guard let block = resolved.node else { throw DataErrors.nodeNotAvailable }
            try await VolumeImpl<Block>(node: block).store(
                paths: [[TRANSACTIONS_PROPERTY]: .recursive],
                storer: counter
            )
        } catch {
            if let failure = await counter.failure { return .failure(failure) }
            throw error
        }
        return .success(await counter.total())
    }
}

public extension VolumeImpl where NodeType == Block {
    /// Resolve the block content package:
    /// block internals, chain spec, and transaction trie + transaction bodies.
    /// This does not resolve state Volumes, parent/ancestor block Volumes, or
    /// the independently retained child-link trie and child block Volumes.
    func resolveBlockContent(fetcher: Fetcher) async throws -> Self {
        try await resolve(paths: Block.contentResolutionPaths, fetcher: fetcher)
    }

    /// The block's content (`Block.contentResolutionPaths`), its transactions
    /// read under its chain's `maxBlockSize`, and that spec. Once their
    /// verified unique bytes exceed it, throws
    /// `BlockContentSizeError.exceedsLimit` and requests nothing further.
    func resolveBoundedContent(fetcher: any Fetcher) async throws -> (Self, ChainSpec) {
        let header = try await resolve(paths: [[SPEC_PROPERTY]: .targeted], fetcher: fetcher)
        guard let spec = header.node?.spec.node else { throw DataErrors.nodeNotAvailable }
        let counter = BlockContentByteCounter(limit: spec.maxBlockSize)
        do {
            let content = try await header.resolve(
                paths: Block.contentResolutionPaths,
                fetcher: fetcher,
                cache: counter
            )
            return (content, spec)
        } catch {
            throw await counter.failure ?? error
        }
    }

    /// The bodies of the transactions resolved `content` carries.
    static func transactionBodies(of content: Self) throws -> [TransactionBody] {
        guard let transactionNode = content.node?.transactions.node else {
            throw DataErrors.nodeNotAvailable
        }
        return try transactionNode.allKeysAndValues().values.map { transaction -> TransactionBody in
            guard let body = transaction.node?.body.node else {
                throw DataErrors.nodeNotAvailable
            }
            return body
        }
    }
}
