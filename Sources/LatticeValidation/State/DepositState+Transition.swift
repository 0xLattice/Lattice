import cashew
import LatticePrimitives

public extension DepositStateHeader {
    func proveExistenceOfCorrespondingDeposit(withdrawalActions: [WithdrawalAction], fetcher: Fetcher) async throws -> DepositStateHeader {
        var proofs = [[String]: SparseMerkleProof]()
        for withdrawalAction in withdrawalActions {
            let depositKey = DepositKey(withdrawalAction: withdrawalAction).description
            proofs[[depositKey]] = .mutation
        }
        return try await proof(paths: proofs, fetcher: fetcher)
    }

    /// Consume deposits without deleting their identities. Receipts are permanent
    /// parent-chain facts, so a spent marker is the child chain's lifetime
    /// nullifier and prevents an old receipt from consuming a recreated deposit.
    func proveAndSpendForWithdrawals(allWithdrawalActions: [WithdrawalAction], fetcher: Fetcher) async throws -> (DepositStateHeader, StateDiff) {
        if allWithdrawalActions.isEmpty { return (self, .empty) }
        var withdrawn: [String: UInt64] = [:]
        for wa in allWithdrawalActions {
            let key = DepositKey(withdrawalAction: wa).description
            if withdrawn.updateValue(wa.amountWithdrawn, forKey: key) != nil { throw StateErrors.conflictingActions }
        }
        // Each deposit must hold exactly the amount withdrawn; it is marked spent.
        let update = try await updating(keys: withdrawn.keys, fetcher: fetcher) { key, stored in
            guard let stored, stored == withdrawn[key]! else { throw StateErrors.conflictingActions }
            return .update(SPENT_DEPOSIT_MARKER)
        }
        return (update.header, StateDiff(cidChanges: update.cidChanges))
    }

    func proveAndUpdateState(allDepositActions: [DepositAction], fetcher: Fetcher) async throws -> (DepositStateHeader, StateDiff) {
        if allDepositActions.isEmpty { return (self, .empty) }
        var deposited: [String: UInt64] = [:]
        for depositAction in allDepositActions {
            if depositAction.amountDeposited == 0 { throw StateErrors.conflictingActions }
            if depositAction.amountDemanded == 0 { throw StateErrors.conflictingActions }
            let depositKey = DepositKey(depositAction: depositAction).description
            if deposited.updateValue(depositAction.amountDeposited, forKey: depositKey) != nil { throw StateErrors.conflictingActions }
        }
        // A deposit's key must be new.
        let update = try await updating(keys: deposited.keys, fetcher: fetcher) { key, _ in .insert(deposited[key]!) }
        return (update.header, StateDiff(cidChanges: update.cidChanges))
    }
}
