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

// Edge cases of the deposit -> receipt -> withdrawal flow across parent forks,
// child forks, sibling child chains, and replays. Every block is real and is
// judged by `validateNexus` on the child's chain path.

private func signTx(
    body: TransactionBody,
    keypair: (privateKey: String, publicKey: String)
) -> Transaction {
    let bodyHeader = try! HeaderImpl<TransactionBody>(node: body)
    let sig = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: keypair.privateKey)!
    return Transaction(signatures: [keypair.publicKey: sig], body: bodyHeader)
}

private func addr(_ publicKey: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: publicKey)).rawCID
}

private func now() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

/// Shared fixture: Nexus genesis, one child genesis anchored on it, a child
/// block holding the deposit, and the parties.
private struct SwapFixture {
    let fetcher: StorableFetcher
    let t: Int64
    let demander: (privateKey: String, publicKey: String)
    let demanderAddr: String
    let withdrawer: (privateKey: String, publicKey: String)
    let withdrawerAddr: String
    let nonce: UInt128 = 4242
    let amount: UInt64 = 200
    let nexusGenesis: Block

    init() async throws {
        fetcher = StorableFetcher()
        t = now()
        demander = CryptoUtils.generateKeyPair()
        demanderAddr = addr(demander.publicKey)
        withdrawer = CryptoUtils.generateKeyPair()
        withdrawerAddr = addr(withdrawer.publicKey)
        nexusGenesis = try await buildAndStoreGenesis(
            spec: ChainSpec.test(),
            transactions: [AdmissionFixture.unsignedStateChangingGenesisTransaction(
                key: "edge-parent-state", chainPath: [DEFAULT_ROOT_DIRECTORY]
            )],
            timestamp: t - 100_000, target: .max, fetcher: fetcher
        )
    }

    var depositAction: DepositAction {
        DepositAction(nonce: nonce, demander: demanderAddr, amountDemanded: amount, amountDeposited: amount)
    }

    var withdrawalAction: WithdrawalAction {
        WithdrawalAction(withdrawer: withdrawerAddr, nonce: nonce, demander: demanderAddr,
                         amountDemanded: amount, amountWithdrawn: amount)
    }

    var depositKey: String {
        DepositKey(nonce: nonce, demander: demanderAddr, amountDemanded: amount).description
    }

    func childGenesis(_ directory: String, timestamp: Int64) async throws -> Block {
        let genesis = try await BlockBuilder.buildChildGenesis(
            spec: ChainSpec.test(), parentState: nexusGenesis.postState,
            timestamp: timestamp, target: .max, fetcher: fetcher
        )
        try await storeBuiltBlock(genesis, in: fetcher)
        let valid = try await genesis.validateGenesis(
            fetcher: fetcher, chainPath: [DEFAULT_ROOT_DIRECTORY, directory]
        ).0
        XCTAssertTrue(valid, "child genesis \(directory) must validate")
        return genesis
    }

    /// A child block in which the demander escrows the deposit.
    func depositBlock(on genesis: Block, directory: String, timestamp: Int64) async throws -> Block {
        let body = TransactionBody(
            accountActions: [AccountAction(owner: demanderAddr, delta: -Int64(amount))],
            actions: [], depositActions: [depositAction],
            receiptActions: [], withdrawalActions: [],
            signers: [demanderAddr], nonce: 0,
            chainPath: [DEFAULT_ROOT_DIRECTORY, directory]
        )
        let block = try await buildAndStoreBlock(
            previous: genesis, transactions: [signTx(body: body, keypair: demander)],
            timestamp: timestamp, target: .max,
            rewardRecipient: demanderAddr, fetcher: fetcher
        )
        let valid = try await block.validateNexus(
            fetcher: fetcher, chainPath: [DEFAULT_ROOT_DIRECTORY, directory]
        ).0
        XCTAssertTrue(valid, "deposit block on \(directory) must validate")
        return block
    }

    func receiptTx(directory: String, txNonce: UInt64) -> Transaction {
        let body = TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [
                ReceiptAction(withdrawer: withdrawerAddr, nonce: nonce, demander: demanderAddr,
                              amountDemanded: amount, directory: directory)
            ],
            withdrawalActions: [],
            signers: [withdrawerAddr], nonce: txNonce,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        return signTx(body: body, keypair: withdrawer)
    }

    /// A Nexus block carrying the receipt for `directory`.
    func receiptBlock(previous: Block, directory: String, timestamp: Int64, txNonce: UInt64 = 0) async throws -> Block {
        let block = try await buildAndStoreBlock(
            previous: previous, transactions: [receiptTx(directory: directory, txNonce: txNonce)],
            timestamp: timestamp, target: .max,
            rewardRecipient: withdrawerAddr, fetcher: fetcher
        )
        let valid = try await block.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid, "receipt block must validate")
        return block
    }

    func emptyNexusBlock(previous: Block, timestamp: Int64, nonce: UInt64 = 0) async throws -> Block {
        try await buildAndStoreBlock(
            previous: previous, timestamp: timestamp, target: .max, nonce: nonce, fetcher: fetcher
        )
    }

    func withdrawalTx(directory: String, txNonce: UInt64) -> Transaction {
        let body = TransactionBody(
            accountActions: [AccountAction(owner: withdrawerAddr, delta: Int64(amount))],
            actions: [], depositActions: [], receiptActions: [],
            withdrawalActions: [withdrawalAction],
            signers: [withdrawerAddr], nonce: txNonce,
            chainPath: [DEFAULT_ROOT_DIRECTORY, directory]
        )
        return signTx(body: body, keypair: withdrawer)
    }

    /// Builds a child withdrawal block anchored on `carrier` (so its
    /// parentState is `carrier.prevState`) and validates it. Returns the
    /// block on success, or the error the builder or validator raised
    /// (`ValidationReturnedFalse` when validation returned false).
    func withdrawal(
        previous: Block, carrier: Block, directory: String, timestamp: Int64, txNonce: UInt64 = 0
    ) async -> Result<Block, Error> {
        do {
            let block = try await buildAndStoreBlock(
                previous: previous, transactions: [withdrawalTx(directory: directory, txNonce: txNonce)],
                parentChainBlock: carrier,
                timestamp: timestamp, target: .max,
                rewardRecipient: withdrawerAddr, fetcher: fetcher
            )
            XCTAssertEqual(block.parentState.rawCID, carrier.prevState.rawCID,
                           "fixture: child parentState must be the carrier's entering state")
            let valid = try await block.validateNexus(
                fetcher: fetcher, chainPath: [DEFAULT_ROOT_DIRECTORY, directory]
            ).0
            return valid ? .success(block) : .failure(ValidationReturnedFalse())
        } catch {
            return .failure(error)
        }
    }
}

private struct ValidationReturnedFalse: Error {}

/// The receipt existence proof failed: the parent state holds no receipt
/// under this withdrawal's (directory-bound) key.
private func assertMissingReceipt(
    _ result: Result<Block, Error>, _ message: String, file: StaticString = #filePath, line: UInt = #line
) {
    guard case .failure(let error) = result else {
        return XCTFail("expected rejection: \(message)", file: file, line: line)
    }
    guard case ProofErrors.invalidProofType(let reason) = error,
          reason.contains("mutation proof on non-existent") else {
        return XCTFail("expected missing-receipt proof failure, got \(error): \(message)", file: file, line: line)
    }
}

/// The deposit spend failed: the deposit key holds `SPENT_DEPOSIT_MARKER`
/// in `spentIn`'s state, so the stored amount no longer matches.
private func assertSpentDeposit(
    _ result: Result<Block, Error>, spentIn: Block, depositKey: String, _ message: String,
    file: StaticString = #filePath, line: UInt = #line
) {
    let marker: UInt64? = try? spentIn.postState.node?.depositState.node?.get(key: depositKey)
    XCTAssertEqual(marker, SPENT_DEPOSIT_MARKER, "fixture: deposit must be spent", file: file, line: line)
    guard case .failure(let error) = result else {
        return XCTFail("expected rejection: \(message)", file: file, line: line)
    }
    guard case StateErrors.conflictingActions = error else {
        return XCTFail("expected spent-deposit rejection, got \(error): \(message)", file: file, line: line)
    }
}

@MainActor
final class CrossChainReorgReplayEdgeTests: XCTestCase {

    // MARK: 1a / 1b — parent forks

    /// Parent fork L carries the receipt; sibling fork R (longer, heavier,
    /// canonical) does not. A child withdrawal anchored on L still validates:
    /// child parentState anchors need only continuity and are
    /// canonicity-independent by design. Anchored on R it is rejected: R's
    /// state holds no receipt.
    func testWithdrawalAnchoredOnNonCanonicalParentForkStillValidates() async throws {
        let f = try await SwapFixture()
        let childGenesis = try await f.childGenesis("Child", timestamp: f.t - 90_000)
        let deposit = try await f.depositBlock(on: childGenesis, directory: "Child", timestamp: f.t - 80_000)

        // L: receipt at height 1, carrier at height 2.
        let l1 = try await f.receiptBlock(previous: f.nexusGenesis, directory: "Child", timestamp: f.t - 70_000)
        let lCarrier = try await f.emptyNexusBlock(previous: l1, timestamp: f.t - 60_000)
        // R: three empty blocks — strictly more work than L at equal target.
        let r1 = try await f.emptyNexusBlock(previous: f.nexusGenesis, timestamp: f.t - 70_000, nonce: 11)
        let r2 = try await f.emptyNexusBlock(previous: r1, timestamp: f.t - 60_000, nonce: 12)
        let r3 = try await f.emptyNexusBlock(previous: r2, timestamp: f.t - 50_000, nonce: 13)
        XCTAssertNotEqual(r1.postState.rawCID, l1.postState.rawCID, "fixture: L and R must diverge")
        // Fork choice over both branches picks R: L is non-canonical.
        let chain = ChainState.fromGenesis(block: f.nexusGenesis)
        for block in [l1, lCarrier, r1, r2, r3] {
            _ = await chain.submitTestBlock(blockHeader: try BlockHeader(node: block), block: block)
        }
        let r3CID = try BlockHeader(node: r3).rawCID
        let tip = await chain.canonicalTip
        XCTAssertEqual(tip, r3CID, "fixture: R must be canonical")
        let canonical = await chain.canonicalHashes
        XCTAssertFalse(canonical.contains(try BlockHeader(node: lCarrier).rawCID),
                       "fixture: L must be non-canonical")

        let onL = await f.withdrawal(previous: deposit, carrier: lCarrier, directory: "Child", timestamp: f.t - 40_000)
        XCTAssertNoThrow(try onL.get(), "a withdrawal anchored on a real, non-canonical parent state must validate")

        let onR = await f.withdrawal(previous: deposit, carrier: r3, directory: "Child", timestamp: f.t - 40_000)
        assertMissingReceipt(onR, "R's state holds no receipt, so a withdrawal anchored there must be rejected")
    }

    /// The receipt exists only on non-canonical fork L, yet the child keeps
    /// the payout: a withdrawal anchored on L validates, and the next child
    /// block — carried by canonical R's tip, as an honest miner would build
    /// it — extends it and validates too. Consensus never ties a withdrawal
    /// to parent canonicity, so the cost of settling an unpaid deposit is
    /// one stale parent block; any defense is miner policy above this layer.
    func testChildExtendsWithdrawalWhoseReceiptIsOnlyOnStaleParentFork() async throws {
        let f = try await SwapFixture()
        let childGenesis = try await f.childGenesis("Child", timestamp: f.t - 90_000)
        let deposit = try await f.depositBlock(on: childGenesis, directory: "Child", timestamp: f.t - 80_000)

        let l1 = try await f.receiptBlock(previous: f.nexusGenesis, directory: "Child", timestamp: f.t - 70_000)
        let lCarrier = try await f.emptyNexusBlock(previous: l1, timestamp: f.t - 60_000)
        let r1 = try await f.emptyNexusBlock(previous: f.nexusGenesis, timestamp: f.t - 70_000, nonce: 11)
        let r2 = try await f.emptyNexusBlock(previous: r1, timestamp: f.t - 60_000, nonce: 12)
        let r3 = try await f.emptyNexusBlock(previous: r2, timestamp: f.t - 50_000, nonce: 13)
        let chain = ChainState.fromGenesis(block: f.nexusGenesis)
        for block in [l1, lCarrier, r1, r2, r3] {
            _ = await chain.submitTestBlock(blockHeader: try BlockHeader(node: block), block: block)
        }
        let tip = await chain.canonicalTip
        XCTAssertEqual(tip, try BlockHeader(node: r3).rawCID, "fixture: R must be canonical")

        let withdrawn = try await f.withdrawal(
            previous: deposit, carrier: lCarrier, directory: "Child", timestamp: f.t - 40_000
        ).get()

        let honest = try await buildAndStoreBlock(
            previous: withdrawn, parentChainBlock: r3,
            timestamp: f.t - 30_000, target: .max, fetcher: f.fetcher
        )
        XCTAssertEqual(honest.parentState.rawCID, r3.prevState.rawCID,
                       "fixture: the honest block anchors on the canonical parent")
        let valid = try await honest.validateNexus(
            fetcher: f.fetcher, chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"]
        ).0
        XCTAssertTrue(valid, "a canonically carried child block may extend a stale-anchored withdrawal")
    }

    /// After the withdrawal executed on the child (anchored on L), a later
    /// child block anchoring on R tries it again: rejected, and the deposit
    /// stays spent. The same replay anchored on L (receipt present) is
    /// rejected too, isolating the spent-deposit ground.
    func testWithdrawalReplayAfterParentReorgRejected() async throws {
        let f = try await SwapFixture()
        let childGenesis = try await f.childGenesis("Child", timestamp: f.t - 90_000)
        let deposit = try await f.depositBlock(on: childGenesis, directory: "Child", timestamp: f.t - 80_000)

        let l1 = try await f.receiptBlock(previous: f.nexusGenesis, directory: "Child", timestamp: f.t - 70_000)
        let lCarrier = try await f.emptyNexusBlock(previous: l1, timestamp: f.t - 60_000)
        let lCarrier2 = try await f.emptyNexusBlock(previous: lCarrier, timestamp: f.t - 50_000)
        let r1 = try await f.emptyNexusBlock(previous: f.nexusGenesis, timestamp: f.t - 70_000, nonce: 11)
        let r2 = try await f.emptyNexusBlock(previous: r1, timestamp: f.t - 60_000, nonce: 12)
        let r3 = try await f.emptyNexusBlock(previous: r2, timestamp: f.t - 50_000, nonce: 13)

        let withdrawn = await f.withdrawal(previous: deposit, carrier: lCarrier, directory: "Child", timestamp: f.t - 40_000)
        let spentBlock = try withdrawn.get() // the first withdrawal must validate

        let replayOnR = await f.withdrawal(
            previous: spentBlock, carrier: r3, directory: "Child", timestamp: f.t - 30_000, txNonce: 1
        )
        assertSpentDeposit(replayOnR, spentIn: spentBlock, depositKey: f.depositKey, "a replay anchored on the reorged-to parent fork must be rejected")

        let replayOnL = await f.withdrawal(
            previous: spentBlock, carrier: lCarrier2, directory: "Child", timestamp: f.t - 30_000, txNonce: 1
        )
        assertSpentDeposit(replayOnL, spentIn: spentBlock, depositKey: f.depositKey, "a replay with the receipt still visible must be rejected: the deposit is spent")
    }

    // MARK: 2a — receipt insert-only

    /// The same receipt key inserted again in a later parent block on the same
    /// chain is rejected: receipts are insert-only.
    func testDuplicateReceiptInLaterParentBlockRejected() async throws {
        let f = try await SwapFixture()
        let n1 = try await f.receiptBlock(previous: f.nexusGenesis, directory: "Child", timestamp: f.t - 70_000)

        var rejected = false
        do {
            let n2 = try await buildAndStoreBlock(
                previous: n1, transactions: [f.receiptTx(directory: "Child", txNonce: 1)],
                timestamp: f.t - 60_000, target: .max,
                rewardRecipient: f.withdrawerAddr, fetcher: f.fetcher
            )
            rejected = try await !n2.validateNexus(fetcher: f.fetcher).0
        } catch let error as ProofErrors {
            // Builder refuses: the insertion proof finds the key already set.
            guard case .invalidProofType(let reason) = error,
                  reason.contains("insertion proof on existing value") else {
                throw error
            }
            rejected = true
        }
        XCTAssertTrue(rejected, "re-inserting an existing receipt key must be rejected")
    }

    // MARK: 2b — directory binding

    /// Two child chains with identical deposits; the parent holds a receipt
    /// only for "ChildA". The withdrawal on ChildB fails the receipt lookup,
    /// the withdrawal on ChildA succeeds.
    func testReceiptForOneChildCannotSettleSiblingChildDeposit() async throws {
        let f = try await SwapFixture()
        let genesisA = try await f.childGenesis("ChildA", timestamp: f.t - 90_000)
        let genesisB = try await f.childGenesis("ChildB", timestamp: f.t - 89_000)
        let depositA = try await f.depositBlock(on: genesisA, directory: "ChildA", timestamp: f.t - 80_000)
        let depositB = try await f.depositBlock(on: genesisB, directory: "ChildB", timestamp: f.t - 79_000)

        let n1 = try await f.receiptBlock(previous: f.nexusGenesis, directory: "ChildA", timestamp: f.t - 70_000)
        let carrier = try await f.emptyNexusBlock(previous: n1, timestamp: f.t - 60_000)

        let onB = await f.withdrawal(previous: depositB, carrier: carrier, directory: "ChildB", timestamp: f.t - 50_000)
        assertMissingReceipt(onB, "a receipt for ChildA must not settle ChildB's identical deposit")

        let onA = await f.withdrawal(previous: depositA, carrier: carrier, directory: "ChildA", timestamp: f.t - 50_000)
        XCTAssertNoThrow(try onA.get(), "the receipt must settle ChildA's deposit")
    }

    // MARK: 2c — child sibling forks

    /// Child sibling forks X and Y each withdraw the same deposit: each is
    /// valid on its own branch (deposit state is per-branch). Within one
    /// branch a second withdrawal is rejected.
    func testChildSiblingForksEachWithdrawOnceOnTheirOwnBranch() async throws {
        let f = try await SwapFixture()
        let childGenesis = try await f.childGenesis("Child", timestamp: f.t - 90_000)
        let deposit = try await f.depositBlock(on: childGenesis, directory: "Child", timestamp: f.t - 80_000)
        let n1 = try await f.receiptBlock(previous: f.nexusGenesis, directory: "Child", timestamp: f.t - 70_000)
        let carrier = try await f.emptyNexusBlock(previous: n1, timestamp: f.t - 60_000)
        let carrier2 = try await f.emptyNexusBlock(previous: carrier, timestamp: f.t - 50_000)

        let x = await f.withdrawal(previous: deposit, carrier: carrier, directory: "Child", timestamp: f.t - 40_000)
        let y = await f.withdrawal(previous: deposit, carrier: carrier, directory: "Child", timestamp: f.t - 39_000)
        let xBlock = try x.get() // fork X's withdrawal must validate on its branch
        let yBlock = try y.get() // fork Y's withdrawal must validate on its branch
        XCTAssertNotEqual(try BlockHeader(node: xBlock).rawCID, try BlockHeader(node: yBlock).rawCID,
                          "fixture: X and Y must be distinct siblings")

        let againOnX = await f.withdrawal(
            previous: xBlock, carrier: carrier2, directory: "Child", timestamp: f.t - 30_000, txNonce: 1
        )
        assertSpentDeposit(againOnX, spentIn: xBlock, depositKey: f.depositKey, "a second withdrawal within branch X must be rejected")
        let againOnY = await f.withdrawal(
            previous: yBlock, carrier: carrier2, directory: "Child", timestamp: f.t - 30_000, txNonce: 1
        )
        assertSpentDeposit(againOnY, spentIn: yBlock, depositKey: f.depositKey, "a second withdrawal within branch Y must be rejected")
    }
}
