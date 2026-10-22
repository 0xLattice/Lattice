import cashew
import CollectionConcurrencyKit
import Foundation
import UInt256
import LatticePrimitives
import LatticePoW

func addStateDelta(_ value: Int, to total: inout Int) -> Bool {
    let next = total.addingReportingOverflow(value)
    guard !next.overflow else { return false }
    total = next.partialValue
    return true
}

extension TransactionBody {
    /// Consensus grammar for every semantic atom used as a state-trie key.
    /// Imposes no length limit — key size is a node storage concern. Visible
    /// ASCII avoids Unicode-version-dependent `Character` segmentation while the
    /// trie keys by `String`; the `/` ban preserves receipt-key injectivity.
    public func stateAtomsAreValid() -> Bool {
        signers.allSatisfy(isValidAccountAtom)
            && chainPath.allSatisfy(isValidDirectoryAtom)
            && accountActions.allSatisfy {
                isValidAccountAtom($0.owner)
            }
            && actions.allSatisfy {
                isValidGeneralAtom($0.key)
            }
            && depositActions.allSatisfy {
                isValidAccountAtom($0.demander)
            }
            && receiptActions.allSatisfy {
                isValidAccountAtom($0.withdrawer)
                    && isValidAccountAtom($0.demander)
                    && isValidDirectoryAtom($0.directory)
            }
            && withdrawalActions.allSatisfy {
                isValidAccountAtom($0.withdrawer)
                    && isValidAccountAtom($0.demander)
            }
    }

    /// Receipt identities must be unique within a block.
    public static func withdrawalsHaveUniqueReceiptKeys(
        bodies: [TransactionBody],
        directory: String
    ) -> Bool {
        var keys = Set<String>()
        for body in bodies {
            for action in body.withdrawalActions {
                let key = ReceiptKey(
                    withdrawalAction: action,
                    directory: directory
                ).description
                guard keys.insert(key).inserted else { return false }
            }
        }
        return true
    }

    /// THE consensus shape rule for deposit actions (non-zero amounts, demander
    /// must sign). Consumed by block validation (validateTransaction*) and by
    /// node-side admission (mempool) — one definition so the two cannot drift.
    public func depositActionsAreValid() -> Bool {
        let signerSet = Set(signers)
        for depositAction in depositActions {
            if depositAction.amountDeposited == 0 { return false }
            if depositAction.amountDemanded == 0 { return false }
            if !signerSet.contains(depositAction.demander) { return false }
        }
        return true
    }

    /// THE consensus shape rule for receipt actions (non-zero amount, the
    /// debited withdrawer must sign). Consumed by block validation and by
    /// node-side admission — one definition so the two cannot drift.
    public func receiptActionsAreValid() -> Bool {
        let signerSet = Set(signers)
        for receipt in receiptActions {
            if receipt.amountDemanded == 0 { return false }
            if !signerSet.contains(receipt.withdrawer) { return false }
        }
        return true
    }

    /// THE consensus shape rule for withdrawal actions (non-zero amounts, the
    /// withdrawer must sign). Consumed by block validation and by node-side
    /// admission — one definition so the two cannot drift.
    public func withdrawalActionsAreValid() -> Bool {
        let signerSet = Set(signers)
        for withdrawalAction in withdrawalActions {
            if withdrawalAction.amountWithdrawn == 0 { return false }
            if withdrawalAction.amountDemanded == 0 { return false }
            if !signerSet.contains(withdrawalAction.withdrawer) { return false }
        }
        return true
    }

    /// What this transaction leaves for the block's coinbase: funds it
    /// destroys (account debits plus withdrawals) minus funds it creates
    /// (account credits plus deposits) — its contribution to F in
    /// `Block.coinbaseAmount`. `nil` when negative: such a transaction creates
    /// value and cannot be included without another transaction paying for
    /// it. Also `nil` when an account action fails `verify()`.
    public func minerSurplus() -> WorkSum? {
        var destroyed = WorkSum.zero
        var created = WorkSum.zero
        for action in accountActions {
            guard action.verify() else { return nil }
            if action.isDebit { destroyed = destroyed + UInt256(action.absoluteAmount) }
            if action.isCredit { created = created + UInt256(action.absoluteAmount) }
        }
        for withdrawal in withdrawalActions {
            destroyed = destroyed + UInt256(withdrawal.amountWithdrawn)
        }
        for deposit in depositActions {
            created = created + UInt256(deposit.amountDeposited)
        }
        return destroyed.subtracting(created)
    }

    package func withdrawalsAreValid(directory: String, prevState: LatticeState, parentState: LatticeState, fetcher: Fetcher) async throws -> Bool {
        if withdrawalActions.isEmpty { return true }
        // Both proofs THROW on a missing or mismatched deposit/receipt (a
        // missing key surfaces as cashew's ProofErrors.invalidProofType, a
        // mismatch as StateErrors.conflictingActions), so awaiting without throwing IS the
        // validation — the returned proof headers are intentionally discarded.
        // (The authoritative enforcement of deposit existence + amount is the
        // post-state transition, DepositState.proveAndSpendForWithdrawals.)
        async let proofOfDeposits = prevState.depositState.proveExistenceOfCorrespondingDeposit(withdrawalActions: withdrawalActions, fetcher: fetcher)
        async let proofOfReceipts = parentState.receiptState.proveExistenceAndVerifyWithdrawers(directory: directory, withdrawalActions: withdrawalActions, fetcher: fetcher)
        let (_, _) = try await (proofOfDeposits, proofOfReceipts)
        return true
    }

    /// THE consensus shape rule for account actions (every debited owner must
    /// sign; every action self-verifies). Consumed by block validation and by
    /// node-side admission — one definition so the two cannot drift.
    public func accountActionsAreValid() -> Bool {
        let signerSet = Set(signers)
        for action in accountActions where action.isDebit {
            if !signerSet.contains(action.owner) { return false }
        }
        for action in accountActions {
            if !action.verify() { return false }
        }
        return true
    }

    /// Aggregate all balance effects before touching state. Exact unsigned
    /// totals make the result independent of transaction ordering.
    public static func netBalanceDeltas(
        accountActions: [AccountAction],
        receiptActions: [ReceiptAction]
    ) throws -> [String: AccountBalanceDelta] {
        var totals: [String: (credits: WorkSum, debits: WorkSum)] = [:]

        func add(_ amount: UInt64, owner: String, credit: Bool) {
            var total = totals[owner] ?? (.zero, .zero)
            if credit {
                total.credits = total.credits + UInt256(amount)
            } else {
                total.debits = total.debits + UInt256(amount)
            }
            totals[owner] = total
        }

        for action in accountActions {
            guard action.verify() else { throw StateErrors.balanceOverflow }
            add(action.absoluteAmount, owner: action.owner, credit: action.isCredit)
        }
        for receipt in receiptActions {
            guard receipt.amountDemanded > 0 else { throw StateErrors.balanceOverflow }
            add(receipt.amountDemanded, owner: receipt.withdrawer, credit: false)
            add(receipt.amountDemanded, owner: receipt.demander, credit: true)
        }

        var result: [String: AccountBalanceDelta] = [:]
        for (owner, total) in totals where total.credits != total.debits {
            if total.credits > total.debits {
                guard let amount = total.credits.subtracting(total.debits)?.uint64Value else {
                    throw StateErrors.balanceOverflow
                }
                result[owner] = .credit(amount)
            } else {
                guard let amount = total.debits.subtracting(total.credits)?.uint64Value else {
                    throw StateErrors.balanceOverflow
                }
                result[owner] = .debit(amount)
            }
        }
        return result
    }

    public func netBalanceDeltas() throws -> [String: AccountBalanceDelta] {
        try Self.netBalanceDeltas(
            accountActions: accountActions,
            receiptActions: receiptActions
        )
    }

    /// Per-owner net OUTFLOW (non-negative magnitudes of the net-negative
    /// deltas) — `netBalanceDeltas` restricted to owners that must fund.
    public func netOutflows() throws -> [String: UInt64] {
        let netDelta = try netBalanceDeltas()
        var outflows: [String: UInt64] = [:]
        for (owner, delta) in netDelta where delta.outflow > 0 {
            outflows[owner] = delta.outflow
        }
        return outflows
    }

    /// Funds `owner` must afford for this body alone, as a non-negative outflow.
    /// Returns 0 when the owner's net position is non-negative.
    public func netOutflow(of owner: String) throws -> UInt64 {
        guard !owner.isEmpty else { return 0 }
        return try netOutflows()[owner] ?? 0
    }

    func actionsAreValid() -> Bool {
        for action in actions {
            if !action.verify() { return false }
        }
        return true
    }

    package func getStateDelta() throws -> Int {
        var delta = 0
        func add(_ value: Int) throws {
            guard addStateDelta(value, to: &delta) else {
                throw StateErrors.stateDeltaOverflow
            }
        }
        for a in accountActions { try add(a.stateDelta()) }
        for a in actions { try add(a.stateDelta()) }
        for a in depositActions { try add(a.stateDelta()) }
        for a in receiptActions { try add(a.stateDelta()) }
        for a in withdrawalActions { try add(a.stateDelta()) }
        return delta
    }

    /// A block's state growth (spec §6.6): its transactions' action deltas
    /// plus the account growth its transition measured; nil on overflow.
    package static func stateGrowth(of bodies: [TransactionBody], accountGrowth: Int) throws -> Int? {
        var growth = accountGrowth
        for body in bodies {
            guard addStateDelta(try body.getStateDelta(), to: &growth) else { return nil }
        }
        return growth
    }

    /// A floor on `stateGrowth`, known before the transition: the action
    /// deltas, less the most account removals could free. Only an owner whose
    /// balance nets to a debit can be removed; entries are never otherwise
    /// freed. A floor over the limit is over it from any starting state.
    package static func stateGrowthFloor(of bodies: [TransactionBody]) throws -> Int? {
        let deltas = try netBalanceDeltas(
            accountActions: bodies.flatMap(\.accountActions),
            receiptActions: bodies.flatMap(\.receiptActions)
        )
        var removable = 0
        for (owner, delta) in deltas {
            if case .debit = delta { removable += owner.utf8.count + ACCOUNT_ENTRY_VALUE_BYTES }
        }
        return try stateGrowth(of: bodies, accountGrowth: -removable)
    }

    public static func batchVerifyPolicies(
        bodies: [TransactionBody],
        spec: ChainSpec,
        chainPath: [String],
        height: UInt64,
        timestamp: Int64,
        fetcher: Fetcher,
        scopes: Set<WasmPolicyRef.Scope>? = nil
    ) async throws -> Bool {
        guard chainPath.first == DEFAULT_ROOT_DIRECTORY else { return false }
        let policies = scopes.map { allowedScopes in
            spec.wasmPolicies.filter { allowedScopes.contains($0.scope) }
        } ?? spec.wasmPolicies
        guard !policies.isEmpty else { return true }

        guard policies.allSatisfy({
            $0.abiVersion == WasmPolicyRef.currentABIVersion
        }) else { return false }
        let moduleBytesByCID = try await policyModuleBytes(
            policies: policies,
            fetcher: fetcher
        )

        func evaluate(_ policy: WasmPolicyRef, _ context: WasmPolicyContext) throws -> Bool {
            guard let moduleBytes = moduleBytesByCID[policy.moduleCID] else {
                throw WasmPolicyError.missingModule(policy.moduleCID)
            }
            return try WasmPolicyEvaluator.evaluate(
                policy: policy,
                contextData: context.canonicalData(),
                moduleBytes: moduleBytes
            )
        }

        for policy in policies {
            switch policy.scope {
            case .transaction:
                for body in bodies {
                    let context = WasmPolicyContext(
                        scope: .transaction, height: height, timestamp: timestamp,
                        chainSpec: spec, chainPath: chainPath,
                        transaction: body, action: nil, actionIndex: nil
                    )
                    guard try evaluate(policy, context) else { return false }
                }
            case .action:
                for body in bodies {
                    for (actionIndex, action) in body.actions.enumerated() {
                        let context = WasmPolicyContext(
                            scope: .action, height: height, timestamp: timestamp,
                            chainSpec: spec, chainPath: chainPath,
                            transaction: body, action: action, actionIndex: actionIndex
                        )
                        guard try evaluate(policy, context) else { return false }
                    }
                }
            }
        }
        return true
    }

    /// Genesis admits the immutable policy program set, so every configured
    /// entrypoint must be valid even when genesis has no matching context.
    public static func validateConfiguredPolicyModules(
        spec: ChainSpec,
        fetcher: Fetcher
    ) async throws -> Bool {
        guard spec.wasmPolicies.allSatisfy({
            $0.abiVersion == WasmPolicyRef.currentABIVersion
        }) else { return false }
        let modules = try await policyModuleBytes(
            policies: spec.wasmPolicies,
            fetcher: fetcher
        )
        for policy in spec.wasmPolicies {
            guard let bytes = modules[policy.moduleCID] else {
                throw WasmPolicyError.missingModule(policy.moduleCID)
            }
            do {
                try WasmPolicyEvaluator.validate(
                    policy: policy,
                    moduleBytes: bytes
                )
            } catch {
                return false
            }
        }
        return true
    }

    private static func policyModuleBytes(
        policies: [WasmPolicyRef],
        fetcher: Fetcher
    ) async throws -> [String: Data] {
        var result: [String: Data] = [:]
        for policy in policies where result[policy.moduleCID] == nil {
            let moduleHeader = WasmPolicyModuleHeader(
                rawCID: policy.moduleCID
            )
            do {
                guard let module = try await moduleHeader.resolve(
                    fetcher: fetcher
                ).node else {
                    throw WasmPolicyError.missingModule(policy.moduleCID)
                }
                result[policy.moduleCID] = module.bytes
            } catch is FetcherError {
                throw WasmPolicyError.missingModule(policy.moduleCID)
            }
        }
        return result
    }
}
