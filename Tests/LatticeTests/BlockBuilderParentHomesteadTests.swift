import XCTest
import UInt256
import cashew
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport

final class BlockBuilderParentHomesteadTests: XCTestCase {
    func testChildGenesisCommitsCarrierEnteringState() async throws {
        let fetcher = StorableFetcher()
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000) - 10_000
        let parentGenesis = try await buildAndStoreGenesis(
            spec: spec("Nexus"),
            transactions: [transaction(delta: 7, nonce: 0, chainPath: ["Nexus"])],
            timestamp: timestamp,
            target: UInt256.max,
            fetcher: fetcher
        )
        let childGenesis = try await BlockBuilder.buildChildGenesis(
            spec: spec("Child"),
            parentState: parentGenesis.postState,
            timestamp: timestamp + 1_000,
            target: UInt256.max,
            fetcher: fetcher
        )
        try await storeBuiltBlock(childGenesis, in: fetcher)
        let carrier = try await buildAndStoreBlock(
            previous: parentGenesis,
            children: ["Child": childGenesis],
            timestamp: timestamp + 2_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            fetcher: fetcher
        )

        XCTAssertEqual(childGenesis.parentState.rawCID, carrier.prevState.rawCID)
        XCTAssertEqual(childGenesis.prevState.rawCID, LatticeState.emptyHeader.rawCID)
        XCTAssertNotEqual(childGenesis.parentState.rawCID, childGenesis.prevState.rawCID)

        let carrierHeader = try BlockHeader(node: carrier)
        let proof = try await ChildBlockProof.generate(
            rootHeader: carrierHeader,
            childDirectory: "Child",
            fetcher: fetcher
        )
        let result = proof.verifySecuringWork(
            child: childGenesis,
            chainPath: ["Nexus", "Child"]
        )
        guard case .success = result else {
            return XCTFail("the builder's parentState must satisfy the same-carrier proof")
        }
    }

    func testChildBlockAnchorsToParentHomesteadNotFrontier() async throws {
        let fetcher = StorableFetcher()
        let parentSpec = spec("Nexus")
        let childSpec = spec("Child")
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000) - 10_000

        let parentGenesis = try await buildAndStoreGenesis(
            spec: parentSpec,
            timestamp: timestamp,
            target: UInt256.max,
            fetcher: fetcher
        )
        let parentBlock = try await buildAndStoreBlock(
            previous: parentGenesis,
            // No credit (a self-credit breaks the fee rule); the signer's
            // nonce advance alone moves the parent's post-state.
            transactions: [transaction(delta: nil, nonce: 0, chainPath: ["Nexus"])],
            timestamp: timestamp + 1_000,
            target: UInt256.max,
            fetcher: fetcher
        )
        let childGenesis = try await buildAndStoreGenesis(
            spec: childSpec,
            timestamp: timestamp,
            target: UInt256.max,
            fetcher: fetcher
        )

        XCTAssertNotEqual(parentBlock.prevState.rawCID, parentBlock.postState.rawCID)

        let childBlock = try await buildAndStoreBlock(
            previous: childGenesis,
            parentChainBlock: parentBlock,
            timestamp: timestamp + 1_000,
            target: UInt256.max,
            fetcher: fetcher
        )

        XCTAssertEqual(childBlock.parentState.rawCID, parentBlock.prevState.rawCID)
        XCTAssertNotEqual(childBlock.parentState.rawCID, parentBlock.postState.rawCID)
    }

    private func transaction(delta: Int64?, nonce: UInt64, chainPath: [String]) -> Transaction {
        let keyPair = CryptoUtils.generateKeyPair()
        let owner = address(keyPair.publicKey)
        let body = TransactionBody(
            accountActions: delta.map { [AccountAction(owner: owner, delta: $0)] } ?? [],
            actions: [],
            depositActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [owner],
            nonce: nonce,
            chainPath: chainPath
        )
        let header = try! HeaderImpl<TransactionBody>(node: body)
        let signature = TransactionSigning.sign(bodyHeader: header, privateKeyHex: keyPair.privateKey)!
        return Transaction(signatures: [keyPair.publicKey: signature], body: header)
    }

    private func address(_ publicKey: String) -> String {
        try! HeaderImpl<PublicKey>(node: PublicKey(key: publicKey)).rawCID
    }

    private func spec(_ directory: String) -> ChainSpec {
        ChainSpec.test(initialReward: 0)
    }
}
