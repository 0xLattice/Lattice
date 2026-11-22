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

private func makeFetcher() -> StorableFetcher {
    StorableFetcher()
}

private func lifecycleSpec(_ dir: String = "Nexus") -> ChainSpec {
    ChainSpec.test(premine: 1000)
}

private func noPremine(_ dir: String = "Nexus") -> ChainSpec {
    ChainSpec.test()
}

private func signTransaction(
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

// MARK: - Block Minting Tests

@MainActor
final class BlockMintingTests: XCTestCase {

    func testMintGenesisWithPremine() async throws {
        let fetcher = makeFetcher()
        let kp = CryptoUtils.generateKeyPair()
        let owner = addr(kp.publicKey)
        let spec = lifecycleSpec()
        let premineAmount = spec.premineAmount()

        let body = TransactionBody(
            accountActions: [AccountAction(owner: owner, delta: Int64(premineAmount))],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [], signers: [], nonce: 0,
            chainPath: ["Nexus"]
        )
        let tx = Transaction(
            signatures: [:],
            body: try HeaderImpl<TransactionBody>(node: body)
        )

        let genesis = try await buildAndStoreGenesis(
            spec: spec, transactions: [tx], timestamp: now() - 10_000,
            target: UInt256.max, fetcher: fetcher
        )

        XCTAssertEqual(genesis.height, 0)
        XCTAssertNil(genesis.parent)
        let emptyState = try! LatticeStateHeader(node: LatticeState.emptyState())
        XCTAssertEqual(genesis.prevState.rawCID, emptyState.rawCID)
        XCTAssertNotEqual(genesis.postState.rawCID, genesis.prevState.rawCID)

        let valid = try await genesis.validateGenesis(
            fetcher: fetcher,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        ).0
        XCTAssertTrue(valid)
    }

    func testGenesisValidationRequiresAnAbsoluteNexusPath() async throws {
        let fetcher = makeFetcher()
        // A child genesis commits a real parent state (§5.1 rule 4).
        let genesis = try await storeBuiltBlock(try await BlockBuilder.buildChildGenesis(
            spec: noPremine("Payments"),
            parentState: LatticeStateHeader(rawCID: testCID("payments-parent-state")),
            timestamp: now() - 10_000,
            target: UInt256.max,
            fetcher: fetcher
        ), in: fetcher)

        let rootRelative = try await genesis.validateGenesis(
            fetcher: fetcher,
            chainPath: ["Payments"]
        ).0
        let absolute = try await genesis.validateGenesis(
            fetcher: fetcher,
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Payments"]
        ).0

        XCTAssertFalse(rootRelative)
        XCTAssertTrue(absolute)
    }

    func testNexusValidationRequiresAnAbsoluteNexusPath() async throws {
        let fetcher = makeFetcher()
        let timestamp = now() - 20_000
        let genesis = try await buildAndStoreGenesis(
            spec: noPremine("Payments"),
            timestamp: timestamp,
            target: UInt256.max,
            fetcher: fetcher
        )
        let block = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: timestamp + 1_000,
            target: UInt256.max,
            fetcher: fetcher
        )

        let rootRelative = try await block.validateNexus(
            fetcher: fetcher,
            chainPath: ["Payments"]
        ).0
        let absolute = try await block.validateNexus(
            fetcher: fetcher,
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Payments"]
        ).0

        XCTAssertFalse(rootRelative)
        XCTAssertTrue(absolute)
    }

    func testAdmissionEmitsBlockAndWorkFactsOnceAndReturnsCommit() async throws {
        let fetcher = makeFetcher()
        let base = now() - 100_000
        let spec = noPremine()
        let genesis = try await buildAndStoreGenesis(
            spec: spec,
            timestamp: base,
            target: UInt256.max,
            fetcher: fetcher
        )
        let miner = CryptoUtils.generateKeyPair()
        let owner = addr(miner.publicKey)
        let built1 = try await BlockBuilder.buildBlockWithTransition(
            previous: genesis,
            timestamp: base + 1_000,
            target: UInt256.max,
            rewardRecipient: owner,
            fetcher: fetcher
        )
        let block1 = try await storeBuiltBlock(built1, in: fetcher)
        var chain = try AdmissionFixture.makeChain(genesis: genesis, spec: spec)

        // The header weighs the block and moves the tip; its execution then
        // records the transition.
        let weighed = try await chain.admit(try BlockHeader(node: block1), mode: .header, fetcher: fetcher)
        guard let commit = weighed.update?.commit else {
            return XCTFail("first block should be weighed and selected")
        }
        XCTAssertTrue(commit.canonicalChanged)
        let first = try await chain.admit(try BlockHeader(node: block1), mode: .execution, fetcher: fetcher)
        guard let acceptance = first.update, !acceptance.excluded else {
            return XCTFail("first block should be executed")
        }
        XCTAssertEqual(chain.canonicalTip, try BlockHeader(node: block1).rawCID)

        let block1Hash = try BlockHeader(node: block1).rawCID
        let live = try XCTUnwrap(chain.getConsensusBlock(hash: block1Hash))
        XCTAssertEqual(live.workContributions.count, 1)

        XCTAssertEqual(acceptance.batches.count, 1)
        // block + work + validation, atomically: execution is recorded with
        // the block it executed.
        let facts = try XCTUnwrap(acceptance.batches.first).facts
        XCTAssertEqual(facts.count, 3)
        XCTAssertEqual(Set(facts.map(\.id)).count, 3)
        guard case .block(let blockFact) = facts[0],
              case .work(let workFact) = facts[1],
              case .validation(let validationFact) = facts[2] else {
            return XCTFail("execution should emit block, work then validation facts in one batch")
        }
        XCTAssertEqual(validationFact.blockHash, block1Hash)
        // The diff is an execution output, not part of the block fact.
        XCTAssertEqual(acceptance.stateDiff, built1.stateDiff)
        XCTAssertEqual(blockFact.blockHash, block1Hash)
        XCTAssertEqual(workFact.blockHash, block1Hash)

        let duplicate = try await chain.admit(try BlockHeader(node: block1), fetcher: fetcher)
        guard case .duplicate = duplicate else {
            return XCTFail("duplicate contribution should not replay admission facts")
        }
        XCTAssertEqual(chain.getConsensusBlock(hash: block1Hash)?.workContributions.count, 1)
    }

    func test_validateGenesis_usesSameTimestampRuleAsBlocks() async throws {
        let fetcher = makeFetcher()
        let base = now()
        let context = ValidationContext(nowMilliseconds: base)

        // A genesis at or before the node's clock validates — no future drift
        // tolerance, the same `timestamp ≤ now` rule non-genesis blocks use.
        let present = try await buildAndStoreGenesis(
            spec: noPremine(),
            timestamp: base,
            target: UInt256(1000),
            fetcher: fetcher
        )
        let presentValid = try await present.validateGenesis(
            fetcher: fetcher,
            chainPath: [DEFAULT_ROOT_DIRECTORY],
            validationContext: context
        ).0
        XCTAssertTrue(presentValid, "a genesis at or before the node's clock validates")

        // A genesis from the node's future does not.
        let future = try await buildAndStoreGenesis(
            spec: noPremine(),
            timestamp: base + 3_600_000,
            target: UInt256(1000),
            fetcher: fetcher
        )
        let futureValid = try await future.validateGenesis(
            fetcher: fetcher,
            chainPath: [DEFAULT_ROOT_DIRECTORY],
            validationContext: context
        ).0
        XCTAssertFalse(futureValid, "a genesis from the node's future must not validate")
    }

    func test_validateGenesis_canReportFutureBlockAsNotYetAdmissible() async throws {
        let fetcher = makeFetcher()
        let context = ValidationContext(nowMilliseconds: now())
        let futureGenesis = try await buildAndStoreGenesis(
            spec: noPremine(),
            timestamp: context.nowMilliseconds + 3 * 3_600_000,
            target: UInt256(1000),
            fetcher: fetcher
        )

        do {
            _ = try await futureGenesis.validateGenesis(
                fetcher: fetcher,
                chainPath: [DEFAULT_ROOT_DIRECTORY],
                reportTemporalFailure: true,
                validationContext: context
            )
            XCTFail("a future block must report temporary inadmissibility")
        } catch let error as BlockValidationError {
            XCTAssertEqual(error, .notYetValid)
        }
    }

    func testMintBlockOnTopOfGenesis() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let genesis = try await buildAndStoreGenesis(
            spec: noPremine(), timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )

        let block1 = try await buildAndStoreBlock(
            previous: genesis, timestamp: t - 10_000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        XCTAssertEqual(block1.height, 1)
        XCTAssertNotNil(block1.parent)
        XCTAssertEqual(block1.prevState.rawCID, genesis.postState.rawCID)
    }

    func testMintChainOfBlocks() async throws {
        let fetcher = makeFetcher()
        let t = now()
        var prev = try await buildAndStoreGenesis(
            spec: noPremine(), timestamp: t - 100_000, target: UInt256(1000), fetcher: fetcher
        )

        for i in 1...10 {
            let block = try await buildAndStoreBlock(
                previous: prev, timestamp: t - 100_000 + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            XCTAssertEqual(block.height, UInt64(i))
            XCTAssertEqual(block.prevState.rawCID, prev.postState.rawCID)
            prev = block
        }
    }

    func testMintBlockWithTransferTransaction() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let sender = CryptoUtils.generateKeyPair()
        let receiver = CryptoUtils.generateKeyPair()
        let senderAddr = addr(sender.publicKey)
        let receiverAddr = addr(receiver.publicKey)
        let spec = lifecycleSpec()
        let premineAmount = spec.premineAmount()

        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: senderAddr, delta: Int64(premineAmount))],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [], signers: [senderAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let genesis = try await buildAndStoreGenesis(
            spec: spec, transactions: [signTransaction(body: premineBody, keypair: sender)],
            timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )

        let transferAmount: UInt64 = 500
        let transferBody = TransactionBody(
            accountActions: [
                AccountAction(owner: senderAddr, delta: Int64(premineAmount - transferAmount) - Int64(premineAmount)),
                AccountAction(owner: receiverAddr, delta: Int64(transferAmount))
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [senderAddr], nonce: 1, chainPath: ["Nexus"]
        )
        let block1 = try await buildAndStoreBlock(
            previous: genesis, transactions: [signTransaction(body: transferBody, keypair: sender)],
            timestamp: t - 10_000, target: UInt256(1000), nonce: 1,
            rewardRecipient: receiverAddr, fetcher: fetcher
        )

        XCTAssertEqual(block1.height, 1)
        XCTAssertNotEqual(block1.postState.rawCID, block1.prevState.rawCID)
        let valid = try await block1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid)
    }

    func testMintBlockRewardAccountingIsCorrect() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let miner = CryptoUtils.generateKeyPair()
        let minerAddr = addr(miner.publicKey)
        let spec = noPremine()

        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )

        let block1 = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: t - 10_000, target: UInt256(1000), nonce: 1,
            rewardRecipient: minerAddr, fetcher: fetcher
        )

        let (valid, _, postState) = try await block1.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid)
        let minerBalance: UInt64? = try postState?.accountState.node?.get(key: minerAddr)
        XCTAssertEqual(minerBalance, spec.rewardAtBlock(1))
    }

    func testMintBlockOverclaimRewardFails() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let miner = CryptoUtils.generateKeyPair()
        let minerAddr = addr(miner.publicKey)
        let spec = noPremine()

        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )

        let reward = spec.rewardAtBlock(0)
        let overclaimBody = TransactionBody(
            accountActions: [AccountAction(owner: minerAddr, delta: Int64(reward + 1))],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [minerAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let block1 = try await buildAndStoreBlock(
            previous: genesis, transactions: [signTransaction(body: overclaimBody, keypair: miner)],
            timestamp: t - 10_000, target: UInt256(1000), nonce: 1,
            allowFeeRuleViolation: true, fetcher: fetcher
        )

        let valid = try await block1.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid)
    }

    func testMineBlockFindValidNonce() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let genesis = try await buildAndStoreGenesis(
            spec: noPremine(), timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )

        let block1 = try await buildAndStoreBlock(
            previous: genesis, timestamp: t - 10_000, target: UInt256(1000), nonce: 0, fetcher: fetcher
        )

        let mined = BlockBuilder.mine(block: block1, target: UInt256.max, maxAttempts: 100)
        XCTAssertNotNil(mined)
    }

    func testMintAndSubmitToChainTree() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let genesis = try await buildAndStoreGenesis(
            spec: noPremine(), timestamp: t - 100_000, target: UInt256(1000), fetcher: fetcher
        )
        var chain = ChainTree.fromGenesis(block: genesis)

        var prev = genesis
        for i in 1...5 {
            let block = try await buildAndStoreBlock(
                previous: prev, timestamp: t - 100_000 + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            let result = chain.submitTestBlock(
                blockHeader: try! VolumeImpl<Block>(node: block), block: block
            )
            XCTAssertTrue(result.extendsCanonical, "Block \(i) should extend main chain")
            prev = block
        }

        let height = chain.getHighestBlockHeight()
        XCTAssertEqual(height, 5)
        let tip = chain.canonicalTip
        XCTAssertEqual(tip, try! VolumeImpl<Block>(node: prev).rawCID)
    }

    func testMintMultipleBlocksWithTransfers() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = addr(alice.publicKey)
        let bobAddr = addr(bob.publicKey)
        let spec = lifecycleSpec()
        let premineAmount = spec.premineAmount()
        let reward = spec.initialReward

        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(premineAmount))],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [], signers: [aliceAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let genesis = try await buildAndStoreGenesis(
            spec: spec, transactions: [signTransaction(body: premineBody, keypair: alice)],
            timestamp: t - 30_000, target: UInt256(1000), fetcher: fetcher
        )
        try await storeBuiltBlock(genesis, in: fetcher)

        let transfer1Body = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(premineAmount - 100) - Int64(premineAmount)),
                AccountAction(owner: bobAddr, delta: 100)
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], nonce: 1, chainPath: ["Nexus"]
        )
        let block1 = try await buildAndStoreBlock(
            previous: genesis, transactions: [signTransaction(body: transfer1Body, keypair: alice)],
            timestamp: t - 20_000, target: UInt256(1000), nonce: 1,
            rewardRecipient: bobAddr, fetcher: fetcher
        )
        let block1Valid = try await block1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(block1Valid)

        let aliceBalance1 = premineAmount - 100
        let bobBalance1: UInt64 = 100 + reward
        let transfer2Body = TransactionBody(
            accountActions: [
                AccountAction(owner: bobAddr, delta: Int64(bobBalance1 - 50) - Int64(bobBalance1)),
                AccountAction(owner: aliceAddr, delta: 50)
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [bobAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let block2 = try await buildAndStoreBlock(
            previous: block1, transactions: [signTransaction(body: transfer2Body, keypair: bob)],
            timestamp: t - 10_000, nonce: 2, rewardRecipient: aliceAddr, fetcher: fetcher
        )
        let block2Valid = try await block2.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(block2Valid)
        XCTAssertEqual(block2.height, 2)
    }
}

// MARK: - Cross-Chain Tests

@MainActor
final class CrossChainTests: XCTestCase {

    func testDepositTransitionChangesState() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let depositor = CryptoUtils.generateKeyPair()
        let depositorAddr = addr(depositor.publicKey)
        let childSpec = lifecycleSpec("Child")
        let premineAmount = childSpec.premineAmount()

        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: depositorAddr, delta: Int64(premineAmount))],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [], signers: [depositorAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let childGenesis = try await buildAndStoreGenesis(
            spec: childSpec, transactions: [signTransaction(body: premineBody, keypair: depositor)],
            timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )

        let swapAmount: UInt64 = 500
        let swapBody = TransactionBody(
            accountActions: [
                AccountAction(owner: depositorAddr, delta: -Int64(swapAmount))
            ],
            actions: [],
            depositActions: [
                DepositAction(nonce: 1, demander: depositorAddr, amountDemanded: swapAmount, amountDeposited: swapAmount)
            ],
            receiptActions: [], withdrawalActions: [],
            signers: [depositorAddr], nonce: 1,
            chainPath: ["Nexus"]
        )
        let childBlock1 = try await buildAndStoreBlock(
            previous: childGenesis, transactions: [signTransaction(body: swapBody, keypair: depositor)],
            timestamp: t - 10_000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        XCTAssertEqual(childBlock1.height, 1)
        XCTAssertNotEqual(childBlock1.postState.rawCID, childBlock1.prevState.rawCID)
    }

    func testSettleOnNexusChain() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let demander = CryptoUtils.generateKeyPair()
        let demanderAddr = addr(demander.publicKey)
        let withdrawer = CryptoUtils.generateKeyPair()
        let withdrawerAddr = addr(withdrawer.publicKey)

        let nexusSpec = noPremine("Nexus")

        let nexusGenesis = try await buildAndStoreGenesis(
            spec: nexusSpec, timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )

        // Withdrawer gets the block reward and pays demander 500 via receipt
        let settleBody = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            receiptActions: [
                ReceiptAction(
                    withdrawer: withdrawerAddr,
                    nonce: 1,
                    demander: demanderAddr,
                    amountDemanded: 500,
                    directory: "ChildA"
                )
            ],
            withdrawalActions: [],
            signers: [withdrawerAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let bodyHeader = try! HeaderImpl<TransactionBody>(node: settleBody)
        let sigB = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: withdrawer.privateKey)!
        let settleTx = Transaction(signatures: [withdrawer.publicKey: sigB], body: bodyHeader)

        let nexusBlock1 = try await buildAndStoreBlock(
            previous: nexusGenesis, transactions: [settleTx],
            timestamp: t - 10_000, target: UInt256(1000), nonce: 1,
            rewardRecipient: withdrawerAddr, fetcher: fetcher
        )

        XCTAssertEqual(nexusBlock1.height, 1)
        let valid = try await nexusBlock1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(valid)
    }

    func testNexusRejectsDepositActions() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let nexusSpec = noPremine("Nexus")

        let nexusGenesis = try await buildAndStoreGenesis(
            spec: nexusSpec, timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )

        // Fund kp through the block reward, not a self-credit.
        let fundBody = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let block1 = try await buildAndStoreBlock(
            previous: nexusGenesis, transactions: [signTransaction(body: fundBody, keypair: kp)],
            timestamp: t - 15_000, nonce: 1, rewardRecipient: kpAddr, fetcher: fetcher
        )

        //: the bodies carry the correct chainPath ["Nexus"] (so the
        // empty-chainPath rejection in validateChainPaths cannot mask the
        // deposit rule) and the blocks inherit target/nextTarget from the
        // builder (so a retarget mismatch cannot mask it either) — the block
        // must be rejected BECAUSE it deposits on the parentless root.
        let swapBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: -100)],
            actions: [],
            depositActions: [DepositAction(nonce: 1, demander: kpAddr, amountDemanded: 100, amountDeposited: 100)],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], nonce: 1, chainPath: ["Nexus"]
        )
        let block2 = try await buildAndStoreBlock(
            previous: block1, transactions: [signTransaction(body: swapBody, keypair: kp)],
            timestamp: t - 10_000, nonce: 2, fetcher: fetcher
        )

        let valid = try await block2.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid, "Nexus root must consensus-reject blocks containing deposit actions")

    }

    func testNexusRejectsWithdrawalActionsAtConsensus() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let nexusSpec = noPremine("Nexus")

        let nexusGenesis = try await buildAndStoreGenesis(
            spec: nexusSpec, timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )

        // Fund kp through the block reward, not a self-credit.
        let fundBody = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let block1 = try await buildAndStoreBlock(
            previous: nexusGenesis, transactions: [signTransaction(body: fundBody, keypair: kp)],
            timestamp: t - 15_000, nonce: 1, rewardRecipient: kpAddr, fetcher: fetcher
        )

        // A deposit on the root (itself invalid under is the only way
        // to materialize deposit state a withdrawal could reference; build it
        // so the withdrawal block below is constructible at all.
        let depositBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: -100)],
            actions: [],
            depositActions: [DepositAction(nonce: 1, demander: kpAddr, amountDemanded: 100, amountDeposited: 100)],
            receiptActions: [], withdrawalActions: [],
            signers: [kpAddr], nonce: 1, chainPath: ["Nexus"]
        )
        let block2 = try await buildAndStoreBlock(
            previous: block1, transactions: [signTransaction(body: depositBody, keypair: kp)],
            timestamp: t - 10_000, nonce: 2, fetcher: fetcher
        )

        let withdrawBody = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: 100)],
            actions: [],
            depositActions: [],
            receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: 100, amountWithdrawn: 100)
            ],
            signers: [kpAddr], nonce: 2, chainPath: ["Nexus"]
        )
        let block3 = try await buildAndStoreBlock(
            previous: block2, transactions: [signTransaction(body: withdrawBody, keypair: kp)],
            timestamp: t - 5_000, nonce: 3, fetcher: fetcher
        )

        let valid = try await block3.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid, "Nexus root must consensus-reject blocks containing withdrawal actions")
    }

    func testNexusWithdrawalFailsDuringConstruction() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let kp = CryptoUtils.generateKeyPair()
        let kpAddr = addr(kp.publicKey)
        let nexusSpec = noPremine("Nexus")

        let nexusGenesis = try await buildAndStoreGenesis(
            spec: nexusSpec, timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )

        // Nexus must reject transactions containing withdrawal actions. The
        // credit equals the amount withdrawn, so the fee rule holds.
        let body = TransactionBody(
            accountActions: [AccountAction(owner: kpAddr, delta: 100)],
            actions: [],
            depositActions: [],
            receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: kpAddr, nonce: 1, demander: kpAddr, amountDemanded: 100, amountWithdrawn: 100)
            ],
            signers: [kpAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let tx = signTransaction(body: body, keypair: kp)

        await assertThrows(
            StateErrors.conflictingActions,
            "Nexus withdrawal actions must fail closed during block construction"
        ) {
            try await buildAndStoreBlock(
                previous: nexusGenesis, transactions: [tx],
                timestamp: t - 10_000, target: UInt256(1000), nonce: 1, fetcher: fetcher
            )
        }
    }

    func testDepositAndReceiptTransitions() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let depositor = CryptoUtils.generateKeyPair()
        let depositorAddr = addr(depositor.publicKey)

        let nexusSpec = noPremine("Nexus")
        let childSpec = lifecycleSpec("Child")
        let childPremineAmount = childSpec.premineAmount()
        let swapAmount: UInt64 = 500

        let childPremineBody = TransactionBody(
            accountActions: [AccountAction(owner: depositorAddr, delta: Int64(childPremineAmount))],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [], signers: [depositorAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let childGenesis = try await buildAndStoreGenesis(
            spec: childSpec, transactions: [signTransaction(body: childPremineBody, keypair: depositor)],
            timestamp: t - 30_000, target: UInt256(1000), fetcher: fetcher
        )

        let nexusGenesis = try await buildAndStoreGenesis(
            spec: nexusSpec, timestamp: t - 30_000, target: UInt256(1000), fetcher: fetcher
        )

        let childSwap = DepositAction(nonce: 1, demander: depositorAddr, amountDemanded: swapAmount, amountDeposited: swapAmount)

        let swapBody = TransactionBody(
            accountActions: [
                AccountAction(owner: depositorAddr, delta: -Int64(swapAmount))
            ],
            actions: [],
            depositActions: [childSwap],
            receiptActions: [], withdrawalActions: [],
            signers: [depositorAddr], nonce: 1,
            chainPath: ["Nexus"]
        )
        let childBlock1 = try await buildAndStoreBlock(
            previous: childGenesis, transactions: [signTransaction(body: swapBody, keypair: depositor)],
            timestamp: t - 20_000, target: UInt256(1000), nonce: 1,
            rewardRecipient: depositorAddr, fetcher: fetcher
        )
        XCTAssertEqual(childBlock1.height, 1)

        let settleBody = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            receiptActions: [
                ReceiptAction(
                    withdrawer: depositorAddr,
                    nonce: 1,
                    demander: depositorAddr,
                    amountDemanded: swapAmount,
                    directory: "Child"
                )
            ],
            withdrawalActions: [],
            signers: [depositorAddr], nonce: 0, chainPath: ["Nexus"]
        )
        let nexusBlock1 = try await buildAndStoreBlock(
            previous: nexusGenesis, transactions: [signTransaction(body: settleBody, keypair: depositor)],
            timestamp: t - 10_000, target: UInt256(1000), nonce: 1,
            rewardRecipient: depositorAddr, fetcher: fetcher
        )
        let nexusValid = try await nexusBlock1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(nexusValid)
    }

    func testUnsignedFundRemovalFails() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = addr(alice.publicKey)
        let bobAddr = addr(bob.publicKey)
        let spec = lifecycleSpec()
        let premineAmount = spec.premineAmount()

        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(premineAmount))],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [], signers: [aliceAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let genesis = try await buildAndStoreGenesis(
            spec: spec, transactions: [signTransaction(body: premineBody, keypair: alice)],
            timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )

        // The same balanced transfer out of alice's premine, signed by either
        // party: only the signer differs between the two blocks.
        func transfer(signedBy signer: (privateKey: String, publicKey: String), nonce: UInt64) async throws -> Bool {
            let body = TransactionBody(
                accountActions: [
                    AccountAction(owner: aliceAddr, delta: -Int64(premineAmount)),
                    AccountAction(owner: bobAddr, delta: Int64(premineAmount))
                ],
                actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
                signers: [addr(signer.publicKey)], nonce: nonce,
                chainPath: ["Nexus"]
            )
            let block = try await buildAndStoreBlock(
                previous: genesis, transactions: [signTransaction(body: body, keypair: signer)],
                timestamp: t - 10_000, target: UInt256(1000), nonce: 1, fetcher: fetcher
            )
            return try await block.validateNexus(fetcher: fetcher).0
        }

        let aliceSignedValid = try await transfer(signedBy: alice, nonce: 1)
        XCTAssertTrue(aliceSignedValid, "control: alice-signed transfer validates")
        let bobSignedValid = try await transfer(signedBy: bob, nonce: 0)
        XCTAssertFalse(bobSignedValid)
    }
}

// MARK: - Full Block Lifecycle Tests

@MainActor
final class BlockLifecycleTests: XCTestCase {

    func testGenesisToMiningToSubmissionToReorg() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let spec = noPremine()
        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: t - 100_000, target: UInt256(1000), fetcher: fetcher
        )
        var chain = ChainTree.fromGenesis(block: genesis)

        var mainPrev = genesis
        for i in 1...3 {
            let block = try await buildAndStoreBlock(
                previous: mainPrev, timestamp: t - 100_000 + Int64(i) * 1000,
                target: UInt256(1000), nonce: UInt64(i), fetcher: fetcher
            )
            let _ = chain.submitTestBlock(
                blockHeader: try! VolumeImpl<Block>(node: block), block: block
            )
            mainPrev = block
        }

        let mainTip = chain.canonicalTip
        XCTAssertEqual(mainTip, try! VolumeImpl<Block>(node: mainPrev).rawCID)

        var forkPrev = genesis
        for i in 1...5 {
            let block = try await buildAndStoreBlock(
                previous: forkPrev, timestamp: t - 100_000 + Int64(i) * 500,
                target: UInt256(1000), nonce: UInt64(i + 100), fetcher: fetcher
            )
            let _ = chain.submitTestBlock(
                blockHeader: try! VolumeImpl<Block>(node: block), block: block
            )
            forkPrev = block
        }

        let newTip = chain.canonicalTip
        let forkTipHash = try! VolumeImpl<Block>(node: forkPrev).rawCID
        XCTAssertEqual(newTip, forkTipHash, "Longer fork should become main chain")
    }

    func testFullLifecycleWithPremineTransferAndBlocks() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let aliceAddr = addr(alice.publicKey)
        let bobAddr = addr(bob.publicKey)
        let spec = lifecycleSpec()
        let premineAmount = spec.premineAmount()

        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: aliceAddr, delta: Int64(premineAmount))],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [], signers: [aliceAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let genesis = try await buildAndStoreGenesis(
            spec: spec, transactions: [signTransaction(body: premineBody, keypair: alice)],
            timestamp: t - 30_000, target: UInt256(1000), fetcher: fetcher
        )
        try await storeBuiltBlock(genesis, in: fetcher)

        var chain = ChainTree.fromGenesis(block: genesis)

        let transferBody = TransactionBody(
            accountActions: [
                AccountAction(owner: aliceAddr, delta: Int64(premineAmount - 1000) - Int64(premineAmount)),
                AccountAction(owner: bobAddr, delta: 1000)
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [aliceAddr], nonce: 1, chainPath: ["Nexus"]
        )
        let block1 = try await buildAndStoreBlock(
            previous: genesis, transactions: [signTransaction(body: transferBody, keypair: alice)],
            timestamp: t - 20_000, target: UInt256(1000), nonce: 1,
            rewardRecipient: bobAddr, fetcher: fetcher
        )
        let block1Valid = try await block1.validateNexus(fetcher: fetcher).0
        XCTAssertTrue(block1Valid)

        let mined = BlockBuilder.mine(block: block1, target: UInt256.max, maxAttempts: 10)
        XCTAssertNotNil(mined)

        let result = chain.submitTestBlock(
            blockHeader: try! VolumeImpl<Block>(node: mined!), block: mined!
        )
        XCTAssertTrue(result.extendsCanonical)

        let height = chain.getHighestBlockHeight()
        XCTAssertEqual(height, 1)
    }

    func testStateChainingSanity() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let spec = noPremine()
        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: t - 30_000, target: UInt256(1000), fetcher: fetcher
        )

        let emptyState = try! LatticeStateHeader(node: LatticeState.emptyState())
        XCTAssertEqual(genesis.prevState.rawCID, emptyState.rawCID)

        let block1 = try await buildAndStoreBlock(
            previous: genesis, timestamp: t - 20_000, target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        XCTAssertEqual(block1.prevState.rawCID, genesis.postState.rawCID)

        let block2 = try await buildAndStoreBlock(
            previous: block1, timestamp: t - 10_000, target: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        XCTAssertEqual(block2.prevState.rawCID, block1.postState.rawCID)
        XCTAssertEqual(block2.spec.rawCID, block1.spec.rawCID)
        XCTAssertEqual(block2.height, block1.height + 1)
    }

    func testTimestampMustBeStrictlyIncreasing() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let spec = noPremine()
        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )
        try await storeBuiltBlock(genesis, in: fetcher)

        let sameTimestamp = try await buildAndStoreBlock(
            previous: genesis, timestamp: t - 20_000,
            target: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let valid = try await sameTimestamp.validateNexus(fetcher: fetcher).0
        XCTAssertFalse(valid)
    }

    func testFeeAccountingInBlocks() async throws {
        let fetcher = makeFetcher()
        let t = now()
        let miner = CryptoUtils.generateKeyPair()
        let payer = CryptoUtils.generateKeyPair()
        let minerAddr = addr(miner.publicKey)
        let payerAddr = addr(payer.publicKey)
        let spec = lifecycleSpec()
        let premineAmount = spec.premineAmount()
        let reward = spec.rewardAtBlock(1)
        let fee: UInt64 = 50

        let premineBody = TransactionBody(
            accountActions: [AccountAction(owner: payerAddr, delta: Int64(premineAmount))],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [], signers: [payerAddr], nonce: 0,
            chainPath: ["Nexus"]
        )
        let genesis = try await buildAndStoreGenesis(
            spec: spec, transactions: [signTransaction(body: premineBody, keypair: payer)],
            timestamp: t - 20_000, target: UInt256(1000), fetcher: fetcher
        )
        try await storeBuiltBlock(genesis, in: fetcher)

        let feeBody = TransactionBody(
            accountActions: [
                AccountAction(owner: payerAddr, delta: Int64(premineAmount - fee) - Int64(premineAmount))
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [payerAddr], nonce: 1, chainPath: ["Nexus"]
        )
        let block1 = try await buildAndStoreBlock(
            previous: genesis, transactions: [signTransaction(body: feeBody, keypair: payer)],
            timestamp: t - 10_000, target: UInt256(1000), nonce: 1,
            rewardRecipient: minerAddr, fetcher: fetcher
        )

        let (valid, _, postState) = try await block1.validateNexus(fetcher: fetcher)
        XCTAssertTrue(valid)
        let minerBalance: UInt64? = try postState?.accountState.node?.get(key: minerAddr)
        XCTAssertEqual(minerBalance, reward + fee, "the recipient earns exactly the reward plus the fee")
    }
}
