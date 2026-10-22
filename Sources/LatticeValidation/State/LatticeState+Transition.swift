import cashew
import Foundation
import LatticePrimitives

extension LatticeState {
    public func proveAndUpdateState(allAccountActions: [AccountAction], allActions: [Action], allDepositActions: [DepositAction], allReceiptActions: [ReceiptAction], allWithdrawalActions: [WithdrawalAction], transactionBodies: [TransactionBody], fetcher: Fetcher) async throws -> (LatticeState, StateDiff) {
        let (updated, diff, _) = try await proveAndUpdateStateMeasuringGrowth(allAccountActions: allAccountActions, allActions: allActions, allDepositActions: allDepositActions, allReceiptActions: allReceiptActions, allWithdrawalActions: allWithdrawalActions, transactionBodies: transactionBodies, fetcher: fetcher)
        return (updated, diff)
    }

    /// `proveAndUpdateState`, plus the account-state growth the transition
    /// measured (`AccountStateHeader.proveAndUpdateStateMeasuringGrowth`).
    public func proveAndUpdateStateMeasuringGrowth(allAccountActions: [AccountAction], allActions: [Action], allDepositActions: [DepositAction], allReceiptActions: [ReceiptAction], allWithdrawalActions: [WithdrawalAction], transactionBodies: [TransactionBody], fetcher: Fetcher) async throws -> (LatticeState, StateDiff, accountGrowth: Int) {
        async let accountResult = accountState.proveAndUpdateStateMeasuringGrowth(
            allAccountActions: allAccountActions,
            allReceiptActions: allReceiptActions,
            transactionBodies: transactionBodies,
            fetcher: fetcher
        )
        async let generalResult = generalState.proveAndUpdateState(allActions: allActions, fetcher: fetcher)
        async let receiptResult = receiptState.proveAndUpdateState(allReceiptActions: allReceiptActions, fetcher: fetcher)
        let (afterWithdrawals, withdrawalDiff) = try await depositState.proveAndSpendForWithdrawals(allWithdrawalActions: allWithdrawalActions, fetcher: fetcher)
        async let depositResult = afterWithdrawals.proveAndUpdateState(allDepositActions: allDepositActions, fetcher: fetcher)

        let (finalAccountState, accountDiff, accountGrowth) = try await accountResult
        let (finalGeneralState, generalDiff) = try await generalResult
        let (finalDepositState, depositDiff) = try await depositResult
        let (finalReceiptState, receiptDiff) = try await receiptResult

        var diff = withdrawalDiff
        diff.merge(accountDiff)
        diff.merge(generalDiff)
        diff.merge(depositDiff)
        diff.merge(receiptDiff)

        let updated = Self(
            accountState: finalAccountState,
            generalState: finalGeneralState,
            depositState: finalDepositState,
            receiptState: finalReceiptState
        )
        let previousRoot = try LatticeStateHeader(node: self).rawCID
        let updatedRoot = try LatticeStateHeader(node: updated).rawCID
        if previousRoot != updatedRoot {
            diff.replaced[previousRoot, default: 0] += 1
            diff.created[updatedRoot, default: 0] += 1
        }
        return (updated, diff, accountGrowth)
    }
}
