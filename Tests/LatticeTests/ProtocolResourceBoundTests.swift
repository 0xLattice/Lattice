import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import UInt256
import cashew

final class ProtocolResourceBoundTests: XCTestCase {
    func testCIDIdentityBoundedByProofWireCapacity() {
        // The only bound is the proof wire's UInt16 CID length capacity, not a
        // policy cap: a real CID (~59 bytes) is far under it, and the canonical
        // round-trip is what actually decides validity.
        let cid = testCID("bounded-cid")
        XCTAssertLessThanOrEqual(cid.utf8.count, CIDIdentity.maximumTextBytes)
        XCTAssertEqual(CIDIdentity.canonicalString(cid), cid)
        XCTAssertNil(CIDIdentity.canonicalString(
            String(repeating: "x", count: CIDIdentity.maximumTextBytes + 1)
        ))
    }

    func testStateAtomGrammarImposesNoLengthLimit() {
        // No length limit — key size is a node storage concern, not a protocol
        // rule. Lengths that the old caps rejected (129/65/129) are now valid.
        XCTAssertTrue(isValidAccountAtom(String(repeating: "a", count: 129)))
        XCTAssertTrue(isValidAccountAtom(String(repeating: "a", count: 100_000)))
        XCTAssertTrue(isValidDirectoryAtom(String(repeating: "d", count: 65)))
        XCTAssertTrue(isValidGeneralAtom(String(repeating: "k", count: 129)))

        // The structural grammar is preserved: non-empty, visible ASCII (the
        // trie keys by Swift String), and the "/" ban on account/directory
        // atoms (cross-chain receipt-key injectivity).
        XCTAssertFalse(isValidAccountAtom(""))
        XCTAssertFalse(isValidAccountAtom("alice bob"))     // space is not visible ASCII
        XCTAssertFalse(isValidAccountAtom("alice/bob"))     // separator banned
        XCTAssertFalse(isValidAccountAtom("álîce"))         // non-ASCII
        XCTAssertFalse(isValidDirectoryAtom("parent/child"))
        XCTAssertTrue(isValidGeneralAtom("k/v"))            // general keys may contain "/"
    }

    func testTransactionShapeChecksEveryStateKeyAtom() {
        let body = TransactionBody(
            accountActions: [AccountAction(owner: "owner", delta: 1)],
            actions: [Action(key: "key", oldValue: nil, newValue: "value")],
            depositActions: [
                DepositAction(
                    nonce: 1,
                    demander: "demander",
                    amountDemanded: 1,
                    amountDeposited: 1
                ),
            ],
            receiptActions: [
                ReceiptAction(
                    withdrawer: "withdrawer",
                    nonce: 1,
                    demander: "demander",
                    amountDemanded: 1,
                    directory: "Child"
                ),
            ],
            withdrawalActions: [
                WithdrawalAction(
                    withdrawer: "withdrawer",
                    nonce: 1,
                    demander: "demander",
                    amountDemanded: 1,
                    amountWithdrawn: 1
                ),
            ],
            signers: ["withdrawer"],
            nonce: 0,
            chainPath: ["Nexus", "Child"]
        )
        XCTAssertTrue(body.stateAtomsAreValid())

        let invalid = TransactionBody(
            accountActions: body.accountActions,
            actions: body.actions,
            depositActions: body.depositActions,
            receiptActions: [
                ReceiptAction(
                    withdrawer: "withdrawer",
                    nonce: 1,
                    demander: "demander",
                    amountDemanded: 1,
                    directory: "Child/Grandchild"
                ),
            ],
            withdrawalActions: body.withdrawalActions,
            signers: body.signers,
            nonce: body.nonce,
            chainPath: body.chainPath
        )
        XCTAssertFalse(invalid.stateAtomsAreValid())
    }

    func testReceiptStateUsesGoldenDomainSeparatedDigest() async throws {
        let action = ReceiptAction(
            withdrawer: "bob",
            nonce: 7,
            demander: "alice",
            amountDemanded: 42,
            directory: "Child"
        )
        let key = ReceiptKey(receiptAction: action)
        XCTAssertEqual(
            key.storageKey,
            "e055b2f2d5ed425be5e6917175e19f86c5ab825b2b6c811af74c93befc48e6c1"
        )
        XCTAssertEqual(
            key.storageKey.count,
            64
        )

        let fetcher = StorableFetcher()
        let (updated, _) = try await LatticeState.empty.receiptState
            .proveAndUpdateState(
                allReceiptActions: [action],
                fetcher: fetcher
            )
        XCTAssertNil(try updated.node?.get(key: key.description) as String?)
        XCTAssertEqual(
            try updated.node?.get(key: key.storageKey) as String?,
            action.withdrawer
        )
    }

    func testAggregateWithdrawalsRejectDuplicateReceiptKeys() {
        func body(nonces: Range<Int>) -> TransactionBody {
            TransactionBody(
                accountActions: [],
                actions: [],
                depositActions: [],
                receiptActions: [],
                withdrawalActions: nonces.map {
                    WithdrawalAction(
                        withdrawer: "withdrawer",
                        nonce: UInt128($0),
                        demander: "demander",
                        amountDemanded: 1,
                        amountWithdrawn: 1
                    )
                },
                signers: ["withdrawer"],
                nonce: 0,
                chainPath: ["Nexus", "Child"]
            )
        }

        let exact = body(nonces: 0..<64)
        XCTAssertTrue(TransactionBody.withdrawalsHaveUniqueReceiptKeys(
            bodies: [exact],
            directory: "Child"
        ))
        XCTAssertTrue(exact.withdrawalActionsAreValid())

        let over = body(nonces: 0..<65)
        XCTAssertTrue(TransactionBody.withdrawalsHaveUniqueReceiptKeys(
            bodies: [over],
            directory: "Child"
        ))
        XCTAssertTrue(over.withdrawalActionsAreValid())

        let duplicate = body(nonces: 0..<1)
        XCTAssertFalse(TransactionBody.withdrawalsHaveUniqueReceiptKeys(
            bodies: [duplicate, duplicate],
            directory: "Child"
        ))
    }

    func testBlockBuilderRejectsInvalidStateAtomBeforeTransition() async throws {
        let body = TransactionBody(
            accountActions: [],
            actions: [
                Action(
                    key: "inv\u{00e1}lid",   // non-ASCII: rejected by the grammar (not a length cap)
                    oldValue: nil,
                    newValue: "value"
                ),
            ],
            depositActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [],
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let transaction = Transaction(
            signatures: [:],
            body: try HeaderImpl<TransactionBody>(node: body)
        )

        do {
            _ = try await BlockBuilder.buildGenesis(
                spec: resourceBoundSpec(),
                transactions: [transaction],
                timestamp: 1,
                target: UInt256.max,
                fetcher: StorableFetcher()
            )
            XCTFail("expected invalid state key to be rejected")
        } catch BlockBuilderError.invalidTransactionContent {
            // Resource grammar is enforced before trie materialization.
        }
    }

    func testGenesisRejectsLatentInvalidActionPolicyModule() async throws {
        let fetcher = StorableFetcher()
        let module = try WasmPolicyModuleHeader(
            node: WasmPolicyModule(bytes: Data([0x00]))
        )
        try await module.storeRecursively(storer: fetcher)
        let policy = WasmPolicyRef(
            moduleCID: module.rawCID,
            scope: .action
        )
        let spec = resourceBoundSpec(wasmPolicies: [policy])
        let genesis = try await buildAndStoreGenesis(
            spec: spec,
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )

        let contextual = try await TransactionBody.batchVerifyPolicies(
            bodies: [],
            spec: spec,
            chainPath: ["Nexus"],
            height: 1, timestamp: 1, parentTimestamp: 0,
            fetcher: fetcher
        )
        let configured = try await TransactionBody.validateConfiguredPolicyModules(
            spec: spec,
            fetcher: fetcher
        )
        let genesisValid = try await genesis.validateGenesis(
            fetcher: fetcher,
            chainPath: ["Nexus"]
        ).0
        XCTAssertTrue(contextual)
        XCTAssertFalse(configured)
        XCTAssertFalse(genesisValid)
    }

}

private func resourceBoundSpec(
    wasmPolicies: [WasmPolicyRef] = []
) -> ChainSpec {
    ChainSpec.test(
        initialReward: 1,
        halvingInterval: 1_000,
        halfLife: 10,
        wasmPolicies: wasmPolicies
    )
}
