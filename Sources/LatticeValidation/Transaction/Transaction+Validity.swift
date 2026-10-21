import cashew
import Foundation
import LatticePrimitives

extension Transaction {
    /// The consensus signature rule: every attached signature must verify over
    /// the lattice-tx-v1 envelope preimage, and at least one
    /// signature must be present. Requires a resolved body.
    public func signaturesAreValid() -> Bool {
        guard let bodyNode = body.node else { return false }
        return signaturesAreValid(bodyNode)
    }

    private func signaturesAreValid(_ bodyNode: TransactionBody) -> Bool {
        guard let signatures = Self.normalized(signatures),
              !signatures.isEmpty else {
            return false
        }
        for (publicKeyHex, signature) in signatures {
            if !TransactionSigning.verify(body: bodyNode, bodyCID: body.rawCID, signature: signature, publicKeyHex: publicKeyHex) {
                return false
            }
        }
        return true
    }

    /// THE consensus signer-coverage rule: the body declares each signer once,
    /// and the set of signing keys (by derived address) equals those signers
    /// exactly, so every listed signer costs a signature. Consumed by block
    /// validation and by node-side admission — one definition so the two
    /// cannot drift. Requires a resolved body.
    public func signaturesMatchSigners() -> Bool {
        guard let bodyNode = body.node else { return false }
        return signaturesMatchSigners(bodyNode)
    }

    private func signaturesMatchSigners(_ bodyNode: TransactionBody) -> Bool {
        guard let signatures = Self.normalized(signatures) else { return false }
        let signatureHashes = Set(signatures.keys.map {
            CryptoUtils.createAddress(from: $0)
        })
        let signerSet = Set(bodyNode.signers)
        return signerSet.count == bodyNode.signers.count && signatureHashes == signerSet
    }

    private func validateSignaturesAndResolve(
        fetcher: Fetcher
    ) async throws -> TransactionBody? {
        let resolvedBody = try await body.resolve(fetcher: fetcher)
        guard let bodyNode = resolvedBody.node else { throw ValidationErrors.transactionNotResolved }
        if !signaturesAreValid(bodyNode) || !signaturesMatchSigners(bodyNode) {
            return nil
        }
        return bodyNode
    }

    func validateTransactionForGenesis(fetcher: Fetcher) async throws -> Bool {
        let resolvedBody = try await body.resolve(fetcher: fetcher)
        guard let bodyNode = resolvedBody.node else {
            throw ValidationErrors.transactionNotResolved
        }
        if !bodyNode.stateAtomsAreValid() { return false }
        if !bodyNode.accountActionsAreValid() { return false }
        if !bodyNode.actionsAreValid() { return false }
        if !bodyNode.depositActions.isEmpty { return false }
        if !bodyNode.withdrawalActions.isEmpty { return false }
        if !bodyNode.receiptActions.isEmpty { return false }
        return true
    }

    package func validateTransactionForNexus(fetcher: Fetcher) async throws -> Bool {
        guard let bodyNode = try await validateSignaturesAndResolve(fetcher: fetcher) else { return false }
        if !bodyNode.stateAtomsAreValid() { return false }
        if !bodyNode.accountActionsAreValid() { return false }
        if !bodyNode.actionsAreValid() { return false }
        if !bodyNode.receiptActionsAreValid() { return false }
        if !bodyNode.depositActionsAreValid() { return false }
        if !bodyNode.withdrawalActionsAreValid() { return false }
        return true
    }

    func validateTransaction(directory: String, prevState: LatticeState, parentState: LatticeState, fetcher: Fetcher) async throws -> Bool {
        guard let bodyNode = try await validateSignaturesAndResolve(fetcher: fetcher) else { return false }
        if !bodyNode.stateAtomsAreValid() { return false }
        if !bodyNode.receiptActionsAreValid() { return false }
        if !bodyNode.accountActionsAreValid() { return false }
        if !bodyNode.actionsAreValid() { return false }
        if !bodyNode.depositActionsAreValid() { return false }
        if !bodyNode.withdrawalActionsAreValid() { return false }
        if try await !bodyNode.withdrawalsAreValid(directory: directory, prevState: prevState, parentState: parentState, fetcher: fetcher) { return false }
        return true
    }
}
