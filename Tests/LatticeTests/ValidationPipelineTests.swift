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
import WasmParser
import WAT

/// Storing rather than no-op: these suites build multi-block chains, and the
/// difficulty schedule is anchored at the height-1 ancestor, so a block past
/// height 2 must be able to reach back through its own ancestry. A block's
/// parent is carried by CID alone, so that reach is a real fetch.
let testFetcher = StorableFetcher()

func testSpec() -> ChainSpec {
    ChainSpec.test(halfLife: 10)
}

func genesisBlock(
    spec: ChainSpec? = nil,
    timestamp: Int64 = 1_000_000,
    target: UInt256 = UInt256(1000),
    nonce: UInt64 = 0
) async throws -> Block {
    try await buildAndStoreGenesis(
        spec: spec ?? testSpec(),
        timestamp: timestamp,
        target: target,
        nonce: nonce,
        fetcher: testFetcher
    )
}

func nextBlock(
    previous: Block,
    timestamp: Int64,
    target: UInt256? = nil,
    nonce: UInt64 = 0
) async throws -> Block {
    try await buildAndStoreBlock(
        previous: previous,
        timestamp: timestamp,
        target: target,
        nonce: nonce,
        fetcher: testFetcher
    )
}

func signedTransaction(
    body: TransactionBody,
    privateKeyHex: String,
    publicKeyHex: String
) -> Transaction {
    let bodyHeader = try! HeaderImpl<TransactionBody>(node: body)
    let signature = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: privateKeyHex) ?? ""
    return Transaction(
        signatures: [publicKeyHex: signature],
        body: bodyHeader
    )
}

// MARK: - Block Builder Pipeline Tests

@MainActor
final class BlockBuilderTests: XCTestCase {

    func testBuildGenesisProducesValidBlock() async throws {
        let genesis = try await genesisBlock()
        XCTAssertNil(genesis.parent)
        XCTAssertEqual(genesis.height, 0)
        XCTAssertEqual(genesis.prevState.rawCID,
            try! LatticeStateHeader(node: LatticeState.emptyState()).rawCID)
        XCTAssertEqual(genesis.prevState.rawCID, genesis.postState.rawCID,
            "Genesis with no transactions should have prevState == postState")
    }

    func testGenesisValidationRejectsInvalidSpec() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: testSpec(),
            timestamp: 1_000,
            target: UInt256.max,
            fetcher: fetcher
        )
        let invalidSpec = ChainSpec.test(
            maxNumberOfTransactionsPerBlock: 0,
            halfLife: 10
        )
        let invalidHeader = try VolumeImpl<ChainSpec>(node: invalidSpec)
        try await invalidHeader.storeRecursively(storer: fetcher)
        let tampered = genesis.set(properties: [SPEC_PROPERTY: invalidHeader])

        let valid = try await tampered.validateGenesis(
            fetcher: fetcher,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        ).0

        XCTAssertFalse(valid)
    }

    func testBuildBlockChainsFrontierToHomestead() async throws {
        let genesis = try await genesisBlock()
        let block1 = try await nextBlock(previous: genesis, timestamp: 2_000_000)
        XCTAssertEqual(block1.prevState.rawCID, genesis.postState.rawCID)
        XCTAssertEqual(block1.height, 1)
        XCTAssertNotNil(block1.parent)
        XCTAssertEqual(block1.parent?.rawCID, try! VolumeImpl<Block>(node: genesis).rawCID)
    }

    func testBuildBlockPreservesSpec() async throws {
        let genesis = try await genesisBlock()
        let block1 = try await nextBlock(previous: genesis, timestamp: 2_000_000)
        let block2 = try await nextBlock(previous: block1, timestamp: 3_000_000)
        XCTAssertEqual(genesis.spec.rawCID, block1.spec.rawCID)
        XCTAssertEqual(block1.spec.rawCID, block2.spec.rawCID)
    }

    func testBuildBlockWithDifferentNonceProducesDifferentCID() async throws {
        let genesis = try await genesisBlock()
        let block1a = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 1)
        let block1b = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 2)
        XCTAssertNotEqual(
            try! VolumeImpl<Block>(node: block1a).rawCID,
            try! VolumeImpl<Block>(node: block1b).rawCID
        )
    }

    func testBuildBlockDifficultyHashChangesWithNonce() async throws {
        let genesis = try await genesisBlock()
        let block1a = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 1)
        let block1b = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 2)
        XCTAssertNotEqual(block1a.proofOfWorkHash(), block1b.proofOfWorkHash())
    }

    func testMineFindsValidNonce() async throws {
        let genesis = try await genesisBlock()
        let template = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 0)
        let target = UInt256.max
        let mined = BlockBuilder.mine(block: template, target: target, maxAttempts: 100)
        XCTAssertNotNil(mined)
        let hash = mined!.proofOfWorkHash()
        XCTAssertTrue(target >= hash)
    }

    func testMineReturnsNilWhenImpossible() async throws {
        let genesis = try await genesisBlock()
        let template = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 0)
        let mined = BlockBuilder.mine(block: template, target: UInt256(0), maxAttempts: 100)
        XCTAssertNil(mined)
    }
}

// MARK: - Full Submission Pipeline via BlockBuilder

@MainActor
final class BlockBuilderSubmissionTests: XCTestCase {

    func testBuiltBlocksFormValidChain() async throws {
        let genesis = try await genesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        var prev = genesis
        var ts: Int64 = 2_000_000
        for i in 1...10 {
            let block = try await nextBlock(previous: prev, timestamp: ts, nonce: UInt64(i))
            let header = try! VolumeImpl<Block>(node: block)
            let result = await chain.submitTestBlock(
                blockHeader: header,
                block: block
            )
            XCTAssertTrue(result.extendsCanonical, "Block \(i) should extend")
            prev = block
            ts += 1_000
        }

        let highest = await chain.getHighestBlockHeight()
        XCTAssertEqual(highest, 10)
    }

    func testBuiltForkTriggersReorg() async throws {
        let genesis = try await genesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        var mainPrev = genesis
        var ts: Int64 = 2_000_000
        for i in 1...3 {
            let block = try await nextBlock(previous: mainPrev, timestamp: ts, nonce: UInt64(i))
            let _ = await chain.submitTestBlock(
                blockHeader: try! VolumeImpl<Block>(node: block),
                block: block
            )
            mainPrev = block
            ts += 1_000
        }

        let tipBefore = await chain.canonicalTip
        let heightBefore = await chain.getHighestBlockHeight()
        XCTAssertEqual(heightBefore, 3)

        var forkPrev = genesis
        ts = 2_000_000
        var sawReorg = false
        for i in 1...5 {
            let block = try await nextBlock(previous: forkPrev, timestamp: ts, nonce: UInt64(100 + i))
            let result = await chain.submitTestBlock(
                blockHeader: try! VolumeImpl<Block>(node: block),
                block: block
            )
            if result.commit?.canonicalChanged == true { sawReorg = true }
            forkPrev = block
            ts += 1_000
        }

        XCTAssertTrue(sawReorg, "Longer fork should trigger reorg")
        let tipAfter = await chain.canonicalTip
        XCTAssertNotEqual(tipBefore, tipAfter)
        let heightAfter = await chain.getHighestBlockHeight()
        XCTAssertEqual(heightAfter, 5)
    }
}

// MARK: - Signature Verification Tests

@MainActor
final class SignatureVerificationTests: XCTestCase {

    func testValidSignatureVerifies() async {
        let keyPair = CryptoUtils.generateKeyPair()
        let message = "test_message_cid"
        let signature = CryptoUtils.sign(message: message, privateKeyHex: keyPair.privateKey)
        XCTAssertNotNil(signature)
        let valid = CryptoUtils.verify(message: message, signature: signature!, publicKeyHex: keyPair.publicKey)
        XCTAssertTrue(valid)
    }

    func testInvalidSignatureRejected() async {
        let keyPair = CryptoUtils.generateKeyPair()
        let message = "test_message_cid"
        let valid = CryptoUtils.verify(message: message, signature: "deadbeef", publicKeyHex: keyPair.publicKey)
        XCTAssertFalse(valid)
    }

    func testWrongKeyRejected() async {
        let keyPair1 = CryptoUtils.generateKeyPair()
        let keyPair2 = CryptoUtils.generateKeyPair()
        let message = "test_message_cid"
        let signature = CryptoUtils.sign(message: message, privateKeyHex: keyPair1.privateKey)!
        let valid = CryptoUtils.verify(message: message, signature: signature, publicKeyHex: keyPair2.publicKey)
        XCTAssertFalse(valid)
    }

    func testTamperedMessageRejected() async {
        let keyPair = CryptoUtils.generateKeyPair()
        let signature = CryptoUtils.sign(message: "original", privateKeyHex: keyPair.privateKey)!
        let valid = CryptoUtils.verify(message: "tampered", signature: signature, publicKeyHex: keyPair.publicKey)
        XCTAssertFalse(valid)
    }

    func testTransactionSignatureMatching() async {
        let keyPair = CryptoUtils.generateKeyPair()
        let publicKeyCID = try! HeaderImpl<PublicKey>(node: PublicKey(key: keyPair.publicKey)).rawCID

        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [publicKeyCID],
            nonce: 1,
            chainPath: ["Nexus"]
        )
        let tx = signedTransaction(body: body, privateKeyHex: keyPair.privateKey, publicKeyHex: keyPair.publicKey)
        XCTAssertTrue(tx.signaturesAreValid())
        XCTAssertTrue(tx.signaturesMatchSigners())
    }

    func testTransactionWrongSignerRejected() async {
        let keyPair1 = CryptoUtils.generateKeyPair()
        let keyPair2 = CryptoUtils.generateKeyPair()
        let wrongSignerCID = try! HeaderImpl<PublicKey>(node: PublicKey(key: keyPair2.publicKey)).rawCID

        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [wrongSignerCID],
            nonce: 1,
            chainPath: ["Nexus"]
        )
        let tx = signedTransaction(body: body, privateKeyHex: keyPair1.privateKey, publicKeyHex: keyPair1.publicKey)
        XCTAssertTrue(tx.signaturesAreValid(), "Signature itself is valid")
        XCTAssertFalse(tx.signaturesMatchSigners(), "But signer doesn't match")
    }
}

// MARK: - Transaction Nonce Scoping Tests

@MainActor
final class TransactionNonceScopingTests: XCTestCase {

    func testSameNonceDifferentSignersProduceDifferentKeys() async {
        let body1 = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [], signers: ["alice"], nonce: 42,
            chainPath: ["Nexus"]
        )
        let body2 = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [], signers: ["bob"], nonce: 42,
            chainPath: ["Nexus"]
        )

        let key1 = AccountStateHeader.nonceTrackingKey(body1.signers[0])
        let key2 = AccountStateHeader.nonceTrackingKey(body2.signers[0])
        XCTAssertNotEqual(key1, key2, "Different signers should track nonces under distinct keys")
    }

    func testSameSignerSameNonceProducesSameKey() async {
        let body1 = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [], signers: ["alice"], nonce: 42,
            chainPath: ["Nexus"]
        )
        let body2 = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [], signers: ["alice"], nonce: 42,
            chainPath: ["Nexus"]
        )

        let key1 = AccountStateHeader.nonceTrackingKey(body1.signers[0])
        let key2 = AccountStateHeader.nonceTrackingKey(body2.signers[0])
        XCTAssertEqual(key1, key2, "Same signer should share a nonce-tracking key")
    }

    func testMultipleSignersOrderIndependent() async {
        let body1 = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [], signers: ["alice", "bob"], nonce: 1,
            chainPath: ["Nexus"]
        )
        let body2 = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [], signers: ["bob", "alice"], nonce: 1,
            chainPath: ["Nexus"]
        )

        let keys1 = Set(body1.signers.map { AccountStateHeader.nonceTrackingKey($0) })
        let keys2 = Set(body2.signers.map { AccountStateHeader.nonceTrackingKey($0) })
        XCTAssertEqual(keys1, keys2, "Signer order should not affect the per-account nonce key set")
    }
}

// MARK: - Balance Validation Tests

@MainActor
final class BalanceValidationTests: XCTestCase {

    func testEmptyBlockBuildsCorrectState() async throws {
        let genesis = try await genesisBlock()
        XCTAssertEqual(genesis.prevState.rawCID, genesis.postState.rawCID,
            "Empty genesis should not change state")

        let block1 = try await nextBlock(previous: genesis, timestamp: 2_000_000)
        XCTAssertEqual(block1.prevState.rawCID, block1.postState.rawCID,
            "Empty block should not change state")
    }

    func testChainOfEmptyBlocksMaintainsStateInvariant() async throws {
        let genesis = try await genesisBlock()
        var prev = genesis
        var ts: Int64 = 2_000_000
        for _ in 1...5 {
            let block = try await nextBlock(previous: prev, timestamp: ts)
            XCTAssertEqual(block.prevState.rawCID, prev.postState.rawCID,
                "prevState must equal previous postState")
            XCTAssertEqual(block.prevState.rawCID, block.postState.rawCID,
                "Empty block should not change state")
            prev = block
            ts += 1_000
        }
    }
}

// MARK: - Key Parsing Safety Tests

@MainActor
final class KeyParsingSafetyTests: XCTestCase {

    func testSwapKeyRoundTrip() async {
        let original = DepositKey(depositAction: DepositAction(nonce: 42, demander: "demander1", amountDemanded: 1000, amountDeposited: 1000))
        let serialized = original.description
        let parsed = DepositKey(serialized)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.nonce, 42)
        XCTAssertEqual(parsed?.demander, "demander1")
        XCTAssertEqual(parsed?.amountDemanded, 1000)
    }

    func testSwapKeyMalformedReturnsNil() async {
        XCTAssertNil(DepositKey(""))
        XCTAssertNil(DepositKey("onlyone"))
        XCTAssertNil(DepositKey("two/parts"))
    }

    func testSettleKeyRoundTrip() async {
        let receiptAction = ReceiptAction(withdrawer: "w1", nonce: 99, demander: "d1", amountDemanded: 500, directory: "chain1")
        let original = ReceiptKey(receiptAction: receiptAction)
        let serialized = original.description
        let parsed = ReceiptKey(serialized)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.directory, "chain1")
        XCTAssertEqual(parsed?.demander, "d1")
        XCTAssertEqual(parsed?.amountDemanded, 500)
        XCTAssertEqual(parsed?.nonce, 99)
    }

    func testSettleKeyMalformedReturnsNil() async {
        XCTAssertNil(ReceiptKey(""))
        XCTAssertNil(ReceiptKey("nodirectory"))
        XCTAssertNil(ReceiptKey("dir/demander"))
        XCTAssertNil(ReceiptKey("dir/demander/notanumber"))
    }
}

// MARK: - Address and Hashing Tests

@MainActor
final class CryptoUtilsTests: XCTestCase {

    func testSha256IsDeterministic() async {
        let hash1 = CryptoUtils.sha256("hello")
        let hash2 = CryptoUtils.sha256("hello")
        XCTAssertEqual(hash1, hash2)
    }

    func testSha256ProducesNonEmptyOutput() async {
        let hash = CryptoUtils.sha256("hello")
        XCTAssertFalse(hash.isEmpty)
        XCTAssertNotEqual(hash, "hello")
    }

    func testCreateAddressIsDeterministic() async {
        let keyPair = CryptoUtils.generateKeyPair()
        let addr1 = CryptoUtils.createAddress(from: keyPair.publicKey)
        let addr2 = CryptoUtils.createAddress(from: keyPair.publicKey)
        XCTAssertEqual(addr1, addr2)
    }

    func testCreateAddressIsNonEmpty() async {
        let keyPair = CryptoUtils.generateKeyPair()
        let addr = CryptoUtils.createAddress(from: keyPair.publicKey)
        XCTAssertFalse(addr.isEmpty)
    }

    func testDifferentKeysDifferentAddresses() async {
        let kp1 = CryptoUtils.generateKeyPair()
        let kp2 = CryptoUtils.generateKeyPair()
        let addr1 = CryptoUtils.createAddress(from: kp1.publicKey)
        let addr2 = CryptoUtils.createAddress(from: kp2.publicKey)
        XCTAssertNotEqual(addr1, addr2)
    }

    func testKeyPairGeneration() async {
        let kp = CryptoUtils.generateKeyPair()
        XCTAssertFalse(kp.privateKey.isEmpty)
        XCTAssertFalse(kp.publicKey.isEmpty)
        XCTAssertNotEqual(kp.privateKey, kp.publicKey)
    }
}

// MARK: - Out-of-Order Submission Tests

@MainActor
final class OutOfOrderSubmissionTests: XCTestCase {

    func testMissingParentIsRequested() async throws {
        let genesis = try await genesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        let block1 = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 1)
        let block2 = try await nextBlock(previous: block1, timestamp: 3_000_000, nonce: 2)

        _ = await chain.submitTestBlock(
            blockHeader: try! VolumeImpl<Block>(node: block2),
            block: block2
        )
        let requirements = await chain.unresolvedSameChainPredecessors()
        XCTAssertEqual(
            requirements,
            [SameChainPredecessorRequirement(
                descendantCID: try VolumeImpl<Block>(node: block2).rawCID,
                predecessorCID: try VolumeImpl<Block>(node: block1).rawCID
            )]
        )
    }

    func testParentArrivalConnectsQueuedDescendant() async throws {
        let genesis = try await genesisBlock()
        let chain = ChainState.fromGenesis(block: genesis)

        let block1 = try await nextBlock(previous: genesis, timestamp: 2_000_000, nonce: 1)
        let block2 = try await nextBlock(previous: block1, timestamp: 3_000_000, nonce: 2)

        _ = await chain.submitTestBlock(
            blockHeader: try! VolumeImpl<Block>(node: block2),
            block: block2
        )
        let orphanRequirements = await chain.unresolvedSameChainPredecessors()
        XCTAssertEqual(orphanRequirements.count, 1)

        let _ = await chain.submitTestBlock(
            blockHeader: try! VolumeImpl<Block>(node: block1),
            block: block1
        )

        let tip = await chain.canonicalTip
        let remainingRequirements = await chain.unresolvedSameChainPredecessors()
        XCTAssertEqual(tip, try! VolumeImpl<Block>(node: block2).rawCID)
        XCTAssertTrue(remainingRequirements.isEmpty)
    }
}

// MARK: - WASM Policy Tests

@MainActor
final class WasmPolicyTests: XCTestCase {

    func testWasmPolicyExecutionProfileIsPinned() async throws {
        XCTAssertEqual(WasmPolicyEvaluator.executionFeatureSet, [.referenceTypes])
        XCTAssertFalse(WasmPolicyEvaluator.executionFeatureSet.contains(.memory64))
        XCTAssertFalse(WasmPolicyEvaluator.executionFeatureSet.contains(.threads))
        XCTAssertFalse(WasmPolicyEvaluator.executionFeatureSet.contains(.tailCall))

        let memory64Module = Data([
            0x00, 0x61, 0x73, 0x6d, // magic
            0x01, 0x00, 0x00, 0x00, // version
            0x05, 0x03,             // memory section, 3-byte payload
            0x01,                   // one memory
            0x04,                   // memory64 limits, no maximum
            0x01                    // min pages
        ])
        let policy = WasmPolicyRef(moduleCID: "memory64", scope: .transaction)

        XCTAssertThrowsError(try WasmPolicyEvaluator.validate(
            policy: policy,
            moduleBytes: memory64Module
        ))
    }

    func testTransactionPolicyAccepts() async throws {
        let fetcher = StorableFetcher()
        let policy = try await storeWasmPolicy(accepts: true, scope: .transaction, fetcher: fetcher)
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [], signers: [], nonce: 1,
            chainPath: ["Nexus"]
        )
        let spec = ChainSpec.test(
            halfLife: 10,
            wasmPolicies: [policy]
        )
        let accepted = try await TransactionBody.batchVerifyPolicies(bodies: [body], spec: spec, chainPath: ["Nexus"], height: 1, timestamp: 1, fetcher: fetcher)
        XCTAssertTrue(accepted)
    }

    func testTransactionPolicySeesBlockHeightAndTimestamp() async throws {
        let fetcher = StorableFetcher()
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [], signers: [], nonce: 1,
            chainPath: ["Nexus"]
        )
        let heightPolicy = try await storeWasmPolicy(
            contextFieldAt: wasmPolicyContextHeightOffset, atLeast: 5, fetcher: fetcher
        )
        let heightSpec = ChainSpec.test(halfLife: 10, wasmPolicies: [heightPolicy])
        let belowHeight = try await TransactionBody.batchVerifyPolicies(bodies: [body], spec: heightSpec, chainPath: ["Nexus"], height: 4, timestamp: 1, fetcher: fetcher)
        let atHeight = try await TransactionBody.batchVerifyPolicies(bodies: [body], spec: heightSpec, chainPath: ["Nexus"], height: 5, timestamp: 1, fetcher: fetcher)
        XCTAssertFalse(belowHeight)
        XCTAssertTrue(atHeight)

        let timePolicy = try await storeWasmPolicy(
            contextFieldAt: wasmPolicyContextTimestampOffset, atLeast: 1_000, fetcher: fetcher
        )
        let timeSpec = ChainSpec.test(halfLife: 10, wasmPolicies: [timePolicy])
        let beforeTime = try await TransactionBody.batchVerifyPolicies(bodies: [body], spec: timeSpec, chainPath: ["Nexus"], height: 1, timestamp: 999, fetcher: fetcher)
        let atTime = try await TransactionBody.batchVerifyPolicies(bodies: [body], spec: timeSpec, chainPath: ["Nexus"], height: 1, timestamp: 1_000, fetcher: fetcher)
        XCTAssertFalse(beforeTime)
        XCTAssertTrue(atTime)
    }

    func testTransactionPolicyRejects() async throws {
        let fetcher = StorableFetcher()
        let policy = try await storeWasmPolicy(accepts: false, scope: .transaction, fetcher: fetcher)
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [], signers: [], nonce: 1,
            chainPath: ["Nexus"]
        )
        let spec = ChainSpec.test(
            halfLife: 10,
            wasmPolicies: [policy]
        )
        let accepted = try await TransactionBody.batchVerifyPolicies(bodies: [body], spec: spec, chainPath: ["Nexus"], height: 1, timestamp: 1, fetcher: fetcher)
        XCTAssertFalse(accepted)
    }

    func testTransactionPolicyCanInspectContextBytes() async throws {
        let fetcher = StorableFetcher()
        let policy = try await storeWasmPolicy(requiringSubstring: "high-signer", scope: .transaction, fetcher: fetcher)
        let lowFee = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [], signers: ["low-signer"], nonce: 1,
            chainPath: ["Nexus"]
        )
        let highFee = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [], signers: ["high-signer"], nonce: 1,
            chainPath: ["Nexus"]
        )
        let spec = ChainSpec.test(
            halfLife: 10,
            wasmPolicies: [policy]
        )
        let lowAccepted = try await TransactionBody.batchVerifyPolicies(bodies: [lowFee], spec: spec, chainPath: ["Nexus"], height: 1, timestamp: 1, fetcher: fetcher)
        let highAccepted = try await TransactionBody.batchVerifyPolicies(bodies: [highFee], spec: spec, chainPath: ["Nexus"], height: 1, timestamp: 1, fetcher: fetcher)
        XCTAssertFalse(lowAccepted)
        XCTAssertTrue(highAccepted)
    }

    func testTransactionPolicyCanInspectChainPath() async throws {
        let fetcher = StorableFetcher()
        let policy = try await storeWasmPolicy(requiringSubstring: "policy-chain-sentinel", scope: .transaction, fetcher: fetcher)
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [], signers: [], nonce: 1,
            chainPath: ["Nexus"]
        )
        let spec = ChainSpec.test(
            halfLife: 10,
            wasmPolicies: [policy]
        )
        let acceptedOnMatchingPath = try await TransactionBody.batchVerifyPolicies(
            bodies: [body], spec: spec, chainPath: ["Nexus", "policy-chain-sentinel"], height: 1, timestamp: 1, fetcher: fetcher
        )
        let rejectedOnDifferentPath = try await TransactionBody.batchVerifyPolicies(
            bodies: [body], spec: spec, chainPath: ["Nexus", "other-chain"], height: 1, timestamp: 1, fetcher: fetcher
        )
        let rejectedOnRootRelativePath = try await TransactionBody.batchVerifyPolicies(
            bodies: [body], spec: spec, chainPath: ["policy-chain-sentinel"], height: 1, timestamp: 1, fetcher: fetcher
        )
        XCTAssertTrue(acceptedOnMatchingPath)
        XCTAssertFalse(rejectedOnDifferentPath)
        XCTAssertFalse(rejectedOnRootRelativePath)
    }

    func testMultiplePoliciesAreAllRequired() async throws {
        let fetcher = StorableFetcher()
        let acceptingPolicy = try await storeWasmPolicy(accepts: true, scope: .transaction, fetcher: fetcher)
        let rejectingPolicy = try await storeWasmPolicy(accepts: false, scope: .transaction, fetcher: fetcher)
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [], signers: [], nonce: 1,
            chainPath: ["Nexus"]
        )
        let spec = ChainSpec.test(
            halfLife: 10,
            wasmPolicies: [acceptingPolicy, rejectingPolicy]
        )
        let accepted = try await TransactionBody.batchVerifyPolicies(bodies: [body], spec: spec, chainPath: ["Nexus"], height: 1, timestamp: 1, fetcher: fetcher)
        XCTAssertFalse(accepted)
    }

    func testPolicyContextCanonicalEncodingGolden() async throws {
        let policy = WasmPolicyRef(moduleCID: "bafy-policy", scope: .transaction)
        let spec = ChainSpec.test(
            halfLife: 10,
            wasmPolicies: [policy]
        )
        let body = TransactionBody(
            accountActions: [],
            actions: [Action(key: "app/v1/data", oldValue: nil, newValue: "value")],
            depositActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: ["alice"],
            nonce: 9,
            chainPath: ["Nexus"]
        )
        let context = WasmPolicyContext(
            scope: .transaction,
            height: 7,
            timestamp: -1,
            chainSpec: spec,
            chainPath: ["Nexus"],
            transaction: body,
            action: nil,
            actionIndex: nil
        )
        let hex = try context.canonicalData().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "4c575043545800020001000000000000000007ffffffffffffffff00000100a9677072656d696e65006868616c664c6966650a6c6d6178426c6f636b53697a651a000f42406c7761736d506f6c696369657381a46573636f70656b7472616e73616374696f6e696d6f64756c654349446b626166792d706f6c6963796a61626956657273696f6e016a656e747279706f696e74781c6c6174746963655f76616c69646174655f7472616e73616374696f6e6d696e697469616c5265776172641904006e6d6178537461746547726f7774681a000186a06f68616c76696e67496e74657276616c1927106f746172676574426c6f636b54696d651903e8781f6d61784e756d6265724f665472616e73616374696f6e73506572426c6f636b186400000001000000054e657875730100000094a8656e6f6e63650967616374696f6e7381a2636b65796b6170702f76312f64617461686e657756616c75656576616c7565677369676e6572738165616c69636569636861696e5061746881654e657875736e6163636f756e74416374696f6e73806e6465706f736974416374696f6e73806e72656365697074416374696f6e7380717769746864726177616c416374696f6e73800000")

        let actionContext = WasmPolicyContext(
            scope: .action,
            height: 7,
            timestamp: -1,
            chainSpec: spec,
            chainPath: ["Nexus"],
            transaction: body,
            action: body.actions[0],
            actionIndex: 0
        )
        let actionHex = try actionContext.canonicalData().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(actionHex, "4c575043545800020001010000000000000007ffffffffffffffff00000100a9677072656d696e65006868616c664c6966650a6c6d6178426c6f636b53697a651a000f42406c7761736d506f6c696369657381a46573636f70656b7472616e73616374696f6e696d6f64756c654349446b626166792d706f6c6963796a61626956657273696f6e016a656e747279706f696e74781c6c6174746963655f76616c69646174655f7472616e73616374696f6e6d696e697469616c5265776172641904006e6d6178537461746547726f7774681a000186a06f68616c76696e67496e74657276616c1927106f746172676574426c6f636b54696d651903e8781f6d61784e756d6265724f665472616e73616374696f6e73506572426c6f636b186400000001000000054e657875730100000094a8656e6f6e63650967616374696f6e7381a2636b65796b6170702f76312f64617461686e657756616c75656576616c7565677369676e6572738165616c69636569636861696e5061746881654e657875736e6163636f756e74416374696f6e73806e6465706f736974416374696f6e73806e72656365697074416374696f6e7380717769746864726177616c416374696f6e73800100000020a2636b65796b6170702f76312f64617461686e657756616c75656576616c7565010000000000000000")
    }

    func testActionPolicyAccepts() async throws {
        let fetcher = StorableFetcher()
        let policy = try await storeWasmPolicy(accepts: true, scope: .action, fetcher: fetcher)
        let action = Action(key: "test/key", oldValue: nil, newValue: "hello")
        let body = TransactionBody(
            accountActions: [], actions: [action], depositActions: [],
            receiptActions: [], withdrawalActions: [], signers: [], nonce: 1,
            chainPath: ["Nexus"]
        )
        let spec = ChainSpec.test(
            halfLife: 10,
            wasmPolicies: [policy]
        )
        let accepted = try await TransactionBody.batchVerifyPolicies(bodies: [body], spec: spec, chainPath: ["Nexus"], height: 1, timestamp: 1, fetcher: fetcher)
        XCTAssertTrue(accepted)
    }

    func testActionPolicyCanInspectContextBytes() async throws {
        let fetcher = StorableFetcher()
        let policy = try await storeWasmPolicy(requiringSubstring: "app", scope: .action, fetcher: fetcher)
        let goodAction = Action(key: "app/v1/data", oldValue: nil, newValue: "value")
        let badAction = Action(key: "forbidden/data", oldValue: nil, newValue: "value")
        let spec = ChainSpec.test(
            halfLife: 10,
            wasmPolicies: [policy]
        )
        let goodBody = TransactionBody(accountActions: [], actions: [goodAction], depositActions: [], receiptActions: [], withdrawalActions: [], signers: [], nonce: 1, chainPath: ["Nexus"])
        let badBody = TransactionBody(accountActions: [], actions: [badAction], depositActions: [], receiptActions: [], withdrawalActions: [], signers: [], nonce: 1, chainPath: ["Nexus"])
        let goodAccepted = try await TransactionBody.batchVerifyPolicies(bodies: [goodBody], spec: spec, chainPath: ["Nexus"], height: 1, timestamp: 1, fetcher: fetcher)
        let badAccepted = try await TransactionBody.batchVerifyPolicies(bodies: [badBody], spec: spec, chainPath: ["Nexus"], height: 1, timestamp: 1, fetcher: fetcher)
        XCTAssertTrue(goodAccepted)
        XCTAssertFalse(badAccepted)
    }

    func testUnsupportedAbiRejects() async throws {
        let fetcher = StorableFetcher()
        let storedPolicy = try await storeWasmPolicy(accepts: true, scope: .transaction, fetcher: fetcher)
        let policy = WasmPolicyRef(
            moduleCID: storedPolicy.moduleCID,
            abiVersion: WasmPolicyRef.currentABIVersion + 1,
            scope: .transaction
        )
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [], signers: [], nonce: 1,
            chainPath: ["Nexus"]
        )
        let spec = ChainSpec.test(
            halfLife: 10,
            wasmPolicies: [policy]
        )
        let accepted = try await TransactionBody.batchVerifyPolicies(bodies: [body], spec: spec, chainPath: ["Nexus"], height: 1, timestamp: 1, fetcher: fetcher)
        XCTAssertFalse(accepted)

        XCTAssertThrowsError(try WasmPolicyEvaluator.validate(
            policy: policy,
            moduleBytes: try wasmPolicyFixture(accepts: true)
        )) { error in
            guard case WasmPolicyError.unsupportedABI(WasmPolicyRef.currentABIVersion + 1) = error else {
                XCTFail("Expected unsupported ABI rejection, got \(error)")
                return
            }
        }
    }

    func testCustomEntrypointAccepts() async throws {
        let fetcher = StorableFetcher()
        let wat = """
        (module
          (memory (export "memory") 1)
          (global $heap (mut i32) (i32.const 1024))
          (func (export "lattice_alloc") (param $len i32) (result i32)
            (local $ptr i32)
            global.get $heap
            local.set $ptr
            global.get $heap
            local.get $len
            i32.add
            global.set $heap
            local.get $ptr)
          (func (export "custom_policy_entrypoint") (param $ptr i32) (param $len i32) (result i32)
            i32.const 1)
        )
        """
        let module = try! WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: Data(try wat2wasm(wat))))
        try await module.storeRecursively(storer: fetcher)
        let policy = WasmPolicyRef(
            moduleCID: module.rawCID,
            scope: .transaction,
            entrypoint: "custom_policy_entrypoint"
        )
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [], signers: [], nonce: 1,
            chainPath: ["Nexus"]
        )
        let spec = ChainSpec.test(
            halfLife: 10,
            wasmPolicies: [policy]
        )
        let accepted = try await TransactionBody.batchVerifyPolicies(bodies: [body], spec: spec, chainPath: ["Nexus"], height: 1, timestamp: 1, fetcher: fetcher)
        XCTAssertTrue(accepted)
    }

    func testMissingPolicyModuleIsUnavailable() async throws {
        let fetcher = StorableFetcher()
        let policy = WasmPolicyRef(moduleCID: "missing", scope: .transaction)
        let spec = ChainSpec.test(
            halfLife: 10,
            wasmPolicies: [policy]
        )
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [], signers: [], nonce: 1,
            chainPath: ["Nexus"]
        )
        do {
            _ = try await TransactionBody.batchVerifyPolicies(
                bodies: [body],
                spec: spec,
                chainPath: ["Nexus"],
                height: 1, timestamp: 1,
                fetcher: fetcher
            )
            XCTFail("missing module bytes must remain retriable")
        } catch WasmPolicyError.missingModule("missing") {}
    }

    func testInvalidAllocatorRejectsWithoutWritingOutOfBounds() async throws {
        let wat = """
        (module
          (memory (export "memory") 1)
          (func (export "lattice_alloc") (param $len i32) (result i32)
            i32.const 70000)
          (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
            i32.const 1)
        )
        """
        let policy = WasmPolicyRef(moduleCID: "inline", scope: .transaction)
        XCTAssertThrowsError(try WasmPolicyEvaluator.evaluate(
            policy: policy,
            contextData: Data(#"{"fee":100}"#.utf8),
            moduleBytes: Data(try wat2wasm(wat))
        )) { error in
            XCTAssertTrue(error is WasmPolicyError)
        }
    }

    func testNegativeAllocatorPointerRejectsWithoutTrapping() async throws {
        let wat = """
        (module
          (memory (export "memory") 1)
          (func (export "lattice_alloc") (param $len i32) (result i32)
            i32.const -1)
          (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
            i32.const 1)
        )
        """
        let policy = WasmPolicyRef(moduleCID: "inline", scope: .transaction)
        XCTAssertThrowsError(try WasmPolicyEvaluator.evaluate(
            policy: policy,
            contextData: Data(#"{"fee":100}"#.utf8),
            moduleBytes: Data(try wat2wasm(wat))
        )) { error in
            guard case WasmPolicyError.invalidAllocation = error else {
                XCTFail("Expected invalidAllocation, got \(error)")
                return
            }
        }
    }

    func testAllocatorPointerDomainFailsClosedWithoutTrapping() async throws {
        struct AllocCase {
            let name: String
            let pointer: String
            let contextSize: Int
            let accepts: Bool
        }

        let pageBytes = 64 * 1024
        let cases = [
            AllocCase(name: "zero", pointer: "0", contextSize: 16, accepts: true),
            AllocCase(name: "last_valid_range", pointer: "\(pageBytes - 16)", contextSize: 16, accepts: true),
            AllocCase(name: "one_past_last_valid_range", pointer: "\(pageBytes - 15)", contextSize: 16, accepts: false),
            AllocCase(name: "end_of_memory_empty_context", pointer: "\(pageBytes)", contextSize: 0, accepts: true),
            AllocCase(name: "end_of_memory_nonempty_context", pointer: "\(pageBytes)", contextSize: 1, accepts: false),
            AllocCase(name: "negative_one", pointer: "-1", contextSize: 16, accepts: false),
            AllocCase(name: "int32_min", pointer: "-2147483648", contextSize: 16, accepts: false),
            AllocCase(name: "near_int32_max", pointer: "2147483640", contextSize: 16, accepts: false),
            AllocCase(name: "int32_max", pointer: "2147483647", contextSize: 16, accepts: false),
        ]
        let policy = WasmPolicyRef(moduleCID: "inline", scope: .transaction)

        for testCase in cases {
            let moduleBytes = try allocatorFixture(pointer: testCase.pointer, memoryPages: 1)
            let context = Data(repeating: 0x41, count: testCase.contextSize)

            if testCase.accepts {
                XCTAssertTrue(try WasmPolicyEvaluator.evaluate(
                    policy: policy,
                    contextData: context,
                    moduleBytes: moduleBytes
                ), testCase.name)
            } else {
                XCTAssertThrowsError(try WasmPolicyEvaluator.evaluate(
                    policy: policy,
                    contextData: context,
                    moduleBytes: moduleBytes
                ), testCase.name) { error in
                    guard case WasmPolicyError.invalidAllocation = error else {
                        XCTFail("Expected invalidAllocation for \(testCase.name), got \(error)")
                        return
                    }
                }
            }
        }
    }

    func testEmptyContextWithZeroPageMemoryDoesNotForceUnwrapBaseAddress() async throws {
        let policy = WasmPolicyRef(moduleCID: "inline", scope: .transaction)
        let moduleBytes = try allocatorFixture(pointer: "0", memoryPages: 0)

        XCTAssertTrue(try WasmPolicyEvaluator.evaluate(
            policy: policy,
            contextData: Data(),
            moduleBytes: moduleBytes
        ))
    }

    private func allocatorFixture(pointer: String, memoryPages: Int) throws -> Data {
        let wat = """
        (module
          (memory (export "memory") \(memoryPages))
          (func (export "lattice_alloc") (param $len i32) (result i32)
            i32.const \(pointer))
          (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
            i32.const 1)
        )
        """
        return Data(try wat2wasm(wat))
    }

    func testPolicyPreflightRejectsWrongEntrypointSignature() async throws {
        let wat = """
        (module
          (memory (export "memory") 1)
          (func (export "lattice_alloc") (param $len i32) (result i32)
            i32.const 1024)
          (func (export "lattice_validate_transaction") (param $ptr i32) (result i32)
            i32.const 1)
        )
        """
        let policy = WasmPolicyRef(moduleCID: "inline", scope: .transaction)
        XCTAssertThrowsError(try WasmPolicyEvaluator.validate(
            policy: policy,
            moduleBytes: Data(try wat2wasm(wat))
        )) { error in
            guard case WasmPolicyError.invalidFunctionSignature("lattice_validate_transaction") = error else {
                XCTFail("Expected invalid entrypoint signature, got \(error)")
                return
            }
        }
    }

    func testGenesisRejectsAPolicyWithAnInvalidFunctionBody() async throws {
        // The engine validates a function body only when it first runs, so a
        // defective body would otherwise surface on the first transaction to
        // reach it. Genesis validates every body, called or not.
        let bodies = [
            "the entrypoint": ("i64.const 1", ""),
            "a function nothing calls": ("i32.const 1", "(func (result i32) i64.const 1)"),
        ]
        for (name, (entrypointBody, extraFunction)) in bodies {
            let bytes = Data(try wat2wasm("""
            (module
              (memory (export "memory") 1)
              (func (export "lattice_alloc") (param i32) (result i32) i32.const 1024)
              (func (export "lattice_validate_transaction") (param i32 i32) (result i32)
                \(entrypointBody))
              \(extraFunction)
            )
            """))
            let fetcher = StorableFetcher()
            let module = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: bytes))
            try await module.storeRecursively(storer: fetcher)
            let policy = WasmPolicyRef(moduleCID: module.rawCID, scope: .transaction)
            let spec = ChainSpec.test(wasmPolicies: [policy])
            let genesis = try await buildAndStoreGenesis(
                spec: spec, timestamp: 1, target: UInt256.max, fetcher: fetcher
            )

            XCTAssertThrowsError(
                try WasmPolicyEvaluator.validate(policy: policy, moduleBytes: bytes), name
            )
            let configured = try await TransactionBody.validateConfiguredPolicyModules(
                spec: spec, fetcher: fetcher
            )
            XCTAssertFalse(configured, name)
            let genesisValid = try await genesis.validateGenesis(
                fetcher: fetcher, chainPath: [DEFAULT_ROOT_DIRECTORY]
            ).0
            XCTAssertFalse(genesisValid, name)
        }
    }

    func testPolicyDeclaringMemoryAboveTwoMiBInstantiatesAndEvaluates() async throws {
        // No node-local memory cap: 33 pages (2 MiB + 64 KiB) of declared
        // initial memory instantiates, and the policy's own result — it accepts
        // only if a byte stored above the 2 MiB mark reads back — is the verdict.
        let module = Data(try wat2wasm("""
        (module
          (memory (export "memory") 33)
          (func (export "lattice_alloc") (param $len i32) (result i32)
            i32.const 1024)
          (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
            i32.const 2100000
            i32.const 7
            i32.store8
            i32.const 2100000
            i32.load8_u
            i32.const 7
            i32.eq)
        )
        """))
        let policy = WasmPolicyRef(moduleCID: "inline", scope: .transaction)

        XCTAssertNoThrow(try WasmPolicyEvaluator.validate(policy: policy, moduleBytes: module))
        XCTAssertTrue(try WasmPolicyEvaluator.evaluate(
            policy: policy, contextData: Data(), moduleBytes: module))
    }

    func testPolicyModuleAboveSixteenMiBValidates() async throws {
        // No node-local module-size cap: a module padded past 16 MiB with a
        // custom section validates like the unpadded one.
        var module = Data(try wat2wasm("""
        (module
          (memory (export "memory") 1)
          (func (export "lattice_alloc") (param $len i32) (result i32) i32.const 1024)
          (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
            i32.const 1)
        )
        """))
        // Custom section: id 0, LEB128 size 0x1000001, one-byte name "p", padding.
        module.append(contentsOf: [0x00, 0x81, 0x80, 0x80, 0x08, 0x01, 0x70])
        module.append(Data(count: 16 * 1024 * 1024 - 1))
        let policy = WasmPolicyRef(moduleCID: "inline", scope: .transaction)

        XCTAssertNoThrow(try WasmPolicyEvaluator.validate(policy: policy, moduleBytes: module))
    }

    func testPolicyGrowingMemoryPastTwoMiBGetsItsOwnVerdict() async throws {
        // memory.grow has no node-local limit to be denied by, so growing from
        // 1 page to 41 (past the old 2 MiB cap) succeeds and the policy's own
        // return value is the verdict. `acceptOnSuccess` picks which outcome of
        // the grow the module accepts on, so a denied grow (-1) would flip both.
        func module(acceptOnSuccess: Bool) throws -> Data {
            Data(try wat2wasm("""
            (module
              (memory (export "memory") 1)
              (func (export "lattice_alloc") (param $len i32) (result i32) i32.const 1024)
              (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
                i32.const 40
                memory.grow
                i32.const 1
                i32.eq
                memory.size
                i32.const 41
                i32.eq
                i32.and
                i32.const \(acceptOnSuccess ? 1 : 0)
                i32.eq)
            )
            """))
        }
        let policy = WasmPolicyRef(moduleCID: "inline-grow", scope: .transaction)

        XCTAssertTrue(try WasmPolicyEvaluator.evaluate(
            policy: policy, contextData: Data(), moduleBytes: try module(acceptOnSuccess: true)))
        XCTAssertFalse(try WasmPolicyEvaluator.evaluate(
            policy: policy, contextData: Data(), moduleBytes: try module(acceptOnSuccess: false)))
    }

    func testPolicyMemoryGrowFailsOnlyAtTheModuleDeclaredMaximum() async throws {
        // The one bound left on growth is the module's own declared maximum:
        // part of the module, so every node sees the same -1.
        let module = Data(try wat2wasm("""
        (module
          (memory (export "memory") 1 2)
          (func (export "lattice_alloc") (param $len i32) (result i32) i32.const 1024)
          (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
            i32.const 2
            memory.grow
            i32.const -1
            i32.eq)
        )
        """))
        XCTAssertTrue(try WasmPolicyEvaluator.evaluate(
            policy: WasmPolicyRef(moduleCID: "inline-grow-max", scope: .transaction),
            contextData: Data(), moduleBytes: module))
    }

    func testPolicyMemoryGrowPastTheFormatCeilingFailsWithoutADeclaredMaximum() async throws {
        // No declared maximum: the bound is WebAssembly's 65,536 pages. The
        // check precedes any allocation, so the largest operand costs nothing
        // and every node answers -1.
        for pages in ["65536", "-1"] {
            let module = Data(try wat2wasm("""
            (module
              (memory (export "memory") 1)
              (func (export "lattice_alloc") (param $len i32) (result i32) i32.const 1024)
              (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
                i32.const \(pages)
                memory.grow
                i32.const -1
                i32.eq)
            )
            """))
            XCTAssertTrue(try WasmPolicyEvaluator.evaluate(
                policy: WasmPolicyRef(moduleCID: "inline-grow-ceiling-\(pages)", scope: .transaction),
                contextData: Data(), moduleBytes: module), "grow by \(pages) pages")
        }
    }

    // MARK: - compiled-module cache

    private func cacheTestSpec(policy: WasmPolicyRef) -> ChainSpec {
        ChainSpec.test(
            halfLife: 10,
            wasmPolicies: [policy]
        )
    }

    private func cacheTestContext(policy: WasmPolicyRef) -> WasmPolicyContext {
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [], signers: [], nonce: 1,
            chainPath: ["Nexus"]
        )
        return WasmPolicyContext(
            scope: .transaction,
            height: 1,
            timestamp: 1,
            chainSpec: cacheTestSpec(policy: policy),
            chainPath: ["Nexus"],
            transaction: body,
            action: nil,
            actionIndex: nil
        )
    }

    /// RED on cold parse-every-time code: the same module is parsed exactly once
    /// across N evaluations through the real `WasmPolicyEvaluator.evaluate` path.
    func test_compiledModuleCache_parsesOncePerModuleAcrossEvaluations() async throws {
        let cache = WasmPolicyEvaluator.moduleCache
        cache.removeAll()
        defer { cache.onParse = nil; cache.removeAll() }

        var parseCount = 0
        cache.onParse = { _ in parseCount += 1 }

        let fetcher = StorableFetcher()
        let policy = try await storeWasmPolicy(accepts: true, scope: .transaction, fetcher: fetcher)
        let context = cacheTestContext(policy: policy)

        for _ in 0..<4 {
            let verdict = try await WasmPolicyEvaluator.evaluate(policy: policy, context: context, fetcher: fetcher)
            XCTAssertTrue(verdict)
        }

        XCTAssertEqual(parseCount, 1, "module must be parsed exactly once across evaluations (cache hit on 2..N)")
    }

    /// A cache hit (warm) produces a byte-identical verdict to a cold parse.
    func test_cacheHitProducesIdenticalVerdict() async throws {
        let cache = WasmPolicyEvaluator.moduleCache
        defer { cache.onParse = nil; cache.removeAll() }

        for accepts in [true, false] {
            let fetcher = StorableFetcher()
            let policy = try await storeWasmPolicy(accepts: accepts, scope: .transaction, fetcher: fetcher)
            let context = cacheTestContext(policy: policy)

            cache.removeAll() // force a cold parse
            let cold = try await WasmPolicyEvaluator.evaluate(policy: policy, context: context, fetcher: fetcher)
            // second call is a guaranteed cache hit (warm)
            let warm = try await WasmPolicyEvaluator.evaluate(policy: policy, context: context, fetcher: fetcher)

            XCTAssertEqual(cold, accepts)
            XCTAssertEqual(cold, warm, "warm cache-hit verdict must equal cold-parse verdict")
        }
    }

    /// With the count bound shrunk via the test seam, inserting >bound distinct
    /// modules evicts the least-recently-used module, which is then re-parsed.
    func test_cacheEvictsLRUAtBound() async throws {
        let cache = WasmPolicyEvaluator.moduleCache
        cache.removeAll()
        cache.setMaxModuleCount(2)
        defer {
            cache.onParse = nil
            cache.removeAll()
            cache.setMaxModuleCount(WasmModuleCache.defaultMaxModuleCount)
        }

        var parsedKeys: [String] = []
        cache.onParse = { parsedKeys.append($0) }

        let fetcher = StorableFetcher()
        // Three distinct modules (distinct content ids via distinct sentinel substrings).
        let policyA = try await storeWasmPolicy(requiringSubstring: "module-a", scope: .transaction, fetcher: fetcher)
        let policyB = try await storeWasmPolicy(requiringSubstring: "module-b", scope: .transaction, fetcher: fetcher)
        let policyC = try await storeWasmPolicy(requiringSubstring: "module-c", scope: .transaction, fetcher: fetcher)
        let ctxA = cacheTestContext(policy: policyA)
        let ctxB = cacheTestContext(policy: policyB)
        let ctxC = cacheTestContext(policy: policyC)

        // Fill cache with A, B (bound = 2). A is now LRU.
        _ = try await WasmPolicyEvaluator.evaluate(policy: policyA, context: ctxA, fetcher: fetcher)
        _ = try await WasmPolicyEvaluator.evaluate(policy: policyB, context: ctxB, fetcher: fetcher)
        XCTAssertEqual(parsedKeys.count, 2)

        // Insert C → evicts A (LRU).
        _ = try await WasmPolicyEvaluator.evaluate(policy: policyC, context: ctxC, fetcher: fetcher)
        XCTAssertEqual(parsedKeys.count, 3)

        // B and C are warm (no re-parse).
        _ = try await WasmPolicyEvaluator.evaluate(policy: policyB, context: ctxB, fetcher: fetcher)
        _ = try await WasmPolicyEvaluator.evaluate(policy: policyC, context: ctxC, fetcher: fetcher)
        XCTAssertEqual(parsedKeys.count, 3, "B and C must be cache hits after C insertion")

        // A was evicted → re-parsed.
        _ = try await WasmPolicyEvaluator.evaluate(policy: policyA, context: ctxA, fetcher: fetcher)
        XCTAssertEqual(parsedKeys.count, 4, "evicted LRU module A must be re-parsed")
        XCTAssertEqual(parsedKeys.last, policyA.moduleCID)
    }
}
