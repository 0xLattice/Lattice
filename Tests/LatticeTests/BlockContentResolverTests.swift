import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import ArrayTrie
import cashew
import UInt256

final class BlockContentResolverTests: XCTestCase {
    func testBuilderReturnsTransitionWithoutWritingToFetcher() async throws {
        let fetcher = StorableFetcher()
        let body = TransactionBody(
            accountActions: [AccountAction(owner: "alice", delta: 10)],
            actions: [],
            depositActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: ["alice"],
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let transaction = Transaction(
            signatures: ["alice": "sig"],
            body: try HeaderImpl(node: body)
        )

        let result = try await BlockBuilder.buildGenesisWithTransition(
            spec: testSpec(directory: "Nexus"),
            transactions: [transaction],
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )

        XCTAssertFalse(result.stateDiff.isEmpty)
        XCTAssertEqual(
            try result.materializedPostState.map { try LatticeStateHeader(node: $0).rawCID },
            result.block.postState.rawCID
        )

        _ = try await BlockBuilder.buildBlockWithTransition(
            previous: result.block,
            timestamp: 2,
            target: UInt256.max,
            fetcher: fetcher
        )
        XCTAssertTrue(fetcher.entries.isEmpty)
    }

    func testValidationPathsUseExactReceiptKeys() {
        let receipt = ReceiptAction(
            withdrawer: "withdrawer",
            nonce: 7,
            demander: "demander",
            amountDemanded: 9,
            directory: "Child"
        )
        let withdrawal = WithdrawalAction(
            withdrawer: "withdrawer",
            nonce: 7,
            demander: "demander",
            amountDemanded: 9,
            amountWithdrawn: 9
        )
        let body = TransactionBody(
            accountActions: [],
            actions: [],
            depositActions: [],
            receiptActions: [receipt],
            withdrawalActions: [withdrawal],
            signers: [],
            nonce: 0,
            chainPath: ["Nexus", "Child"]
        )

        let paths = Block.validationPaths(transactionBodies: [body], rewardRecipient: nil)
        XCTAssertEqual(
            paths[[
                PREV_STATE_PROPERTY,
                RECEIPT_STATE_PROPERTY,
                ReceiptKey(receiptAction: receipt).storageKey,
            ]],
            .targeted
        )
        XCTAssertEqual(
            paths[[
                PARENT_STATE_PROPERTY,
                RECEIPT_STATE_PROPERTY,
                ReceiptKey(
                    withdrawalAction: withdrawal,
                    directory: "Child"
                ).storageKey,
            ]],
            .targeted
        )
        XCTAssertNil(paths[[PREV_STATE_PROPERTY, RECEIPT_STATE_PROPERTY, ""]])
        XCTAssertNil(paths[[PARENT_STATE_PROPERTY, RECEIPT_STATE_PROPERTY, ""]])
    }

    func testResolveBlockContentIncludesTransactionsAndSpecButLeavesChildrenIndependent() async throws {
        let fetcher = StorableFetcher()
        let parent = try await buildAndStoreGenesis(
            spec: testSpec(directory: "Nexus"),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )
        try await VolumeImpl<Block>(node: parent).store(
            paths: Block.contentResolutionPaths,
            storer: fetcher
        )

        let txBody = TransactionBody(
            // Content only: a bare credit would break the fee rule.
            accountActions: [],
            actions: [],
            depositActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: ["alice"],
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let tx = Transaction(signatures: ["alice": "sig"], body: try! HeaderImpl(node: txBody))
        let child = try await buildAndStoreGenesis(
            spec: testSpec(directory: "Child"),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )
        let block = try await buildAndStoreBlock(
            previous: parent,
            transactions: [tx],
            children: ["Child": child],
            timestamp: 2,
            target: UInt256.max,
            nonce: 0,
            fetcher: fetcher
        )
        let contentOnly = StorableFetcher()
        try await VolumeImpl<Block>(node: block).store(
            paths: Block.contentResolutionPaths,
            storer: contentOnly
        )

        let header = VolumeImpl<Block>(rawCID: try! VolumeImpl<Block>(node: block).rawCID)
        let resolved = try await header.resolveBlockContent(fetcher: contentOnly)
        let resolvedBlock = try XCTUnwrap(resolved.node)

        XCTAssertNotNil(resolvedBlock.spec.node)
        XCTAssertNotNil(resolvedBlock.transactions.node)
        XCTAssertNil(resolvedBlock.children.node)
        // postState is owned but excluded from the content package — left unresolved.
        XCTAssertNil(resolvedBlock.postState.node)
        // Independent roots are omitted by the content policy; their CID
        // commitments survive intact.
        XCTAssertEqual(resolvedBlock.parent?.rawCID, block.parent?.rawCID)
        XCTAssertEqual(resolvedBlock.prevState.rawCID, block.prevState.rawCID)
        XCTAssertEqual(resolvedBlock.parentState.rawCID, block.parentState.rawCID)

        let transactions = try XCTUnwrap(resolvedBlock.transactions.node?.allKeysAndValues())
        XCTAssertEqual(transactions.count, 1)
        let resolvedTx = try XCTUnwrap(transactions.values.first)
        XCTAssertNotNil(resolvedTx.node)
        XCTAssertNotNil(resolvedTx.node?.body.node)

        XCTAssertEqual(resolvedBlock.children.rawCID, block.children.rawCID)
        XCTAssertNil(contentOnly.entries[block.children.rawCID])
    }

    func testStoreBlockCopiesTheSameValidationPackageFromNodefulAndDecodedBlocks() async throws {
        let source = StorableFetcher()
        let nodeDestination = StorableFetcher()
        let decodedDestination = StorableFetcher()
        let unresolvedDestination = StorableFetcher()
        let genesisResult = try await BlockBuilder.buildGenesisWithTransition(
            spec: testSpec(directory: "Nexus"),
            timestamp: 1,
            target: UInt256.max,
            fetcher: source
        )
        let genesis = try await storeBuiltBlock(genesisResult, in: source)
        let body = TransactionBody(
            // Content only: a bare credit would break the fee rule.
            accountActions: [],
            actions: [],
            depositActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: ["alice"],
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let transaction = Transaction(
            signatures: ["alice": "sig"],
            body: try HeaderImpl(node: body)
        )
        let child = try await buildAndStoreGenesis(
            spec: testSpec(directory: "Child"),
            timestamp: 1,
            target: UInt256.max,
            fetcher: source
        )
        let block = try await buildAndStoreBlock(
            previous: genesis,
            transactions: [transaction],
            children: ["Child": child],
            timestamp: 2,
            target: UInt256.max,
            nonce: 0,
            fetcher: source
        )
        let nodeful = try VolumeImpl<Block>(node: block)
        try await nodeful.storeBlock(fetcher: source, storer: source)

        let cid = nodeful.rawCID
        let decoded = try await VolumeImpl<Block>(rawCID: cid).resolveBlockContent(fetcher: source)
        XCTAssertNil(decoded.node?.postState.node)

        try await nodeful.storeBlock(fetcher: source, storer: nodeDestination)
        try await decoded.storeBlock(fetcher: source, storer: decodedDestination)
        let unresolved = VolumeImpl<Block>(rawCID: cid)
        try await unresolved.storeBlock(fetcher: source, storer: unresolvedDestination)

        XCTAssertEqual(nodeDestination.entries, decodedDestination.entries)
        XCTAssertEqual(nodeDestination.entries, unresolvedDestination.entries)
        XCTAssertTrue(nodeDestination.volumeRoots().contains(cid))
        XCTAssertTrue(nodeDestination.volumeRoots().contains(block.spec.rawCID))
        XCTAssertTrue(nodeDestination.volumeRoots().contains(block.prevState.rawCID))
        XCTAssertTrue(nodeDestination.volumeRoots().contains(try VolumeImpl<Transaction>(node: transaction).rawCID))
        XCTAssertFalse(nodeDestination.contains(rawCid: block.postState.rawCID))
        XCTAssertFalse(nodeDestination.contains(rawCid: try XCTUnwrap(block.parent).rawCID))
        XCTAssertFalse(nodeDestination.volumeRoots().contains(block.postState.rawCID))
        XCTAssertFalse(nodeDestination.volumeRoots().contains(try XCTUnwrap(block.parent).rawCID))
        XCTAssertFalse(nodeDestination.volumeRoots().contains(try VolumeImpl<Block>(node: child).rawCID))

        let copied = try await VolumeImpl<Block>(rawCID: cid).resolveBlockContent(fetcher: decodedDestination)
        XCTAssertNotNil(copied.node?.transactions.node)
        let prevState = try await block.prevState.resolve(
            paths: [[ACCOUNT_STATE_PROPERTY, "alice"]: .targeted],
            fetcher: decodedDestination
        )
        XCTAssertNil(try prevState.node?.accountState.node?.get(key: "alice"))
    }

    func testStoreBlockIncludesPrevStateRootWithoutTransactions() async throws {
        let source = StorableFetcher()
        let destination = StorableFetcher()
        let genesisResult = try await BlockBuilder.buildGenesisWithTransition(
            spec: testSpec(directory: "Nexus"),
            timestamp: 1,
            target: UInt256.max,
            fetcher: source
        )
        let genesis = try await storeBuiltBlock(genesisResult, in: source)
        let block = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 2,
            target: UInt256.max,
            nonce: 0,
            fetcher: source
        )
        let nodeful = try VolumeImpl<Block>(node: block)
        try await nodeful.storeBlock(fetcher: source, storer: source)
        let cid = nodeful.rawCID
        let decoded = try await VolumeImpl<Block>(rawCID: cid).resolveBlockContent(fetcher: source)

        try await decoded.storeBlock(fetcher: source, storer: destination)

        let prevState = try await block.prevState.resolve(fetcher: destination)
        XCTAssertNotNil(prevState.node)
    }

    func testStoreBlockIncludesPolicyModulesNeededForFreshGenesisValidation() async throws {
        let source = StorableFetcher()
        let policy = try await storeWasmPolicy(
            accepts: true,
            scope: .transaction,
            fetcher: source
        )
        let spec = testSpec(directory: "Nexus", wasmPolicies: [policy])
        let result = try await BlockBuilder.buildGenesisWithTransition(
            spec: spec,
            timestamp: 1,
            target: UInt256.max,
            fetcher: source
        )
        let genesis = try await storeBuiltBlock(result, in: source)
        let header = try VolumeImpl<Block>(node: genesis)
        let destination = StorableFetcher()

        try await header.storeBlock(fetcher: source, storer: destination)
        XCTAssertTrue(destination.contains(rawCid: policy.moduleCID))
        let roots = destination.volumeRoots()
        XCTAssertTrue(roots.contains(header.rawCID))
        XCTAssertTrue(roots.contains(policy.moduleCID))
        XCTAssertTrue(roots.contains(LatticeState.emptyHeader.rawCID))
        let emptyState = try XCTUnwrap(LatticeState.emptyHeader.node)
        XCTAssertTrue(roots.contains(emptyState.accountState.rawCID))
        XCTAssertTrue(roots.contains(emptyState.generalState.rawCID))
        XCTAssertTrue(roots.contains(emptyState.depositState.rawCID))
        XCTAssertTrue(roots.contains(emptyState.receiptState.rawCID))

        let copied = try await VolumeImpl<Block>(rawCID: header.rawCID)
            .resolveBlockContent(fetcher: destination)
        let block = try XCTUnwrap(copied.node)
        let (valid, _) = try await block.validateGenesis(
            fetcher: destination,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        XCTAssertTrue(valid)
    }

    func testLogicalBlockSizeUsesExactConsensusLimitForGenesisAndOrdinaryBlocks() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await buildAndStoreGenesis(
            spec: testSpec(directory: "Nexus"),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )
        let block = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 2,
            target: UInt256.max,
            fetcher: fetcher
        )

        for candidate in [genesis, block] {
            let size = try await candidate.logicalContentByteSize(fetcher: fetcher)
            let exact = sizeSpec(maxBlockSize: size)
            let oneOver = sizeSpec(maxBlockSize: size - 1)
            let exactValid = try await candidate.validateBlockSize(spec: exact, fetcher: fetcher)
            let oneOverValid = try await candidate.validateBlockSize(spec: oneOver, fetcher: fetcher)
            XCTAssertTrue(exactValid)
            XCTAssertFalse(oneOverValid)
        }
    }

    func testLogicalBlockSizeCountsSharedTransactionContentOnce() async throws {
        let fetcher = StorableFetcher()
        let transaction = contentTransaction(nonce: 0, payloadBytes: 20_000)
        let one = try await buildAndStoreGenesis(
            spec: testSpec(directory: "Nexus"),
            transactions: [transaction],
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )
        let duplicate = try await buildAndStoreGenesis(
            spec: testSpec(directory: "Nexus"),
            transactions: [transaction, transaction],
            timestamp: 2,
            target: UInt256.max,
            fetcher: fetcher
        )

        let oneSize = try await one.logicalContentByteSize(fetcher: fetcher)
        let duplicateSize = try await duplicate.logicalContentByteSize(fetcher: fetcher)
        XCTAssertGreaterThan(duplicateSize, oneSize)
        XCTAssertLessThan(duplicateSize - oneSize, 20_000)
    }

    func testLogicalBlockSizeIsIndependentOfTransactionOrder() async throws {
        let fetcher = StorableFetcher()
        let first = contentTransaction(nonce: 1, payloadBytes: 256)
        let second = contentTransaction(nonce: 2, payloadBytes: 256)
        let forward = try await buildAndStoreGenesis(
            spec: testSpec(directory: "Nexus"),
            transactions: [first, second],
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )
        let reverse = try await buildAndStoreGenesis(
            spec: testSpec(directory: "Nexus"),
            transactions: [second, first],
            timestamp: 2,
            target: UInt256.max,
            fetcher: fetcher
        )

        let forwardSize = try await forward.logicalContentByteSize(fetcher: fetcher)
        let reverseSize = try await reverse.logicalContentByteSize(fetcher: fetcher)
        XCTAssertEqual(forwardSize, reverseSize)
    }

    func testLogicalBlockSizeExcludesSpecContentsAndChildBlockContents() async throws {
        let fetcher = StorableFetcher()
        let base = try await buildAndStoreGenesis(
            spec: testSpec(directory: "Nexus"),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )
        let module = try WasmPolicyModuleHeader(node: WasmPolicyModule(
            bytes: Data(repeating: 0x7f, count: 20_000)
        ))
        try await module.storeRecursively(storer: fetcher)
        let policy = WasmPolicyRef(
            moduleCID: module.rawCID,
            scope: .transaction
        )
        let largeSpec = ChainSpec.test(
            initialReward: 1,
            halvingInterval: 1_000,
            halfLife: 10,
            wasmPolicies: Array(repeating: policy, count: 1_000)
        )
        let withLargeSpec = base.set(properties: [
            SPEC_PROPERTY: try VolumeImpl<ChainSpec>(node: largeSpec),
        ])
        let baseSize = try await base.logicalContentByteSize(fetcher: fetcher)
        let largeSpecSize = try await withLargeSpec.logicalContentByteSize(fetcher: fetcher)
        XCTAssertEqual(baseSize, largeSpecSize)

        let stateCarrier = try await buildAndStoreGenesis(
            spec: testSpec(directory: "Nexus"),
            transactions: [stateContentTransaction(payloadBytes: 20_000)],
            timestamp: 2,
            target: UInt256.max,
            fetcher: fetcher
        )
        let withLargeState = base.set(properties: [
            POST_STATE_PROPERTY: stateCarrier.postState,
        ])
        let largeStateSize = try await withLargeState.logicalContentByteSize(fetcher: fetcher)
        XCTAssertEqual(baseSize, largeStateSize)

        let child = try await buildAndStoreGenesis(
            spec: testSpec(directory: "Child"),
            transactions: [contentTransaction(nonce: 0, payloadBytes: 20_000)],
            timestamp: 2,
            target: UInt256.max,
            fetcher: fetcher
        )
        let parent = try await buildAndStoreGenesis(
            spec: testSpec(directory: "Nexus"),
            children: ["Child": child],
            timestamp: 3,
            target: UInt256.max,
            fetcher: fetcher
        )
        let parentSize = try await parent.logicalContentByteSize(fetcher: fetcher)
        let childSize = try await child.logicalContentByteSize(fetcher: fetcher)
        XCTAssertLessThan(parentSize - baseSize, childSize)

        let ordinary = try await buildAndStoreBlock(
            previous: base,
            timestamp: 4,
            target: UInt256.max,
            fetcher: fetcher
        )
        let withLargeParent = ordinary.set(properties: [
            PARENT_PROPERTY: try VolumeImpl<Block>(node: child),
        ])
        let ordinarySize = try await ordinary.logicalContentByteSize(fetcher: fetcher)
        let largeParentSize = try await withLargeParent.logicalContentByteSize(fetcher: fetcher)
        XCTAssertEqual(ordinarySize, largeParentSize)
    }

    /// A size error is a verdict only as the counter's own result. Thrown by a
    /// fetcher it is a node-local condition: thrown on, and classified as no
    /// verdict wherever it surfaces.
    func testBlockSizeErrorThrownByAFetcherIsNotAVerdict() async throws {
        let fetcher = StorableFetcher()
        let block = try await buildAndStoreGenesis(
            spec: testSpec(directory: "Nexus"),
            timestamp: 1,
            target: UInt256.max,
            fetcher: fetcher
        )
        let decoded = try XCTUnwrap(Block(data: XCTUnwrap(block.toData())))

        for thrown in [BlockContentSizeError.overflow, .exceedsLimit] {
            do {
                _ = try await decoded.validateBlockSize(
                    spec: sizeSpec(maxBlockSize: 16 * 1_024 * 1_024),
                    fetcher: ThrowingFetcher(error: thrown)
                )
                XCTFail("a fetcher's error must not complete the size check")
            } catch {
                XCTAssertEqual(error as? BlockContentSizeError, thrown)
            }
            XCTAssertFalse(ChainLevel.isDeterministicInvalidityForTesting(
                ChainLevel.classifyValidationFailureForTesting(thrown)
            ))
            XCTAssertFalse(ChainLevel.isDeterministicInvalidityForTesting(
                ChainLevel.classifyResolutionFailureForTesting(thrown)
            ))
        }
    }

    func testBlockSizePropagatesUnavailableContent() async throws {
        let source = StorableFetcher()
        let block = try await buildAndStoreGenesis(
            spec: testSpec(directory: "Nexus"),
            timestamp: 1,
            target: UInt256.max,
            fetcher: source
        )
        let decoded = try XCTUnwrap(Block(data: XCTUnwrap(block.toData())))

        do {
            _ = try await decoded.validateBlockSize(
                spec: sizeSpec(maxBlockSize: 16 * 1_024 * 1_024),
                fetcher: StorableFetcher()
            )
            XCTFail("expected unavailable transaction content to throw")
        } catch is BlockContentSizeError {
            XCTFail("missing content must not be classified as oversized")
        } catch {
            // Availability failures remain retryable by the node.
        }
    }

    func testStateDeltaAccumulationRejectsIntegerOverflow() {
        var positive = Int.max
        XCTAssertFalse(addStateDelta(1, to: &positive))
        XCTAssertEqual(positive, .max)

        var negative = Int.min
        XCTAssertFalse(addStateDelta(-1, to: &negative))
        XCTAssertEqual(negative, .min)
    }
}

private func testSpec(
    directory: String,
    wasmPolicies: [WasmPolicyRef] = []
) -> ChainSpec {
    ChainSpec.test(
        initialReward: 1,
        halvingInterval: 1_000,
        halfLife: 10,
        wasmPolicies: wasmPolicies
    )
}

private func sizeSpec(maxBlockSize: Int) -> ChainSpec {
    ChainSpec.test(
        maxBlockSize: maxBlockSize,
        initialReward: 1,
        halvingInterval: 1_000,
        halfLife: 10
    )
}

private func contentTransaction(nonce: UInt64, payloadBytes: Int) -> Transaction {
    let body = TransactionBody(
        accountActions: [],
        actions: [],
        depositActions: [],
        receiptActions: [],
        withdrawalActions: [],
        signers: [],
        nonce: nonce,
        chainPath: ["Nexus"]
    )
    return Transaction(
        signatures: ["fixture": String(repeating: "x", count: payloadBytes)],
        body: try! HeaderImpl(node: body)
    )
}

private func stateContentTransaction(payloadBytes: Int) -> Transaction {
    let body = TransactionBody(
        accountActions: [],
        actions: [Action(
            key: "large-state",
            oldValue: nil,
            newValue: String(repeating: "s", count: payloadBytes)
        )],
        depositActions: [],
        receiptActions: [],
        withdrawalActions: [],
        signers: [],
        nonce: 0,
        chainPath: ["Nexus"]
    )
    return Transaction(signatures: [:], body: try! HeaderImpl(node: body))
}
