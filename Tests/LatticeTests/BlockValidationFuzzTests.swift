import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import UInt256
import Foundation

// MARK: - ChainSpec Fuzz Tests

final class ChainSpecFuzzTests: XCTestCase {

    func testRewardAtBlockNeverOverflows() {
        var rng = SeededRNG(seed: 42)
        for _ in 0..<1000 {
            let reward = UInt64.random(in: 1...1_000_000, using: &rng)
            let interval = UInt64.random(in: 1...1_000_000, using: &rng)
            let premine = UInt64.random(in: 0...interval - 1, using: &rng)
            let spec = ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 1000,
                premine: premine,
                targetBlockTime: 1000,
                initialReward: reward,
                halvingInterval: interval,
                halfLife: 10
            )
            guard spec.isValid else { continue }

            let blockHeight = UInt64.random(in: 0...UInt64.max / 2, using: &rng)
            let blockReward = spec.rewardAtBlock(blockHeight)
            XCTAssertTrue(blockReward <= spec.initialReward,
                          "Reward \(blockReward) exceeded initial \(spec.initialReward) at block \(blockHeight)")
        }
    }

    func testRewardMonotonicallyDecreases() {
        var rng = SeededRNG(seed: 101)
        for _ in 0..<200 {
            let reward = UInt64.random(in: 1...1_000_000, using: &rng)
            let interval = UInt64.random(in: 1...100_000, using: &rng)
            let spec = ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 1000,
                premine: 0,
                targetBlockTime: 1000,
                initialReward: reward,
                halvingInterval: interval,
                halfLife: 10
            )
            guard spec.isValid else { continue }

            var prevReward = spec.rewardAtBlock(0)
            for i: UInt64 in 1..<10 {
                let (block, overflow) = interval.multipliedReportingOverflow(by: i)
                guard !overflow else { break }
                let r = spec.rewardAtBlock(block)
                XCTAssertTrue(r <= prevReward,
                              "Reward increased from \(prevReward) to \(r) at halving \(i)")
                prevReward = r
            }
        }
    }

    func testTotalRewardsConsistentWithIndividualSum() {
        var rng = SeededRNG(seed: 202)
        for _ in 0..<100 {
            let reward = UInt64.random(in: 1...10_000, using: &rng)
            let interval = UInt64.random(in: 100...10_000, using: &rng)
            let spec = ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 1000,
                premine: 0,
                targetBlockTime: 1000,
                initialReward: reward,
                halvingInterval: interval,
                halfLife: 10
            )
            guard spec.isValid else { continue }

            let blockCount = UInt64.random(in: 1...500, using: &rng)
            let totalFromMethod = spec.totalRewards(upToBlock: blockCount)
            let totalFromIndividual = (0..<blockCount).reduce(UInt64(0)) { sum, idx in
                sum + spec.rewardAtBlock(idx)
            }
            XCTAssertEqual(totalFromMethod, totalFromIndividual,
                           "Mismatch for reward=\(reward), interval=\(interval), blockCount=\(blockCount)")
        }
    }
    func testChainSpecValidationEdgeCases() {
        var rng = SeededRNG(seed: 404)
        for _ in 0..<500 {
            let txCount = UInt64.random(in: 0...100, using: &rng)
            let stateGrowth = Int.random(in: 0...10000, using: &rng)
            let blockTime = UInt64.random(in: 0...600_000, using: &rng)
            let reward = UInt64.random(in: 0...1_000_000, using: &rng)
            let interval = UInt64.random(in: 0...1_000_000, using: &rng)
            let premine = UInt64.random(in: 0...UInt64.max / 2, using: &rng)

            let spec = ChainSpec(
                maxNumberOfTransactionsPerBlock: txCount,
                maxStateGrowth: stateGrowth,
                premine: premine,
                targetBlockTime: blockTime,
                initialReward: reward,
                halvingInterval: interval,
                halfLife: 10
            )

            if spec.isValid {
                XCTAssertGreaterThan(txCount, 0)
                XCTAssertGreaterThan(stateGrowth, 0)
                XCTAssertGreaterThan(blockTime, 0)
                XCTAssertGreaterThan(reward, 0)
                XCTAssertGreaterThan(interval, 0)
                // premine is intentionally uncapped (cap `premine < halvingInterval`
                // removed); a valid spec may premine across many halvings. The
                // emission math stays well-defined and supply-bounded — see
                // PremineUncappedTests.
            }
        }
    }

    func testPremineAmountConsistency() {
        var rng = SeededRNG(seed: 505)
        for _ in 0..<200 {
            let reward = UInt64.random(in: 1...10_000, using: &rng)
            let interval = UInt64.random(in: 100...100_000, using: &rng)
            let premine = UInt64.random(in: 0...min(interval - 1, 10_000), using: &rng)

            let spec = ChainSpec(
                maxNumberOfTransactionsPerBlock: 100,
                maxStateGrowth: 1000,
                premine: premine,
                targetBlockTime: 1000,
                initialReward: reward,
                halvingInterval: interval,
                halfLife: 10
            )
            guard spec.isValid else { continue }

            let premineTotal = spec.premineAmount()
            let manualTotal = (0..<premine).reduce(UInt64(0)) { sum, idx in
                sum + (reward >> (idx / interval))
            }
            XCTAssertEqual(premineTotal, manualTotal,
                           "Premine mismatch for reward=\(reward), premine=\(premine)")
        }
    }
}

// MARK: - Fork Choice Fuzz Tests

@MainActor
final class ForkChoiceFuzzTests: XCTestCase {

    func testRandomChainTopologyInvariants() async {
        var rng = SeededRNG(seed: 909)

        for _ in 0..<50 {
            let chainLength = Int.random(in: 2...20, using: &rng)
            let numForks = Int.random(in: 0...5, using: &rng)

            var blocks: [BlockMeta] = []
            let genesis = makeBlockMeta(hash: blockCID("G"), height: 0)
            blocks.append(genesis)

            var tip = blockCID("G")
            for i in 1..<chainLength {
                let hash = blockCID("main_\(i)")
                let meta = makeBlockMeta(hash: hash, previousHash: tip, height: UInt64(i))
                blocks[blocks.count - 1].childHashes.append(hash)
                blocks.append(meta)
                tip = hash
            }

            var longestFork = 0
            for f in 0..<numForks {
                let forkPoint = Int.random(in: 0..<chainLength, using: &rng)
                let forkLen = Int.random(in: 1...8, using: &rng)
                longestFork = max(longestFork, forkLen)

                for j in 0..<forkLen {
                    let forkIdx = UInt64(forkPoint + j + 1)
                    let hash = blockCID("fork\(f)_\(j)")
                    let prevHash = j == 0 ? blocks[forkPoint].blockHash : blockCID("fork\(f)_\(j-1)")
                    let meta = makeBlockMeta(hash: hash, previousHash: prevHash, height: forkIdx)
                    if j == 0 {
                        blocks[forkPoint].childHashes.append(hash)
                    } else {
                        blocks[blocks.count - 1].childHashes.append(hash)
                    }
                    blocks.append(meta)
                }
            }

            let mainHashes = Set((1..<chainLength).map { blockCID("main_\($0)") } + [blockCID("G")])
            let chain = makeChain(blocks: blocks, canonicalHashes: mainHashes)

            let canonicalTip = await chain.canonicalTip
            let tipOnMain = await chain.isCanonical(hash: canonicalTip)
            XCTAssertTrue(tipOnMain, "Chain tip must be on main chain")

            let tipBlock = await chain.getConsensusBlock(hash: canonicalTip)
            XCTAssertNotNil(tipBlock, "Chain tip must exist in block map")

            let genesisOnMain = await chain.isCanonical(hash: blockCID("G"))
            XCTAssertTrue(genesisOnMain, "Genesis must always be on main chain")
        }
    }

    func testRandomReorgPreservesConnectivity() async {
        var rng = SeededRNG(seed: 1010)

        for _ in 0..<30 {
            let mainLen = Int.random(in: 3...10, using: &rng)
            let forkLen = mainLen + Int.random(in: 1...5, using: &rng)

            var blocks: [BlockMeta] = []
            let genesis = makeBlockMeta(hash: blockCID("G"), height: 0, childHashes: [blockCID("M1"), blockCID("F1")])
            blocks.append(genesis)

            for i in 1...mainLen {
                let hash = blockCID("M\(i)")
                let prev = i == 1 ? blockCID("G") : blockCID("M\(i-1)")
                let children = i < mainLen ? [blockCID("M\(i+1)")] : [String]()
                blocks.append(makeBlockMeta(hash: hash, previousHash: prev, height: UInt64(i), childHashes: children))
            }
            for i in 1...forkLen {
                let hash = blockCID("F\(i)")
                let prev = i == 1 ? blockCID("G") : blockCID("F\(i-1)")
                let children = i < forkLen ? [blockCID("F\(i+1)")] : [String]()
                blocks.append(makeBlockMeta(hash: hash, previousHash: prev, height: UInt64(i), childHashes: children))
            }

            let mainHashes = Set([blockCID("G")] + (1...mainLen).map { blockCID("M\($0)") })
            let chain = makeChain(blocks: blocks, canonicalHashes: mainHashes)
            let forkTipHash = blockCID("F\(forkLen)")

            let reorg = await chain.reevaluateForkChoice()

            XCTAssertNotNil(reorg, "Longer fork should trigger reorg")

            let newTip = await chain.canonicalTip
            XCTAssertEqual(newTip, forkTipHash)

            var current = newTip
            var depth = 0
            while current != blockCID("G") {
                let block = await chain.getConsensusBlock(hash: current)
                XCTAssertNotNil(block, "Block \(current) missing from chain")
                guard let prevHash = block?.parentBlockHash else {
                    XCTFail("Block \(current) has no previous hash but is not genesis")
                    break
                }
                current = prevHash
                depth += 1
                if depth > forkLen + 10 { XCTFail("Infinite loop in chain traversal"); break }
            }
        }
    }
}

// MARK: - CryptoUtils Fuzz Tests

final class CryptoUtilsFuzzTests: XCTestCase {

    func testSignVerifyRoundTrip() {
        var rng = SeededRNG(seed: 1111)
        for _ in 0..<50 {
            let keyPair = CryptoUtils.generateKeyPair()
            let message = rng.randomString(length: Int.random(in: 1...200, using: &rng))
            guard let signature = CryptoUtils.sign(message: message, privateKeyHex: keyPair.privateKey) else {
                XCTFail("Signing failed")
                continue
            }
            XCTAssertTrue(CryptoUtils.verify(message: message, signature: signature, publicKeyHex: keyPair.publicKey),
                          "Valid signature rejected")
        }
    }

    func testWrongKeyRejected() {
        var rng = SeededRNG(seed: 1212)
        for _ in 0..<50 {
            let keyPair1 = CryptoUtils.generateKeyPair()
            let keyPair2 = CryptoUtils.generateKeyPair()
            let message = rng.randomString(length: 32)
            guard let signature = CryptoUtils.sign(message: message, privateKeyHex: keyPair1.privateKey) else {
                continue
            }
            XCTAssertFalse(CryptoUtils.verify(message: message, signature: signature, publicKeyHex: keyPair2.publicKey),
                           "Signature verified with wrong public key")
        }
    }

    func testTamperedMessageRejected() {
        var rng = SeededRNG(seed: 1313)
        for _ in 0..<50 {
            let keyPair = CryptoUtils.generateKeyPair()
            let message = rng.randomString(length: 32)
            guard let signature = CryptoUtils.sign(message: message, privateKeyHex: keyPair.privateKey) else {
                continue
            }
            let tampered = message + "x"
            XCTAssertFalse(CryptoUtils.verify(message: tampered, signature: signature, publicKeyHex: keyPair.publicKey),
                           "Tampered message accepted")
        }
    }

    func testSha256Determinism() {
        var rng = SeededRNG(seed: 1414)
        for _ in 0..<200 {
            let input = rng.randomString(length: Int.random(in: 0...500, using: &rng))
            let hash1 = CryptoUtils.sha256(input)
            let hash2 = CryptoUtils.sha256(input)
            XCTAssertEqual(hash1, hash2)
            XCTAssertEqual(hash1.count, 64)
        }
    }

    func testSha256CollisionResistance() {
        var hashes = Set<String>()
        for i in 0..<1000 {
            let input = "unique_input_\(i)"
            let hash = CryptoUtils.sha256(input)
            XCTAssertFalse(hashes.contains(hash), "SHA-256 collision found for input \(i)")
            hashes.insert(hash)
        }
    }
}

// MARK: - UInt256 Fuzz Tests

final class UInt256FuzzTests: XCTestCase {

    func testHexRoundTrip() {
        var rng = SeededRNG(seed: 1616)
        for _ in 0..<500 {
            let value = UInt256(UInt64.random(in: 0...UInt64.max, using: &rng))
            let hex = value.toPrefixedHexString()
            let parsed = UInt256.fromHexString(hex)
            XCTAssertEqual(parsed, value, "Round-trip failed for \(value)")
        }
    }

    func testHashDeterminism() {
        var rng = SeededRNG(seed: 1717)
        for _ in 0..<200 {
            let len = Int.random(in: 0...500, using: &rng)
            var data = Data(count: len)
            for i in 0..<len {
                data[i] = UInt8.random(in: 0...255, using: &rng)
            }
            let h1 = UInt256.hash(data)
            let h2 = UInt256.hash(data)
            XCTAssertEqual(h1, h2)
        }
    }

    func testHashDistribution() {
        var rng = SeededRNG(seed: 1818)
        var hashes: Set<String> = Set()
        for i in 0..<500 {
            let h = UInt256.hash("input_\(i)_\(rng.randomString(length: 8))")
            hashes.insert(h.toPrefixedHexString())
        }
        XCTAssertEqual(hashes.count, 500, "Hash collisions detected in 500 unique inputs")
    }
}

// MARK: - AccountAction Fuzz Tests

final class AccountActionFuzzTests: XCTestCase {

    func testVerifyRejectsZeroDelta() {
        var rng = SeededRNG(seed: 1919)
        for _ in 0..<200 {
            let action = AccountAction(owner: rng.randomHash(), delta: 0)
            XCTAssertFalse(action.verify(), "Verify should reject zero-delta action")
        }
    }

    func testVerifyAcceptsChange() {
        var rng = SeededRNG(seed: 2020)
        for _ in 0..<200 {
            let old = UInt64.random(in: 0...UInt64.max / 2, using: &rng)
            let new = old + UInt64.random(in: 1...1000, using: &rng)
            let action = AccountAction(owner: rng.randomHash(), delta: Int64(new) - Int64(old))
            XCTAssertTrue(action.verify(), "Verify should accept changed action")
        }
    }

    func testStateDeltaIsConservativelyZero() {
        var rng = SeededRNG(seed: 2121)
        for _ in 0..<200 {
            let owner = rng.randomHash()

            // With delta model, stateDelta() returns 0 (conservative) since
            // insertion/deletion can't be determined without current state
            let creditAction = AccountAction(owner: owner, delta: Int64(100))
            XCTAssertEqual(creditAction.stateDelta(), 0)

            let debitAction = AccountAction(owner: owner, delta: -Int64(100))
            XCTAssertEqual(debitAction.stateDelta(), 0)

            let smallDelta = AccountAction(owner: owner, delta: Int64(50))
            XCTAssertEqual(smallDelta.stateDelta(), 0)
        }
    }
}

// MARK: - Action (Generic KV) Fuzz Tests

final class ActionFuzzTests: XCTestCase {

    func testVerifyRequiresNonEmptyKey() {
        let action = Action(key: "", oldValue: nil, newValue: "val")
        XCTAssertFalse(action.verify())
    }

    func testVerifyRequiresAtLeastOneValue() {
        var rng = SeededRNG(seed: 2222)
        for _ in 0..<100 {
            let key = rng.randomString(length: 10)
            let action = Action(key: key, oldValue: nil, newValue: nil)
            XCTAssertFalse(action.verify())
        }
    }

    func testStateDeltaInsertIsPositive() {
        var rng = SeededRNG(seed: 2323)
        for _ in 0..<100 {
            let key = rng.randomString(length: Int.random(in: 1...50, using: &rng))
            let value = rng.randomString(length: Int.random(in: 1...100, using: &rng))
            let action = Action(key: key, oldValue: nil, newValue: value)
            let delta = action.stateDelta()
            XCTAssertGreaterThan(delta, 0)
        }
    }

    func testStateDeltaDeleteIsNegative() {
        var rng = SeededRNG(seed: 2424)
        for _ in 0..<100 {
            let key = rng.randomString(length: Int.random(in: 1...50, using: &rng))
            let value = rng.randomString(length: Int.random(in: 1...100, using: &rng))
            let action = Action(key: key, oldValue: value, newValue: nil)
            let delta = action.stateDelta()
            XCTAssertLessThan(delta, 0)
        }
    }

    func testStateDeltaUpdateReflectsSizeDiff() {
        var rng = SeededRNG(seed: 2525)
        for _ in 0..<100 {
            let key = rng.randomString(length: 10)
            let shortVal = rng.randomString(length: 5)
            let longVal = rng.randomString(length: 50)
            let growAction = Action(key: key, oldValue: shortVal, newValue: longVal)
            let growDelta = growAction.stateDelta()
            XCTAssertGreaterThan(growDelta, 0)

            let shrinkAction = Action(key: key, oldValue: longVal, newValue: shortVal)
            let shrinkDelta = shrinkAction.stateDelta()
            XCTAssertLessThan(shrinkDelta, 0)
        }
    }
}

// MARK: - Coinbase: builder and validator agree

@MainActor
final class CoinbaseAgreementFuzzTests: XCTestCase {

    /// Random fee-paying blocks with a random recipient (none, fresh, a payer,
    /// a payee): the validator accepts exactly what `BlockBuilder` built, and
    /// supply changes by the reward when a recipient is paid, or falls by the
    /// fees when they burn.
    func testBuilderAndValidatorAgreeOnTheCoinbase() async throws {
        var rng = SeededRNG(seed: 0xC01B)
        for _ in 0..<25 {
            let f = try await CoinbaseFixture.make()
            let payees = (0..<3).map { _ in freshAddress() }
            var transactions: [Transaction] = []
            var fees: UInt64 = 0
            for nonce in 0..<UInt64.random(in: 0...4, using: &rng) {
                let debit = UInt64.random(in: 1...1_000, using: &rng)
                let credit = UInt64.random(in: 0...debit, using: &rng)
                let payee = payees[Int.random(in: 0..<payees.count, using: &rng)]
                transactions.append(f.transfer(
                    debit: debit, credits: credit > 0 ? [(payee, credit)] : [], nonce: nonce
                ).transaction)
                fees += debit - credit
            }
            let choices: [String?] = [nil, freshAddress(), f.payerAddress, payees[0]]
            let recipient = choices[Int.random(in: 0..<choices.count, using: &rng)]

            let block = try await f.block(transactions, recipient: recipient)
            let (valid, _, post) = try await block.validateNexus(fetcher: f.fetcher)
            XCTAssertTrue(valid, "recipient \(String(describing: recipient)), fees \(fees)")
            let accountState = try await XCTUnwrap(post).accountState.resolveRecursive(fetcher: f.fetcher)
            let accounts = try XCTUnwrap(accountState.node?.allKeysAndValues())
            let supply = accounts.filter { !AccountStateHeader.isReservedAccountKey($0.key) }
                .values.reduce(UInt64(0), +)
            XCTAssertEqual(supply, recipient == nil ? f.premine - fees : f.premine + f.reward)
        }
    }
}
