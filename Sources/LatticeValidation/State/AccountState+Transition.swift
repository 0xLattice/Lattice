import cashew
import LatticePrimitives

public extension AccountStateHeader {
    /// Aggregate deltas per owner, resolve current balances, apply net changes.
    /// Also advances each transaction's first signer's nonce via
    /// `_nonce_<signer>` keys in the same trie (Ethereum-style per-account nonce).
    func proveAndUpdateState(
        allAccountActions: [AccountAction],
        allReceiptActions: [ReceiptAction] = [],
        transactionBodies: [TransactionBody] = [],
        fetcher: Fetcher
    ) async throws -> (AccountStateHeader, StateDiff) {
        let (result, diff, _) = try await proveAndUpdateStateMeasuringGrowth(
            allAccountActions: allAccountActions,
            allReceiptActions: allReceiptActions,
            transactionBodies: transactionBodies,
            fetcher: fetcher
        )
        return (result, diff)
    }

    /// `proveAndUpdateState`, plus the bytes the transition adds to account
    /// state (spec §6.6): `len(key) + ACCOUNT_ENTRY_VALUE_BYTES` for each
    /// balance or nonce entry created, minus the same for each balance removed.
    func proveAndUpdateStateMeasuringGrowth(
        allAccountActions: [AccountAction],
        allReceiptActions: [ReceiptAction] = [],
        transactionBodies: [TransactionBody] = [],
        fetcher: Fetcher
    ) async throws -> (AccountStateHeader, StateDiff, Int) {
        let netDeltas = try TransactionBody.netBalanceDeltas(
            accountActions: allAccountActions,
            receiptActions: allReceiptActions
        )
        let ownerOrder = netDeltas.keys.sorted()

        // Group transactions by their first signer and validate each such
        // signer's contiguous nonce sequence. Co-signers' nonces are not
        // consulted or advanced: the first signer's nonce already makes the
        // body every signer signed unique, so it cannot be replayed.
        var signerOrder: [String] = []
        var groups: [String: [TransactionBody]] = [:]
        for tx in transactionBodies {
            guard !tx.signers.contains(where: Self.isReservedAccountKey) else { throw StateErrors.conflictingActions }
            guard let signer = tx.signers.first else { continue }
            if groups[signer] == nil { signerOrder.append(signer) }
            groups[signer, default: []].append(tx)
        }
        for signer in signerOrder {
            groups[signer]!.sort { $0.nonce < $1.nonce }
            let sorted = groups[signer]!
            for i in 1..<sorted.count {
                let (expected, overflow) = sorted[i - 1].nonce.addingReportingOverflow(1)
                if overflow || sorted[i].nonce != expected {
                    throw StateErrors.nonceGap
                }
            }
        }

        if netDeltas.isEmpty && signerOrder.isEmpty { return (self, .empty, 0) }

        // Resolve targeted paths to read current balances + current nonces
        var resolvePaths = [[String]: ResolutionStrategy]()
        for owner in ownerOrder {
            guard !Self.isReservedAccountKey(owner) else { throw StateErrors.conflictingActions }
            resolvePaths[[owner]] = .targeted
        }
        for signer in signerOrder {
            resolvePaths[[Self.nonceTrackingKey(signer)]] = .targeted
        }
        let resolved = try await resolve(paths: resolvePaths, fetcher: fetcher)

        var proofs = [[String]: SparseMerkleProof]()
        var transforms = [[String]: Transform]()
        var growth = 0

        for owner in ownerOrder {
            let delta = netDeltas[owner]!
            let current: UInt64 = resolved.node.flatMap({ try? $0.get(key: owner) }) ?? 0

            let newBalance: UInt64
            switch delta {
            case .debit(let debit):
                guard current >= debit else { throw StateErrors.insufficientBalance }
                newBalance = current - debit
            case .credit(let credit):
                let (result, overflow) = current.addingReportingOverflow(credit)
                guard !overflow else { throw StateErrors.balanceOverflow }
                newBalance = result
            }

            if current == 0 && newBalance > 0 {
                proofs[[owner]] = .insertion
                transforms[[owner]] = .insert(String(newBalance))
                growth += owner.utf8.count + ACCOUNT_ENTRY_VALUE_BYTES
            } else if current > 0 && newBalance == 0 {
                proofs[[owner]] = .deletion
                transforms[[owner]] = .delete
                growth -= owner.utf8.count + ACCOUNT_ENTRY_VALUE_BYTES
            } else if current > 0 && newBalance > 0 {
                proofs[[owner]] = .mutation
                transforms[[owner]] = .update(String(newBalance))
            }
            // current == 0 && newBalance == 0 → no-op
        }

        for signer in signerOrder {
            // groups[signer]! and sorted.first!/.last! are safe: signerOrder only
            // gains a signer when `groups[signer] == nil` and at least one tx is
            // appended in the same loop above, so every entry is present and non-empty.
            let sorted = groups[signer]!
            let nonceKey = Self.nonceTrackingKey(signer)
            let currentNonce: UInt64? = resolved.node.flatMap { try? $0.get(key: nonceKey) }
            let expectedFirst = try Self.nextExpectedNonce(afterStored: currentNonce)
            guard sorted.first!.nonce == expectedFirst else {
                throw StateErrors.nonceGap
            }
            let newNonce = sorted.last!.nonce
            if currentNonce != nil {
                proofs[[nonceKey]] = .mutation
                transforms[[nonceKey]] = .update(String(newNonce))
            } else {
                proofs[[nonceKey]] = .insertion
                transforms[[nonceKey]] = .insert(String(newNonce))
                growth += nonceKey.utf8.count + ACCOUNT_ENTRY_VALUE_BYTES
            }
        }

        if proofs.isEmpty { return (resolved, .empty, growth) }

        let proven = try await resolved.proof(paths: proofs, fetcher: fetcher)
        guard let result = try proven.transform(transforms: transforms) else {
            throw TransformErrors.transformFailed("account state transform returned nil")
        }
        return (result, diffCIDs(old: proven, new: result), growth)
    }
}
