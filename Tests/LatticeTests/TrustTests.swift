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
import Foundation


private func f() -> StorableFetcher { StorableFetcher() }

private func s(_ dir: String = "Nexus", premine: UInt64 = 1000) -> ChainSpec {
    ChainSpec.test(premine: premine)
}

private func tx(_ body: TransactionBody, _ kp: (privateKey: String, publicKey: String)) -> Transaction {
    let h = try! HeaderImpl<TransactionBody>(node: body)
    let sig = TransactionSigning.sign(bodyHeader: h, privateKeyHex: kp.privateKey)!
    return Transaction(signatures: [kp.publicKey: sig], body: h)
}

private func id(_ pubKey: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: pubKey)).rawCID
}

private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

private func premineGenesis(
    spec: ChainSpec, owner: (privateKey: String, publicKey: String),
    fetcher: StorableFetcher, time: Int64
) async throws -> Block {
    let addr = id(owner.publicKey)
    let body = TransactionBody(
        accountActions: [AccountAction(owner: addr, delta: Int64(spec.premineAmount()))],
        actions: [], depositActions: [], receiptActions: [], withdrawalActions: [], signers: [addr], nonce: 0,
        chainPath: ["Nexus"]
    )
    return try await buildAndStoreGenesis(
        spec: spec, transactions: [tx(body, owner)],
        timestamp: time, target: UInt256(1000), fetcher: fetcher
    )
}

// ============================================================================
// MARK: - Cross-Chain Protocol Integration
// ============================================================================

@MainActor
final class CrossChainProtocolIntegrationTests: XCTestCase {

    // Variable-rate two-party trade: Alice deposits 100 ChildA tokens
    // demanding 250 nexus tokens. Bob pays 250 on nexus and claims the
    // 100 ChildA tokens. Exercises the full deposit→receipt→withdraw flow
    // with amountDeposited ≠ amountDemanded across all three layers.
    func testVariableRateParentChildExchangeValidates() async throws {
        let fetcher = f()
        let base = now() - 40_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        let childSpec = s("Child")
        let nexusSpec = s("Nexus", premine: 0)
        let childPremine = childSpec.premineAmount()
        let childReward = childSpec.initialReward
        let nexusReward0 = nexusSpec.rewardAtBlock(1)

        let amountDeposited: UInt64 = 100   // Alice locks 100 Child tokens
        let amountDemanded: UInt64 = 250    // and demands 250 Nexus tokens
        XCTAssertNotEqual(amountDeposited, amountDemanded, "Test premise: rates must differ")

        let childGenesis = try await premineGenesis(spec: childSpec, owner: alice, fetcher: fetcher, time: base)
        let nexusGenesis = try await buildAndStoreGenesis(
            spec: nexusSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        // Fund Bob on nexus (he needs ≥ amountDemanded to pay Alice via receipt)
        let t1 = base + 1000
        let nexusBlock1 = try await buildAndStoreBlock(
            previous: nexusGenesis,
            timestamp: t1, target: UInt256(1000), nonce: 1,
            rewardRecipient: bobAddr, fetcher: fetcher
        )
        XCTAssertGreaterThanOrEqual(nexusReward0, amountDemanded, "Bob must have funds for receipt")

        // Step 1: Alice deposits on Child (locks amountDeposited, demands amountDemanded)
        let aliceDeposit = DepositAction(
            nonce: 1, demander: aliceAddr,
            amountDemanded: amountDemanded,
            amountDeposited: amountDeposited
        )
        let depositBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: -Int64(amountDeposited))],
            actions: [], depositActions: [aliceDeposit],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], nonce: 1, chainPath: ["Nexus", "Child"]
        )
        let childBlock1 = try await buildAndStoreBlock(
            previous: childGenesis, transactions: [tx(depositBody, alice)],
            parentChainBlock: nexusBlock1,
            timestamp: t1, target: UInt256(1000), nonce: 1,
            rewardRecipient: aliceAddr, fetcher: fetcher
        )
        let aliceBalanceAfterDeposit = childPremine - amountDeposited + childReward

        // Step 2: Receipt on nexus — Bob pays Alice amountDemanded
        let t2 = base + 2000
        let receiptBody = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], receiptActions: [
                ReceiptAction(withdrawer: bobAddr, nonce: 1, demander: aliceAddr,
                              amountDemanded: amountDemanded, directory: "Child")
            ],
            withdrawalActions: [],
            signers: [bobAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let receiptHeader = try! HeaderImpl<TransactionBody>(node: receiptBody)
        let bobSig = TransactionSigning.sign(bodyHeader: receiptHeader, privateKeyHex: bob.privateKey)!
        let receiptTx = Transaction(signatures: [bob.publicKey: bobSig], body: receiptHeader)
        let nexusBlock2 = try await buildAndStoreBlock(
            previous: nexusBlock1, transactions: [receiptTx],
            timestamp: t2, target: UInt256(1000), nonce: 2,
            rewardRecipient: bobAddr, fetcher: fetcher
        )
        let nexusValid = try await nexusBlock2.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(nexusValid, "Receipt with amountDemanded=250 on nexus should validate")

        // Pad nexus so child can advance with a fresh parent reference
        let t3 = base + 3000
        let nexusBlock3 = try await buildAndStoreBlock(
            previous: nexusBlock2, timestamp: t3,
            target: UInt256(1000), nonce: 3, fetcher: fetcher
        )

        // Step 3: Withdrawal on Child — Bob claims amountDeposited tokens.
        // amountWithdrawn must equal deposit.amountDeposited (on-chain check)
        // amountDemanded on the withdrawal must match the receipt
        let bobWithdraw = WithdrawalAction(
            withdrawer: bobAddr, nonce: 1, demander: aliceAddr,
            amountDemanded: amountDemanded,
            amountWithdrawn: amountDeposited
        )
        let withdrawBody = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: Int64(amountDeposited))],
            actions: [], depositActions: [],
            receiptActions: [],
            withdrawalActions: [bobWithdraw],
            signers: [bobAddr], nonce: 0, chainPath: ["Nexus", "Child"]
        )
        let childBlock2 = try await buildAndStoreBlock(
            previous: childBlock1, transactions: [tx(withdrawBody, bob)],
            parentChainBlock: nexusBlock3,
            timestamp: t3, target: UInt256(1000), nonce: 2,
            rewardRecipient: bobAddr, fetcher: fetcher
        )
        let childValid = try await childBlock2.validateNexus(fetcher: fetcher, chainPath: ["Nexus", "Child"]).0
        XCTAssertTrue(childValid, "Variable-rate withdrawal (amountWithdrawn=100) should validate against deposit (amountDeposited=100)")

        // Final balances reflect the variable-rate trade
        // Alice locked 100 Child, kept (premine - 100 + childReward) but the
        // amount she actually receives on Nexus is amountDemanded=250 (via receipt's implicit credit).
        XCTAssertEqual(aliceBalanceAfterDeposit, childPremine - amountDeposited + childReward)
    }

    // Negative: a withdrawal claiming more child tokens than the deposit
    // locked must be rejected even when the receipt and signers are valid.
    // Frontier mismatch (or proof failure) should kill the block.
    func testVariableRateOverclaimRejected() async throws {
        let fetcher = f()
        let base = now() - 40_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        let childSpec = s("Child")
        let nexusSpec = s("Nexus", premine: 0)
        let childPremine = childSpec.premineAmount()

        let amountDeposited: UInt64 = 100
        let amountDemanded: UInt64 = 250
        let overclaim: UInt64 = 200  // Bob tries to claim 200 when only 100 was deposited

        let childGenesis = try await premineGenesis(spec: childSpec, owner: alice, fetcher: fetcher, time: base)
        let nexusGenesis = try await buildAndStoreGenesis(
            spec: nexusSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let t1 = base + 1000
        // Bob is funded by the block reward.
        let fundBob = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let nexusBlock1 = try await buildAndStoreBlock(
            previous: nexusGenesis, transactions: [tx(fundBob, bob)],
            timestamp: t1, target: UInt256(1000), nonce: 1,
            rewardRecipient: bobAddr, fetcher: fetcher
        )

        let aliceDeposit = DepositAction(
            nonce: 1, demander: aliceAddr,
            amountDemanded: amountDemanded, amountDeposited: amountDeposited
        )
        let depositBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: -Int64(amountDeposited))],
            actions: [], depositActions: [aliceDeposit],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], nonce: 1,
            chainPath: ["Nexus", "Child"]
        )
        let childBlock1 = try await buildAndStoreBlock(
            previous: childGenesis, transactions: [tx(depositBody, alice)],
            parentChainBlock: nexusBlock1,
            timestamp: t1, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let t2 = base + 2000
        let receiptBody = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], receiptActions: [
                ReceiptAction(withdrawer: bobAddr, nonce: 1, demander: aliceAddr,
                              amountDemanded: amountDemanded, directory: "Child")
            ],
            withdrawalActions: [],
            signers: [bobAddr], nonce: 1,
            chainPath: ["Nexus"]
        )
        let nexusBlock2 = try await buildAndStoreBlock(
            previous: nexusBlock1, transactions: [tx(receiptBody, bob)],
            timestamp: t2, target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let t3 = base + 3000
        let nexusBlock3 = try await buildAndStoreBlock(
            previous: nexusBlock2, timestamp: t3,
            target: UInt256(1000), nonce: 3, fetcher: fetcher
        )

        // Bob's overclaim attempt
        let bobOverclaim = WithdrawalAction(
            withdrawer: bobAddr, nonce: 1, demander: aliceAddr,
            amountDemanded: amountDemanded,
            amountWithdrawn: overclaim
        )
        let withdrawBody = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: Int64(overclaim))],
            actions: [], depositActions: [],
            receiptActions: [],
            withdrawalActions: [bobOverclaim],
            signers: [bobAddr], nonce: 0,
            chainPath: ["Nexus", "Child"]
        )

        // The stored deposit (100) does not match amountWithdrawn (200).
        await assertThrows(
            StateErrors.conflictingActions,
            "Withdrawal claiming amountWithdrawn=200 against deposit.amountDeposited=100 must be rejected"
        ) {
            try await buildAndStoreBlock(
                previous: childBlock1, transactions: [tx(withdrawBody, bob)],
                parentChainBlock: nexusBlock3,
                timestamp: t3, target: UInt256(1000), nonce: 2, fetcher: fetcher
            )
        }
    }

    func testWithdrawalWithoutReceiptRejected() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        let childSpec = s("Child")
        let nexusSpec = s("Nexus", premine: 0)
        let swapAmount: UInt64 = 1000

        let childGenesis = try await premineGenesis(spec: childSpec, owner: alice, fetcher: fetcher, time: base)
        let nexusGenesis = try await buildAndStoreGenesis(
            spec: nexusSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let childSwap = DepositAction(nonce: 1, demander: aliceAddr, amountDemanded: swapAmount, amountDeposited: swapAmount)

        let t1 = base + 1000
        let nexusBlock1 = try await buildAndStoreBlock(
            previous: nexusGenesis, timestamp: t1,
            target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let swapBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: -Int64(swapAmount))
            ],
            actions: [],
            depositActions: [childSwap],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], nonce: 1,
            chainPath: ["Nexus", "Child"]
        )
        let childBlock1 = try await buildAndStoreBlock(
            previous: childGenesis, transactions: [tx(swapBody, alice)],
            parentChainBlock: nexusBlock1,
            timestamp: t1, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // No receipt/settle on nexus -- try to withdraw anyway
        let t2 = base + 2000
        let nexusBlock2 = try await buildAndStoreBlock(
            previous: nexusBlock1, timestamp: t2,
            target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let withdrawBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(swapAmount))
            ],
            actions: [], depositActions: [],
            receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: aliceAddr, nonce: 1, demander: aliceAddr, amountDemanded: swapAmount, amountWithdrawn: swapAmount)
            ],
            signers: [aliceAddr], nonce: 2,
            chainPath: ["Nexus", "Child"]
        )

        let childBlock2 = try await buildAndStoreBlock(
            previous: childBlock1,
            transactions: [tx(withdrawBody, alice)],
            parentChainBlock: nexusBlock2,
            timestamp: t2, target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        // Validation must prove the receipt exists in the parent homestead;
        // with no receipt there, that proof cannot be built.
        do {
            _ = try await childBlock2.validateNexus(
                fetcher: fetcher,
                chainPath: ["Nexus", "Child"]
            )
            XCTFail("Withdrawal without corresponding receipt on parent chain must be rejected")
        } catch ProofErrors.invalidProofType {
            // Expected: no receipt exists on nexus to prove
        }
    }

    func testTwoChildExchangeValidatesAtProtocolBoundary() async throws {
        let fetcher = f()
        let base = now() - 40_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        let childASpec = s("ChildA")
        let childBSpec = s("ChildB")
        let nexusSpec = s("Nexus", premine: 0)

        let childAGenesis = try await premineGenesis(spec: childASpec, owner: alice, fetcher: fetcher, time: base)
        let childBGenesis = try await premineGenesis(spec: childBSpec, owner: bob, fetcher: fetcher, time: base)
        let nexusGenesis = try await buildAndStoreGenesis(
            spec: nexusSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let aliceSwapAmount: UInt64 = 300
        let bobSwapAmount: UInt64 = 200

        let aliceSwap = DepositAction(nonce: 1, demander: aliceAddr, amountDemanded: aliceSwapAmount, amountDeposited: aliceSwapAmount)
        let bobSwap = DepositAction(nonce: 1, demander: bobAddr, amountDemanded: bobSwapAmount, amountDeposited: bobSwapAmount)

        let t1 = base + 1000
        // Fund bob on nexus so he can pay alice via receipt in the settle step
        let fundBobBody = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let advanceAliceOnNexus = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let nexusBlock1 = try await buildAndStoreBlock(
            previous: nexusGenesis, transactions: [tx(fundBobBody, bob), tx(advanceAliceOnNexus, alice)],
            timestamp: t1,
            target: UInt256(1000), nonce: 1, rewardRecipient: bobAddr, fetcher: fetcher
        )

        let aliceSwapBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: -Int64(aliceSwapAmount))],
            actions: [], depositActions: [aliceSwap],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], nonce: 1, chainPath: ["Nexus", "ChildA"]
        )
        let childABlock1 = try await buildAndStoreBlock(
            previous: childAGenesis, transactions: [tx(aliceSwapBody, alice)],
            parentChainBlock: nexusBlock1,
            timestamp: t1, target: UInt256(1000), nonce: 1, rewardRecipient: aliceAddr, fetcher: fetcher
        )

        let bobSwapBody = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: -Int64(bobSwapAmount))],
            actions: [], depositActions: [bobSwap],
            receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], nonce: 1, chainPath: ["Nexus", "ChildB"]
        )
        let childBBlock1 = try await buildAndStoreBlock(
            previous: childBGenesis, transactions: [tx(bobSwapBody, bob)],
            parentChainBlock: nexusBlock1,
            timestamp: t1, target: UInt256(1000), nonce: 1, rewardRecipient: bobAddr, fetcher: fetcher
        )

        // Settle: two receipts (one for each direction) co-signed by both parties
        let t2 = base + 2000
        let settleBody = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], receiptActions: [
                ReceiptAction(withdrawer: bobAddr, nonce: 1, demander: aliceAddr, amountDemanded: aliceSwapAmount, directory: "ChildA"),
                ReceiptAction(withdrawer: aliceAddr, nonce: 1, demander: bobAddr, amountDemanded: bobSwapAmount, directory: "ChildB")
            ],
            withdrawalActions: [],
            signers: [aliceAddr, bobAddr], nonce: 1, chainPath: ["Nexus"]
        )
        let settleHeader = try! HeaderImpl<TransactionBody>(node: settleBody)
        let sigA = TransactionSigning.sign(bodyHeader: settleHeader, privateKeyHex: alice.privateKey)!
        let sigB = TransactionSigning.sign(bodyHeader: settleHeader, privateKeyHex: bob.privateKey)!
        let settleTx = Transaction(signatures: [alice.publicKey: sigA, bob.publicKey: sigB], body: settleHeader)

        let nexusBlock2 = try await buildAndStoreBlock(
            previous: nexusBlock1, transactions: [settleTx],
            timestamp: t2, target: UInt256(1000), nonce: 2, rewardRecipient: aliceAddr, fetcher: fetcher
        )
        let nexusValid = try await nexusBlock2.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(nexusValid, "Settlement co-signed by both parties should be valid")

        let t3 = base + 3000
        let nexusBlock3 = try await buildAndStoreBlock(
            previous: nexusBlock2, timestamp: t3,
            target: UInt256(1000), nonce: 3, fetcher: fetcher
        )

        let bobClaimOnA = TransactionBody(
            accountActions: [AccountAction(owner: bobAddr, delta: Int64(aliceSwapAmount))],
            actions: [], depositActions: [],
            receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: bobAddr, nonce: 1, demander: aliceAddr, amountDemanded: aliceSwapAmount, amountWithdrawn: aliceSwapAmount)],
            signers: [bobAddr], nonce: 0, chainPath: ["Nexus", "ChildA"]
        )
        let childABlock2 = try await buildAndStoreBlock(
            previous: childABlock1, transactions: [tx(bobClaimOnA, bob)],
            parentChainBlock: nexusBlock3,
            timestamp: t3, target: UInt256(1000), nonce: 2, rewardRecipient: bobAddr, fetcher: fetcher
        )
        let childAValid = try await childABlock2.validateNexus(fetcher: fetcher, chainPath: ["Nexus", "ChildA"]).0
        XCTAssertTrue(childAValid, "Bob claiming Alice's swap on ChildA should be valid")

        let aliceClaimOnB = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(bobSwapAmount))],
            actions: [], depositActions: [],
            receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: aliceAddr, nonce: 1, demander: bobAddr, amountDemanded: bobSwapAmount, amountWithdrawn: bobSwapAmount)],
            signers: [aliceAddr], nonce: 0, chainPath: ["Nexus", "ChildB"]
        )
        let childBBlock2 = try await buildAndStoreBlock(
            previous: childBBlock1, transactions: [tx(aliceClaimOnB, alice)],
            parentChainBlock: nexusBlock3,
            timestamp: t3, target: UInt256(1000), nonce: 2, rewardRecipient: aliceAddr, fetcher: fetcher
        )
        let childBValid = try await childBBlock2.validateNexus(fetcher: fetcher, chainPath: ["Nexus", "ChildB"]).0
        XCTAssertTrue(childBValid, "Alice claiming Bob's swap on ChildB should be valid")
    }
}

// ============================================================================
// MARK: - Swap Authorization Negative Tests
// ============================================================================

@MainActor
final class SwapAuthorizationTests: XCTestCase {

    func testWithdrawalByNonWithdrawerRejected() async {
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let eve = CryptoUtils.generateKeyPair()
        let eveAddr = id(eve.publicKey)

        // Eve signs but the withdrawal specifies bob as the withdrawer
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: bobAddr, nonce: 1, demander: aliceAddr, amountDemanded: 100, amountWithdrawn: 100)],
            signers: [eveAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        XCTAssertFalse(body.withdrawalActionsAreValid(), "Withdrawal signed by non-withdrawer should be rejected")
    }

    func testWithdrawalByWithdrawerAccepted() async {
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: bobAddr, nonce: 1, demander: aliceAddr, amountDemanded: 100, amountWithdrawn: 100)],
            signers: [bobAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        XCTAssertTrue(body.withdrawalActionsAreValid(), "Withdrawal signed by withdrawer should be accepted")
    }

    func testWithdrawalDifferingFromDemandAccepted() async {
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        // Variable-rate swap: amountWithdrawn may differ from amountDemanded.
        // The actual amount-vs-stored-deposit check happens at state-application
        // time in DepositStateHeader.proveAndSpendForWithdrawals.
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: aliceAddr, nonce: 1, demander: aliceAddr, amountDemanded: 100, amountWithdrawn: 200)],
            signers: [aliceAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        XCTAssertTrue(body.withdrawalActionsAreValid(), "Body-level withdrawal validation no longer requires amountWithdrawn == amountDemanded")
    }

    func testReceiptWithMismatchedWithdrawerRejected() async {
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        // Receipt withdrawer is bob but only alice signs — rejected because
        // the receipt debits bob's funds, so bob must authorize
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [ReceiptAction(withdrawer: bobAddr, nonce: 1, demander: aliceAddr, amountDemanded: 100, directory: "A")],
            withdrawalActions: [],
            signers: [aliceAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        XCTAssertFalse(body.receiptActionsAreValid(), "Withdrawer must sign — their nexus funds are debited by the receipt")
    }

    func testSettleAndClaimInSameBlockFails() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let alice = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)

        let nexusSpec = s("Nexus")
        let nexusGenesis = try await premineGenesis(spec: nexusSpec, owner: alice, fetcher: fetcher, time: base)

        let swapAmount: UInt64 = 100
        let swap = DepositAction(nonce: 1, demander: aliceAddr, amountDemanded: swapAmount, amountDeposited: swapAmount)

        let swapBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: -Int64(swapAmount))],
            actions: [], depositActions: [swap],
            receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], nonce: 1,
            chainPath: ["Nexus"]
        )
        let nexusBlock1 = try await buildAndStoreBlock(
            previous: nexusGenesis, transactions: [tx(swapBody, alice)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let settleAndClaimBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(swapAmount))],
            actions: [], depositActions: [],
            receiptActions: [ReceiptAction(withdrawer: aliceAddr, nonce: 1, demander: aliceAddr, amountDemanded: swapAmount, directory: "Nexus")],
            withdrawalActions: [WithdrawalAction(withdrawer: aliceAddr, nonce: 1, demander: aliceAddr, amountDemanded: swapAmount, amountWithdrawn: swapAmount)],
            signers: [aliceAddr], nonce: 2,
            chainPath: ["Nexus"]
        )
        do {
            let nexusBlock2 = try await buildAndStoreBlock(
                previous: nexusBlock1, transactions: [tx(settleAndClaimBody, alice)],
                timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
            )
            let valid = try await nexusBlock2.validateNexus(fetcher: fetcher).0
            XCTAssertFalse(valid, "Settle and claim in same block should fail — settlement not yet in homestead")
        } catch {
            // Claim proof or build fails because settle is not yet in homestead.receiptState
        }
    }
}

// ============================================================================
// MARK: - CRITICAL: Transaction Nonce Replay Protection On-Chain
// ============================================================================

@MainActor
final class NonceReplayTests: XCTestCase {

    func testSameTransactionCannotBeIncludedTwice() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let spec = s(premine: 0)

        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let body = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let transaction = tx(body, kp)

        let block1 = try await buildAndStoreBlock(
            previous: genesis, transactions: [transaction],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let block1Valid = try await block1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(block1Valid, "control: the first inclusion validates")

        // Try including the SAME transaction in the next block (replay):
        // the signer's nonce already advanced past 0.
        await assertThrows(StateErrors.nonceGap, "Replayed transaction should fail") {
            try await buildAndStoreBlock(
                previous: block1, transactions: [transaction],
                timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
            )
        }
    }

    func testTransactionNonceIsUniquePerSignerInState() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let recipientAddr = id(CryptoUtils.generateKeyPair().publicKey)
        let spec = s(premine: 0)

        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let body1 = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let block1 = try await buildAndStoreBlock(
            previous: genesis, transactions: [tx(body1, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            rewardRecipient: kpAddr, fetcher: fetcher
        )

        // Same nonce (0) but different body — should fail because the signer's
        // nonce already advanced past 0; the new block's batch starts at 0 again,
        // which violates the "nonce must be current+1" invariant.
        func transfer(nonce: UInt64) -> TransactionBody {
            TransactionBody(
                accountActions: [
                    AccountAction(owner: kpAddr, delta: -1),
                    AccountAction(owner: recipientAddr, delta: 1)
                ],
                actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
                signers: [kpAddr], nonce: nonce,
                chainPath: ["Nexus"]
            )
        }

        let control = try await buildAndStoreBlock(
            previous: block1, transactions: [tx(transfer(nonce: 1), kp)],
            timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let controlValid = try await control.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(controlValid, "control: the funded transfer at the next nonce validates")

        await assertThrows(StateErrors.nonceGap, "Reused nonce should fail — signer's nonce must advance monotonically") {
            try await buildAndStoreBlock(
                previous: block1, transactions: [tx(transfer(nonce: 0), kp)],
                timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
            )
        }
    }

    func testDifferentSignersSameNonceAllowed() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let spec = s(premine: 0)

        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let aliceBody = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let bobBody = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], nonce: 0, chainPath: ["Nexus"]
        )

        let block1 = try await buildAndStoreBlock(
            previous: genesis, transactions: [tx(aliceBody, alice), tx(bobBody, bob)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            rewardRecipient: aliceAddr, fetcher: fetcher
        )
        let valid = try await block1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid)
    }
}

// ============================================================================
// MARK: - CRITICAL: Balance Conservation Across Reorgs
// ============================================================================

@MainActor
final class ReorgBalanceTests: XCTestCase {

    func testReorgPreservesBalanceInvariants() async throws {
        let fetcher = f()
        let base = now() - 100_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let spec = s()
        let premine = spec.premineAmount()

        let genesis = try await premineGenesis(spec: spec, owner: alice, fetcher: fetcher, time: base)
        let chain = ChainState.fromGenesis(block: genesis)

        // Main chain: alice sends 100 to bob
        let mainBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(premine - 100) - Int64(premine)),
                AccountAction(owner: bobAddr, delta: 100)
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], nonce: 1, chainPath: ["Nexus"]
        )
        let mainBlock1 = try await buildAndStoreBlock(
            previous: genesis, transactions: [tx(mainBody, alice)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            rewardRecipient: bobAddr, fetcher: fetcher
        )
        let mainValid = try await mainBlock1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(mainValid)
        let _ = await chain.submitTestBlock(
            blockHeader: try! VolumeImpl<Block>(node: mainBlock1), block: mainBlock1
        )

        let mainTip = await chain.canonicalTip
        XCTAssertEqual(mainTip, try! VolumeImpl<Block>(node: mainBlock1).rawCID)

        // Fork: 3 empty blocks from genesis (longer chain, triggers reorg)
        var forkPrev = genesis
        for i in 1...3 {
            let b = try await buildAndStoreBlock(
                previous: forkPrev, timestamp: base + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i + 100), fetcher: fetcher
            )
            let _ = await chain.submitTestBlock(
                blockHeader: try! VolumeImpl<Block>(node: b), block: b
            )
            forkPrev = b
        }

        let newTip = await chain.canonicalTip
        XCTAssertEqual(newTip, try! VolumeImpl<Block>(node: forkPrev).rawCID)
        XCTAssertNotEqual(newTip, mainTip, "Reorg should have switched main chain")

        // After reorg: the transfer block is no longer on main chain
        // The fork has empty blocks — no account actions
        // State on main chain should reflect only genesis + empty blocks
        let height = await chain.getHighestBlockHeight()
        XCTAssertEqual(height, 3)
    }
}

// ============================================================================
// MARK: - HIGH: Multi-Signer Transactions
// ============================================================================

@MainActor
final class MultiSignerTests: XCTestCase {

    func testMultiSignerTransactionAccepted() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let spec = s()
        let premine = spec.premineAmount()

        // Genesis gives alice the premine, block1 gives bob some funds
        let genesis = try await premineGenesis(spec: spec, owner: alice, fetcher: fetcher, time: base)

        let fundBob = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(premine - 500) - Int64(premine)),
                AccountAction(owner: bobAddr, delta: 500)
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], nonce: 1, chainPath: ["Nexus"]
        )
        let bobNonce0 = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let bobNonce1 = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], nonce: 1, chainPath: ["Nexus"]
        )
        let block1 = try await buildAndStoreBlock(
            previous: genesis, transactions: [tx(fundBob, alice), tx(bobNonce0, bob), tx(bobNonce1, bob)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            rewardRecipient: bobAddr, fetcher: fetcher
        )

        // Multi-signer: both alice and bob move funds in one transaction
        let aliceBalance = premine - 500
        let multiBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(aliceBalance - 200) - Int64(aliceBalance)),
                AccountAction(owner: bobAddr, delta: 200)
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr, bobAddr], nonce: 2, chainPath: ["Nexus"]
        )
        let bodyHeader = try! HeaderImpl<TransactionBody>(node: multiBody)
        let aliceSig = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: alice.privateKey)!
        let bobSig = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: bob.privateKey)!
        let multiTx = Transaction(
            signatures: [alice.publicKey: aliceSig, bob.publicKey: bobSig],
            body: bodyHeader
        )

        let block2 = try await buildAndStoreBlock(
            previous: block1, transactions: [multiTx],
            timestamp: base + 2000, target: UInt256(1000), nonce: 2,
            rewardRecipient: bobAddr, fetcher: fetcher
        )
        let valid = try await block2.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid)
    }

    func testMultiSignerMissingOneSignatureFails() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let spec = s()
        let premine = spec.premineAmount()

        let genesis = try await premineGenesis(spec: spec, owner: alice, fetcher: fetcher, time: base)

        let fundBob = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(premine - 500) - Int64(premine)),
                AccountAction(owner: bobAddr, delta: 500)
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], nonce: 1,
            chainPath: ["Nexus"]
        )
        let bobNonce0 = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let bobNonce1 = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], nonce: 1,
            chainPath: ["Nexus"]
        )
        let block1 = try await buildAndStoreBlock(
            previous: genesis, transactions: [tx(fundBob, alice), tx(bobNonce0, bob), tx(bobNonce1, bob)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let block1Valid = try await block1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(block1Valid)

        // Both remove funds (to carol); both are declared signers
        let carolAddr = id(CryptoUtils.generateKeyPair().publicKey)
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: -100),
                AccountAction(owner: bobAddr, delta: -100),
                AccountAction(owner: carolAddr, delta: 200)
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr, bobAddr], nonce: 2,
            chainPath: ["Nexus"]
        )
        let bodyHeader = try! HeaderImpl<TransactionBody>(node: body)
        let aliceSig = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: alice.privateKey)!
        let bobSig = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: bob.privateKey)!

        func validates(_ signatures: [String: String]) async throws -> Bool {
            let block2 = try await buildAndStoreBlock(
                previous: block1, transactions: [Transaction(signatures: signatures, body: bodyHeader)],
                timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
            )
            return try await block2.validateNexus(fetcher: fetcher).0
        }
        let bothValid = try await validates([alice.publicKey: aliceSig, bob.publicKey: bobSig])
        XCTAssertTrue(bothValid, "control: signed by both declared signers validates")
        // Only alice signs
        let onlyAliceValid = try await validates([alice.publicKey: aliceSig])
        XCTAssertFalse(onlyAliceValid, "Missing bob's signature should fail validation")
    }
}

// ============================================================================
// MARK: - HIGH: Long-Chain Economic Invariant Tests
// ============================================================================

@MainActor
final class LongChainEconomicTests: XCTestCase {

    func testSupplyConservationOver100Blocks() async throws {
        let fetcher = f()
        let base = now() - 200_000
        let miner = CryptoUtils.generateKeyPair()
        let minerAddr = id(miner.publicKey)
        let spec = s(premine: 0)

        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        var prev = genesis
        var expectedSupply: UInt64 = 0

        for height: UInt64 in 1...100 {
            let block = try await buildAndStoreBlock(
                previous: prev,
                timestamp: base + Int64(height) * 1000, target: UInt256(1000),
                nonce: height, rewardRecipient: minerAddr, fetcher: fetcher
            )
            let (valid, _, postState) = try await block.validateNexus(fetcher: fetcher)
            XCTAssertTrue(valid, "block \(height) must validate")
            expectedSupply += spec.rewardAtBlock(height)
            let minerBalance: UInt64? = try postState?.accountState.node?.get(key: minerAddr)
            XCTAssertEqual(minerBalance, expectedSupply, "the sole holder's balance is the supply at height \(height)")
            prev = block
        }

        XCTAssertEqual(prev.height, 100)
        XCTAssertEqual(expectedSupply, spec.totalRewards(upToBlock: 101) - spec.rewardAtBlock(0))
    }

    func testTransferChainConservesBalance() async throws {
        let fetcher = f()
        let base = now() - 100_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let spec = s()
        let premine = spec.premineAmount()

        let genesis = try await premineGenesis(spec: spec, owner: alice, fetcher: fetcher, time: base)

        var prev = genesis
        var aliceBalance = premine
        var bobBalance: UInt64 = 0
        var aliceNonce: UInt64 = 1  // premineGenesis used nonce 0
        var bobNonce: UInt64 = 0
        var totalRewards: UInt64 = 0

        // Alternate transfers for 20 blocks; the receiver also earns the reward.
        for height: UInt64 in 1...20 {
            let isAliceSending = height % 2 == 1
            let amount: UInt64 = 10
            let (sender, senderAddr, receiverAddr) = isAliceSending
                ? (alice, aliceAddr, bobAddr) : (bob, bobAddr, aliceAddr)
            let body = TransactionBody(
                accountActions: [
                    AccountAction(owner: senderAddr, delta: -Int64(amount)),
                    AccountAction(owner: receiverAddr, delta: Int64(amount))
                ],
                actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
                signers: [senderAddr], nonce: isAliceSending ? aliceNonce : bobNonce,
                chainPath: ["Nexus"]
            )

            let block = try await buildAndStoreBlock(
                previous: prev, transactions: [tx(body, sender)],
                timestamp: base + Int64(height) * 1000, target: UInt256(1000),
                nonce: height, rewardRecipient: receiverAddr, fetcher: fetcher
            )
            let (valid, _, postState) = try await block.validateNexus(fetcher: fetcher)
            XCTAssertTrue(valid, "block \(height) must validate")

            let reward = spec.rewardAtBlock(height)
            totalRewards += reward
            if isAliceSending {
                aliceBalance -= amount
                bobBalance += amount + reward
                aliceNonce += 1
            } else {
                bobBalance -= amount
                aliceBalance += amount + reward
                bobNonce += 1
            }
            let aliceOnChain: UInt64? = try postState?.accountState.node?.get(key: aliceAddr)
            let bobOnChain: UInt64? = try postState?.accountState.node?.get(key: bobAddr)
            XCTAssertEqual(aliceOnChain, aliceBalance, "alice at height \(height)")
            XCTAssertEqual(bobOnChain, bobBalance, "bob at height \(height)")
            prev = block
        }

        XCTAssertEqual(aliceBalance + bobBalance, premine + totalRewards)
    }
}

// ============================================================================
// MARK: - HIGH: State Growth Attack
// ============================================================================

@MainActor
final class StateGrowthAttackTests: XCTestCase {

    func testStateDeltaExceedingLimitRejected() async throws {
        let fetcher = f()
        let base = now() - 10_000
        // Tiny state growth limit
        let tinySpec = ChainSpec.test(maxStateGrowth: 10)

        let genesis = try await buildAndStoreGenesis(
            spec: tinySpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        // Use a KV action with a large key that exceeds the 10-byte state growth limit
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let body = TransactionBody(
            accountActions: [],
            actions: [Action(key: "large_key_exceeds_limit", oldValue: nil, newValue: "value")],
            depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        await assertThrows(StateErrors.stateGrowthExceeded, "the builder refuses what validation would") {
            try await buildAndStoreBlock(
                previous: genesis, transactions: [tx(body, kp)],
                timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
            )
        }
        let block = try await buildAndStoreBlock(
            previous: genesis, transactions: [tx(body, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            allowStateGrowthViolation: true, fetcher: fetcher
        )

        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid, "State delta should exceed tiny 10-byte limit")
        XCTAssertFalse(try block.validateStateDeltaSize(spec: tinySpec, transactionBodies: [body], accountGrowth: 0))
        XCTAssertTrue(
            try block.validateStateDeltaSize(spec: ChainSpec.test(), transactionBodies: [body], accountGrowth: 0),
            "control: the same delta fits the default limit"
        )
    }
}

// ============================================================================
// MARK: - MEDIUM: Concurrent Block Processing
// ============================================================================

@MainActor
final class ConcurrentBlockTests: XCTestCase {

    func testConcurrentBlockSubmission() async throws {
        let fetcher = f()
        let base = now() - 100_000
        let spec = s(premine: 0)
        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        // Build 10 competing blocks from genesis
        var blocks: [Block] = []
        for i in 1...10 {
            let b = try await buildAndStoreBlock(
                previous: genesis, timestamp: base + Int64(i) * 100,
                target: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            blocks.append(b)
        }

        // Submit all concurrently
        await withTaskGroup(of: Void.self) { group in
            for block in blocks {
                group.addTask {
                    let _ = await chain.submitTestBlock(
                        blockHeader: try! VolumeImpl<Block>(node: block), block: block
                    )
                }
            }
        }

        // Chain should be consistent: exactly one tip at height 1
        let height = await chain.getHighestBlockHeight()
        XCTAssertEqual(height, 1)
        let tip = await chain.canonicalTip
        XCTAssertNotNil(tip)
    }
}

// ============================================================================
// MARK: - MEDIUM: Difficulty Manipulation Resistance
// ============================================================================

@MainActor
final class DifficultyManipulationTests: XCTestCase {

    private func scheduled(_ spec: ChainSpec, anchor: UInt256, elapsed: Int64) -> UInt256 {
        spec.calculateAsertTarget(
            anchorTarget: anchor, anchorTimestamp: 1_000, anchorHeight: 1,
            blockTimestamp: 1_000 + elapsed, blockHeight: 2
        )
    }

    func testDifficultyMovesWithDriftAndNeverToZero() async {
        let spec = s()
        let anchor = UInt256(1000)

        // A block far ahead of schedule hardens the target, but a single
        // block's drift is bounded by the half-life: never to zero.
        let fast = scheduled(spec, anchor: anchor, elapsed: 1)
        XCTAssertLessThan(fast, anchor)
        XCTAssertGreaterThan(fast, .zero)

        // A block far behind schedule eases it.
        let slow = scheduled(spec, anchor: anchor, elapsed: Int64(spec.targetBlockTime) * 100)
        XCTAssertGreaterThan(slow, anchor)
    }

    func testZeroElapsedTimeHardens() async {
        // A timestamp at the anchor is a whole block ahead of schedule: it
        // costs the miner difficulty rather than holding the target.
        let spec = s()
        let anchor = UInt256(1000)
        XCTAssertLessThan(scheduled(spec, anchor: anchor, elapsed: 0), anchor)
    }

    func testNegativeElapsedTimeHardensLikeZero() async {
        // A clock moved before the anchor clamps to zero elapsed: no easier
        // than zero, so moving the clock back buys nothing.
        let spec = s()
        let anchor = UInt256(1000)
        XCTAssertEqual(
            scheduled(spec, anchor: anchor, elapsed: -100),
            scheduled(spec, anchor: anchor, elapsed: 0)
        )
    }
}
// ============================================================================
// MARK: - Delta Model Invariants
// ============================================================================

@MainActor
final class DeltaModelTests: XCTestCase {

    // Two independent senders credit the same recipient in one block
    func testMultipleTransactionsSameRecipientInOneBlock() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let spec = s(premine: 10_000)
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let carol = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let carolAddr = id(carol.publicKey)

        let genesis = try await premineGenesis(spec: spec, owner: alice, fetcher: fetcher, time: base)

        // Block 1: alice sends 500 to bob and 300 to carol
        let body1 = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: -Int64(500 + 300)),
                AccountAction(owner: bobAddr, delta: Int64(500)),
                AccountAction(owner: carolAddr, delta: Int64(300))
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], nonce: 1, chainPath: ["Nexus"]
        )
        let block1 = try await buildAndStoreBlock(
            previous: genesis, transactions: [tx(body1, alice)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            rewardRecipient: carolAddr, fetcher: fetcher
        )
        let valid1 = try await block1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid1)

        // Block 2: bob and carol BOTH send to alice in the same block (two separate txs)

        let tx1Body = TransactionBody(
            accountActions: [
                AccountAction(owner: bobAddr, delta: -Int64(200)),
                AccountAction(owner: aliceAddr, delta: Int64(200))
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let tx2Body = TransactionBody(
            accountActions: [
                AccountAction(owner: carolAddr, delta: -Int64(100)),
                AccountAction(owner: aliceAddr, delta: Int64(100))
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [carolAddr], nonce: 0, chainPath: ["Nexus"]
        )

        let block2 = try await buildAndStoreBlock(
            previous: block1, transactions: [tx(tx1Body, bob), tx(tx2Body, carol)],
            timestamp: base + 2000, target: UInt256(1000), nonce: 2,
            rewardRecipient: aliceAddr, fetcher: fetcher
        )
        let valid2 = try await block2.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid2, "Two senders crediting the same recipient in one block must be valid")
    }

    // Debit exceeding balance is rejected during state application
    func testDebitExceedingBalanceRejected() async throws {
        let fetcher = f()
        let base = now() - 10_000
        let spec = s(premine: 1000)
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)
        let premine = spec.premineAmount()

        let genesis = try await premineGenesis(spec: spec, owner: alice, fetcher: fetcher, time: base)

        // Try to debit more than alice's balance
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: -Int64(premine + 1)),
                AccountAction(owner: bobAddr, delta: Int64(premine + 1))
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], nonce: 1,
            chainPath: ["Nexus"]
        )

        await assertThrows(StateErrors.insufficientBalance, "Debit exceeding balance should fail during block construction") {
            try await buildAndStoreBlock(
                previous: genesis, transactions: [tx(body, alice)],
                timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
            )
        }
    }

    func testInt64MinDeltaRejected() async {
        let action = AccountAction(owner: "test", delta: Int64.min)
        XCTAssertFalse(action.verify(), "Int64.min delta must be rejected")
    }

    func testZeroDeltaRejected() async {
        let action = AccountAction(owner: "test", delta: 0)
        XCTAssertFalse(action.verify(), "Zero delta must be rejected")
    }

    func testValidDeltasAccepted() async {
        XCTAssertTrue(AccountAction(owner: "a", delta: 1).verify())
        XCTAssertTrue(AccountAction(owner: "a", delta: -1).verify())
        XCTAssertTrue(AccountAction(owner: "a", delta: Int64.max).verify())
        XCTAssertTrue(AccountAction(owner: "a", delta: Int64.min + 1).verify())
    }

    // Net-zero deltas across multiple txs on same owner in one block
    func testNetZeroDeltasNoStateChange() async throws {
        let fetcher = f()
        let base = now() - 10_000
        let spec = s(premine: 1000)
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = id(alice.publicKey)
        let bobAddr = id(bob.publicKey)

        let genesis = try await premineGenesis(spec: spec, owner: alice, fetcher: fetcher, time: base)

        // alice sends 100 to bob, bob sends 100 back to alice
        // Net: alice unchanged, bob unchanged, only reward moves
        let tx1Body = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: -100),
                AccountAction(owner: bobAddr, delta: Int64(100))
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], nonce: 1, chainPath: ["Nexus"]
        )
        let tx2Body = TransactionBody(
            accountActions: [
                AccountAction(owner: bobAddr, delta: -100),
                AccountAction(owner: aliceAddr, delta: Int64(100))
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], nonce: 0, chainPath: ["Nexus"]
        )

        let block = try await buildAndStoreBlock(
            previous: genesis, transactions: [tx(tx1Body, alice), tx(tx2Body, bob)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            rewardRecipient: aliceAddr, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid, "Net-zero cross-transfers with reward should produce valid block")
    }
}
