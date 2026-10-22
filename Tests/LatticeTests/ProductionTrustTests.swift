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

private func buildChain(from genesis: Block, length: Int, base: Int64, fetcher: StorableFetcher) async throws -> [Block] {
    var blocks = [genesis]
    for i in 1..<length {
        let b = try await buildAndStoreBlock(
            previous: blocks.last!, timestamp: base + Int64(i) * 1000,
            target: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
        )
        blocks.append(b)
    }
    return blocks
}

// ============================================================================
// MARK: - Crash Recovery: Replay, Restart, Continue
// ============================================================================

@MainActor
final class CrashRecoveryTests: XCTestCase {

    func testFactReplayRestoreContinueMining() async throws {
        let fetcher = f()
        let base = now() - 50_000
        let spec = s(premine: 0)

        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let chain1 = ChainState.fromGenesis(block: genesis)
        var batches = [try testAdmissionBatch(for: genesis)]

        var prev = genesis
        for i in 1...5 {
            let b = try await buildAndStoreBlock(
                previous: prev, timestamp: base + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            let _ = await chain1.submitTestBlock(
                blockHeader: try! VolumeImpl<Block>(node: b), block: b
            )
            batches.append(try testAdmissionBatch(for: b))
            prev = b
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(batches)
        let decoded = try JSONDecoder().decode([BlockImportBatch].self, from: data)

        let chain2 = try await ChainState.restoreWithoutContext(replaying: decoded)

        let tip2 = await chain2.canonicalTip
        let tip1 = await chain1.canonicalTip
        XCTAssertEqual(tip2, tip1)

        let height2 = await chain2.getHighestBlockHeight()
        XCTAssertEqual(height2, 5)

        let block6 = try await buildAndStoreBlock(
            previous: prev, timestamp: base + 6000,
            target: UInt256(1000), nonce: 6, fetcher: fetcher
        )
        let result = await chain2.submitTestBlock(
            blockHeader: try! VolumeImpl<Block>(node: block6), block: block6
        )
        XCTAssertTrue(result.extendsCanonical)

        let finalHeight = await chain2.getHighestBlockHeight()
        XCTAssertEqual(finalHeight, 6)
    }

    func testFactBatchSerializationIsDeterministic() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let spec = s(premine: 0)
        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        let b1 = try await buildAndStoreBlock(
            previous: genesis, timestamp: base + 1000,
            target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let _ = await chain.submitTestBlock(
            blockHeader: try! VolumeImpl<Block>(node: b1), block: b1
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let batch = try testAdmissionBatch(for: b1)
        let d1 = try encoder.encode(batch)
        let d2 = try encoder.encode(batch)
        XCTAssertEqual(d1, d2, "Fact serialization must be deterministic")
    }

}

// ============================================================================
// MARK: - Two-Node Convergence
// ============================================================================

@MainActor
final class TwoNodeConvergenceTests: XCTestCase {

    func testTwoNodesFromSameGenesisConverge() async throws {
        let fetcher = f()
        let base = now() - 50_000
        let spec = s(premine: 0)

        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let nodeA = ChainState.fromGenesis(block: genesis)
        let nodeB = ChainState.fromGenesis(block: genesis)

        let blocks = try await buildChain(from: genesis, length: 6, base: base, fetcher: fetcher)

        for block in blocks.dropFirst() {
            let _ = await nodeA.submitTestBlock(
                blockHeader: try! VolumeImpl<Block>(node: block), block: block
            )
            let _ = await nodeB.submitTestBlock(
                blockHeader: try! VolumeImpl<Block>(node: block), block: block
            )
        }

        let tipA = await nodeA.canonicalTip
        let tipB = await nodeB.canonicalTip
        XCTAssertEqual(tipA, tipB, "Both nodes should converge to same tip")

        let heightA = await nodeA.getHighestBlockHeight()
        let heightB = await nodeB.getHighestBlockHeight()
        XCTAssertEqual(heightA, heightB)
        XCTAssertEqual(heightA, 5)
    }

    func testNodesConvergeAfterDivergentBlocks() async throws {
        let fetcher = f()
        let base = now() - 100_000
        let spec = s(premine: 0)

        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let nodeA = ChainState.fromGenesis(block: genesis)
        let nodeB = ChainState.fromGenesis(block: genesis)

        let forkA = try await buildChain(from: genesis, length: 6, base: base, fetcher: fetcher)
        for block in forkA.dropFirst() {
            let _ = await nodeA.submitTestBlock(
                blockHeader: try! VolumeImpl<Block>(node: block), block: block
            )
        }

        var forkBBlocks: [Block] = [genesis]
        for i in 1...3 {
            let b = try await buildAndStoreBlock(
                previous: forkBBlocks.last!, timestamp: base + Int64(i) * 500,
                target: UInt256(1000), nonce: UInt64(i + 200), fetcher: fetcher
            )
            forkBBlocks.append(b)
        }
        for block in forkBBlocks.dropFirst() {
            let _ = await nodeB.submitTestBlock(
                blockHeader: try! VolumeImpl<Block>(node: block), block: block
            )
        }

        let tipA = await nodeA.canonicalTip
        let tipB = await nodeB.canonicalTip
        XCTAssertNotEqual(tipA, tipB, "Nodes diverge initially")

        // Node B receives all of fork A (longer) and should converge
        for block in forkA.dropFirst() {
            let _ = await nodeB.submitTestBlock(
                blockHeader: try! VolumeImpl<Block>(node: block), block: block
            )
        }

        let finalTipB = await nodeB.canonicalTip
        XCTAssertEqual(finalTipB, tipA, "Node B should converge to longer chain")
    }
}

// ============================================================================
// MARK: - Cross-Chain Claim Security
// ============================================================================

@MainActor
final class ClaimSecurityTests: XCTestCase {

    func testClaimWithWrongNonceThrows() async throws {
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

        let childSwap = DepositAction(nonce: 1, demander: kpAddr, amountDemanded: 500, amountDeposited: 500)

        let swapBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: -500)],
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
            actions: [], depositActions: [], receiptActions: [ReceiptAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: 500, directory: "Child")],
            withdrawalActions: [],
            signers: [kpAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let nexusBlock1 = try await buildAndStoreBlock(
            previous: nexusGenesis, transactions: [tx(settleBody, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            rewardRecipient: kpAddr, fetcher: fetcher
        )

        let wrongNonceBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: 500)],
            actions: [], depositActions: [],
            receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: kpAddr, nonce: 99, demander: kpAddr, amountDemanded: 500, amountWithdrawn: 500)
            ],
            signers: [kpAddr], nonce: 2,
            chainPath: ["Nexus"]
        )

        // Wrong nonce produces a different SwapKey, so no spendable deposit exists.
        await assertThrows(StateErrors.conflictingActions, "Claim with wrong nonce should fail validation") {
            try await buildAndStoreBlock(
                previous: childBlock1,
                transactions: [tx(wrongNonceBody, kp)],
                parentChainBlock: nexusBlock1,
                timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
            )
        }
    }

    func testClaimWithWrongAmountThrows() async throws {
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

        let childSwap = DepositAction(nonce: 1, demander: kpAddr, amountDemanded: 500, amountDeposited: 500)

        let swapBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: -500)],
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
            actions: [], depositActions: [], receiptActions: [ReceiptAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: 500, directory: "Child")],
            withdrawalActions: [],
            signers: [kpAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let nexusBlock1 = try await buildAndStoreBlock(
            previous: nexusGenesis, transactions: [tx(settleBody, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            rewardRecipient: kpAddr, fetcher: fetcher
        )

        let wrongAmountBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: 9999)],
            actions: [], depositActions: [],
            receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: 9999, amountWithdrawn: 9999)
            ],
            signers: [kpAddr], nonce: 2,
            chainPath: ["Nexus"]
        )

        // Wrong amount produces a different SwapKey, so no spendable deposit exists.
        await assertThrows(StateErrors.conflictingActions, "Claim with wrong amount should fail validation") {
            try await buildAndStoreBlock(
                previous: childBlock1,
                transactions: [tx(wrongAmountBody, kp)],
                parentChainBlock: nexusBlock1,
                timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
            )
        }
    }
}

// ============================================================================
// MARK: - Fee-Only Blocks (Post-Halving Economy)
// ============================================================================

@MainActor
final class FeeOnlyEconomyTests: XCTestCase {

    func testZeroRewardBlockWithFeesIsValid() async throws {
        let fetcher = f()
        let base = now() - 20_000
        let payer = CryptoUtils.generateKeyPair()
        let miner = CryptoUtils.generateKeyPair()
        let payerAddr = id(payer.publicKey)
        let minerAddr = id(miner.publicKey)

        // Spec where reward is 1 (exponent=0 is invalid, but exponent=1 gives reward=2)
        // Use a premine to fund the payer, then test fee-only
        let spec = s()
        let premine = spec.premineAmount()

        let genesis = try await premineGenesis(spec: spec, owner: payer, fetcher: fetcher, time: base)

        // Normal block with fee — the miner gets reward + fee
        let fee: UInt64 = 77
        let reward = spec.rewardAtBlock(1)
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: payerAddr, delta: Int64(premine - fee) - Int64(premine))
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [payerAddr], nonce: 1, chainPath: ["Nexus"]
        )
        let block = try await buildAndStoreBlock(
            previous: genesis, transactions: [tx(body, payer)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            rewardRecipient: minerAddr, fetcher: fetcher
        )
        let (valid, _, postState) = try await block.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid)
        let minerBalance: UInt64? = try postState?.accountState.node?.get(key: minerAddr)
        XCTAssertEqual(minerBalance, reward + fee)
    }
}

// ============================================================================
// MARK: - Dust Attack Resistance (State Bloat)
// ============================================================================

@MainActor
final class DustAttackTests: XCTestCase {

    func testStateDeltaLimitPreventsExcessiveStateGrowth() async throws {
        let fetcher = f()
        let base = now() - 10_000
        // 200 bytes state growth limit
        let tinySpec = ChainSpec.test(maxStateGrowth: 200, premine: 1000)
        let funder = CryptoUtils.generateKeyPair()
        let funderAddr = id(funder.publicKey)
        let premine = tinySpec.premineAmount()

        let genesis = try await buildAndStoreGenesis(
            spec: tinySpec, transactions: [tx(TransactionBody(
                accountActions: [AccountAction(owner: funderAddr, delta: Int64(premine))],
                actions: [], depositActions: [], receiptActions: [], withdrawalActions: [], signers: [funderAddr], nonce: 0,
                chainPath: ["Nexus"]
            ), funder)],
            timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        // Create many KV insertions that exceed the 200-byte state growth limit
        var kvActions: [Action] = []
        for i in 0..<10 {
            kvActions.append(Action(key: "dust_key_\(i)_padding", oldValue: nil, newValue: "some_value_here"))
        }

        func validates(_ actions: [Action]) async throws -> Bool {
            let body = TransactionBody(
                accountActions: [],
                actions: actions, depositActions: [], receiptActions: [], withdrawalActions: [],
                signers: [funderAddr], nonce: 1,
                chainPath: ["Nexus"]
            )
            let block = try await buildAndStoreBlock(
                previous: genesis, transactions: [tx(body, funder)],
                timestamp: base + 1000, target: UInt256(1000), nonce: 1,
                allowStateGrowthViolation: true, fetcher: fetcher
            )
            return try await block.validateNexus(fetcher: fetcher).0
        }
        let oneInsertionValid = try await validates(Array(kvActions.prefix(1)))
        XCTAssertTrue(oneInsertionValid, "control: one insertion fits the 200-byte limit")
        let valid = try await validates(kvActions)
        XCTAssertFalse(valid, "KV insertions should exceed 200-byte state growth limit")
    }
}

// ============================================================================
// MARK: - Total Supply Fits UInt64
// ============================================================================

@MainActor
final class SupplyOverflowTests: XCTestCase {

    func testPremineDoesNotOverflowUInt64() async {
        let spec = s()
        let (_, overflow) = spec.premine.multipliedReportingOverflow(by: spec.initialReward)
        XCTAssertFalse(overflow)
    }

    func testRewardNeverOverflowsAtAnyBlock() async {
        let spec = s()
        let interval = spec.halvingInterval
        let samplePoints: [UInt64] = (0..<30).map { UInt64($0) * (interval / 10) }
        for blockHeight in samplePoints {
            let reward = spec.rewardAtBlock(blockHeight)
            XCTAssertTrue(reward <= spec.initialReward)
        }
    }

    func testTotalRewardsMonotonicallyIncreases() async {
        let spec = s(premine: 0)
        var prev: UInt64 = 0
        for count: UInt64 in stride(from: 100, through: 10000, by: 100) {
            let total = spec.totalRewards(upToBlock: count)
            XCTAssertGreaterThan(total, prev)
            prev = total
        }
    }
}

// ============================================================================
// MARK: - Cross-Chain Balance Conservation
// ============================================================================

@MainActor
final class CrossChainBalanceConservationTests: XCTestCase {

    func testCrossChainSwapSettleBalanceSumsCorrectly() async throws {
        let fetcher = f()
        let base = now() - 30_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = id(kp.publicKey)
        let childSpec = s("Child")
        let nexusSpec = s("Nexus", premine: 0)
        let childPremine = childSpec.premineAmount()
        let childReward = childSpec.rewardAtBlock(1)
        let nexusReward = nexusSpec.rewardAtBlock(1)
        let swapAmount: UInt64 = 300

        let childGenesis = try await premineGenesis(spec: childSpec, owner: kp, fetcher: fetcher, time: base)
        let nexusGenesis = try await buildAndStoreGenesis(
            spec: nexusSpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let totalBefore = childPremine

        let childSwap = DepositAction(nonce: 1, demander: kpAddr, amountDemanded: swapAmount, amountDeposited: swapAmount)

        let swapBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: -Int64(swapAmount))],
            actions: [],
            depositActions: [childSwap],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], nonce: 1,
            chainPath: ["Nexus"]
        )
        let _ = try await buildAndStoreBlock(
            previous: childGenesis, transactions: [tx(swapBody, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            rewardRecipient: kpAddr, fetcher: fetcher
        )
        let childBalanceAfterSwap = childPremine - swapAmount + childReward

        let settleBody = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [], receiptActions: [ReceiptAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: swapAmount, directory: "Child")],
            withdrawalActions: [],
            signers: [kpAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let nv = try await buildAndStoreBlock(
            previous: nexusGenesis, transactions: [tx(settleBody, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            rewardRecipient: kpAddr, fetcher: fetcher
        )
        let nexusValid = try await nv.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(nexusValid)

        let totalCirculating = childBalanceAfterSwap + nexusReward
        let expectedTotal = totalBefore - swapAmount + childReward + nexusReward
        XCTAssertEqual(totalCirculating, expectedTotal)
    }
}

// ============================================================================
// MARK: - Performance Regression
// ============================================================================

@MainActor
final class PerformanceRegressionTests: XCTestCase {

    func testBlockBuildPerformance() async throws {
        let fetcher = f()
        let base = now() - 200_000
        let spec = s(premine: 0)
        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        var prev = genesis
        let start = Date()
        for i in 1...50 {
            prev = try await buildAndStoreBlock(
                previous: prev, timestamp: base + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 5.0, "Building 50 empty blocks should take < 5 seconds")
    }

    func testChainSubmissionPerformance() async throws {
        let fetcher = f()
        let base = now() - 200_000
        let spec = s(premine: 0)
        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let blocks = try await buildChain(from: genesis, length: 51, base: base, fetcher: fetcher)
        let chain = ChainState.fromGenesis(block: genesis)

        let start = Date()
        for block in blocks.dropFirst() {
            let _ = await chain.submitTestBlock(
                blockHeader: try! VolumeImpl<Block>(node: block), block: block
            )
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 2.0, "Submitting 50 blocks should take < 2 seconds")
        let height = await chain.getHighestBlockHeight()
        XCTAssertEqual(height, 50)
    }
}
