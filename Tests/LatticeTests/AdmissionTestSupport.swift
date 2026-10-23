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

// MARK: - Admission with test defaults

extension ChainLevel {
    /// Chain-local admission with the fixture defaults: eager mode, the
    /// fetcher doubling as the validation-content store (and, unless
    /// `materialized` says otherwise, the materialized store), no child
    /// package, the current validation context, and a no-op stage. A call
    /// names only what its scenario changes.
    func admit(
        _ header: BlockHeader,
        mode: ImportMode = .full,
        fetcher: any Fetcher & VolumeStorer,
        materialized: (any VolumeStorer)? = nil,
        childPackage: ChildValidationPackage? = nil,
        validationContext: ValidationContext = .current,
        stage: @Sendable (BlockImportStagingContext) async throws -> Void = testAdmissionStage
    ) async throws -> BlockImportResult {
        try await admit(
            header,
            mode: mode,
            fetcher: fetcher,
            storer: fetcher,
            materialized: materialized,
            childPackage: childPackage,
            validationContext: validationContext,
            stage: stage
        )
    }

    /// The fixture defaults for a fetcher that does not store: the
    /// validation-content store is named explicitly.
    func admit(
        _ header: BlockHeader,
        mode: ImportMode = .full,
        fetcher: any Fetcher,
        storer: any VolumeStorer,
        materialized: (any VolumeStorer)? = nil,
        childPackage: ChildValidationPackage? = nil,
        validationContext: ValidationContext = .current,
        stage: @Sendable (BlockImportStagingContext) async throws -> Void = testAdmissionStage
    ) async throws -> BlockImportResult {
        try await importBlock(
            header,
            fetcher: fetcher,
            childPackage: childPackage,
            validationContext: validationContext,
            validationContentStorer: storer,
            materializedVolumeStorer: materialized ?? storer,
            mode: mode,
            stage: stage
        )
    }

    /// ``admit(_:mode:fetcher:materialized:childPackage:validationContext:stage:)``
    /// for a block held inline.
    func admit(
        _ block: Block,
        mode: ImportMode = .full,
        fetcher: any Fetcher & VolumeStorer,
        materialized: (any VolumeStorer)? = nil,
        childPackage: ChildValidationPackage? = nil,
        validationContext: ValidationContext = .current,
        stage: @Sendable (BlockImportStagingContext) async throws -> Void = testAdmissionStage
    ) async throws -> BlockImportResult {
        try await admit(
            try BlockHeader(node: block),
            mode: mode,
            fetcher: fetcher,
            materialized: materialized,
            childPackage: childPackage,
            validationContext: validationContext,
            stage: stage
        )
    }

    /// ``admit(_:mode:fetcher:storer:materialized:childPackage:validationContext:stage:)``
    /// for a block held inline.
    func admit(
        _ block: Block,
        mode: ImportMode = .full,
        fetcher: any Fetcher,
        storer: any VolumeStorer,
        materialized: (any VolumeStorer)? = nil,
        childPackage: ChildValidationPackage? = nil,
        validationContext: ValidationContext = .current,
        stage: @Sendable (BlockImportStagingContext) async throws -> Void = testAdmissionStage
    ) async throws -> BlockImportResult {
        try await admit(
            try BlockHeader(node: block),
            mode: mode,
            fetcher: fetcher,
            storer: storer,
            materialized: materialized,
            childPackage: childPackage,
            validationContext: validationContext,
            stage: stage
        )
    }
}

// MARK: - Shared fixtures and stubs

func chainLocalSpec(wasmPolicies: [WasmPolicyRef] = []) -> ChainSpec {
    ChainSpec.test(wasmPolicies: wasmPolicies)
}

enum ChainLocalTestError: Error, Sendable {
    case unexpectedFailure
    case storageFailure
    case stageFailure
}

struct FailingAdmissionStorer: Storer, VolumeStorer {
    func store(entries: [String: Data]) async throws {
        throw ChainLocalTestError.storageFailure
    }

    func store(volume: SerializedVolume) async throws {
        throw ChainLocalTestError.storageFailure
    }
}

actor RecordingAdmissionStorer: Storer, VolumeStorer {
    private let backing = StorableFetcher()
    private var roots = Set<String>()
    private var calls = 0

    func store(entries: [String: Data]) async throws {
        calls += 1
        await backing.store(entries: entries)
    }

    func store(volume: SerializedVolume) async throws {
        calls += 1
        roots.insert(volume.root)
        await backing.store(volume: volume)
    }

    func volumeRoots() -> Set<String> { roots }
    func storeCallCount() -> Int { calls }
}

actor AdmissionStageRecorder {
    private var batches: [BlockImportBatch] = []
    private var contexts: [BlockImportStagingContext] = []

    func stage(_ batch: BlockImportBatch) {
        batches.append(batch)
    }

    func stage(_ context: BlockImportStagingContext) {
        contexts.append(context)
        batches.append(context.batch)
    }

    func count(for blockHash: String) -> Int {
        batches.count { batch in
            batch.facts.contains { fact in
                switch fact {
                case .block(let block): block.blockHash == blockHash
                case .work(let work): work.blockHash == blockHash
                case .exclusion(let exclusion): exclusion.blockHash == blockHash
                case .validation(let validation): validation.blockHash == blockHash
                case .fold(let fold): fold.blockHash == blockHash
                }
            }
        }
    }

    func recordedBatches() -> [BlockImportBatch] { batches }
    func recordedContexts() -> [BlockImportStagingContext] { contexts }
}

/// The admission fixtures: an always-hit target, chain-local genesis/child
/// builders and the level under test, plus the genesis-transaction and child
/// proof shapes more than one suite exercises.
enum AdmissionFixture {
    static let easy = UInt256.max

    static func makeGenesis(
        fetcher: StorableFetcher,
        timestamp: Int64,
        nonce: UInt64 = 0,
        transactions: [Transaction] = []
    ) async throws -> Block {
        return try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            transactions: transactions,
            timestamp: timestamp,
            target: easy,
            nonce: nonce,
            fetcher: fetcher
        )
    }

    static func makeChild(
        of previous: Block,
        fetcher: StorableFetcher,
        timestamp: Int64,
        nonce: UInt64,
        parentChainBlock: Block? = nil
    ) async throws -> Block {
        try await buildAndStoreBlock(
            previous: previous,
            parentChainBlock: parentChainBlock,
            timestamp: timestamp,
            target: easy,
            nonce: nonce,
            fetcher: fetcher
        )
    }

    static func makeLevel(genesis: Block) -> ChainLevel {
        ChainLevel(testChain: ChainState.fromGenesis(block: genesis))
    }

    static func makeLevel(
        genesis: Block,
        revision: UInt64
    ) async throws -> (level: ChainLevel, seedBatch: BlockImportBatch) {
        let seedBatch = try testAdmissionBatch(for: genesis)
        return (
            ChainLevel(testChain: try await ChainState.restoreWithoutContext(
                replaying: [seedBatch],
                revisionFloor: revision
            )),
            seedBatch
        )
    }

    static func signedStateChangingGenesisTransaction(
        key: String,
        chainPath: [String]
    ) -> Transaction {
        let keyPair = CryptoUtils.generateKeyPair()
        let signer = testAddress(publicKey: keyPair.publicKey)
        let body = TransactionBody(
            accountActions: [],
            actions: [Action(key: key, oldValue: nil, newValue: "value")],
            depositActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [signer],
            nonce: 0,
            chainPath: chainPath
        )
        return signedTestTransaction(body, by: keyPair)
    }

    static func unsignedStateChangingGenesisTransaction(
        key: String,
        chainPath: [String]
    ) -> Transaction {
        let body = TransactionBody(
            accountActions: [],
            actions: [Action(key: key, oldValue: nil, newValue: "value")],
            depositActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [],
            nonce: 0,
            chainPath: chainPath
        )
        return Transaction(
            signatures: [:],
            body: try! HeaderImpl<TransactionBody>(node: body)
        )
    }

    static func makeChildProofFixture() async throws -> (
        fetcher: StorableFetcher,
        childLevel: ChainLevel,
        candidate: Block,
        package: ChildValidationPackage
    ) {
        let fetcher = StorableFetcher()
        let parentGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let childGenesis = try await makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let candidate = try await makeChild(
            of: childGenesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1,
            parentChainBlock: parentGenesis
        )
        let carrierWithChild = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": candidate],
            timestamp: 3_000,
            target: easy,
            nonce: 2,
            fetcher: fetcher
        )
        let childLevel = ChainLevel(
            chain: ChainState.fromGenesis(block: childGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        )

        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrierWithChild),
            childDirectory: "Child",
            fetcher: fetcher
        )
        return (
            fetcher,
            childLevel,
            candidate,
            try await childValidationPackage(proof: proof, fetcher: fetcher)
        )
    }
}
