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
    spec: ChainSpec, owner kp: (privateKey: String, publicKey: String),
    fetcher: StorableFetcher, time: Int64
) async throws -> Block {
    let addr = id(kp.publicKey)
    let body = TransactionBody(
        accountActions: [AccountAction(owner: addr, delta: Int64(spec.premineAmount()))],
        actions: [], depositActions: [], receiptActions: [], withdrawalActions: [], signers: [addr], nonce: 0,
        chainPath: ["Nexus"]
    )
    return try await buildAndStoreGenesis(
        spec: spec, transactions: [tx(body, kp)],
        timestamp: time, target: UInt256(1000), fetcher: fetcher
    )
}

// ============================================================================
// MARK: - 1. Double Claim: Same Swap Claimed Twice
// ============================================================================

@MainActor
final class DoubleClaimTests: XCTestCase {

    func testSameSwapCannotBeClaimedTwice() async throws {
        let fetcher = f()
        let base = now() - 40_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let childSpec = s("Child")
        let nexusSpec = s("Nexus", premine: 0)
        let amount: UInt64 = 500

        let childGenesis = try await premineGenesis(spec: childSpec, owner: kp, fetcher: fetcher, time: base)
        let nexusGenesis = try await buildAndStoreGenesis(
            spec: nexusSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let childSwap = DepositAction(nonce: 1, demander: kpAddr, amountDemanded: amount, amountDeposited: amount)
        let childSwapKey = DepositKey(depositAction: childSwap).description

        let swapBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: -Int64(amount))],
            actions: [],
            depositActions: [childSwap],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], nonce: 1,
            chainPath: ["Nexus"]
        )
        let childBlock1 = try await buildAndStoreBlock(
            previous: childGenesis, transactions: [tx(swapBody, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // The receipt's payment is funded by the coinbase.
        let settleBody = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], receiptActions: [ReceiptAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: amount, directory: "Child")],
            withdrawalActions: [],
            signers: [kpAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let nexusBlock1 = try await buildAndStoreBlock(
            previous: nexusGenesis, transactions: [tx(settleBody, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            rewardRecipient: kpAddr, fetcher: fetcher
        )

        let c1Body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(amount))],
            actions: [], depositActions: [],
            receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: amount, amountWithdrawn: amount)],
            signers: [kpAddr], nonce: 2,
            chainPath: ["Nexus"]
        )
        let childBlock2 = try await buildAndStoreBlock(
            previous: childBlock1,
            transactions: [tx(c1Body, kp)],
            parentChainBlock: nexusBlock1,
            timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
        )

        let c2Body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(amount))],
            actions: [], depositActions: [],
            receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: amount, amountWithdrawn: amount)],
            signers: [kpAddr], nonce: 3,
            chainPath: ["Nexus"]
        )

        await assertThrows(StateErrors.conflictingActions, "Second claim of same swap should fail because the deposit is marked spent") {
            try await buildAndStoreBlock(
                previous: childBlock2,
                transactions: [tx(c2Body, kp)],
                parentChainBlock: nexusBlock1,
                timestamp: base + 3000, target: UInt256(1000), nonce: 3, fetcher: fetcher
            )
        }
    }
}

// ============================================================================
// MARK: - 2. Phantom Settle: Settle Without Corresponding Swap
// ============================================================================

@MainActor
final class PhantomSettleTests: XCTestCase {

    func testSettleAcceptedButClaimWithoutSwapFails() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let childSpec = s("Child")
        let nexusSpec = s("Nexus", premine: 0)

        let childGenesis = try await premineGenesis(spec: childSpec, owner: kp, fetcher: fetcher, time: base)
        let nexusGenesis = try await buildAndStoreGenesis(
            spec: nexusSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let phantomSwapKey = DepositKey(depositAction: DepositAction(nonce: 99, demander: kpAddr, amountDemanded: 1000, amountDeposited: 1000)).description

        let settleBody = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], receiptActions: [ReceiptAction(withdrawer: kpAddr, nonce: 99, demander: kpAddr, amountDemanded: 1000, directory: "Child")],
            withdrawalActions: [],
            signers: [kpAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let nexusBlock1 = try await buildAndStoreBlock(
            previous: nexusGenesis, transactions: [tx(settleBody, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, rewardRecipient: kpAddr, fetcher: fetcher
        )
        let nv = try await nexusBlock1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(nv, "Settle is accepted on nexus — nexus doesn't cross-verify swaps")

        let claimBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: 1000)],
            actions: [], depositActions: [],
            receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: kpAddr, nonce: 99, demander: kpAddr, amountDemanded: 1000, amountWithdrawn: 1000)],
            signers: [kpAddr], nonce: 1,
            chainPath: ["Nexus"]
        )

        let childBlock1 = try await buildAndStoreBlock(
            previous: childGenesis, timestamp: base + 1000,
            target: UInt256(1000), nonce: 1, rewardRecipient: kpAddr, fetcher: fetcher
        )

        do {
            let badBlock = try await buildAndStoreBlock(
                previous: childBlock1,
                transactions: [tx(claimBody, kp)],
                parentChainBlock: nexusBlock1,
                timestamp: base + 2000, target: UInt256(1000), nonce: 2, rewardRecipient: kpAddr, fetcher: fetcher
            )
            let valid = try await badBlock.validateNexus(fetcher: fetcher).0
            XCTAssertFalse(valid, "Claim referencing phantom swap should fail validation")
        } catch {
            // No spendable deposit exists, so the phantom swap is rejected.
        }
    }
}

// ============================================================================
// MARK: - 3. Cross-Chain Replay: Child A Swap Claimed on Child B
// ============================================================================

@MainActor
final class CrossChainReplayTests: XCTestCase {

    func testSwapOnChildACannotBeClaimedOnChildB() async throws {
        let fetcher = f()
        let base = now() - 40_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)

        let childASpec = s("ChildA")
        let childBSpec = s("ChildB")
        let nexusSpec = s("Nexus", premine: 0)
        let amount: UInt64 = 500

        let childAGenesis = try await premineGenesis(spec: childASpec, owner: kp, fetcher: fetcher, time: base)
        let childBGenesis = try await premineGenesis(spec: childBSpec, owner: kp, fetcher: fetcher, time: base)
        let nexusGenesis = try await buildAndStoreGenesis(
            spec: nexusSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let childASwap = DepositAction(nonce: 1, demander: kpAddr, amountDemanded: amount, amountDeposited: amount)
        let childASwapKey = DepositKey(depositAction: childASwap).description

        let swapBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: -Int64(amount))],
            actions: [],
            depositActions: [childASwap],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], nonce: 1,
            chainPath: ["Nexus"]
        )
        let _ = try await buildAndStoreBlock(
            previous: childAGenesis, transactions: [tx(swapBody, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        // The receipt's payment is funded by the coinbase.
        let settleBody = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], receiptActions: [ReceiptAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: amount, directory: "ChildA")],
            withdrawalActions: [],
            signers: [kpAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let nexusBlock1 = try await buildAndStoreBlock(
            previous: nexusGenesis, transactions: [tx(settleBody, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            rewardRecipient: kpAddr, fetcher: fetcher
        )

        let replayBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(amount))],
            actions: [], depositActions: [],
            receiptActions: [],
            withdrawalActions: [WithdrawalAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: amount, amountWithdrawn: amount)],
            signers: [kpAddr], nonce: 1,
            chainPath: ["Nexus"]
        )

        // No spendable swap key exists in child B's depositState.
        await assertThrows(StateErrors.conflictingActions, "Claim on child B using child A swap should fail — no swap exists on B") {
            try await buildAndStoreBlock(
                previous: childBGenesis,
                transactions: [tx(replayBody, kp)],
                parentChainBlock: nexusBlock1,
                timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
            )
        }
    }
}

// ============================================================================
// MARK: - 4. Selfish Mining: Withheld Chain vs Honest Chain
// ============================================================================

@MainActor
final class SelfishMiningTests: XCTestCase {

    func testWithheldEqualWorkUsesStableSegmentBase() async throws {
        let fetcher = f()
        let base = now() - 100_000
        let spec = s(premine: 0)
        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        // Honest miner publishes 3 blocks immediately
        var honestPrev = genesis
        var honestBase: Block?
        for i in 1...3 {
            let b = try await buildAndStoreBlock(
                previous: honestPrev, timestamp: base + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            if honestBase == nil { honestBase = b }
            let _ = await chain.submitTestBlock(
                blockHeader: try! VolumeImpl<Block>(node: b), block: b
            )
            honestPrev = b
        }

        let honestTip = await chain.canonicalTip
        XCTAssertEqual(honestTip, try! VolumeImpl<Block>(node: honestPrev).rawCID)

        // Selfish miner withholds 3 blocks (same length), publishes all at once
        var selfishBlocks: [Block] = []
        var selfishPrev = genesis
        for i in 1...3 {
            let b = try await buildAndStoreBlock(
                previous: selfishPrev, timestamp: base + Int64(i) * 500,
                target: UInt256(1000), nonce: UInt64(i + 200), fetcher: fetcher
            )
            selfishBlocks.append(b)
            selfishPrev = b
        }

        // Submit all withheld blocks
        for b in selfishBlocks {
            let _ = await chain.submitTestBlock(
                blockHeader: try! VolumeImpl<Block>(node: b), block: b
            )
        }

        let honestBaseHash = try VolumeImpl<Block>(node: honestBase!).rawCID
        let selfishBaseHash = try VolumeImpl<Block>(node: selfishBlocks[0]).rawCID
        let selfishTip = try VolumeImpl<Block>(node: selfishBlocks[2]).rawCID
        let selfishWins = forkChoicePrefersBlock(
            selfishBaseHash,
            over: honestBaseHash
        )
        let finalTip = await chain.canonicalTip
        XCTAssertEqual(finalTip, selfishWins ? selfishTip : honestTip)
    }

    func testLongerSelfishChainDoesReorg() async throws {
        let fetcher = f()
        let base = now() - 100_000
        let spec = s(premine: 0)
        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        // Honest: 3 blocks
        var honestPrev = genesis
        for i in 1...3 {
            let b = try await buildAndStoreBlock(
                previous: honestPrev, timestamp: base + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            let _ = await chain.submitTestBlock(
                blockHeader: try! VolumeImpl<Block>(node: b), block: b
            )
            honestPrev = b
        }

        // Selfish: 4 blocks (longer, wins)
        var selfishPrev = genesis
        for i in 1...4 {
            let b = try await buildAndStoreBlock(
                previous: selfishPrev, timestamp: base + Int64(i) * 500,
                target: UInt256(1000), nonce: UInt64(i + 300), fetcher: fetcher
            )
            let _ = await chain.submitTestBlock(
                blockHeader: try! VolumeImpl<Block>(node: b), block: b
            )
            selfishPrev = b
        }

        let finalTip = await chain.canonicalTip
        XCTAssertEqual(finalTip, try! VolumeImpl<Block>(node: selfishPrev).rawCID, "Longer chain wins regardless of timing")
    }
}

// ============================================================================
// MARK: - 5. Chain Policies End-to-End in Block Validation
// ============================================================================

@MainActor
final class ChainPolicyBlockTests: XCTestCase {

    func testAcceptingTransactionPolicyAllowsBlockValidation() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)

        let acceptingPolicy = try await storeWasmPolicy(accepts: true, scope: .transaction, fetcher: fetcher)
        let policySpec = ChainSpec.test(wasmPolicies: [acceptingPolicy])

        let genesis = try await buildAndStoreGenesis(
            spec: policySpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let body = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let block = try await buildAndStoreBlock(
            previous: genesis, transactions: [tx(body, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, rewardRecipient: kpAddr, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid)
    }

    func testRejectingTransactionPolicyFailsBlockValidation() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)

        let rejectingPolicy = try await storeWasmPolicy(accepts: false, scope: .transaction, fetcher: fetcher)
        let filteredSpec = ChainSpec.test(wasmPolicies: [rejectingPolicy])

        let genesis = try await buildAndStoreGenesis(
            spec: filteredSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )


        // Block rejected by the chain's transaction policy.
        let lowFeeBody = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let lowFeeBlock = try await buildAndStoreBlock(
            previous: genesis, transactions: [tx(lowFeeBody, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, rewardRecipient: kpAddr, fetcher: fetcher
        )
        let lowFeeValid = try await lowFeeBlock.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(lowFeeValid, "Block rejected by chain policy should fail validation")
    }

    func testRejectingActionPolicyFailsBlockValidation() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)

        let rejectingPolicy = try await storeWasmPolicy(accepts: false, scope: .action, fetcher: fetcher)
        let policySpec = ChainSpec.test(wasmPolicies: [rejectingPolicy])

        let genesis = try await buildAndStoreGenesis(
            spec: policySpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let body = TransactionBody(
            accountActions: [],
            actions: [Action(key: "policy/test", oldValue: nil, newValue: "value")],
            depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let block = try await buildAndStoreBlock(
            previous: genesis, transactions: [tx(body, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, rewardRecipient: kpAddr, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid, "Block rejected by action-scoped chain policy should fail validation")
    }

    func testPolicySeesValidatedBlockHeightTimestampAndParentTimestamp() async throws {
        let base = now() - 20_000
        let blockTimestamp = base + 1000
        // (offset, minimum, expected validity of a height-1 block at blockTimestamp)
        let cases: [(Int, Int64, Bool)] = [
            (wasmPolicyContextHeightOffset, 1, true),
            (wasmPolicyContextHeightOffset, 2, false),
            (wasmPolicyContextTimestampOffset, blockTimestamp, true),
            (wasmPolicyContextTimestampOffset, blockTimestamp + 1, false),
            (wasmPolicyContextParentTimestampOffset, base, true),
            (wasmPolicyContextParentTimestampOffset, base + 1, false),
        ]
        for (offset, minimum, expected) in cases {
            let fetcher = f()
            let kp = CryptoUtils.generateKeyPair()
            let kpAddr = id(kp.publicKey)
            let policy = try await storeWasmPolicy(contextFieldAt: offset, atLeast: minimum, fetcher: fetcher)
            let policySpec = ChainSpec.test(wasmPolicies: [policy])
            // Genesis carries no transactions, so the policy is not exercised there.
            let genesis = try await buildAndStoreGenesis(
                spec: policySpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
            )
            let body = TransactionBody(
                accountActions: [],
                actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
                signers: [kpAddr], nonce: 0, chainPath: ["Nexus"]
            )
            let block = try await buildAndStoreBlock(
                previous: genesis, transactions: [tx(body, kp)],
                timestamp: blockTimestamp, target: UInt256(1000), nonce: 1, rewardRecipient: kpAddr, fetcher: fetcher
            )
            let valid = try await block.validateNexus(fetcher: fetcher).0
            XCTAssertEqual(valid, expected, "offset \(offset), minimum \(minimum)")
        }
    }
}

// ============================================================================
// MARK: - 6. General State (Action) Mutations Through Block Lifecycle
// ============================================================================

@MainActor
final class GeneralStateBlockTests: XCTestCase {

    func testInsertReadUpdateDeleteGeneralState() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let spec = s(premine: 0)

        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        // Block 1: Insert key-value pair
        let insertBody = TransactionBody(
            accountActions: [],
            actions: [Action(key: "greeting", oldValue: nil, newValue: "hello")],
            depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let block1 = try await buildAndStoreBlock(
            previous: genesis, transactions: [tx(insertBody, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, rewardRecipient: kpAddr, fetcher: fetcher
        )
        let v1 = try await block1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(v1)
        XCTAssertNotEqual(block1.postState.rawCID, block1.prevState.rawCID)

        // Block 2: Update the value
        let updateBody = TransactionBody(
            accountActions: [],
            actions: [Action(key: "greeting", oldValue: "hello", newValue: "world")],
            depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], nonce: 1, chainPath: ["Nexus"]
        )
        let block2 = try await buildAndStoreBlock(
            previous: block1, transactions: [tx(updateBody, kp)],
            timestamp: base + 2000, target: UInt256(1000), nonce: 2, rewardRecipient: kpAddr, fetcher: fetcher
        )
        let v2 = try await block2.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(v2)

        // Block 3: Delete the key
        let deleteBody = TransactionBody(
            accountActions: [],
            actions: [Action(key: "greeting", oldValue: "world", newValue: nil)],
            depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], nonce: 2, chainPath: ["Nexus"]
        )
        let block3 = try await buildAndStoreBlock(
            previous: block2, transactions: [tx(deleteBody, kp)],
            timestamp: base + 3000, target: UInt256(1000), nonce: 3, rewardRecipient: kpAddr, fetcher: fetcher
        )
        let v3 = try await block3.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(v3)
    }

    func testInsertWithWrongOldValueFails() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let spec = s(premine: 0)

        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let insertBody = TransactionBody(
            accountActions: [],
            actions: [Action(key: "key1", oldValue: nil, newValue: "value1")],
            depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let block1 = try await buildAndStoreBlock(
            previous: genesis, transactions: [tx(insertBody, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, rewardRecipient: kpAddr, fetcher: fetcher
        )

        // Update with wrong oldValue
        let wrongBody = TransactionBody(
            accountActions: [],
            actions: [Action(key: "key1", oldValue: "WRONG", newValue: "value2")],
            depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], nonce: 1,
            chainPath: ["Nexus"]
        )

        do {
            let _ = try await buildAndStoreBlock(
                previous: block1, transactions: [tx(wrongBody, kp)],
                timestamp: base + 2000, target: UInt256(1000), nonce: 2, rewardRecipient: kpAddr, fetcher: fetcher
            )
            XCTFail("Update with wrong oldValue should throw")
        } catch {
            // GeneralState.updateState checks oldValue matches actual
        }
    }
}
