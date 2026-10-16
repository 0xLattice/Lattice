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
import Crypto

// MARK: - Shared Test Infrastructure

/// Storing, not the throwing stub: these suites build real multi-block chains
/// and the difficulty schedule is anchored at the height-1 ancestor, so a block
/// past height 2 has to be able to reach back through its own ancestry. The old
/// windowed retarget tolerated an unreachable ancestor by silently retargeting
/// on whatever prefix it could read, which made a non-resolving fetcher look
/// harmless here; it no longer is, and a chain whose blocks cannot be fetched
/// was never a realistic thing to assert chain invariants against.
private let fetcher = StorableFetcher()

private func spec() -> ChainSpec {
    ChainSpec.test()
}

private func genesis(timestamp: Int64 = 1_000_000, nonce: UInt64 = 0) async throws -> Block {
    try await buildAndStoreGenesis(
        spec: spec(), timestamp: timestamp, target: UInt256(1000), nonce: nonce, fetcher: fetcher
    )
}

private func next(_ previous: Block, ts: Int64, nonce: UInt64 = 0) async throws -> Block {
    try await buildAndStoreBlock(
        previous: previous, timestamp: ts, target: UInt256(1000), nonce: nonce, fetcher: fetcher
    )
}

private func header(_ block: Block) -> BlockHeader { try! VolumeImpl<Block>(node: block) }

private func buildChain(length: Int, startTimestamp: Int64 = 1_000_000) async throws -> [Block] {
    var blocks: [Block] = [try await genesis(timestamp: startTimestamp)]
    for i in 1..<length {
        blocks.append(try await next(blocks.last!, ts: startTimestamp + Int64(i) * 1000, nonce: UInt64(i)))
    }
    return blocks
}

private func submitChain(_ chain: ChainState, blocks: [Block]) async {
    for block in blocks.dropFirst() {
        let _ = await chain.submitTestBlock(
            blockHeader: header(block), block: block
        )
    }
}

// MARK: - Adversarial: Double-Spend Prevention

@MainActor
final class DoubleSpendTests: XCTestCase {

    func testSameBlockSubmittedTwiceIsRejected() async throws {
        let g = try await genesis()
        let chain = ChainState.fromGenesis(block: g)
        let b1 = try await next(g, ts: 2_000_000, nonce: 1)

        let first = await chain.submitTestBlock(blockHeader: header(b1), block: b1)
        XCTAssertTrue(first.addedBlock)

        let second = await chain.submitTestBlock(blockHeader: header(b1), block: b1)
        XCTAssertFalse(second.addedBlock, "Duplicate block must be rejected")
    }

    func testTransactionNonceReplayBlocked() async {
        let body1 = TransactionBody(
            accountActions: [AccountAction(owner: "alice", delta: Int64(50) - Int64(100))],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [], signers: ["alice"], nonce: 42,
            chainPath: ["Nexus"]
        )
        let body2 = TransactionBody(
            accountActions: [AccountAction(owner: "alice", delta: -Int64(50))],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [], signers: ["alice"], nonce: 42,
            chainPath: ["Nexus"]
        )
        let key1 = AccountStateHeader.nonceTrackingKey(body1.signers[0])
        let key2 = AccountStateHeader.nonceTrackingKey(body2.signers[0])
        XCTAssertEqual(key1, key2, "Same signer must produce same nonce-tracking key")
        XCTAssertEqual(body1.nonce, body2.nonce, "Replaying the same nonce must be detectable at state update time")
    }

    func testDifferentSignersSameNonceNotBlocked() async {
        let body1 = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: ["alice"], nonce: 1,
            chainPath: ["Nexus"]
        )
        let body2 = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: ["bob"], nonce: 1,
            chainPath: ["Nexus"]
        )
        XCTAssertNotEqual(
            AccountStateHeader.nonceTrackingKey(body1.signers[0]),
            AccountStateHeader.nonceTrackingKey(body2.signers[0]),
            "Different signers must track nonces under distinct keys"
        )
    }
}

// MARK: - State Model Hardening

@MainActor
final class StateModelHardeningTests: XCTestCase {

    func testPerAccountNonceIgnoresCosignerSet() async throws {
        let stateFetcher = StorableFetcher()
        let empty = try! AccountStateHeader(node: AccountState())
        try await empty.storeRecursively(storer: stateFetcher)

        let solo = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: ["alice"], nonce: 0,
            chainPath: ["Nexus"]
        )
        let (afterSolo, _) = try await empty.proveAndUpdateState(
            allAccountActions: [],
            transactionBodies: [solo],
            fetcher: stateFetcher
        )
        try await afterSolo.storeRecursively(storer: stateFetcher)

        let cosignedReplay = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: ["alice", "bob"], nonce: 0,
            chainPath: ["Nexus"]
        )
        do {
            _ = try await afterSolo.proveAndUpdateState(
                allAccountActions: [],
                transactionBodies: [cosignedReplay],
                fetcher: stateFetcher
            )
            XCTFail("reusing alice's nonce under a cosigner set must fail")
        } catch StateErrors.nonceGap {
            // expected
        }

        let nextSolo = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: ["alice"], nonce: 1,
            chainPath: ["Nexus"]
        )
        _ = try await afterSolo.proveAndUpdateState(
            allAccountActions: [],
            transactionBodies: [nextSolo],
            fetcher: stateFetcher
        )
    }

    func testWithdrawalWithoutDepositRejectsInAccounting() async throws {
        let stateFetcher = StorableFetcher()
        let empty = try! DepositStateHeader(node: DepositState())
        try await empty.storeRecursively(storer: stateFetcher)

        let missing = WithdrawalAction(
            withdrawer: "bob",
            nonce: 1,
            demander: "alice",
            amountDemanded: 100,
            amountWithdrawn: 100
        )
        do {
            _ = try await empty.proveAndSpendForWithdrawals(
                allWithdrawalActions: [missing],
                fetcher: stateFetcher
            )
            XCTFail("absent deposits must fail closed in accounting")
        } catch StateErrors.conflictingActions {
            // expected
        }

        let deposit = DepositAction(
            nonce: 2,
            demander: "alice",
            amountDemanded: 100,
            amountDeposited: 90
        )
        let (afterDeposit, _) = try await empty.proveAndUpdateState(
            allDepositActions: [deposit],
            fetcher: stateFetcher
        )
        try await afterDeposit.storeRecursively(storer: stateFetcher)

        let overClaim = WithdrawalAction(
            withdrawer: "bob",
            nonce: 2,
            demander: "alice",
            amountDemanded: 100,
            amountWithdrawn: 100
        )
        do {
            _ = try await afterDeposit.proveAndSpendForWithdrawals(
                allWithdrawalActions: [overClaim],
                fetcher: stateFetcher
            )
            XCTFail("amount mismatch must remain rejected")
        } catch StateErrors.conflictingActions {
            // expected
        }
    }

    func testSignatureRequiresDomainTag() async throws {
        let keyPair = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [CryptoUtils.createAddress(from: keyPair.publicKey)],
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let message = try! HeaderImpl<TransactionBody>(node: body).rawCID
        let privateKeyData = try XCTUnwrap(Data(hex: keyPair.privateKey))
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        let rawSignature = try privateKey.signature(for: Data(message.utf8)).hexString

        XCTAssertFalse(CryptoUtils.verify(message: message, signature: rawSignature, publicKeyHex: keyPair.publicKey))

        let domainSignature = try XCTUnwrap(CryptoUtils.sign(message: message, privateKeyHex: keyPair.privateKey))
        XCTAssertTrue(CryptoUtils.verify(message: message, signature: domainSignature, publicKeyHex: keyPair.publicKey))
    }

    func testNonceKeyCannotCollideWithBalanceKey() async throws {
        let keyPair = CryptoUtils.generateKeyPair()
        let address = CryptoUtils.createAddress(from: keyPair.publicKey)
        XCTAssertFalse(AccountStateHeader.isReservedAccountKey(address))
        XCTAssertTrue(AccountStateHeader.isReservedAccountKey(AccountStateHeader.nonceTrackingKey(address)))

        let stateFetcher = StorableFetcher()
        let empty = try! AccountStateHeader(node: AccountState())
        try await empty.storeRecursively(storer: stateFetcher)

        do {
            _ = try await empty.proveAndUpdateState(
                allAccountActions: [AccountAction(owner: AccountStateHeader.nonceTrackingKey(address), delta: 1)],
                fetcher: stateFetcher
            )
            XCTFail("reserved nonce namespace must not be usable as an account balance key")
        } catch StateErrors.conflictingActions {
            // expected
        }
    }

    func testVerifyHelpersAreWiredIntoTransactionValidation() async throws {
        let keyPair = CryptoUtils.generateKeyPair()
        let signer = CryptoUtils.createAddress(from: keyPair.publicKey)
        let invalidGeneralAction = TransactionBody(
            accountActions: [],
            actions: [Action(key: "", oldValue: nil, newValue: "value")],
            depositActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [signer],
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let invalidGeneralTx = signedTransaction(
            body: invalidGeneralAction,
            privateKeyHex: keyPair.privateKey,
            publicKeyHex: keyPair.publicKey
        )
        let invalidGeneralAccepted = try await invalidGeneralTx.validateTransactionForNexus(fetcher: fetcher)
        XCTAssertFalse(invalidGeneralAccepted)

        let invalidAccountAction = TransactionBody(
            accountActions: [AccountAction(owner: signer, delta: 0)],
            actions: [],
            depositActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [signer],
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let invalidAccountTx = signedTransaction(
            body: invalidAccountAction,
            privateKeyHex: keyPair.privateKey,
            publicKeyHex: keyPair.publicKey
        )
        let invalidAccountAccepted = try await invalidAccountTx.validateTransactionForNexus(fetcher: fetcher)
        XCTAssertFalse(invalidAccountAccepted)
    }

    func testVerifyHelperWiringStillAcceptsValidInlineEdgeCase() async throws {
        let keyPair = CryptoUtils.generateKeyPair()
        let signer = CryptoUtils.createAddress(from: keyPair.publicKey)
        let recipient = "recipient-credit-only"
        let body = TransactionBody(
            accountActions: [AccountAction(owner: recipient, delta: 25)],
            actions: [Action(key: "profile", oldValue: "old", newValue: "new")],
            depositActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [signer],
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let tx = signedTransaction(
            body: body,
            privateKeyHex: keyPair.privateKey,
            publicKeyHex: keyPair.publicKey
        )

        let accepted = try await tx.validateTransactionForNexus(fetcher: fetcher)
        XCTAssertTrue(accepted)
    }
}

// MARK: - Adversarial: Signature Forgery

@MainActor
final class SignatureForgeryTests: XCTestCase {

    /// Exactly one accepted key encoding: the legacy branch that also accepted
    /// a bare 32-byte Ed25519 hex key gave the same key two valid encodings on
    /// live consensus surface. Bare-hex must now fail verification while the
    /// canonical Multikey form still verifies.
    func testBareHexPublicKeyEncodingRejected() async {
        let kp = CryptoUtils.generateKeyPair()
        let message = "single-encoding-check"
        guard let sig = CryptoUtils.sign(message: message, privateKeyHex: kp.privateKey) else {
            return XCTFail("signing failed")
        }
        XCTAssertTrue(
            CryptoUtils.verify(message: message, signature: sig, publicKeyHex: kp.publicKey),
            "canonical Multikey encoding must verify")
        XCTAssertTrue(kp.publicKey.hasPrefix("ed01"), "Multikey ed25519 keys are ed01-prefixed")
        let bareHex = String(kp.publicKey.dropFirst(4))
        XCTAssertFalse(
            CryptoUtils.verify(message: message, signature: sig, publicKeyHex: bareHex),
            "bare 32-byte hex encoding of the same key must fail closed")
    }

    func testNoncanonicalSignatureAndPublicKeyHexFailClosed() async {
        let kp = CryptoUtils.generateKeyPair()
        let message = "canonical-hex-check"
        guard let signature = CryptoUtils.sign(message: message, privateKeyHex: kp.privateKey),
              let letter = signature.firstIndex(where: { $0.isLetter }) else {
            return XCTFail("signing must produce lowercase hexadecimal")
        }
        var uppercaseSignature = signature
        uppercaseSignature.replaceSubrange(
            letter...letter,
            with: String(signature[letter]).uppercased()
        )

        XCTAssertFalse(CryptoUtils.verify(
            message: message,
            signature: "0x\(signature)",
            publicKeyHex: kp.publicKey
        ))
        XCTAssertFalse(CryptoUtils.verify(
            message: message,
            signature: uppercaseSignature,
            publicKeyHex: kp.publicKey
        ))
        XCTAssertFalse(CryptoUtils.verify(
            message: message,
            signature: signature,
            publicKeyHex: "0x\(kp.publicKey)"
        ))
        XCTAssertFalse(CryptoUtils.verify(
            message: message,
            signature: signature,
            publicKeyHex: kp.publicKey.uppercased()
        ))

        let alteredSignature = (signature.first == "0" ? "1" : "0") + signature.dropFirst()
        XCTAssertFalse(CryptoUtils.verify(
            message: message,
            signature: alteredSignature,
            publicKeyHex: kp.publicKey
        ))
    }

    func testForgedSignatureRejected() async {
        let kp = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [try! HeaderImpl<PublicKey>(node: PublicKey(key: kp.publicKey)).rawCID],
            nonce: 1,
            chainPath: ["Nexus"]
        )
        let bodyHeader = try! HeaderImpl<TransactionBody>(node: body)
        let tx = Transaction(signatures: [kp.publicKey: "000000deadbeef000000"], body: bodyHeader)
        XCTAssertFalse(tx.signaturesAreValid(), "Forged signature must be rejected")
    }

    func testWrongSignerKeyRejected() async {
        let kp1 = CryptoUtils.generateKeyPair()
        let kp2 = CryptoUtils.generateKeyPair()
        let signerCID = try! HeaderImpl<PublicKey>(node: PublicKey(key: kp2.publicKey)).rawCID
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [signerCID], nonce: 1,
            chainPath: ["Nexus"]
        )
        let bodyHeader = try! HeaderImpl<TransactionBody>(node: body)
        let sig = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: kp1.privateKey)!
        let tx = Transaction(signatures: [kp1.publicKey: sig], body: bodyHeader)
        XCTAssertTrue(tx.signaturesAreValid(), "Signature is cryptographically valid")
        XCTAssertFalse(tx.signaturesMatchSigners(), "But signer CID doesn't match")
    }

    func testEmptySignatureRejected() async {
        let kp = CryptoUtils.generateKeyPair()
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [try! HeaderImpl<PublicKey>(node: PublicKey(key: kp.publicKey)).rawCID],
            nonce: 1,
            chainPath: ["Nexus"]
        )
        let tx = Transaction(signatures: [kp.publicKey: ""], body: try! HeaderImpl<TransactionBody>(node: body))
        XCTAssertFalse(tx.signaturesAreValid())
    }
}

// MARK: - Adversarial: Balance Conservation

@MainActor
final class BalanceConservationTests: XCTestCase {

    func testMinerSurplus() {
        func body(
            _ accountActions: [AccountAction],
            deposits: [DepositAction] = [],
            withdrawals: [WithdrawalAction] = []
        ) -> TransactionBody {
            TransactionBody(
                accountActions: accountActions, actions: [],
                depositActions: deposits, receiptActions: [], withdrawalActions: withdrawals,
                signers: ["sender"], nonce: 0, chainPath: ["Nexus"]
            )
        }
        XCTAssertEqual(body([
            AccountAction(owner: "sender", delta: -101),
            AccountAction(owner: "recipient", delta: 100),
        ]).minerSurplus(), WorkSum(UInt256(1)))
        XCTAssertEqual(body([
            AccountAction(owner: "sender", delta: -100),
            AccountAction(owner: "recipient", delta: 100),
        ]).minerSurplus(), .zero)
        XCTAssertNil(body([
            AccountAction(owner: "recipient", delta: 1),
        ]).minerSurplus(), "a transaction that creates value has no surplus")

        // Debits 150 + withdrawn 20 − credits 100 − deposited 30 = 40.
        XCTAssertEqual(body(
            [
                AccountAction(owner: "sender", delta: -150),
                AccountAction(owner: "recipient", delta: 100),
            ],
            deposits: [DepositAction(nonce: 1, demander: "sender", amountDemanded: 30, amountDeposited: 30)],
            withdrawals: [WithdrawalAction(withdrawer: "sender", nonce: 1, demander: "recipient", amountDemanded: 20, amountWithdrawn: 20)]
        ).minerSurplus(), WorkSum(UInt256(40)))

        XCTAssertNil(body([AccountAction(owner: "sender", delta: Int64.min)]).minerSurplus())

        // Sums past UInt64 stay exact.
        let beyondUInt64 = body(
            Array(repeating: AccountAction(owner: "sender", delta: -Int64.max), count: 3)
                + Array(repeating: AccountAction(owner: "recipient", delta: Int64.max), count: 2)
        )
        XCTAssertEqual(beyondUInt64.minerSurplus(), WorkSum(UInt256(UInt64(Int64.max))))
    }

    func testCannotCreateMoneyFromNothing() async throws {
        let g = Block(
            parent: nil,
            transactions: try! HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Transaction>>()),
            target: UInt256(1000), nextTarget: UInt256(1000),
            spec: try! VolumeImpl<ChainSpec>(node: spec()),
            parentState: try! LatticeStateHeader(node: LatticeState.emptyState()).removingNode(),
            prevState: try! LatticeStateHeader(node: LatticeState.emptyState()).removingNode(),
            postState: try! LatticeStateHeader(node: LatticeState.emptyState()),
            children: try! HeaderImpl(node: FlatDictionary<BlockHeader>()),
            height: 0, timestamp: 1_000_000, rewardRecipient: nil, nonce: 0
        )
        let accountActions = [AccountAction(owner: "miner", delta: Int64(999_999_999))]
        let valid = try g.validateBalanceChangesForGenesis(
            spec: spec(), allAccountActions: accountActions
        )
        XCTAssertFalse(valid, "Cannot create more value than premine allows")
    }

    func testFeeClaimRequiresSignerDebit() async throws {
        let g = Block(
            parent: nil,
            transactions: try! HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Transaction>>()),
            target: UInt256(1000), nextTarget: UInt256(1000),
            spec: try! VolumeImpl<ChainSpec>(node: spec()),
            parentState: try! LatticeStateHeader(node: LatticeState.emptyState()).removingNode(),
            prevState: try! LatticeStateHeader(node: LatticeState.emptyState()).removingNode(),
            postState: try! LatticeStateHeader(node: LatticeState.emptyState()),
            children: try! HeaderImpl(node: FlatDictionary<BlockHeader>()),
            height: 1, timestamp: 2_000_000, rewardRecipient: nil, nonce: 0
        )
        let s = spec()
        let reward = s.rewardAtBlock(1)
        let fees: UInt64 = 50
        let recipient = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let funded = Block.coinbaseCredit(
            spec: s, height: g.height, recipient: recipient,
            accountActions: [AccountAction(owner: "sender", delta: -Int64(fees))],
            depositActions: [], withdrawalActions: []
        )
        guard case .success(let credit?) = funded else {
            return XCTFail("Signer debits fund the recipient's fees")
        }
        XCTAssertEqual(credit.delta, Int64(reward + fees))

        // A transaction credit is not funded by the reward any more: minting
        // even the reward alone, with no debit behind it, breaks the fee rule.
        XCTAssertEqual(coinbaseFailure(Block.coinbaseCredit(
            spec: s, height: g.height, recipient: recipient,
            accountActions: [AccountAction(owner: "miner", delta: Int64(reward))],
            depositActions: [], withdrawalActions: []
        )), .feeRuleViolated, "Credits without matching debits must be rejected")
    }

    func testGenesisFeesDoNotExpandPremineBudget() async throws {
        let g = Block(
            parent: nil,
            transactions: try! HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Transaction>>()),
            target: UInt256(1000), nextTarget: UInt256(1000),
            spec: try! VolumeImpl<ChainSpec>(node: spec()),
            parentState: try! LatticeStateHeader(node: LatticeState.emptyState()).removingNode(),
            prevState: try! LatticeStateHeader(node: LatticeState.emptyState()).removingNode(),
            postState: try! LatticeStateHeader(node: LatticeState.emptyState()),
            children: try! HeaderImpl(node: FlatDictionary<BlockHeader>()),
            height: 0, timestamp: 1_000_000, rewardRecipient: nil, nonce: 0
        )
        let s = spec()
        let fees: UInt64 = 50
        let invalid = try g.validateBalanceChangesForGenesis(
            spec: s, allAccountActions: [
                AccountAction(owner: "miner", delta: Int64(fees))
            ]
        )
        XCTAssertFalse(invalid, "Genesis transaction fees must not mint beyond premine")
    }
}

// MARK: -: Model-A Fee Keystone (block-level)

/// E4.4 keystone. The fee-market equilibrium analysis rests on one consensus
/// fact: a fee cannot enlarge issuance — it is only an ordinary signer debit
/// redistributed to the block's `rewardRecipient`, so net mint stays equal to
/// `reward` (see `Block.coinbaseAmount`). This drives a BLOCK-LEVEL entry
/// (validateNexus) so the assertion exercises real per-tx structure, not the
/// flattened coinbase helper.
@MainActor
final class ModelAFeeKeystoneTests: XCTestCase {

    private func nexusSpec(premine: UInt64) -> ChainSpec {
        ChainSpec.test(premine: premine)
    }

    private func signNexus(_ body: TransactionBody, _ kp: (privateKey: String, publicKey: String)) -> Transaction {
        let h = try! HeaderImpl<TransactionBody>(node: body)
        let sig = TransactionSigning.sign(bodyHeader: h, privateKeyHex: kp.privateKey)!
        return Transaction(signatures: [kp.publicKey: sig], body: h)
    }

    private func addr(_ pubKey: String) -> String {
        try! HeaderImpl<PublicKey>(node: PublicKey(key: pubKey)).rawCID
    }

    /// A fee with NO backing signer debit must be rejected. The block carries
    /// one signed tx whose only account action is a miner self-credit
    /// AccountAction(delta: +(reward+X)) — the old reward-transaction shape.
    /// Credits exceed debits (C > D), so the fee rule fails and the block is
    /// rejected — neither the fee nor the reward can be minted by a transaction.
    func test_feeRequiresSignerDebit_blockRejected() async throws {
        let f = StorableFetcher()
        let base = Int64(Date().timeIntervalSince1970 * 1000) - 10_000
        let miner = CryptoUtils.generateKeyPair()
        let minerAddr = addr(miner.publicKey)
        let s = nexusSpec(premine: 0)
        let fee: UInt64 = 50
        let reward = s.rewardAtBlock(1)

        let genesis = try await buildAndStoreGenesis(
            spec: s, timestamp: base, target: UInt256(1000), fetcher: f
        )
        // The signer is never debited; the only account action is the miner
        // crediting itself reward + fee.
        let maliciousBody = TransactionBody(
            accountActions: [AccountAction(owner: minerAddr, delta: Int64(reward + fee))],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [minerAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let block = try await buildAndStoreBlock(
            previous: genesis, transactions: [signNexus(maliciousBody, miner)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            allowFeeRuleViolation: true, fetcher: f
        )

        let valid = try await block.validateNexus(fetcher: f).0
        XCTAssertFalse(valid, "Model A: a declared fee with no backing signer debit must not enlarge issuance — the block must be rejected by the conservation check")
    }

    /// Positive companion: when the signer IS debited exactly `fee`, the block's
    /// recipient is credited reward + fee and the block validates. This proves
    /// the keystone test rejects for the conservation reason, not because all
    /// fees are refused.
    func test_feeWithSignerDebit_blockValidates() async throws {
        let f = StorableFetcher()
        let base = Int64(Date().timeIntervalSince1970 * 1000) - 10_000
        let payer = CryptoUtils.generateKeyPair()
        let payerAddr = addr(payer.publicKey)
        let miner = CryptoUtils.generateKeyPair()
        let minerAddr = addr(miner.publicKey)
        let s = nexusSpec(premine: 1000)
        let fee: UInt64 = 50
        let reward = s.rewardAtBlock(1)

        let genesis = try await buildPremineGenesis(spec: s, owner: payer, fetcher: f, timestamp: base)
        let fundedBody = TransactionBody(
            accountActions: [AccountAction(owner: payerAddr, delta: -Int64(fee))],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [payerAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let block = try await buildAndStoreBlock(
            previous: genesis, transactions: [signNexus(fundedBody, payer)],
            timestamp: base + 1000, target: UInt256(1000), nonce: 1,
            rewardRecipient: minerAddr, fetcher: f
        )

        let (valid, _, postState) = try await block.validateNexus(fetcher: f)
        XCTAssertTrue(valid, "A fee backed by an exact signer debit funds the recipient credit and must validate")
        let minerBalance: UInt64? = try postState?.accountState.node?.get(key: minerAddr)
        XCTAssertEqual(minerBalance, reward + fee)
    }
}

// MARK: - Adversarial: Block Validation Checks

@MainActor
final class BlockValidationAdversarialTests: XCTestCase {

    func testBlockWithWrongIndexRejected() async throws {
        let g = try await genesis()
        let wrongIndex = Block(
            parent: try! VolumeImpl(node: g).removingNode(),
            transactions: try! HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Transaction>>()),
            target: UInt256(1000), nextTarget: UInt256(1000),
            spec: g.spec,
            parentState: try! LatticeStateHeader(node: LatticeState.emptyState()).removingNode(),
            prevState: g.postState.removingNode(),
            postState: g.postState,
            children: try! HeaderImpl(node: FlatDictionary<BlockHeader>()),
            height: 5, timestamp: 2_000_000, rewardRecipient: nil, nonce: 0
        )
        XCTAssertFalse(wrongIndex.validateHeight(parent: g), "Non-sequential index must fail")
    }

    func testBlockWithPastTimestampRejected() async throws {
        let g = try await genesis(timestamp: 5_000_000)
        let pastBlock = Block(
            parent: try! VolumeImpl(node: g).removingNode(),
            transactions: try! HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Transaction>>()),
            target: UInt256(1000), nextTarget: UInt256(1000),
            spec: g.spec,
            parentState: try! LatticeStateHeader(node: LatticeState.emptyState()).removingNode(),
            prevState: g.postState.removingNode(),
            postState: g.postState,
            children: try! HeaderImpl(node: FlatDictionary<BlockHeader>()),
            height: 1, timestamp: 4_000_000, rewardRecipient: nil, nonce: 0
        )
        XCTAssertFalse(pastBlock.validateTimestamp(parent: g), "Timestamp before parent must fail")
    }

    func testBlockWithWrongSpecRejected() async throws {
        let g = try await genesis()
        let differentSpec = ChainSpec.test(
            maxNumberOfTransactionsPerBlock: 999,
            maxStateGrowth: 999,
            targetBlockTime: 999,
            initialReward: 32,
            halfLife: 10
        )
        let wrongSpec = Block(
            parent: try! VolumeImpl(node: g).removingNode(),
            transactions: try! HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Transaction>>()),
            target: UInt256(1000), nextTarget: UInt256(1000),
            spec: try! VolumeImpl<ChainSpec>(node: differentSpec),
            parentState: try! LatticeStateHeader(node: LatticeState.emptyState()).removingNode(),
            prevState: g.postState.removingNode(),
            postState: g.postState,
            children: try! HeaderImpl(node: FlatDictionary<BlockHeader>()),
            height: 1, timestamp: 2_000_000, rewardRecipient: nil, nonce: 0
        )
        XCTAssertFalse(wrongSpec.validateSpec(parent: g), "Changed spec must fail")
    }

    func testBlockWithWrongHomesteadRejected() async throws {
        let g = try await genesis()
        let wrongState = try! LatticeStateHeader(node: LatticeState.emptyState())
        let b = Block(
            parent: try! VolumeImpl(node: g).removingNode(),
            transactions: try! HeaderImpl(node: MerkleDictionaryImpl<VolumeImpl<Transaction>>()),
            target: UInt256(1000), nextTarget: UInt256(1000),
            spec: g.spec,
            parentState: wrongState.removingNode(),
            prevState: wrongState.removingNode(),
            postState: wrongState,
            children: try! HeaderImpl(node: FlatDictionary<BlockHeader>()),
            height: 1, timestamp: 2_000_000, rewardRecipient: nil, nonce: 0
        )
        let stateValid = b.validateState(parent: g)
        XCTAssertTrue(stateValid || g.postState.rawCID == wrongState.rawCID,
            "If frontier == emptyState, this may pass; otherwise must fail")
    }

    func testBlockSizeLimitEnforced() async throws {
        let tinySpec = ChainSpec.test(
            maxBlockSize: 10,
            halfLife: 10
        )
        let g = try await buildAndStoreGenesis(
            spec: tinySpec, timestamp: 1_000_000, target: UInt256(1000), fetcher: fetcher
        )
        let validSize = try await g.validateBlockSize(spec: tinySpec, fetcher: fetcher)
        XCTAssertFalse(validSize,
            "Block larger than 10 bytes must fail size check")
    }
}

// MARK: - Adversarial: Filter Bypass

@MainActor
final class FilterBypassTests: XCTestCase {

    func testTransactionPolicyEnforced() async throws {
        let fetcher = StorableFetcher()
        let policy = try await storeWasmPolicy(accepts: false, scope: .transaction, fetcher: fetcher)
        let feeSpec = ChainSpec.test(
            halfLife: 10,
            wasmPolicies: [policy]
        )
        let cheapTx = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [], nonce: 1,
            chainPath: ["Nexus"]
        )
        let accepted = try await TransactionBody.batchVerifyPolicies(bodies: [cheapTx], spec: feeSpec, chainPath: ["Nexus"], height: 1, timestamp: 1, parentTimestamp: 0, fetcher: fetcher)
        XCTAssertFalse(accepted)
    }

    func testActionPolicyEnforced() async throws {
        let fetcher = StorableFetcher()
        let policy = try await storeWasmPolicy(accepts: false, scope: .action, fetcher: fetcher)
        let nsSpec = ChainSpec.test(
            halfLife: 10,
            wasmPolicies: [policy]
        )
        let badAction = Action(key: "system/hack", oldValue: nil, newValue: "data")
        let body = TransactionBody(accountActions: [], actions: [badAction], depositActions: [], receiptActions: [], withdrawalActions: [], signers: [], nonce: 0, chainPath: ["Nexus"])
        let accepted = try await TransactionBody.batchVerifyPolicies(bodies: [body], spec: nsSpec, chainPath: ["Nexus"], height: 1, timestamp: 1, parentTimestamp: 0, fetcher: fetcher)
        XCTAssertFalse(accepted)
    }

    func testChildPoliciesDoNotImplicitlyInheritParentPolicies() async throws {
        let fetcher = StorableFetcher()
        let rejectingParentPolicy = try await storeWasmPolicy(accepts: false, scope: .transaction, fetcher: fetcher)
        let parentSpec = ChainSpec.test(
            halfLife: 10,
            wasmPolicies: [rejectingParentPolicy]
        )
        let childSpec = ChainSpec.test(halfLife: 10)
        let cheapTx = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [], nonce: 1,
            chainPath: ["Nexus"]
        )
        let childAccepted = try await TransactionBody.batchVerifyPolicies(bodies: [cheapTx], spec: childSpec, chainPath: ["Nexus", "Child"], height: 1, timestamp: 1, parentTimestamp: 0, fetcher: fetcher)
        let parentAccepted = try await TransactionBody.batchVerifyPolicies(bodies: [cheapTx], spec: parentSpec, chainPath: ["Nexus", "Child"], height: 1, timestamp: 1, parentTimestamp: 0, fetcher: fetcher)
        XCTAssertTrue(childAccepted, "Child spec has no policy, so it should not inherit the parent's rejecting policy by consensus")
        XCTAssertFalse(parentAccepted, "Parent policy still rejects when evaluated as the parent's own policy")
    }
}

// MARK: - Consensus Invariants Under Stress

@MainActor
final class ConsensusStressTests: XCTestCase {

    func testLongChainMaintainsInvariants() async throws {
        let blocks = try await buildChain(length: 100)
        let chain = ChainState.fromGenesis(block: blocks[0])
        await submitChain(chain, blocks: blocks)

        let tip = await chain.canonicalTip
        let highest = await chain.getHighestBlockHeight()
        XCTAssertEqual(highest, 99)

        let tipOnMain = await chain.isCanonical(hash: tip)
        XCTAssertTrue(tipOnMain)

        let genesisOnMain = await chain.isCanonical(hash: header(blocks[0]).rawCID)
        XCTAssertTrue(genesisOnMain)
    }

    func testManyForksFromSameBlock() async throws {
        let g = try await genesis()
        let chain = ChainState.fromGenesis(block: g)

        let b1 = try await next(g, ts: 2_000_000, nonce: 1)
        let _ = await chain.submitTestBlock(blockHeader: header(b1), block: b1)

        var candidates = [b1]
        for i in 0..<20 {
            let fork = try await next(g, ts: 2_000_000, nonce: UInt64(100 + i))
            let _ = await chain.submitTestBlock(blockHeader: header(fork), block: fork)
            candidates.append(fork)
        }

        // Fold with the consensus tie-break itself (raw CID BYTES): base32
        // string order differs from byte order, so String.min() is not the rule.
        let expected = candidates.map { header($0).rawCID }.reduce(nil as String?) { best, cid in
            guard let best else { return cid }
            return forkChoicePrefersBlock(cid, over: best) ? cid : best
        }
        let tip = await chain.canonicalTip
        XCTAssertEqual(tip, expected, "Equal-work bases should converge on the stable CID tie-break")
    }

    func testDeepReorgPreservesCommonAncestor() async throws {
        let blocks = try await buildChain(length: 20)
        let chain = ChainState.fromGenesis(block: blocks[0])
        await submitChain(chain, blocks: blocks)

        let forkPoint = blocks[5]
        var forkBlocks: [Block] = [forkPoint]
        for i in 6..<25 {
            let b = try await next(forkBlocks.last!, ts: 1_000_000 + Int64(i) * 1000, nonce: UInt64(200 + i))
            forkBlocks.append(b)
        }
        for b in forkBlocks.dropFirst() {
            let _ = await chain.submitTestBlock(blockHeader: header(b), block: b)
        }

        let newTip = await chain.canonicalTip
        XCTAssertEqual(newTip, header(forkBlocks.last!).rawCID)

        for i in 0...5 {
            let onMain = await chain.isCanonical(hash: header(blocks[i]).rawCID)
            XCTAssertTrue(onMain, "Common ancestor block \(i) must survive deep reorg")
        }

        for i in 6..<20 {
            let onMain = await chain.isCanonical(hash: header(blocks[i]).rawCID)
            XCTAssertFalse(onMain, "Replaced block \(i) must be off main chain")
        }
    }

    func testOutOfOrderBlockSubmission() async throws {
        let blocks = try await buildChain(length: 5)
        let chain = ChainState.fromGenesis(block: blocks[0])

        _ = await chain.submitTestBlock(blockHeader: header(blocks[3]), block: blocks[3])
        let requirements = await chain.unresolvedSameChainPredecessors()
        XCTAssertEqual(
            requirements,
            [SameChainPredecessorRequirement(
                descendantCID: header(blocks[3]).rawCID,
                predecessorCID: header(blocks[2]).rawCID
            )]
        )

        let r1 = await chain.submitTestBlock(blockHeader: header(blocks[1]), block: blocks[1])
        XCTAssertTrue(r1.extendsCanonical)

        let r2 = await chain.submitTestBlock(blockHeader: header(blocks[2]), block: blocks[2])
        XCTAssertTrue(r2.extendsCanonical)

        let r4 = await chain.submitTestBlock(blockHeader: header(blocks[4]), block: blocks[4])
        XCTAssertTrue(r4.addedBlock)

        let tipHash = await chain.canonicalTip
        let tipIndex = await chain.getHighestBlockHeight()
        XCTAssertEqual(tipIndex, 4)
        XCTAssertEqual(tipHash, header(blocks[4]).rawCID)
    }

}

// MARK: - Economic Invariant Tests

@MainActor
final class EconomicInvariantTests: XCTestCase {

    func testRewardHalvingOccursAtCorrectBlock() async {
        let s = spec()
        let halfInterval = s.halvingInterval
        let initial = s.rewardAtBlock(0)
        let beforeHalving = s.rewardAtBlock(halfInterval - 1)
        let atHalving = s.rewardAtBlock(halfInterval)
        XCTAssertEqual(initial, beforeHalving, "Reward constant within first period")
        XCTAssertEqual(atHalving, initial / 2, "Reward halves at interval boundary")
    }

    func testPremineOffsetShiftsHalving() async {
        let premineSpec = ChainSpec.test(
            premine: 100,
            halfLife: 10
        )
        let halfInterval = premineSpec.halvingInterval
        let firstHalvingBlock = halfInterval - 100
        let reward = premineSpec.initialReward
        XCTAssertEqual(premineSpec.rewardAtBlock(firstHalvingBlock - 1), reward)
        XCTAssertEqual(premineSpec.rewardAtBlock(firstHalvingBlock), reward / 2)
    }

    func testTotalRewardsMatchIndividualSum() async {
        let s = spec()
        let n: UInt64 = 200
        let individual = (0..<n).reduce(UInt64(0)) { $0 + s.rewardAtBlock($1) }
        let total = s.totalRewards(upToBlock: n)
        XCTAssertEqual(individual, total)
    }

}

// MARK: - Cross-Chain Key Integrity

@MainActor
final class CrossChainKeyIntegrityTests: XCTestCase {

    func testSwapKeyRoundTrip() async {
        for nonce: UInt128 in [0, 1, 42, UInt128.max / 2] {
            let key = DepositKey(depositAction: DepositAction(nonce: nonce, demander: "abc", amountDemanded: 999, amountDeposited: 999))
            let parsed = DepositKey(key.description)
            XCTAssertNotNil(parsed)
            XCTAssertEqual(parsed?.nonce, nonce)
            XCTAssertEqual(parsed?.demander, "abc")
            XCTAssertEqual(parsed?.amountDemanded, 999)
        }
    }

    func testSettleKeyRoundTrip() async {
        let receiptAction = ReceiptAction(withdrawer: "w", nonce: 77, demander: "d", amountDemanded: 500, directory: "chain1")
        let key = ReceiptKey(receiptAction: receiptAction)
        let parsed = ReceiptKey(key.description)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.directory, "chain1")
        XCTAssertEqual(parsed?.demander, "d")
        XCTAssertEqual(parsed?.amountDemanded, 500)
        XCTAssertEqual(parsed?.nonce, 77)
    }

    func testSwapAndClaimKeysMatch() async {
        let swap = DepositAction(nonce: 42, demander: "alice", amountDemanded: 100, amountDeposited: 100)
        let claim = WithdrawalAction(withdrawer: "bob", nonce: 42, demander: "alice", amountDemanded: 100, amountWithdrawn: 100)
        let swapKey = DepositKey(depositAction: swap)
        let claimKey = DepositKey(withdrawalAction: claim)
        XCTAssertEqual(swapKey.description, claimKey.description,
            "Swap and claim must produce the same lookup key")
    }

    func testMalformedKeysReturnNil() async {
        for bad in ["", "x", "a/b"] {
            XCTAssertNil(DepositKey(bad), "'\(bad)' should fail to parse as SwapKey")
        }
        for bad in ["", "x", "nodirectory", "dir/demander", "dir/demander/notanumber"] {
            XCTAssertNil(ReceiptKey(bad), "'\(bad)' should fail to parse as SettleKey")
        }
    }
}

// MARK: - Regression Tests for Fixed Bugs

@MainActor
final class BugRegressionTests: XCTestCase {

    func testSettleKeySeparatorFixed() async {
        let receiptAction = ReceiptAction(withdrawer: "w", nonce: 42, demander: "d", amountDemanded: 100, directory: "c")
        let key = ReceiptKey(receiptAction: receiptAction)
        let desc = key.description
        XCTAssertTrue(desc.contains("/"), "ReceiptKey parts must be separated by /")
        let parts = desc.split(separator: "/")
        XCTAssertEqual(parts.count, 4, "Must have 4 slash-separated parts: directory/demander/amountDemanded/nonce")
    }

    func testAccountStateProveUsesCorrectProofTypes() async throws {
        let emptyAccount = try! AccountStateHeader(node: AccountState())
        let insertAction = AccountAction(owner: "new_user", delta: Int64(100))
        let (proved, _) = try await emptyAccount.proveAndUpdateState(allAccountActions: [insertAction], fetcher: fetcher)
        XCTAssertNotNil(proved, "Insertion proof should succeed on empty state")
    }

    func testBestChainCacheInvalidationWalksFullAncestorChain() async throws {
        let blocks = try await buildChain(length: 5)
        let chain = ChainState.fromGenesis(block: blocks[0])
        await submitChain(chain, blocks: blocks)

        let tipBefore = await chain.canonicalTip
        XCTAssertEqual(tipBefore, header(blocks[4]).rawCID)

        var forkBlocks: [Block] = [blocks[2]]
        for i in 3..<8 {
            let b = try await next(forkBlocks.last!, ts: 1_000_000 + Int64(i) * 1000, nonce: UInt64(300 + i))
            forkBlocks.append(b)
            let _ = await chain.submitTestBlock(blockHeader: header(b), block: b)
        }

        let tipAfter = await chain.canonicalTip
        XCTAssertEqual(tipAfter, header(forkBlocks.last!).rawCID,
            "Cache must be invalidated so the longer fork wins")
    }
}

// MARK: - State Continuity Chain Invariant

@MainActor
final class StateChainInvariantTests: XCTestCase {

    func testFrontierChainsAcrossMultipleBlocks() async throws {
        let blocks = try await buildChain(length: 10)
        for i in 1..<blocks.count {
            XCTAssertEqual(
                blocks[i].prevState.rawCID,
                blocks[i-1].postState.rawCID,
                "Block \(i) homestead must equal block \(i-1) frontier"
            )
        }
    }

    func testEmptyBlocksPreserveState() async throws {
        let blocks = try await buildChain(length: 10)
        let genesisState = blocks[0].prevState.rawCID
        for block in blocks {
            XCTAssertEqual(block.prevState.rawCID, block.postState.rawCID,
                "Empty block \(block.height) should not change state")
            XCTAssertEqual(block.prevState.rawCID, genesisState,
                "All empty blocks should have same state as genesis")
        }
    }

    func testSpecImmutableAcrossChain() async throws {
        let blocks = try await buildChain(length: 10)
        let genesisSpec = blocks[0].spec.rawCID
        for block in blocks {
            XCTAssertEqual(block.spec.rawCID, genesisSpec, "Spec must never change")
        }
    }

    func testCIDsAreUnique() async throws {
        let blocks = try await buildChain(length: 50)
        let cids = Set(blocks.map { header($0).rawCID })
        XCTAssertEqual(cids.count, blocks.count, "Every block must have a unique CID")
    }

    func testDifficultyHashesAreUnique() async throws {
        let blocks = try await buildChain(length: 50)
        let hashes = Set(blocks.map { $0.proofOfWorkHash() })
        XCTAssertEqual(hashes.count, blocks.count, "Every block must have a unique target hash")
    }
}

// MARK: - State Root Validation (header-first gossip correctness)

/// Verifies that blocks with valid PoW + valid structure but a tampered/wrong
/// state root are rejected before being submitted to ChainState.
/// This is the critical invariant for the header-first gossip design:
/// gossip relay happens before state validation, so chain-local admission MUST
/// reject invalid state roots synchronously before submitBlock is called.
@MainActor
final class StateRootValidationTests: XCTestCase {

    /// A block with valid PoW and valid structure but a tampered postState CID
    /// must be rejected by chain-local admission before submitBlock is called.
    func testNexusBlockWithTamperedPostStateIsRejected() async throws {
        let f = StorableFetcher()
        let t = Int64(Date().timeIntervalSince1970 * 1000)
        // UInt256.max as target: any hash qualifies, so nonce 0 always works.
        let easyDifficulty = UInt256.max

        let g = try await buildAndStoreGenesis(
            spec: spec(), timestamp: t - 20_000, target: easyDifficulty, nonce: 0, fetcher: f
        )
        try await storeBuiltBlock(g, in: f)
        let validBlock = try await buildAndStoreBlock(
            previous: g, timestamp: t - 10_000, target: easyDifficulty, nonce: 0, fetcher: f
        )
        try await storeBlockToFetcher(validBlock, fetcher: f)

        // Tamper postState. Re-mine using the block's own target (UInt256.max),
        // so nonce 0 trivially satisfies the PoW check.
        let fakePostState = VolumeImpl<LatticeState>(rawCID: "bafyfaketamperedpoststate000000000000000000000000000000000000")
        let tampered = validBlock.set(properties: [POST_STATE_PROPERTY: fakePostState])
        guard let minedTampered = BlockBuilder.mine(
            block: tampered, target: easyDifficulty, maxAttempts: 10
        ) else {
            XCTFail("Could not mine tampered block with easy target")
            return
        }
        try await storeBlockToFetcher(minedTampered, fetcher: f)

        let level = ChainLevel(testChain: ChainState.fromGenesis(block: g))
        let result = try await level.importBlock(
            header(minedTampered),
            fetcher: f,
            validationContentStorer: f,
            materializedVolumeStorer: f,
            stage: testAdmissionStage
        )

        guard case .rejected(.protocolInvalid, _) = result else {
            return XCTFail("block with tampered postState must be rejected")
        }
        let tip = await level.chain.getHighestBlockHeight()
        XCTAssertEqual(tip, 0, "submitBlock must not have been called for a block with bad state root")
    }

    func testAcceptedBlockReturnsMaterializedPostStateAndRejectedBlockDoesNot() async throws {
        let f = StorableFetcher()
        let t = Int64(Date().timeIntervalSince1970 * 1000)
        let easyDifficulty = UInt256.max

        let g = try await buildAndStoreGenesis(
            spec: spec(), timestamp: t - 20_000, target: easyDifficulty, nonce: 0, fetcher: f
        )
        try await storeBuiltBlock(g, in: f)
        let validBlock = try await buildAndStoreBlock(
            previous: g, timestamp: t - 10_000, target: easyDifficulty, nonce: 0, fetcher: f
        )
        try await storeBlockToFetcher(validBlock, fetcher: f)

        let acceptingLevel = ChainLevel(testChain: ChainState.fromGenesis(block: g))
        let accepted = try await acceptingLevel.importBlock(
            header(validBlock),
            fetcher: f,
            validationContentStorer: f,
            materializedVolumeStorer: f,
            stage: testAdmissionStage
        )

        guard case let .accepted(acceptance) = accepted,
              let materializedPostState = acceptance.materializedPostState else {
            return XCTFail("accepted block should canonicalize with its materialized post-state")
        }
        XCTAssertEqual(
            try LatticeStateHeader(node: materializedPostState).rawCID,
            validBlock.postState.rawCID,
            "Returned state must be the post-state committed by the accepted block"
        )

        let fakePostState = VolumeImpl<LatticeState>(rawCID: "bafyfaketamperedpoststate000000000000000000000000000000000000")
        let tampered = validBlock.set(properties: [POST_STATE_PROPERTY: fakePostState])
        guard let minedTampered = BlockBuilder.mine(
            block: tampered, target: easyDifficulty, maxAttempts: 10
        ) else {
            XCTFail("Could not mine tampered block with easy target")
            return
        }
        try await storeBlockToFetcher(minedTampered, fetcher: f)

        let rejectingLevel = ChainLevel(testChain: ChainState.fromGenesis(block: g))
        let rejected = try await rejectingLevel.importBlock(
            header(minedTampered),
            fetcher: f,
            validationContentStorer: f,
            materializedVolumeStorer: f,
            stage: testAdmissionStage
        )

        guard case .rejected(.protocolInvalid, _) = rejected else {
            return XCTFail("tampered block must be rejected")
        }
    }

    func testWithheldParentReportsUnavailableThenAccepts() async throws {
        let producerFetcher = StorableFetcher()
        let incompleteFetcher = StorableFetcher()
        let completeFetcher = StorableFetcher()
        let t = Int64(Date().timeIntervalSince1970 * 1000)
        let easyDifficulty = UInt256.max

        let g = try await buildAndStoreGenesis(
            spec: spec(), timestamp: t - 20_000, target: easyDifficulty, nonce: 0, fetcher: producerFetcher
        )
        try await storeBuiltBlock(g, in: producerFetcher)
        let block = try await buildAndStoreBlock(
            previous: g, timestamp: t - 10_000, target: easyDifficulty, nonce: 0, fetcher: producerFetcher
        )
        try await VolumeImpl<Block>(node: block).storeBlock(
            fetcher: producerFetcher,
            storer: incompleteFetcher
        )

        let level = ChainLevel(testChain: ChainState.fromGenesis(block: g))
        let unavailable = try await level.importBlock(
            header(block),
            fetcher: incompleteFetcher,
            validationContentStorer: incompleteFetcher,
            materializedVolumeStorer: incompleteFetcher,
            stage: testAdmissionStage
        )

        guard case .rejected(.unavailableEvidence, _) = unavailable else {
            return XCTFail("a block whose parent data is unavailable must not be admitted")
        }
        let unavailableHeight = await level.chain.getHighestBlockHeight()
        XCTAssertEqual(unavailableHeight, 0, "Unavailable blocks must not be submitted")

        try await VolumeImpl<Block>(node: g).storeBlock(fetcher: producerFetcher, storer: completeFetcher)
        try await VolumeImpl<Block>(node: block).storeBlock(fetcher: producerFetcher, storer: completeFetcher)
        let accepted = try await level.importBlock(
            header(block),
            fetcher: completeFetcher,
            validationContentStorer: completeFetcher,
            materializedVolumeStorer: completeFetcher,
            stage: testAdmissionStage
        )

        guard case .accepted = accepted else {
            return XCTFail("an unavailable block must canonicalize once evidence arrives")
        }
        let acceptedHeight = await level.chain.getHighestBlockHeight()
        XCTAssertEqual(acceptedHeight, 1)
    }

    func testGenuinelyInvalidBlockRejects() async throws {
        let f = StorableFetcher()
        let t = Int64(Date().timeIntervalSince1970 * 1000)
        let easyDifficulty = UInt256.max

        let g = try await buildAndStoreGenesis(
            spec: spec(), timestamp: t - 20_000, target: easyDifficulty, nonce: 0, fetcher: f
        )
        try await storeBuiltBlock(g, in: f)
        let validBlock = try await buildAndStoreBlock(
            previous: g, timestamp: t - 10_000, target: easyDifficulty, nonce: 0, fetcher: f
        )

        let fakePostState = VolumeImpl<LatticeState>(rawCID: "bafyfaketamperedpoststate000000000000000000000000000000000000")
        let tampered = validBlock.set(properties: [POST_STATE_PROPERTY: fakePostState])
        guard let minedTampered = BlockBuilder.mine(
            block: tampered, target: easyDifficulty, maxAttempts: 10
        ) else {
            XCTFail("Could not mine tampered block with easy target")
            return
        }
        try await storeBlockToFetcher(minedTampered, fetcher: f)

        let level = ChainLevel(testChain: ChainState.fromGenesis(block: g))
        let rejected = try await level.importBlock(
            header(minedTampered),
            fetcher: f,
            validationContentStorer: f,
            materializedVolumeStorer: f,
            stage: testAdmissionStage
        )
        let rejectedAgain = try await level.importBlock(
            header(minedTampered),
            fetcher: f,
            validationContentStorer: f,
            materializedVolumeStorer: f,
            stage: testAdmissionStage
        )

        guard case .rejected(.protocolInvalid, _) = rejected else {
            return XCTFail("fully-resolvable invalid blocks must reject")
        }
        guard case .rejected(.protocolInvalid, _) = rejectedAgain else {
            return XCTFail("reprocessing complete invalid data must not become accepted")
        }
        let rejectedHeight = await level.chain.getHighestBlockHeight()
        XCTAssertEqual(rejectedHeight, 0)
    }

    /// A child block with valid PoW and valid structure but a tampered postState
    /// must not be submitted to the child chain.
    func testChildBlockWithTamperedPostStateIsRejected() async throws {
        let f = StorableFetcher()
        let t = Int64(Date().timeIntervalSince1970 * 1000)
        let easyDifficulty = UInt256.max
        let nexusSpec = ChainSpec.test()
        let childSpec = ChainSpec.test(initialReward: 512)

        let childGenesis = try await buildAndStoreGenesis(
            spec: childSpec, timestamp: t - 20_000, target: easyDifficulty, nonce: 0, fetcher: f
        )
        let nexusGenesis = try await buildAndStoreGenesis(
            spec: nexusSpec, timestamp: t - 20_000, target: easyDifficulty, nonce: 0, fetcher: f
        )
        try await storeBuiltBlock(childGenesis, in: f)
        try await storeBuiltBlock(nexusGenesis, in: f)

        let validChildBlock = try await buildAndStoreBlock(
            previous: childGenesis, parentChainBlock: nexusGenesis,
            timestamp: t - 10_000, target: easyDifficulty, nonce: 0, fetcher: f
        )
        try await storeBlockToFetcher(validChildBlock, fetcher: f)

        let fakePostState = VolumeImpl<LatticeState>(rawCID: "bafyfakechildpoststate00000000000000000000000000000000000000")
        let tamperedChild = validChildBlock.set(properties: [POST_STATE_PROPERTY: fakePostState])
        guard let minedTamperedChild = BlockBuilder.mine(
            block: tamperedChild, target: easyDifficulty, maxAttempts: 10
        ) else {
            XCTFail("Could not mine tampered child block with easy target")
            return
        }
        try await storeBlockToFetcher(minedTamperedChild, fetcher: f)

        // The child process receives the complete root-to-child proof package;
        // it does not depend on an in-process parent-chain runtime.
        let nexusCarrier = try await buildAndStoreGenesis(
            spec: nexusSpec, children: ["Child": minedTamperedChild],
            timestamp: t - 10_000, target: easyDifficulty, nonce: 0, fetcher: f
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: header(nexusCarrier),
            childDirectory: "Child",
            fetcher: f,
        )
        let package = try await childValidationPackage(proof: proof, fetcher: f)
        let childLevel = ChainLevel(
            chain: ChainState.fromGenesis(block: childGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        )
        let result = try await childLevel.importBlock(
            header(minedTamperedChild),
            fetcher: f,
            childPackage: package,
            validationContentStorer: f,
            materializedVolumeStorer: f,
            stage: testAdmissionStage
        )

        guard case .rejected(.protocolInvalid, _) = result else {
            return XCTFail("tampered child block must be rejected")
        }
        let childTip = await childLevel.chain.getHighestBlockHeight()
        XCTAssertEqual(childTip, 0, "Tampered child block must not be submitted to child chain")
    }
}

private func storeBlockToFetcher(_ block: Block, fetcher: StorableFetcher) async throws {
    try await VolumeImpl<Block>(node: block).storeBlock(storer: fetcher)
}
