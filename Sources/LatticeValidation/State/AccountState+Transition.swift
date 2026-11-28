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

        // Read and write every balance and nonce in one walk of the trie.
        var keys: [String] = []
        for owner in netDeltas.keys {
            guard !Self.isReservedAccountKey(owner) else { throw StateErrors.conflictingActions }
            keys.append(owner)
        }
        var nonceSigners: [String: String] = [:]
        for signer in signerOrder {
            let nonceKey = Self.nonceTrackingKey(signer)
            nonceSigners[nonceKey] = signer
            keys.append(nonceKey)
        }

        var growth = 0
        let update = try await updating(keys: keys, fetcher: fetcher) { key, stored in
            if let signer = nonceSigners[key] {
                // groups[signer]! and sorted.first!/.last! are safe: signerOrder only
                // gains a signer when `groups[signer] == nil` and at least one tx is
                // appended in the same loop above, so every entry is present and non-empty.
                let sorted = groups[signer]!
                let expectedFirst = try Self.nextExpectedNonce(afterStored: stored)
                guard sorted.first!.nonce == expectedFirst else {
                    throw StateErrors.nonceGap
                }
                let newNonce = sorted.last!.nonce
                if stored != nil { return .update(newNonce) }
                growth += key.utf8.count + ACCOUNT_ENTRY_VALUE_BYTES
                return .insert(newNonce)
            }
            let current = stored ?? 0
            let newBalance: UInt64
            switch netDeltas[key]! {
            case .debit(let debit):
                guard current >= debit else { throw StateErrors.insufficientBalance }
                newBalance = current - debit
            case .credit(let credit):
                let (result, overflow) = current.addingReportingOverflow(credit)
                guard !overflow else { throw StateErrors.balanceOverflow }
                newBalance = result
            }
            if current == 0 && newBalance > 0 {
                growth += key.utf8.count + ACCOUNT_ENTRY_VALUE_BYTES
                return .insert(newBalance)
            } else if current > 0 && newBalance == 0 {
                growth -= key.utf8.count + ACCOUNT_ENTRY_VALUE_BYTES
                return .delete
            } else if current > 0 && newBalance > 0 {
                return .update(newBalance)
            }
            // current == 0 && newBalance == 0 → no-op
            return .keep
        }
        return (update.header, StateDiff(cidChanges: update.cidChanges), growth)
    }
}
