import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import cashew

/// A post-state stored by its diff alone (the `storeMaterialized(createdBy:)`
/// fixture, as a node stores `materializedPostState`) resolves whole: the
/// diff names every node the transition created, compressed radix nodes and
/// receipt, balance and nonce changes included.
final class MaterializedStatePersistenceTests: XCTestCase {
    func testStoreMaterializedPersistsCompressedRadixDescendants() async throws {
        let storage = StorableFetcher()
        try await LatticeState.emptyHeader.storeRecursively(storer: storage)

        let initialState = try XCTUnwrap(LatticeState.emptyHeader.node)
        let (updatedState, diff) = try await initialState.proveAndUpdateState(
            allAccountActions: [
                AccountAction(owner: "shared-owner-alpha", delta: 1),
                AccountAction(owner: "shared-owner-beta", delta: 1)
            ],
            allActions: [],
            allDepositActions: [],
            allReceiptActions: [],
            allWithdrawalActions: [],
            transactionBodies: [],
            fetcher: storage
        )
        let updatedHeader = try LatticeStateHeader(node: updatedState)

        try await updatedHeader.storeMaterialized(
            createdBy: diff,
            storer: storage
        )
        let reloaded = try await updatedHeader.removingNode().resolveRecursive(fetcher: storage)
        let reloadedState = try XCTUnwrap(reloaded.node)
        let accounts = try XCTUnwrap(reloadedState.accountState.node?.allKeysAndValues())
        XCTAssertEqual(accounts["shared-owner-alpha"], 1)
        XCTAssertEqual(accounts["shared-owner-beta"], 1)
    }

    func testStoreMaterializedPersistsReceiptBalanceAndNonceChanges() async throws {
        let storage = StorableFetcher()
        try await LatticeState.emptyHeader.storeRecursively(storer: storage)
        let buyer = CryptoUtils.generateKeyPair()
        let seller = CryptoUtils.generateKeyPair()
        let buyerAddress = CryptoUtils.createAddress(from: buyer.publicKey)
        let sellerAddress = CryptoUtils.createAddress(from: seller.publicKey)

        let fundingBody = TransactionBody(
            accountActions: [AccountAction(owner: buyerAddress, delta: 250)],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [buyerAddress], nonce: 0,
            chainPath: ["Nexus"]
        )
        let initial = try XCTUnwrap(LatticeState.emptyHeader.node)
        let (funded, fundingDiff) = try await initial.proveAndUpdateState(
            allAccountActions: fundingBody.accountActions,
            allActions: [], allDepositActions: [], allReceiptActions: [], allWithdrawalActions: [],
            transactionBodies: [fundingBody], fetcher: storage
        )
        let fundedHeader = try LatticeStateHeader(node: funded)
        try await fundedHeader.storeMaterialized(
            createdBy: fundingDiff,
            storer: storage
        )
        let resolvedFunded = try await fundedHeader.removingNode()
            .resolveRecursive(fetcher: storage)
        let reloadedFunded = try XCTUnwrap(resolvedFunded.node)

        let receipt = ReceiptAction(
            withdrawer: buyerAddress,
            nonce: 7,
            demander: sellerAddress,
            amountDemanded: 250,
            directory: "Market"
        )
        let receiptBody = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [receipt],
            withdrawalActions: [], signers: [buyerAddress],
            nonce: 1, chainPath: ["Nexus"]
        )
        let (settled, receiptDiff) = try await reloadedFunded.proveAndUpdateState(
            allAccountActions: [], allActions: [], allDepositActions: [],
            allReceiptActions: [receipt],
            allWithdrawalActions: [], transactionBodies: [receiptBody],
            fetcher: storage
        )
        let settledHeader = try LatticeStateHeader(node: settled)
        try await settledHeader.storeMaterialized(
            createdBy: receiptDiff,
            storer: storage
        )

        let reloaded = try await settledHeader.removingNode()
            .resolveRecursive(fetcher: storage)
        let state = try XCTUnwrap(reloaded.node)
        let accounts = try XCTUnwrap(state.accountState.node?.allKeysAndValues())
        XCTAssertNil(accounts[buyerAddress])
        XCTAssertEqual(accounts[sellerAddress], 250)
        XCTAssertEqual(
            accounts[AccountStateHeader.nonceTrackingKey(buyerAddress)],
            1
        )
        let receipts = try XCTUnwrap(state.receiptState.node?.allKeysAndValues())
        XCTAssertEqual(
            receipts[ReceiptKey(receiptAction: receipt).storageKey],
            buyerAddress
        )
    }
}
