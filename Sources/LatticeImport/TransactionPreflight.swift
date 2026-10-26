import cashew
import LatticePrimitives
import LatticeValidation
import LatticeBlockTree

public enum TransactionPreflightDisposition: Sendable, Equatable {
    case ready
    case future
    case invalid
    case unavailable
}

public struct TransactionPreflightResult: Sendable, Equatable {
    public let tipCID: String
    public let disposition: TransactionPreflightDisposition
}

public extension ChainLevel {
    /// Classify one transaction as the next block on `tipCID` would carry it.
    ///
    /// `tipCID` names the block to build on; nil means the canonical tip. The
    /// block must be on this chain's executed-from-genesis frontier, so its
    /// post-state is one this node reproduced; otherwise the result is
    /// `.unavailable`. A node that admits transactions and builds templates on
    /// its deepest executed canonical block passes that block here, so
    /// preflight and admission agree while the weighed canonical tip is ahead
    /// of execution. The result's `tipCID` is the block classified against.
    ///
    /// `parentState` is needed only for a child-chain withdrawal; it must be the
    /// entering parent state of the carrier the caller is considering.
    /// A transaction with negative miner surplus (it creates value) is
    /// `.invalid`. Block-wide conservation, count, and aggregate-growth checks
    /// remain the block builder's responsibility.
    ///
    /// The chain's policies run after the checks that can refuse a
    /// transaction cheaply (signatures, nonce, withdrawals, state), and before
    /// any verdict that keeps it: nothing they refuse is `.ready`, `.future`,
    /// or `.unavailable` for want of its parent's state.
    func preflightTransaction(
        _ transaction: Transaction,
        at tipCID: String? = nil,
        parentState: LatticeStateHeader? = nil,
        fetcher: any Fetcher,
        validationContext: ValidationContext = .current
    ) async -> TransactionPreflightResult {
        let tip = await chain.transactionPreflightTip(at: tipCID)
        return await TransactionPreflight.classify(
            transaction,
            tipCID: tip.cid,
            snapshot: tip.snapshot,
            chainPath: context.path,
            parentState: parentState,
            fetcher: fetcher,
            validationContext: validationContext
        )
    }
}

public enum TransactionPreflight {
    /// `ChainLevel.preflightTransaction` from its basis alone: the block to
    /// build on and its snapshot, as `ChainTree.transactionPreflightTip`
    /// reads them (a nil snapshot is `.unavailable`), and the chain's path.
    /// A host job that holds only these classifies exactly as the level
    /// would, without holding the chain's tree.
    ///
    /// `checksPolicies: false` leaves the chain's policies out: a host
    /// re-checking a transaction they already accepted on an earlier tip
    /// learns whether it still fits this one's state. It must judge the
    /// transaction by them again before any block it builds carries it.
    public static func classify(
        _ transaction: Transaction,
        tipCID: String,
        snapshot: TipBlockSnapshot?,
        chainPath: [String],
        parentState: LatticeStateHeader? = nil,
        fetcher: any Fetcher,
        validationContext: ValidationContext = .current,
        checksPolicies: Bool = true
    ) async -> TransactionPreflightResult {
        let tip = (cid: tipCID, snapshot: snapshot)
        guard let snapshot = tip.snapshot else {
            return TransactionPreflightResult(
                tipCID: tip.cid,
                disposition: .unavailable
            )
        }

        do {
            let bodyHeader = try await transaction.body.resolve(fetcher: fetcher)
            guard let body = bodyHeader.node else {
                return result(.unavailable, tipCID: tip.cid)
            }
            let resolved = Transaction(
                signatures: transaction.signatures,
                body: bodyHeader
            )
            // A transaction that creates value (negative surplus) can never
            // be carried alone under the fee rule, so it is refused here.
            guard try await resolved.validateTransactionForNexus(fetcher: fetcher),
                  body.minerSurplus() != nil,
                  body.chainPath == chainPath,
                  chainPath.count > 1
                    || (body.depositActions.isEmpty
                        && body.withdrawalActions.isEmpty) else {
                return result(.invalid, tipCID: tip.cid)
            }

            let specHeader = VolumeImpl<ChainSpec>(rawCID: snapshot.specCID)
            guard let spec = try await specHeader.resolve(fetcher: fetcher).node else {
                return result(.unavailable, tipCID: tip.cid)
            }
            // Only the floor is a permanent verdict: whether credits create
            // accounts depends on the state the transaction lands on.
            guard spec.isValid,
                  try TransactionBody.stateGrowthFloor(of: [body]).map({ $0 <= spec.maxStateGrowth }) ?? false else {
                return result(.invalid, tipCID: tip.cid)
            }

            // The policies run after every cheap check that can refuse: a
            // transaction those refuse never costs this node a policy
            // evaluation. Any verdict that keeps a transaction (ready, future,
            // or a withdrawal waiting for its parent) is reached only through
            // them, so nothing they refuse is pooled. They see the block that
            // would carry it next: the one above the tip, stamped no earlier
            // than now.
            func judged(_ disposition: TransactionPreflightDisposition) async throws -> TransactionPreflightResult {
                guard checksPolicies else { return result(disposition, tipCID: tip.cid) }
                let (afterTip, overflow) = snapshot.timestamp.addingReportingOverflow(1)
                guard !overflow else { return result(.unavailable, tipCID: tip.cid) }
                let nextTimestamp = max(afterTip, validationContext.nowMilliseconds)
                guard try await TransactionBody.batchVerifyPolicies(
                    bodies: [body],
                    spec: spec,
                    chainPath: chainPath,
                    height: snapshot.tipHeight + 1,
                    timestamp: nextTimestamp,
                    fetcher: fetcher
                ) else {
                    return result(.invalid, tipCID: tip.cid)
                }
                return result(disposition, tipCID: tip.cid)
            }

            let stateHeader = LatticeStateHeader(rawCID: snapshot.postStateCID)
            guard let state = try await stateHeader.resolve(fetcher: fetcher).node else {
                return result(.unavailable, tipCID: tip.cid)
            }

            // Only the first signer's nonce is consensus (spec §6.2).
            if let signer = body.signers.first {
                let expected = try await state.accountState.nextExpectedNonce(
                    for: signer,
                    fetcher: fetcher
                )
                if body.nonce < expected {
                    return result(.invalid, tipCID: tip.cid)
                }
                if body.nonce > expected {
                    return try await judged(.future)
                }
            }

            if !body.withdrawalActions.isEmpty {
                guard let parentState,
                      let directory = chainPath.last,
                      let parent = try await parentState.resolve(fetcher: fetcher).node
                else {
                    return try await judged(.unavailable)
                }
                // A receipt or deposit this node does not hold yet may be one
                // block away (its parent level lags the wallet's): a retry,
                // the transaction not ready and not pooled. One it holds
                // that contradicts the withdrawal is a verdict, as is a spent
                // deposit (`proveAndUpdateState` below).
                for withdrawal in body.withdrawalActions {
                    let receiptKey = ReceiptKey(withdrawalAction: withdrawal, directory: directory).storageKey
                    let depositKey = DepositKey(withdrawalAction: withdrawal).description
                    let receipts = try await parent.receiptState.resolve(
                        paths: [[receiptKey]: .targeted], fetcher: fetcher
                    ).node
                    let deposits = try await state.depositState.resolve(
                        paths: [[depositKey]: .targeted], fetcher: fetcher
                    ).node
                    let withdrawer: String? = try? receipts?.get(key: receiptKey)
                    if let withdrawer, withdrawer != withdrawal.withdrawer {
                        return result(.invalid, tipCID: tip.cid)
                    }
                    guard withdrawer != nil, (try? deposits?.get(key: depositKey) as UInt64?) != nil else {
                        return result(.unavailable, tipCID: tip.cid)
                    }
                }
                guard try await body.withdrawalsAreValid(
                    directory: directory,
                    prevState: state,
                    parentState: parent,
                    fetcher: fetcher
                ) else {
                    return result(.invalid, tipCID: tip.cid)
                }
            }

            _ = try await state.proveAndUpdateState(
                allAccountActions: body.accountActions,
                allActions: body.actions,
                allDepositActions: body.depositActions,
                allReceiptActions: body.receiptActions,
                allWithdrawalActions: body.withdrawalActions,
                transactionBodies: [body],
                fetcher: fetcher
            )
            return try await judged(.ready)
        } catch {
            return result(
                transactionPreflightEvidenceUnavailable(error)
                    ? .unavailable
                    : .invalid,
                tipCID: tip.cid
            )
        }
    }

    private static func result(
        _ disposition: TransactionPreflightDisposition,
        tipCID: String
    ) -> TransactionPreflightResult {
        TransactionPreflightResult(tipCID: tipCID, disposition: disposition)
    }
}

/// Preflight evicts exactly what import would exclude: an error is a verdict
/// on the transaction only where import records it as a deterministic
/// invalidity. Everything else is retried.
func transactionPreflightEvidenceUnavailable(_ error: Error) -> Bool {
    !BlockImport.isDeterministicInvalidity(classifyValidationFailure(error))
}
