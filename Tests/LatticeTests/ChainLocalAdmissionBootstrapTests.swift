import Foundation
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
import WAT

fileprivate extension Result where Failure == BlockImportError {
    var failure: BlockImportError? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

final class ChainLocalAdmissionBootstrapTests: XCTestCase {
    /// `ChainTree.bootstrap` of `header` on `context`. A child genesis brings
    /// `package`: its proof, verified for the genesis on the chain's path
    /// (failures classified as header admission does), and its link as the
    /// parent facts.
    private func bootstrap(
        _ header: BlockHeader,
        context: ChainRuntimeContext,
        fetcher: any Fetcher,
        package: TestChildPackage? = nil
    ) async throws -> Result<GenesisBootstrap, BlockImportError> {
        var evidence: VerifiedChildEvidence?
        if let package {
            switch package.proof.verifySecuringWork(child: try XCTUnwrap(header.node), chainPath: context.path) {
            case .failure(let failure): return .failure(ChainTree.headerFailure(failure))
            case .success(let verified): evidence = verified
            }
        }
        return await ChainTree.bootstrap(
            genesis: header,
            evidence: evidence,
            fetcher: fetcher,
            context: context,
            parentFacts: package?.parentFacts
        )
    }

    func testRootLevelRejectsASecondParentlessRoot() async throws {
        let fetcher = StorableFetcher()
        let first = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let second = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 2_000, nonce: 1)
        var chain = try AdmissionFixture.makeChain(genesis: first)
        let secondHeader = try BlockHeader(node: second)

        let result = try await chain.admit(secondHeader, fetcher: fetcher)

        XCTAssertEqual(result.failure, .protocolInvalid)
        XCTAssertFalse(chain.contains(blockHash: secondHeader.rawCID))

        let targetMiss = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            timestamp: 3_000,
            target: UInt256(1),
            nonce: 2,
            fetcher: fetcher
        )
        XCTAssertGreaterThan(targetMiss.proofOfWorkHash(), targetMiss.target)
        let missResult = try await chain.admit(targetMiss, fetcher: fetcher)
        XCTAssertEqual(missResult.failure, .proofOfWorkInvalid)
    }

    func testChildBootstrapRequiresAVerifiedGenesis() async throws {
        let fetcher = StorableFetcher()
        let transaction = AdmissionFixture.unsignedStateChangingGenesisTransaction(
            key: "bootstrap",
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"]
        )
        let childGenesis = try await makeChildGenesis(
            fetcher: fetcher,
            nonce: 1,
            transactions: [transaction]
        )
        let context = testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        let header = try BlockHeader(node: childGenesis)
        // A child genesis is weighed by its proof like any child block: no
        // parent record authorizes it.
        let package = try await carriedGenesisPackage(childGenesis, fetcher: fetcher)

        // A proof of another block weighs nothing here.
        let other = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 9)
        let wrongProof = try await bootstrap(
            header,
            context: context,
            fetcher: fetcher,
            package: try await carriedGenesisPackage(other, fetcher: fetcher)
        )
        XCTAssertEqual(wrongProof.failure, .proofOfWorkInvalid)

        let bootstrapResult = try await bootstrap(header, context: context, fetcher: fetcher, package: package)
        guard case .success(let bootstrapped) = bootstrapResult else {
            return XCTFail("the target-hit child genesis must bootstrap: \(bootstrapResult)")
        }
        XCTAssertFalse(bootstrapped.stateDiff.created.isEmpty)
        XCTAssertNotNil(bootstrapped.materializedPostState)
        XCTAssertEqual(bootstrapped.tree.canonicalTip, header.rawCID)
        XCTAssertEqual(bootstrapped.tree.canonicalHashByHeight, [0: header.rawCID])
        XCTAssertTrue(bootstrapped.tree.isExecuted(blockHash: header.rawCID))

        // Even with a proof that verifies for it, a non-genesis block cannot
        // create a child runtime.
        let nonGenesis = try await AdmissionFixture.makeChild(
            of: childGenesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 2
        )
        let nonGenesisResult = try await bootstrap(
            try BlockHeader(node: nonGenesis),
            context: context,
            fetcher: fetcher,
            package: try await carriedGenesisPackage(nonGenesis, nonce: 2, fetcher: fetcher)
        )
        XCTAssertEqual(nonGenesisResult.failure, .protocolInvalid, "a non-genesis block cannot create a child runtime")
    }

    /// The one batch bootstrap returns restores the tree it built.
    func testRootBootstrapBatchRestoresTheLiveTree() async throws {
        let fetcher = StorableFetcher()
        let transaction = AdmissionFixture.unsignedStateChangingGenesisTransaction(
            key: "root-bootstrap",
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        let genesis = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            transactions: [transaction]
        )
        let header = try BlockHeader(node: genesis)
        let context = testChainContext(genesisCID: header.rawCID)

        let result = try await bootstrap(header, context: context, fetcher: fetcher).get()

        XCTAssertFalse(result.stateDiff.created.isEmpty)
        XCTAssertNotNil(result.materializedPostState)
        let rootChain = result.tree
        XCTAssertEqual(rootChain.canonicalTip, header.rawCID)
        let restored = try ChainTree.restoreWithoutContext(replaying: [result.facts])
        XCTAssertEqual(restored.canonicalTip, rootChain.canonicalTip)
    }

    func testGenesisPolicyDeclaringMemoryAboveTwoMiBIsAdmitted() async throws {
        // No node-local memory cap: a policy module declaring 33 pages (2 MiB +
        // 64 KiB) of initial memory is admitted at genesis like any other.
        let fetcher = StorableFetcher()
        let module = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: Data(try wat2wasm("""
        (module
          (memory (export "memory") 33)
          (func (export "lattice_alloc") (param $len i32) (result i32) i32.const 1024)
          (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
            i32.const 1)
        )
        """))))
        try await module.storeRecursively(storer: fetcher)
        let policy = WasmPolicyRef(moduleCID: module.rawCID, scope: .transaction)
        let genesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(wasmPolicies: [policy]),
            timestamp: 1_000,
            target: AdmissionFixture.easy,
            fetcher: fetcher
        )
        let header = try BlockHeader(node: genesis)
        let context = testChainContext(genesisCID: header.rawCID)

        let result = try await bootstrap(header, context: context, fetcher: fetcher).get()
        XCTAssertEqual(result.tree.canonicalTip, header.rawCID)
    }

    func testGenesisBootstrapRequiresUnsignedTransactions() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            transactions: [AdmissionFixture.unsignedStateChangingGenesisTransaction(
                key: "unsigned-root",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )]
        )
        let header = try BlockHeader(node: genesis)
        let context = testChainContext(genesisCID: header.rawCID)

        let direct = try await genesis.validateGenesis(
            fetcher: fetcher,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        XCTAssertTrue(direct.0)

        let result = try await bootstrap(header, context: context, fetcher: fetcher).get()
        XCTAssertEqual(result.tree.canonicalTip, header.rawCID)
        XCTAssertEqual(result.tree.canonicalHashByHeight, [0: header.rawCID])
    }

    /// Genesis exemptions end at the genesis: an unsigned transaction at
    /// height one weighs, and its execution proves the block invalid.
    func testGenesisBootstrapDoesNotRelaxLaterTransactions() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            transactions: [AdmissionFixture.unsignedStateChangingGenesisTransaction(
                key: "unsigned-root",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )]
        )
        let genesisHeader = try BlockHeader(node: genesis)
        var chain = try await bootstrap(
            genesisHeader,
            context: testChainContext(genesisCID: (genesisHeader).rawCID),
            fetcher: fetcher
        ).get().tree
        let unsignedBody = TransactionBody(
            accountActions: [],
            actions: [Action(key: "unsigned-height-one", oldValue: nil, newValue: "value")],
            depositActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [],
            nonce: 0,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        let unsignedTransaction = Transaction(
            signatures: [:],
            body: try HeaderImpl<TransactionBody>(node: unsignedBody)
        )
        let candidate = try await buildAndStoreBlock(
            previous: genesis,
            transactions: [unsignedTransaction],
            timestamp: 2_000,
            target: AdmissionFixture.easy,
            nonce: 1,
            fetcher: fetcher
        )

        let result = try await chain.admit(candidate, fetcher: fetcher)
        XCTAssertEqual(result.update?.excluded, true, "proven invalid: \(result)")
        let candidateHash = try BlockHeader(node: candidate).rawCID
        XCTAssertTrue(chain.isExcludedRoot(candidateHash))
        XCTAssertFalse(chain.isExecuted(blockHash: candidateHash))
        XCTAssertEqual(chain.canonicalTip, genesisHeader.rawCID)
    }

    func testGenesisBootstrapIgnoresSignatures() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            transactions: [AdmissionFixture.signedStateChangingGenesisTransaction(
                key: "signed-root",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )]
        )
        let header = try BlockHeader(node: genesis)

        _ = try await bootstrap(
            header,
            context: testChainContext(genesisCID: (header).rawCID),
            fetcher: fetcher
        ).get()
    }

    func testGenesisBootstrapIgnoresEverySignatureShape() async throws {
        let keyPair = CryptoUtils.generateKeyPair()
        let signer = testAddress(publicKey: keyPair.publicKey)

        func body(signers: [String]) -> TransactionBody {
            TransactionBody(
                accountActions: [],
                actions: [Action(key: "malformed-pair", oldValue: nil, newValue: "value")],
                depositActions: [],
                receiptActions: [],
                withdrawalActions: [],
                signers: signers,
                nonce: 0,
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )
        }

        let declaredButUnsigned = Transaction(
            signatures: [:],
            body: try HeaderImpl<TransactionBody>(node: body(signers: [signer]))
        )
        let signedButUndeclared = signedTestTransaction(body(signers: []), by: keyPair)
        let invalidSignature = Transaction(
            signatures: [keyPair.publicKey: "not-a-signature"],
            body: try HeaderImpl<TransactionBody>(node: body(signers: [signer]))
        )

        for transaction in [declaredButUnsigned, signedButUndeclared, invalidSignature] {
            let fetcher = StorableFetcher()
            let genesis = try await AdmissionFixture.makeGenesis(
                fetcher: fetcher,
                timestamp: 1_000,
                transactions: [transaction]
            )
            let header = try BlockHeader(node: genesis)
            _ = try await bootstrap(
                header,
                context: testChainContext(genesisCID: (header).rawCID),
                fetcher: fetcher
            ).get()
        }
    }

    func testChildBootstrapAcceptsUnsignedGenesisTransactions() async throws {
        let fetcher = StorableFetcher()
        let childGenesis = try await BlockBuilder.buildChildGenesis(
            spec: chainLocalSpec(),
            parentState: try await testAnchorParentGenesis(fetcher: fetcher).postState,
            transactions: [AdmissionFixture.unsignedStateChangingGenesisTransaction(
                key: "unsigned-child",
                chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"]
            )],
            timestamp: 1_000,
            target: AdmissionFixture.easy,
            fetcher: fetcher
        )
        try await storeBuiltBlock(childGenesis, in: fetcher)
        let childHeader = try BlockHeader(node: childGenesis)

        let result = try await bootstrap(
            childHeader,
            context: testChainContext(
                path: [DEFAULT_ROOT_DIRECTORY, "Child"]
            ),
            fetcher: fetcher,
            package: try await carriedGenesisPackage(childGenesis, fetcher: fetcher)
        )
        XCTAssertNil(result.failure)
    }

    func testGenesisDifficultySeedIsValidated() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let forged = Block(
            version: genesis.version,
            parent: genesis.parent,
            transactions: genesis.transactions,
            target: genesis.target,
            nextTarget: genesis.target - UInt256(1),
            spec: genesis.spec,
            parentState: genesis.parentState,
            prevState: genesis.prevState,
            postState: genesis.postState,
            children: genesis.children,
            height: genesis.height,
            timestamp: genesis.timestamp,
            rewardRecipient: genesis.rewardRecipient,
            nonce: genesis.nonce
        )
        try await storeBuiltBlock(forged, in: fetcher)
        let direct = try await forged.validateGenesis(
            fetcher: fetcher,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        )
        XCTAssertFalse(direct.0)
        XCTAssertFalse(GenesisCeremony.verify(
            block: forged,
            config: GenesisConfig(
                spec: chainLocalSpec(),
                timestamp: forged.timestamp
            )
        ))

        let result = try await bootstrap(
            try BlockHeader(node: forged),
            context: testChainContext(genesis: forged),
            fetcher: fetcher
        )
        XCTAssertEqual(result.failure, .protocolInvalid, "genesis must seed its first successor with its own target")
    }

    /// The configured Nexus genesis keeps its own grind: a target miss is a
    /// proof-of-work failure.
    func testRootBootstrapRejectsTargetMiss() async throws {
        let fetcher = StorableFetcher()
        let hardGenesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            timestamp: 2_000,
            target: UInt256(1),
            nonce: 1,
            fetcher: fetcher
        )
        XCTAssertGreaterThan(hardGenesis.proofOfWorkHash(), hardGenesis.target)
        let result = try await bootstrap(
            try BlockHeader(node: hardGenesis),
            context: testChainContext(genesis: hardGenesis),
            fetcher: fetcher
        )
        XCTAssertEqual(result.failure, .proofOfWorkInvalid, "a target miss cannot bootstrap the root")
    }

    /// The root chain admits only its configured genesis (§5.1).
    func testRootBootstrapRefusesAnUnpinnedGenesis() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let result = try await bootstrap(
            try BlockHeader(node: genesis),
            context: testChainContext(),
            fetcher: fetcher
        )
        XCTAssertEqual(result.failure, .protocolInvalid, "only the configured genesis may root the root chain")
    }

    /// A child genesis weighs only by its proof: a carrier hash that misses
    /// the genesis's target yields no work.
    func testChildBootstrapRejectsTargetMiss() async throws {
        let fetcher = StorableFetcher()
        let childGenesis = try await makeChildGenesis(
            fetcher: fetcher, nonce: 1, target: UInt256(1)
        )
        let header = try BlockHeader(node: childGenesis)

        let result = try await bootstrap(
            header,
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"]),
            fetcher: fetcher,
            package: try await carriedGenesisPackage(childGenesis, fetcher: fetcher)
        )
        XCTAssertEqual(result.failure, .proofOfWorkInvalid)
    }

    func testHeightOverflowFailsClosedInBuilder() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let overflowParent = Block(
            version: genesis.version,
            parent: genesis.parent,
            transactions: genesis.transactions,
            target: genesis.target,
            nextTarget: genesis.nextTarget,
            spec: genesis.spec,
            parentState: genesis.parentState,
            prevState: genesis.prevState,
            postState: genesis.postState,
            children: genesis.children,
            height: UInt64.max,
            timestamp: genesis.timestamp,
            rewardRecipient: genesis.rewardRecipient,
            nonce: genesis.nonce
        )

        do {
            _ = try await BlockBuilder.buildBlock(
                previous: overflowParent,
                timestamp: 2_000,
                fetcher: fetcher
            )
            XCTFail("height overflow must reject construction")
        } catch BlockBuilderError.heightOverflow {
            // Expected.
        }
    }
}
