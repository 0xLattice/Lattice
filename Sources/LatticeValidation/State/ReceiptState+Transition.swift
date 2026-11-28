import cashew
import LatticePrimitives

public extension ReceiptStateHeader {
    func proveExistenceAndVerifyWithdrawers(directory: String, withdrawalActions: [WithdrawalAction], fetcher: Fetcher) async throws -> ReceiptStateHeader {
        var proofs = [[String]: SparseMerkleProof]()
        for withdrawalAction in withdrawalActions {
            let receiptKey = ReceiptKey(
                withdrawalAction: withdrawalAction,
                directory: directory
            )
            proofs[[receiptKey.storageKey]] = .mutation
        }
        let proven = try await proof(paths: proofs, fetcher: fetcher)
        guard let node = proven.node else { throw StateErrors.conflictingActions }
        for wa in withdrawalActions {
            let key = ReceiptKey(
                withdrawalAction: wa,
                directory: directory
            )
            guard let stored: String = try? node.get(key: key.storageKey) else {
                throw StateErrors.conflictingActions
            }
            if stored != wa.withdrawer { throw StateErrors.conflictingActions }
        }
        return proven
    }

    func proveAndUpdateState(allReceiptActions: [ReceiptAction], fetcher: Fetcher) async throws -> (ReceiptStateHeader, StateDiff) {
        if allReceiptActions.isEmpty { return (self, .empty) }
        var withdrawers: [String: String] = [:]
        for receiptAction in allReceiptActions {
            let receiptKey = ReceiptKey(receiptAction: receiptAction)
            if withdrawers.updateValue(receiptAction.withdrawer, forKey: receiptKey.storageKey) != nil {
                throw StateErrors.conflictingActions
            }
        }
        // A receipt's key must be new.
        let update = try await updating(keys: withdrawers.keys, fetcher: fetcher) { key, _ in .insert(withdrawers[key]!) }
        return (update.header, StateDiff(cidChanges: update.cidChanges))
    }
}
