import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import cashew
import UInt256
import WAT

@MainActor
final class TransactionPreflightTests: XCTestCase {
    private let easy = UInt256.max

    private func spec(
        premine: UInt64 = 0,
        policies: [WasmPolicyRef] = []
    ) -> ChainSpec {
        ChainSpec.test(
            premine: premine,
            wasmPolicies: policies
        )
    }

    private func transaction(
        signers: [(privateKey: String, publicKey: String)],
        nonce: UInt64,
        chainPath: [String] = [DEFAULT_ROOT_DIRECTORY],
        accountActions: [AccountAction] = [],
        actions: [Action] = [],
        withdrawalActions: [WithdrawalAction] = []
    ) -> Transaction {
        let addresses = signers.map { testAddress(publicKey: $0.publicKey) }
        let body = TransactionBody(
            accountActions: accountActions,
            actions: actions,
            depositActions: [],
            receiptActions: [],
            withdrawalActions: withdrawalActions,
            signers: addresses,
            nonce: nonce,
            chainPath: chainPath
        )
        let header = try! HeaderImpl<TransactionBody>(node: body)
        let signatures = Dictionary(uniqueKeysWithValues: signers.map {
            ($0.publicKey, TransactionSigning.sign(
                bodyHeader: header,
                privateKeyHex: $0.privateKey
            )!)
        })
        return Transaction(signatures: signatures, body: header)
    }

    private func fundedLevel(
        fetcher: StorableFetcher,
        alice: (privateKey: String, publicKey: String),
        bob: (privateKey: String, publicKey: String)
    ) async throws -> (ChainLevel, ChainState, Block) {
        let aliceAddress = testAddress(publicKey: alice.publicKey)
        let bobAddress = testAddress(publicKey: bob.publicKey)
        let premine = transaction(
            signers: [alice, bob],
            nonce: 0,
            accountActions: [
                AccountAction(owner: aliceAddress, delta: 500),
                AccountAction(owner: bobAddress, delta: 500),
            ]
        )
        let genesis = try await buildAndStoreGenesis(
            spec: spec(premine: 1),
            transactions: [premine],
            timestamp: 1_000,
            target: easy,
            fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)
        return (ChainLevel(testChain: chain), chain, genesis)
    }

    func testMultiSignerNonceClassificationUsesTheFirstSignerOnly() async throws {
        let fetcher = StorableFetcher()
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        // Genesis is signed by [alice, bob] at nonce 0: alice's next nonce is
        // 1, and bob, a co-signer only, has never used a nonce.
        let (level, chain, genesis) = try await fundedLevel(
            fetcher: fetcher,
            alice: alice,
            bob: bob
        )

        let ready = await level.preflightTransaction(
            transaction(signers: [alice, bob], nonce: 1),
            fetcher: fetcher
        )
        XCTAssertEqual(ready.disposition, .ready)
        XCTAssertEqual(ready.tipCID, try BlockHeader(node: genesis).rawCID)

        let future = await level.preflightTransaction(
            transaction(signers: [alice, bob], nonce: 2),
            fetcher: fetcher
        )
        XCTAssertEqual(future.disposition, .future)

        // Bob first: his own floor (0) decides, whatever alice's is.
        let bobFirst = await level.preflightTransaction(
            transaction(signers: [bob, alice], nonce: 0),
            fetcher: fetcher
        )
        XCTAssertEqual(bobFirst.disposition, .ready)

        let aliceAdvance = transaction(signers: [alice], nonce: 1)
        let block = try await buildAndStoreBlock(
            previous: genesis,
            transactions: [aliceAdvance],
            timestamp: 2_000,
            target: easy,
            fetcher: fetcher
        )
        let blockHeader = try BlockHeader(node: block)
        _ = await chain.submitTestBlock(blockHeader: blockHeader, block: block)
        await chain.markValidated(blockHash: blockHeader.rawCID)

        let stale = await level.preflightTransaction(
            transaction(signers: [alice, bob], nonce: 1),
            fetcher: fetcher
        )
        XCTAssertEqual(stale.disposition, .invalid)
        XCTAssertEqual(stale.tipCID, blockHeader.rawCID)

        let next = await level.preflightTransaction(
            transaction(signers: [alice, bob], nonce: 2),
            fetcher: fetcher
        )
        XCTAssertEqual(next.disposition, .ready)

        let bobStillFirst = await level.preflightTransaction(
            transaction(signers: [bob, alice], nonce: 0),
            fetcher: fetcher
        )
        XCTAssertEqual(bobStillFirst.disposition, .ready)
    }

    func testPreflightClassifiesAgainstTheExecutedTipNotTheWeighedOne() async throws {
        // lattice-node #228: genesis -> block 1 (executed) -> block 2 (weighed
        // only, the canonical tip). Block 2 declares Alice's nonce 1 spent, so
        // her nonce-1 transaction is valid only on block 1's executed state.
        let fetcher = StorableFetcher()
        let alice = CryptoUtils.generateKeyPair()
        let bob = CryptoUtils.generateKeyPair()
        let (level, chain, genesis) = try await fundedLevel(
            fetcher: fetcher,
            alice: alice,
            bob: bob
        )
        let executed = try await buildAndStoreBlock(
            previous: genesis,
            transactions: [],
            timestamp: 2_000,
            target: easy,
            fetcher: fetcher
        )
        let executedHeader = try BlockHeader(node: executed)
        _ = await chain.submitTestBlock(blockHeader: executedHeader, block: executed)
        await chain.markValidated(blockHash: executedHeader.rawCID)
        let weighed = try await buildAndStoreBlock(
            previous: executed,
            transactions: [transaction(signers: [alice], nonce: 1)],
            timestamp: 3_000,
            target: easy,
            fetcher: fetcher
        )
        let weighedHeader = try BlockHeader(node: weighed)
        _ = await chain.submitTestBlock(blockHeader: weighedHeader, block: weighed)
        let canonicalTip = await chain.canonicalTip
        XCTAssertEqual(canonicalTip, weighedHeader.rawCID)
        let executedTipIsExecuted = await chain.hasExecutedAncestry(
            blockHash: executedHeader.rawCID
        )
        let weighedTipIsExecuted = await chain.hasExecutedAncestry(
            blockHash: weighedHeader.rawCID
        )
        XCTAssertTrue(executedTipIsExecuted)
        XCTAssertFalse(weighedTipIsExecuted)

        let aliceNext = transaction(signers: [alice], nonce: 1)
        let atExecuted = await level.preflightTransaction(
            aliceNext,
            at: executedHeader.rawCID,
            fetcher: fetcher
        )
        XCTAssertEqual(atExecuted.disposition, .ready)
        XCTAssertEqual(atExecuted.tipCID, executedHeader.rawCID)
        let futureAtExecuted = await level.preflightTransaction(
            transaction(signers: [alice], nonce: 2),
            at: executedHeader.rawCID,
            fetcher: fetcher
        )
        XCTAssertEqual(futureAtExecuted.disposition, .future)

        // Neither naming the weighed block nor defaulting to the canonical tip
        // classifies against its declared state.
        for (tip, label) in [(Optional(weighedHeader.rawCID), "named"), (nil, "default")] {
            let result = await level.preflightTransaction(
                aliceNext,
                at: tip,
                fetcher: fetcher
            )
            XCTAssertEqual(result.disposition, .unavailable, label)
            XCTAssertEqual(result.tipCID, weighedHeader.rawCID, label)
        }

        // Once the weighed block is executed it is a valid tip, and its state
        // has spent Alice's nonce 1.
        await chain.markValidated(blockHash: weighedHeader.rawCID)
        let afterExecution = await level.preflightTransaction(
            aliceNext,
            fetcher: fetcher
        )
        XCTAssertEqual(afterExecution.disposition, .invalid)
        XCTAssertEqual(afterExecution.tipCID, weighedHeader.rawCID)
    }

    func testStateTransitionAndSignatureFailuresAreInvalid() async throws {
        let fetcher = StorableFetcher()
        let signer = CryptoUtils.generateKeyPair()
        let genesis = try await buildAndStoreGenesis(
            spec: spec(),
            timestamp: 1_000,
            target: easy,
            fetcher: fetcher
        )
        let level = ChainLevel(testChain: ChainState.fromGenesis(block: genesis))
        let address = testAddress(publicKey: signer.publicKey)

        let overspend = transaction(
            signers: [signer],
            nonce: 0,
            accountActions: [AccountAction(owner: address, delta: -1)]
        )
        let overspendResult = await level.preflightTransaction(
            overspend,
            fetcher: fetcher
        )
        XCTAssertEqual(overspendResult.disposition, .invalid)

        let valid = transaction(signers: [signer], nonce: 0)
        let badSignature = Transaction(
            signatures: [signer.publicKey: "00"],
            body: valid.body
        )
        let badSignatureResult = await level.preflightTransaction(
            badSignature,
            fetcher: fetcher
        )
        XCTAssertEqual(badSignatureResult.disposition, .invalid)
    }

    func testClassifyFromTheTreesBasisMatchesTheLevel() async throws {
        let fetcher = StorableFetcher()
        let signer = CryptoUtils.generateKeyPair()
        let genesis = try await buildAndStoreGenesis(
            spec: spec(),
            timestamp: 1_000,
            target: easy,
            fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)
        let level = ChainLevel(testChain: chain)
        let address = testAddress(publicKey: signer.publicKey)
        let tree = await chain.tree

        let ready = transaction(signers: [signer], nonce: 0)
        let overspend = transaction(
            signers: [signer],
            nonce: 0,
            accountActions: [AccountAction(owner: address, delta: -1)]
        )
        let missingBody = Transaction(
            signatures: [:],
            body: HeaderImpl<TransactionBody>(rawCID: testCID("missing-body"))
        )
        let cases: [(Transaction, String?, TransactionPreflightDisposition)] = [
            (ready, nil, .ready),
            (overspend, nil, .invalid),
            (missingBody, nil, .unavailable),
            // A block this chain never executed has no snapshot.
            (ready, testCID("not-executed"), .unavailable),
        ]
        for (tx, tipCID, expected) in cases {
            let basis = tree.transactionPreflightTip(at: tipCID)
            let classified = await TransactionPreflight.classify(
                tx,
                tipCID: basis.cid,
                snapshot: basis.snapshot,
                chainPath: level.context.path,
                fetcher: fetcher
            )
            let viaLevel = await level.preflightTransaction(tx, at: tipCID, fetcher: fetcher)
            XCTAssertEqual(classified, viaLevel)
            XCTAssertEqual(classified.disposition, expected)
        }
    }

    func testValueCreatingTransactionIsInvalid() async throws {
        let fetcher = StorableFetcher()
        let signer = CryptoUtils.generateKeyPair()
        let genesis = try await buildAndStoreGenesis(
            spec: spec(),
            timestamp: 1_000,
            target: easy,
            fetcher: fetcher
        )
        let level = ChainLevel(testChain: ChainState.fromGenesis(block: genesis))
        let address = testAddress(publicKey: signer.publicKey)

        // Credits with nothing debited: negative miner surplus. The block
        // reward no longer funds transactions, so no block may carry it.
        let minting = transaction(
            signers: [signer],
            nonce: 0,
            accountActions: [AccountAction(owner: address, delta: 5)]
        )
        let mintingResult = await level.preflightTransaction(minting, fetcher: fetcher)
        XCTAssertEqual(mintingResult.disposition, .invalid)

        let neutral = transaction(signers: [signer], nonce: 0)
        let neutralResult = await level.preflightTransaction(neutral, fetcher: fetcher)
        XCTAssertEqual(neutralResult.disposition, .ready)
    }

    func testMissingBodyAndPolicyContentAreUnavailable() async throws {
        let fetcher = StorableFetcher()
        let signer = CryptoUtils.generateKeyPair()
        let missingModule = WasmPolicyRef(
            moduleCID: testCID("missing-policy"),
            scope: .transaction
        )
        let genesis = try await buildAndStoreGenesis(
            spec: spec(policies: [missingModule]),
            timestamp: 1_000,
            target: easy,
            fetcher: fetcher
        )
        let level = ChainLevel(testChain: ChainState.fromGenesis(block: genesis))

        let missingPolicyResult = await level.preflightTransaction(
            transaction(signers: [signer], nonce: 0),
            fetcher: fetcher
        )
        XCTAssertEqual(missingPolicyResult.disposition, .unavailable)

        let missingBody = Transaction(
            signatures: [:],
            body: HeaderImpl<TransactionBody>(rawCID: testCID("missing-body"))
        )
        let missingBodyResult = await level.preflightTransaction(
            missingBody,
            fetcher: fetcher
        )
        XCTAssertEqual(missingBodyResult.disposition, .unavailable)
    }

    func testRejectingPolicyIsInvalid() async throws {
        let fetcher = StorableFetcher()
        let policy = try await storeWasmPolicy(
            accepts: false,
            scope: .transaction,
            fetcher: fetcher
        )
        let genesis = try await buildAndStoreGenesis(
            spec: spec(policies: [policy]),
            timestamp: 1_000,
            target: easy,
            fetcher: fetcher
        )
        let level = ChainLevel(testChain: ChainState.fromGenesis(block: genesis))
        let signer = CryptoUtils.generateKeyPair()

        let rejected = await level.preflightTransaction(
            transaction(signers: [signer], nonce: 0),
            fetcher: fetcher
        )
        XCTAssertEqual(rejected.disposition, .invalid)
    }

    func testPolicySeesNextBlockHeight() async throws {
        // The tip is genesis (height 0), so the carrying block is height 1.
        for (minimum, expected) in [(Int64(1), TransactionPreflightDisposition.ready), (2, .invalid)] {
            let fetcher = StorableFetcher()
            let policy = try await storeWasmPolicy(
                contextFieldAt: wasmPolicyContextHeightOffset,
                atLeast: minimum,
                fetcher: fetcher
            )
            let genesis = try await buildAndStoreGenesis(
                spec: spec(policies: [policy]),
                timestamp: 1_000,
                target: easy,
                fetcher: fetcher
            )
            let level = ChainLevel(testChain: ChainState.fromGenesis(block: genesis))
            let result = await level.preflightTransaction(
                transaction(signers: [CryptoUtils.generateKeyPair()], nonce: 0),
                fetcher: fetcher
            )
            XCTAssertEqual(result.disposition, expected, "minimum height \(minimum)")
        }
    }

    func testPolicySeesInjectedValidationTime() async throws {
        // The carrying block is stamped max(tip + 1, now), and the policy
        // requires at least 3_000. Every clock sits far below wall time, which
        // would accept each case, so only the injected clock decides.
        let cases: [(tip: Int64, now: Int64, expected: TransactionPreflightDisposition)] = [
            (1_000, 3_000, .ready),    // now wins and meets the bound
            (1_000, 2_999, .invalid),  // now wins, one below the bound
            (5_000, 0, .ready),        // tip + 1 wins over a stale clock
        ]
        for (tip, now, expected) in cases {
            let fetcher = StorableFetcher()
            let policy = try await storeWasmPolicy(
                contextFieldAt: wasmPolicyContextTimestampOffset,
                atLeast: 3_000,
                fetcher: fetcher
            )
            let genesis = try await buildAndStoreGenesis(
                spec: spec(policies: [policy]),
                timestamp: tip,
                target: easy,
                fetcher: fetcher
            )
            let level = ChainLevel(testChain: ChainState.fromGenesis(block: genesis))
            let result = await level.preflightTransaction(
                transaction(signers: [CryptoUtils.generateKeyPair()], nonce: 0),
                fetcher: fetcher,
                validationContext: ValidationContext(nowMilliseconds: now)
            )
            XCTAssertEqual(result.disposition, expected, "tip \(tip), now \(now)")
        }
    }

    func testWasmPolicyErrorClassificationMatchesImport() {
        // Preflight evicts exactly what import would exclude, and keeps pooled
        // exactly what import would retry (#63). Every policy error is a
        // function of the module and the input, so a verdict, except a module
        // this node cannot obtain: retry, never exclude.
        let cases: [WasmPolicyError] = [
            .unsupportedABI(WasmPolicyRef.currentABIVersion + 1),
            .missingModule("m"),
            .invalidModule,
            .missingMemory,
            .missingAllocator,
            .missingEntrypoint("e"),
            .invalidFunctionSignature("f"),
            .invalidAllocation,
            .invalidReturn,
            .contextEncodingFailed,
            .nondeterministicConstruct("c"),
        ]
        for error in cases {
            let imported = ChainLevel.classifyValidationFailureForTesting(error)
            let preflightUnavailable = transactionPreflightEvidenceUnavailable(error)
            let isVerdict: Bool
            if case .missingModule = error { isVerdict = false } else { isVerdict = true }
            XCTAssertEqual(
                imported,
                isVerdict ? .protocolInvalid : .unavailableEvidence,
                "import: \(error)"
            )
            XCTAssertEqual(preflightUnavailable, !isVerdict, "preflight: \(error)")
        }
    }

    func testAProviderFaultOrAnUnknownErrorIsRetriedNotEvicted() {
        // Bytes that do not hash to the id asked for are a provider's fault,
        // and an error nothing enumerates is not known to be the
        // transaction's: neither is a verdict on it.
        struct Unenumerated: Error {}
        XCTAssertTrue(transactionPreflightEvidenceUnavailable(DataErrors.cidMismatch))
        XCTAssertTrue(transactionPreflightEvidenceUnavailable(Unenumerated()))
    }

    /// Fails the fetch of one content id with `error`; serves the rest.
    private actor FailingFetcher: Fetcher {
        let backing: StorableFetcher
        let failing: String
        let error: Error?

        init(backing: StorableFetcher, failing: String, error: Error?) {
            self.backing = backing
            self.failing = failing
            self.error = error
        }

        func fetch(rawCid: String) async throws -> Data {
            if rawCid == failing, let error { throw error }
            return try await backing.fetch(rawCid: rawCid)
        }
    }

    private enum PolicyOutcome { case accepted, invalid, unavailable }

    /// One outcome of a policy evaluation: the module, how it is referenced,
    /// whether this node can fetch it, and the verdict both paths must reach.
    private struct PolicyCase {
        var name: String
        /// The body of both entrypoints.
        var body = "i32.const 1"
        var alloc = "i32.const 1024"
        var imports = ""
        var scope = WasmPolicyRef.Scope.transaction
        var entrypoint: String? = nil
        var fetchError: Error? = nil
        var expected: PolicyOutcome
    }

    func testPreflightAndImportClassifyEveryPolicyOutcomeAlike() async throws {
        // Every outcome of a policy evaluation, judged on the same transaction
        // by preflight and by import of a block carrying it. An outcome that
        // is a function of (module, input) on the pinned engine is a completed
        // verdict, so both exclude; only a module this node cannot obtain, or
        // an error nothing enumerates, is unavailable. The chains here skip
        // genesis validation, which would refuse the defective modules.
        let cases = [
            PolicyCase(name: "accept", expected: .accepted),
            PolicyCase(name: "reject", body: "i32.const 0", expected: .invalid),
            PolicyCase(name: "unreachable", body: "unreachable", expected: .invalid),
            PolicyCase(
                name: "out-of-bounds load",
                body: "(i32.load (i32.const 0x7fffffff))", expected: .invalid),
            PolicyCase(
                name: "divide by zero",
                body: "(i32.div_u (i32.const 1) (i32.const 0))", expected: .invalid),
            PolicyCase(
                name: "divide overflow",
                body: "(i32.div_s (i32.const 0x80000000) (i32.const -1))", expected: .invalid),
            PolicyCase(
                name: "indirect call to null",
                body: "(call_indirect (type $nullary) (i32.const 1)) i32.const 1", expected: .invalid),
            PolicyCase(
                name: "mismatched indirect call",
                body: "(call_indirect (type $nullary) (i32.const 0)) i32.const 1", expected: .invalid),
            PolicyCase(
                name: "table out of bounds",
                body: "(call_indirect (type $nullary) (i32.const 9)) i32.const 1", expected: .invalid),
            PolicyCase(name: "call stack exhaustion", body: "call $recurse", expected: .invalid),
            PolicyCase(name: "trap in the allocator", alloc: "unreachable", expected: .invalid),
            PolicyCase(
                name: "allocator returns an out-of-range pointer",
                alloc: "i32.const 0x7ffffff0", expected: .invalid),
            PolicyCase(name: "type-invalid body", body: "i64.const 1", expected: .invalid),
            PolicyCase(name: "stack-invalid body", body: "i32.add", expected: .invalid),
            PolicyCase(
                name: "unlinkable import",
                imports: "(import \"env\" \"f\" (func))", expected: .invalid),
            PolicyCase(name: "missing entrypoint", entrypoint: "absent_entrypoint", expected: .invalid),
            PolicyCase(name: "action scope: accept", scope: .action, expected: .accepted),
            PolicyCase(name: "action scope: reject", body: "i32.const 0", scope: .action, expected: .invalid),
            PolicyCase(name: "action scope: trap", body: "unreachable", scope: .action, expected: .invalid),
            PolicyCase(
                name: "action scope: allocator returns an out-of-range pointer",
                alloc: "i32.const 0x7ffffff0", scope: .action, expected: .invalid),
            PolicyCase(
                name: "missing module",
                fetchError: cashew.FetcherError.notFound("module"), expected: .unavailable),
            PolicyCase(
                name: "unenumerated error",
                fetchError: ChainLocalTestError.unexpectedFailure, expected: .unavailable),
        ]
        for testCase in cases {
            let store = StorableFetcher()
            let wat = """
            (module
              \(testCase.imports)
              (type $nullary (func))
              (memory (export "memory") 1)
              (table 2 funcref)
              (elem (i32.const 0) $recurse)
              (func $recurse (result i32) call $recurse)
              (func (export "lattice_alloc") (param i32) (result i32) \(testCase.alloc))
              (func (export "lattice_validate_transaction") (param i32 i32) (result i32)
                \(testCase.body))
              (func (export "lattice_validate_action") (param i32 i32) (result i32)
                \(testCase.body))
            )
            """
            let module = try WasmPolicyModuleHeader(
                node: WasmPolicyModule(bytes: Data(try wat2wasm(wat)))
            )
            try await module.storeRecursively(storer: store)
            let policy = WasmPolicyRef(
                moduleCID: module.rawCID, scope: testCase.scope, entrypoint: testCase.entrypoint
            )
            let genesis = try await buildAndStoreGenesis(
                spec: spec(policies: [policy]),
                timestamp: 1_000,
                target: easy,
                fetcher: store
            )
            let tx = transaction(
                signers: [CryptoUtils.generateKeyPair()],
                nonce: 0,
                actions: testCase.scope == .action
                    ? [Action(key: "app/v1/data", oldValue: nil, newValue: "value")] : []
            )
            let block = try await buildAndStoreBlock(
                previous: genesis,
                transactions: [tx],
                timestamp: 2_000,
                target: easy,
                nonce: 1,
                fetcher: store
            )
            let fetcher = FailingFetcher(
                backing: store, failing: policy.moduleCID, error: testCase.fetchError
            )

            let preflight = await ChainLevel(testChain: ChainState.fromGenesis(block: genesis))
                .preflightTransaction(tx, fetcher: fetcher)
            let imported = try await ChainLevel(testChain: ChainState.fromGenesis(block: genesis))
                .admit(block, fetcher: fetcher, storer: store)

            switch testCase.expected {
            case .accepted:
                XCTAssertEqual(preflight.disposition, .ready, testCase.name)
                XCTAssertNil(imported.failure, testCase.name)
            case .invalid:
                XCTAssertEqual(preflight.disposition, .invalid, testCase.name)
                XCTAssertEqual(imported.failure, .protocolInvalid, testCase.name)
            case .unavailable:
                XCTAssertEqual(preflight.disposition, .unavailable, testCase.name)
                XCTAssertEqual(imported.failure, .unavailableEvidence, testCase.name)
            }
        }
    }

    func testEveryEngineModuleDefectErrorIsAVerdict() throws {
        // The engine's module-defect errors are matched by type name, so each
        // name is pinned here against the error the engine really throws.
        func module(_ body: String, imports: String = "") throws -> Data {
            Data(try wat2wasm("""
            (module
              \(imports)
              (memory (export "memory") 1)
              (func (export "lattice_alloc") (param i32) (result i32) i32.const 1024)
              (func (export "lattice_validate_transaction") (param i32 i32) (result i32)
                \(body))
            )
            """))
        }
        var truncated = try module("i32.const 1")
        truncated.removeLast(3)
        var overlong = Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01])
        overlong.append(contentsOf: [UInt8](repeating: 0x80, count: 6))
        let defects: [(String, Data)] = [
            ("WasmKit.TranslationError", try module("i64.const 1")),
            ("WasmKit.ValidationError", try module("i32.add")),
            ("WasmKit.ImportError", try module("i32.const 1", imports: "(import \"env\" \"f\" (func))")),
            ("WasmParser.WasmParserError", Data([0, 1, 2, 3])),
            ("WasmParser.StreamError<Swift.UInt8>", truncated),
            ("WasmParser.LEBError", overlong),
        ]
        let policy = WasmPolicyRef(moduleCID: "inline", scope: .transaction)
        for (typeName, bytes) in defects {
            XCTAssertThrowsError(try WasmPolicyEvaluator.evaluate(
                policy: policy, contextData: Data(), moduleBytes: bytes
            )) { error in
                XCTAssertEqual(String(reflecting: type(of: error)), typeName)
                XCTAssertEqual(
                    ChainLevel.classifyValidationFailureForTesting(error), .protocolInvalid, typeName
                )
                XCTAssertFalse(transactionPreflightEvidenceUnavailable(error), typeName)
            }
        }
    }

    func testMisbehavingPolicyIsInvalid() async throws {
        // A module without the configured entrypoint throws
        // `.missingEntrypoint` at evaluation: a property of the chain's
        // committed policy, so the transaction is evicted as import would
        // exclude a block carrying it.
        let fetcher = StorableFetcher()
        let policy = try await storeWasmPolicy(
            accepts: true,
            scope: .transaction,
            fetcher: fetcher,
            entrypoint: "absent_entrypoint"
        )
        let genesis = try await buildAndStoreGenesis(
            spec: spec(policies: [policy]),
            timestamp: 1_000,
            target: easy,
            fetcher: fetcher
        )
        let level = ChainLevel(testChain: ChainState.fromGenesis(block: genesis))
        let result = await level.preflightTransaction(
            transaction(signers: [CryptoUtils.generateKeyPair()], nonce: 0),
            fetcher: fetcher
        )
        XCTAssertEqual(result.disposition, .invalid)
    }

    func testChildWithdrawalNeedsCandidateParentState() async throws {
        let fetcher = StorableFetcher()
        let signer = CryptoUtils.generateKeyPair()
        let childSpec = spec()
        let genesis = try await buildAndStoreGenesis(
            spec: childSpec,
            timestamp: 1_000,
            target: easy,
            fetcher: fetcher
        )
        let level = ChainLevel(
            chain: ChainState.fromGenesis(block: genesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        )
        let address = testAddress(publicKey: signer.publicKey)
        let withdrawal = transaction(
            signers: [signer],
            nonce: 0,
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"],
            withdrawalActions: [WithdrawalAction(
                withdrawer: address,
                nonce: 1,
                demander: address,
                amountDemanded: 1,
                amountWithdrawn: 1
            )]
        )

        let result = await level.preflightTransaction(
            withdrawal,
            fetcher: fetcher
        )
        XCTAssertEqual(result.disposition, .unavailable)
    }
}
