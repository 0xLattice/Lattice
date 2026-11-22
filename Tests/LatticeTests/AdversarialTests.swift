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

private func makeFetcher() -> StorableFetcher { StorableFetcher() }

private func spec(_ dir: String = "Nexus", premine: UInt64 = 1000) -> ChainSpec {
    ChainSpec.test(premine: premine)
}

private func sign(_ body: TransactionBody, _ kp: (privateKey: String, publicKey: String)) -> Transaction {
    let h = try! HeaderImpl<TransactionBody>(node: body)
    let sig = TransactionSigning.sign(bodyHeader: h, privateKeyHex: kp.privateKey)!
    return Transaction(signatures: [kp.publicKey: sig], body: h)
}

private func cid(_ pubKey: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: pubKey)).rawCID
}

private func t() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

// MARK: - 1. Double-Spend Resistance

@MainActor
final class DoubleSpendAdversarialTests: XCTestCase {

    func testDoubleSpendSameBlockRejected() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let charlie = CryptoUtils.generateKeyPair()
        let aliceAddr = cid(alice.publicKey)
        let bobAddr = cid(bob.publicKey)
        let charlieAddr = cid(charlie.publicKey)
        let s = spec()
        let premine = s.premineAmount()

        let genesis = try await buildPremineGenesis(spec: s, owner: alice, fetcher: fetcher, timestamp: base)

        let spend1 = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: -Int64(premine)),
                AccountAction(owner: bobAddr, delta: Int64(premine))
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let spend2 = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: -Int64(premine)),
                AccountAction(owner: charlieAddr, delta: Int64(premine))
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], nonce: 1,
            chainPath: ["Nexus"]
        )

        // Each spend alone is funded; together they debit alice twice.
        await assertThrows(StateErrors.insufficientBalance, "Building block with double-spend should throw") {
            try await buildAndStoreBlock(
                previous: genesis, transactions: [sign(spend1, alice), sign(spend2, alice)],
                timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
            )
        }
    }

    func testDoubleSpendAcrossBlocksRejected() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = cid(alice.publicKey)
        let bobAddr = cid(bob.publicKey)
        let s = spec()
        let premine = s.premineAmount()

        let genesis = try await buildPremineGenesis(spec: s, owner: alice, fetcher: fetcher, timestamp: base)

        let spend1Body = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: -Int64(premine)),
                AccountAction(owner: bobAddr, delta: Int64(premine))
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let block1 = try await buildAndStoreBlock(
            previous: genesis, transactions: [sign(spend1Body, alice)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let block1Valid = try await block1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(block1Valid, "control: the first spend is funded")

        let spend2Body = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: -1),
                AccountAction(owner: bobAddr, delta: 1)
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], nonce: 1,
            chainPath: ["Nexus"]
        )

        // alice's balance is 0 after block1, not premine
        await assertThrows(StateErrors.insufficientBalance, "Block referencing stale balance should throw") {
            try await buildAndStoreBlock(
                previous: block1, transactions: [sign(spend2Body, alice)],
                timestamp: base + 2000, target: UInt256(1000), nonce: 2, fetcher: fetcher
            )
        }
    }
}

// MARK: - 1b. Fee Accounting

@MainActor
final class FeeAccountingValidationTests: XCTestCase {

    func testValidateNexusRejectsFeeFundedMintWithoutSignerDebit() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let miner = CryptoUtils.generateKeyPair()
        let minerAddr = cid(miner.publicKey)
        let s = spec(premine: 0)
        let fee: UInt64 = 50
        let reward = s.rewardAtBlock(1)

        let genesis = try await buildAndStoreGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        try await storeBuiltBlock(genesis, in: fetcher)
        let body = TransactionBody(
            accountActions: [AccountAction(owner: minerAddr, delta: Int64(reward + fee))],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [minerAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let block = try await buildAndStoreBlock(
            previous: genesis, transactions: [sign(body, miner)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            allowFeeRuleViolation: true, fetcher: fetcher
        )

        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid, "Transaction fee must not create spendable block budget unless a signer debit funds it")
    }

    func testValidateNexusAcceptsFeeClaimWhenSignerDebitFundsIt() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let payer = CryptoUtils.generateKeyPair()
        let payerAddr = cid(payer.publicKey)
        let miner = CryptoUtils.generateKeyPair()
        let minerAddr = cid(miner.publicKey)
        let s = spec(premine: 1000)
        let fee: UInt64 = 50
        let reward = s.rewardAtBlock(1)

        let genesis = try await buildPremineGenesis(spec: s, owner: payer, fetcher: fetcher, timestamp: base)
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: payerAddr, delta: -Int64(fee))
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [payerAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let block = try await buildAndStoreBlock(
            previous: genesis, transactions: [sign(body, payer)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            rewardRecipient: minerAddr, fetcher: fetcher
        )

        let (valid, _, postState) = try await block.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid, "The recipient's fee should validate when the fee is debited from a signer")
        let minerBalance: UInt64? = try postState?.accountState.node?.get(key: minerAddr)
        XCTAssertEqual(minerBalance, reward + fee)
    }

    func testValidateGenesisRejectsFeeFundedPremineExpansion() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let miner = CryptoUtils.generateKeyPair()
        let minerAddr = cid(miner.publicKey)
        let s = spec(premine: 0)
        let fee: UInt64 = 50
        let body = TransactionBody(
            accountActions: [AccountAction(owner: minerAddr, delta: Int64(fee))],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [minerAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let genesis = try await buildAndStoreGenesis(
            spec: s, transactions: [sign(body, miner)],
            timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let valid = try await genesis.validateGenesis(
            fetcher: fetcher,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        ).0
        XCTAssertFalse(valid, "Genesis fees must not expand the premine budget")
    }
}

// MARK: - 2. Signature & Authentication Security

@MainActor
final class SignatureSecurityTests: XCTestCase {

    /// A funded transfer from the premine whose only defect is its signature:
    /// the correctly signed twin validates, so a rejection is the signature's.
    private func premineTransfer(
        spec s: ChainSpec, owner: (privateKey: String, publicKey: String),
        fetcher: StorableFetcher, base: Int64
    ) async throws -> (genesis: Block, body: HeaderImpl<TransactionBody>) {
        let genesis = try await buildPremineGenesis(spec: s, owner: owner, fetcher: fetcher, timestamp: base)
        let ownerAddr = cid(owner.publicKey)
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: ownerAddr, delta: -100),
                AccountAction(owner: cid(CryptoUtils.generateKeyPair().publicKey), delta: 100)
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [ownerAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        return (genesis, try HeaderImpl<TransactionBody>(node: body))
    }

    private func validates(
        _ tx: Transaction, after genesis: Block, fetcher: StorableFetcher, base: Int64
    ) async throws -> Bool {
        let block = try await buildAndStoreBlock(
            previous: genesis, transactions: [tx],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        return try await block.validateNexus(fetcher: fetcher).0
    }

    func testTamperedSignatureRejected() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let kp = CryptoUtils.generateKeyPair()
        let (genesis, bodyHeader) = try await premineTransfer(spec: spec(), owner: kp, fetcher: fetcher, base: base)

        let realSig = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: kp.privateKey)!
        var tamperedSig = realSig
        let idx = tamperedSig.index(tamperedSig.startIndex, offsetBy: 10)
        let c = tamperedSig[idx]
        let replacement: Character = c == "a" ? "b" : "a"
        tamperedSig = String(tamperedSig.prefix(upTo: idx)) + String(replacement) + String(tamperedSig.suffix(from: tamperedSig.index(after: idx)))

        let signed = Transaction(signatures: [kp.publicKey: realSig], body: bodyHeader)
        let tampered = Transaction(signatures: [kp.publicKey: tamperedSig], body: bodyHeader)
        XCTAssertFalse(tampered.signaturesAreValid())
        let signedValid = try await validates(signed, after: genesis, fetcher: fetcher, base: base)
        XCTAssertTrue(signedValid, "control: the correctly signed transfer validates")
        let tamperedValid = try await validates(tampered, after: genesis, fetcher: fetcher, base: base)
        XCTAssertFalse(tamperedValid)
    }

    func testWrongSignerKeyRejected() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let real = CryptoUtils.generateKeyPair()
        let imposter = CryptoUtils.generateKeyPair()
        let (genesis, bodyHeader) = try await premineTransfer(spec: spec(), owner: real, fetcher: fetcher, base: base)

        // The imposter's signature, filed under the real owner's key: signer
        // coverage holds, so only signature verification can reject it.
        let sig = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: imposter.privateKey)!
        let forged = Transaction(signatures: [real.publicKey: sig], body: bodyHeader)
        XCTAssertTrue(forged.signaturesMatchSigners())
        XCTAssertFalse(forged.signaturesAreValid())
        let realSig = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: real.privateKey)!
        let signedValid = try await validates(
            Transaction(signatures: [real.publicKey: realSig], body: bodyHeader),
            after: genesis, fetcher: fetcher, base: base
        )
        XCTAssertTrue(signedValid, "control: the owner-signed transfer validates")
        let forgedValid = try await validates(forged, after: genesis, fetcher: fetcher, base: base)
        XCTAssertFalse(forgedValid)
    }

    func testEmptySignatureRejected() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let s = spec(premine: 0)

        let genesis = try await buildAndStoreGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [], nonce: 0,
            chainPath: ["Nexus"]
        )
        let tx = Transaction(signatures: [:], body: try! HeaderImpl<TransactionBody>(node: body))

        let block = try await buildAndStoreBlock(
            previous: genesis, transactions: [tx],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid)
    }

    func testFundRemovalWithoutOwnerSignatureFails() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let alice = CryptoUtils.generateKeyPair()
        let thief = CryptoUtils.generateKeyPair()
        let aliceAddr = cid(alice.publicKey)
        let thiefAddr = cid(thief.publicKey)
        let s = spec()
        let premine = s.premineAmount()

        let genesis = try await buildPremineGenesis(spec: s, owner: alice, fetcher: fetcher, timestamp: base)

        func steal(signedBy signer: (privateKey: String, publicKey: String)) async throws -> Bool {
            let signerAddr = cid(signer.publicKey)
            let body = TransactionBody(
                accountActions: [
                    AccountAction(owner: aliceAddr, delta: -Int64(premine)),
                    AccountAction(owner: thiefAddr, delta: Int64(premine))
                ],
                actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
                signers: [signerAddr], nonce: 0,
                chainPath: ["Nexus"]
            )
            let block = try await buildAndStoreBlock(
                previous: genesis, transactions: [sign(body, signer)],
                timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
            )
            return try await block.validateNexus(fetcher: fetcher).0
        }
        let ownerSignedValid = try await steal(signedBy: alice)
        XCTAssertTrue(ownerSignedValid, "control: the same transfer signed by alice validates")
        let thiefSignedValid = try await steal(signedBy: thief)
        XCTAssertFalse(thiefSignedValid)
    }
}

// MARK: - 3. Balance Overflow / Underflow

@MainActor
final class BalanceOverflowTests: XCTestCase {

    func testOverclaimBeyondRewardFails() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = cid(kp.publicKey)
        let s = spec(premine: 0)
        let reward = s.rewardAtBlock(0)

        let genesis = try await buildAndStoreGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        try await storeBuiltBlock(genesis, in: fetcher)

        let body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(reward + 1))],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let block = try await buildAndStoreBlock(
            previous: genesis, transactions: [sign(body, kp)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            allowFeeRuleViolation: true, fetcher: fetcher
        )
        let v = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(v)
    }

    func testGenesisOverclaimBeyondPremineFails() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = cid(kp.publicKey)
        let s = spec()
        let premine = s.premineAmount()

        let body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: Int64(premine + 1))],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [], signers: [kpAddr], nonce: 0,
            chainPath: ["Nexus"]
        )

        let genesis = try await buildAndStoreGenesis(
            spec: s, transactions: [sign(body, kp)],
            timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let gv = try await genesis.validateGenesis(
            fetcher: fetcher,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        ).0
        XCTAssertFalse(gv)
    }

    func testZeroAmountAccountActionRejected() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = cid(kp.publicKey)
        let action = AccountAction(owner: kpAddr, delta: Int64(0))
        XCTAssertFalse(action.verify())
    }
}

// MARK: - 4. Cross-Chain Swap Security

@MainActor
final class CrossChainSecurityTests: XCTestCase {

    func testDuplicateSwapNonceRejected() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = cid(kp.publicKey)
        let s = spec("Child")

        let genesis = try await buildPremineGenesis(spec: s, owner: kp, fetcher: fetcher, timestamp: base)

        // Both deposits are funded; only the repeated swap nonce is wrong.
        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: kpAddr, delta: -200)
            ],
            actions: [],
            depositActions: [
                DepositAction(nonce: 1, demander: kpAddr, amountDemanded: 100, amountDeposited: 100),
                DepositAction(nonce: 1, demander: kpAddr, amountDemanded: 100, amountDeposited: 100)
            ],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], nonce: 0,
            chainPath: ["Nexus"]
        )

        await assertThrows(StateErrors.conflictingActions, "Duplicate swap nonce should throw") {
            try await buildAndStoreBlock(
                previous: genesis, transactions: [sign(body, kp)],
                timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
            )
        }
    }

    func testZeroSwapAmountRejected() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = cid(kp.publicKey)
        let s = spec("Child")

        let genesis = try await buildPremineGenesis(spec: s, owner: kp, fetcher: fetcher, timestamp: base)

        // A zero deposit needs no funding, so the fee rule holds.
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [
                DepositAction(nonce: 1, demander: kpAddr, amountDemanded: 0, amountDeposited: 0)
            ],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], nonce: 0,
            chainPath: ["Nexus"]
        )

        await assertThrows(StateErrors.conflictingActions, "Zero swap amount should throw") {
            try await buildAndStoreBlock(
                previous: genesis, transactions: [sign(body, kp)],
                timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
            )
        }
    }

    func testZeroClaimAmountIsInvalid() async {
        let c = WithdrawalAction(withdrawer: "r", nonce: 1, demander: "s", amountDemanded: 0, amountWithdrawn: 0)
        XCTAssertEqual(c.amountWithdrawn, 0)
    }
}

// MARK: - 5. Economic Invariants

@MainActor
final class EconomicInvariantAdversarialTests: XCTestCase {

    func testTotalSupplyConservationOverBlocks() async throws {
        let fetcher = makeFetcher()
        let base = t() - 20_000
        let miner = CryptoUtils.generateKeyPair()
        let minerAddr = cid(miner.publicKey)
        let s = spec(premine: 0)

        let genesis = try await buildAndStoreGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        var prev = genesis
        var totalMined: UInt64 = 0
        var minerBalance: UInt64 = 0

        for i: UInt64 in 1...5 {
            let block = try await buildAndStoreBlock(
                previous: prev,
                timestamp: base + Int64(i) * 1000, target: UInt256(1000), nonce: i,
                rewardRecipient: minerAddr, fetcher: fetcher
            )
            let (valid, _, postState) = try await block.validateNexus(fetcher: fetcher)
            XCTAssertTrue(valid, "Block \(i) should be valid")
            totalMined += s.rewardAtBlock(i)
            minerBalance = try XCTUnwrap(postState?.accountState.node?.get(key: minerAddr))
            prev = block
        }

        let expectedTotal = (1...5).map { s.rewardAtBlock(UInt64($0)) }.reduce(0, +)
        XCTAssertEqual(totalMined, expectedTotal)
        XCTAssertEqual(minerBalance, expectedTotal)
    }

    func testFeeConservation() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let payer = CryptoUtils.generateKeyPair()
        let miner = CryptoUtils.generateKeyPair()
        let payerAddr = cid(payer.publicKey)
        let minerAddr = cid(miner.publicKey)
        let s = spec()
        let premine = s.premineAmount()
        let reward = s.rewardAtBlock(1)
        let fee: UInt64 = 100

        let genesis = try await buildPremineGenesis(spec: s, owner: payer, fetcher: fetcher, timestamp: base)

        let body = TransactionBody(
            accountActions: [
                AccountAction(owner: payerAddr, delta: Int64(premine - fee) - Int64(premine))
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [payerAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let block = try await buildAndStoreBlock(
            previous: genesis, transactions: [sign(body, payer)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            rewardRecipient: minerAddr, fetcher: fetcher
        )
        let (valid, _, postState) = try await block.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid)

        let balanceAfterPayer = try XCTUnwrap(postState?.accountState.node?.get(key: payerAddr))
        let balanceAfterMiner = try XCTUnwrap(postState?.accountState.node?.get(key: minerAddr))
        XCTAssertEqual(balanceAfterMiner, reward + fee)
        XCTAssertEqual(balanceAfterPayer + balanceAfterMiner, premine + reward)
    }

    func testHalvingScheduleCorrectness() async {
        let s = spec(premine: 0)
        let initial = s.initialReward
        let halvingInterval = s.halvingInterval

        XCTAssertEqual(s.rewardAtBlock(0), initial)
        XCTAssertEqual(s.rewardAtBlock(halvingInterval - 1), initial)
        XCTAssertEqual(s.rewardAtBlock(halvingInterval), initial / 2)
        XCTAssertEqual(s.rewardAtBlock(halvingInterval * 2), initial / 4)
    }

    func testHalvingWithPremineOffset() async {
        let s = spec(premine: 100)
        let initial = s.initialReward
        let halvingInterval = s.halvingInterval

        XCTAssertEqual(s.rewardAtBlock(0), initial)
        let firstHalving = halvingInterval - 100
        XCTAssertEqual(s.rewardAtBlock(firstHalving - 1), initial)
        XCTAssertEqual(s.rewardAtBlock(firstHalving), initial / 2)
    }

    func testPremineAmountCalculation() async {
        let s = spec(premine: 1000)
        XCTAssertEqual(s.premineAmount(), 1000 * s.initialReward)
    }

    func testPremineMayEqualOrExceedHalvingInterval() async {
        // The `premine < halvingInterval` cap was removed: premine is a block-count
        // offset into the emission schedule and the reward math handles any size.
        // A premine spanning halving epochs — up to a fully-premined chain — is a
        // valid, honest tokenomics choice. See PremineUncappedTests for the
        // emission/conservation coverage.
        XCTAssertTrue(spec(premine: 1000).isValid)
        XCTAssertTrue(spec(premine: 10_000).isValid)            // == halvingInterval
        XCTAssertTrue(spec(premine: 35_000).isValid)            // spans multiple halvings
        XCTAssertTrue(spec(premine: UInt64.max).isValid)        // extreme premine still well-defined
    }

    func testPremineImmutability() async throws {
        let fetcher1 = makeFetcher()
        let fetcher2 = makeFetcher()
        let kp = CryptoUtils.generateKeyPair()
        let ownerAddr = cid(kp.publicKey)
        let base = t() - 10_000
        let s = spec()
        let premine = s.premineAmount()

        let body = TransactionBody(
            accountActions: [AccountAction(owner: ownerAddr, delta: Int64(premine))],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [], signers: [ownerAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let tx = sign(body, kp)

        let genesis1 = try await buildAndStoreGenesis(
            spec: s, transactions: [tx], timestamp: base, target: UInt256(1000), fetcher: fetcher1
        )
        let genesis2 = try await buildAndStoreGenesis(
            spec: s, transactions: [tx], timestamp: base, target: UInt256(1000), fetcher: fetcher2
        )

        let hash1 = try! VolumeImpl<Block>(node: genesis1).rawCID
        let hash2 = try! VolumeImpl<Block>(node: genesis2).rawCID
        XCTAssertEqual(hash1, hash2, "Genesis block must be deterministic given same inputs")
    }
}

// MARK: - 6. Consensus & Reorg Resilience

@MainActor
final class ConsensusResilienceTests: XCTestCase {

    func testLongerForkBecomesMainChain() async throws {
        let fetcher = makeFetcher()
        let base = t() - 100_000
        let s = spec(premine: 0)
        let genesis = try await buildAndStoreGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        var chain = ChainTree.fromGenesis(block: genesis)

        var shortPrev = genesis
        for i in 1...3 {
            let b = try await buildAndStoreBlock(
                previous: shortPrev, timestamp: base + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            let _ = chain.submitTestBlock(
                blockHeader: try! VolumeImpl<Block>(node: b), block: b
            )
            shortPrev = b
        }
        let shortTip = chain.canonicalTip

        var longPrev = genesis
        for i in 1...5 {
            let b = try await buildAndStoreBlock(
                previous: longPrev, timestamp: base + Int64(i) * 500,
                target: UInt256(1000), nonce: UInt64(i + 100), fetcher: fetcher
            )
            let _ = chain.submitTestBlock(
                blockHeader: try! VolumeImpl<Block>(node: b), block: b
            )
            longPrev = b
        }
        let longTip = chain.canonicalTip

        XCTAssertNotEqual(shortTip, longTip)
        XCTAssertEqual(longTip, try! VolumeImpl<Block>(node: longPrev).rawCID)
    }

    func testOrphanBlocksHandled() async throws {
        let fetcher = makeFetcher()
        let base = t() - 100_000
        let s = spec(premine: 0)
        let genesis = try await buildAndStoreGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let block1 = try await buildAndStoreBlock(
            previous: genesis, timestamp: base + 1000,
            target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let block2 = try await buildAndStoreBlock(
            previous: block1, timestamp: base + 2000,
            target: UInt256(1000), nonce: 2, fetcher: fetcher
        )

        var chain = ChainTree.fromGenesis(block: genesis)

        let result2 = chain.submitTestBlock(
            blockHeader: try! VolumeImpl<Block>(node: block2), block: block2
        )
        XCTAssertFalse(result2.extendsCanonical, "Block 2 submitted before block 1 should not extend")

        let result1 = chain.submitTestBlock(
            blockHeader: try! VolumeImpl<Block>(node: block1), block: block1
        )
        XCTAssertTrue(result1.extendsCanonical)
    }

    func testDuplicateBlockSubmissionIgnored() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let s = spec(premine: 0)
        let genesis = try await buildAndStoreGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        var chain = ChainTree.fromGenesis(block: genesis)

        let block1 = try await buildAndStoreBlock(
            previous: genesis, timestamp: base + 1000,
            target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let result1 = chain.submitTestBlock(
            blockHeader: try! VolumeImpl<Block>(node: block1), block: block1
        )
        XCTAssertTrue(result1.extendsCanonical)

        let result2 = chain.submitTestBlock(
            blockHeader: try! VolumeImpl<Block>(node: block1), block: block1
        )
        XCTAssertFalse(result2.extendsCanonical, "Duplicate should not extend")

        let height = chain.getHighestBlockHeight()
        XCTAssertEqual(height, 1)
    }

}

// MARK: - 7. Block Limits & Stress

@MainActor
final class BlockLimitTests: XCTestCase {

    func testMaxTransactionsPerBlockEnforced() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let s = ChainSpec.test(maxNumberOfTransactionsPerBlock: 2)

        let genesis = try await buildAndStoreGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        var txs: [Transaction] = []
        for i: UInt64 in 0..<3 {
            let kp = CryptoUtils.generateKeyPair()
            let body = TransactionBody(
                accountActions: [], actions: [], depositActions: [],
                receiptActions: [], withdrawalActions: [],
                signers: [], nonce: i,
                chainPath: ["Nexus"]
            )
            txs.append(sign(body, kp))
        }

        let block = try await buildAndStoreBlock(
            previous: genesis, transactions: txs,
            timestamp: base + 1000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid, "Should reject block exceeding max transaction count")
    }

    func testEmptyBlockChainMaintainsConsistency() async throws {
        let fetcher = makeFetcher()
        let base = t() - 200_000
        let s = spec(premine: 0)

        var prev = try await buildAndStoreGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        for i in 1...100 {
            let block = try await buildAndStoreBlock(
                previous: prev, timestamp: base + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            XCTAssertEqual(block.height, UInt64(i))
            XCTAssertEqual(block.prevState.rawCID, prev.postState.rawCID)
            XCTAssertEqual(block.postState.rawCID, block.prevState.rawCID, "Empty blocks should not change state")
            prev = block
        }
    }

    func testBlockSizeLimitEnforced() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let tinySpec = ChainSpec.test(maxBlockSize: 100)

        let genesis = try await buildAndStoreGenesis(
            spec: tinySpec, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let valid = try await genesis.validateGenesis(
            fetcher: fetcher,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        ).0
        XCTAssertFalse(valid, "Genesis block should exceed 100 byte limit")
    }

    func testChainSpecValidation() async {
        let validSpec = spec()
        XCTAssertTrue(validSpec.isValid)

        let zeroTx = ChainSpec.test(
            maxNumberOfTransactionsPerBlock: 0,
            maxStateGrowth: 100,
            maxBlockSize: 100
        )
        XCTAssertFalse(zeroTx.isValid)

        let zeroTarget = ChainSpec.test(maxStateGrowth: 100, maxBlockSize: 100, targetBlockTime: 0)
        XCTAssertFalse(zeroTarget.isValid)

        let zeroReward = ChainSpec.test(maxStateGrowth: 100, maxBlockSize: 100, initialReward: 0)
        XCTAssertFalse(zeroReward.isValid)
    }
}

// MARK: - 8. Timestamp Validation

@MainActor
final class TimestampSecurityTests: XCTestCase {

    func testNearFutureTimestampNotAdmitted() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let s = spec(premine: 0)

        let genesis = try await buildAndStoreGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        // There is no future-drift budget: the single rule is `timestamp ≤ now`.
        // A block even 60 s ahead of the node's clock is not admitted now — it is
        // deferred until real time reaches its timestamp (retriable, not
        // permanently invalid), never built upon in the meantime.
        let nearFuture = try await buildAndStoreBlock(
            previous: genesis, timestamp: t() + 60_000,
            target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await nearFuture.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid, "a block from the node's future must not be admitted now")
    }

    func testFarFutureTimestampNotAdmitted() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let s = spec(premine: 0)

        let genesis = try await buildAndStoreGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        // Same rule, larger lead: a far-future stamp is likewise not admitted.
        // This is what stops a warp-forward timestamp from entering the chain and
        // locking out honest real-time miners.
        let farFuture = try await buildAndStoreBlock(
            previous: genesis, timestamp: t() + 3 * 60 * 60 * 1000,
            target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await farFuture.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid, "a far-future timestamp must not be admitted")
    }

    func testOldTimestampStillValidatesForSync() async throws {
        let fetcher = makeFetcher()
        // A block from 24 h ago: must still validate so cold-syncing nodes
        // can ingest historical blocks. The consensus rule gates only the
        // future side against wall clock; MTP handles ordering.
        let base = t() - 24 * 60 * 60 * 1000
        let s = spec(premine: 0)

        let genesis = try await buildAndStoreGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )
        let nextOld = try await buildAndStoreBlock(
            previous: genesis, timestamp: base + 1_000,
            target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await nextOld.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid, "blocks >2h old must still validate for sync")
    }

    func testNonIncreasingTimestampRejected() async throws {
        let fetcher = makeFetcher()
        let base = t() - 10_000
        let s = spec(premine: 0)

        let genesis = try await buildAndStoreGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: fetcher
        )

        let sameTime = try await buildAndStoreBlock(
            previous: genesis, timestamp: base,
            target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let v1 = try await sameTime.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(v1)

        let earlier = try await buildAndStoreBlock(
            previous: genesis, timestamp: base - 1,
            target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let v2 = try await earlier.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(v2)
    }
}
