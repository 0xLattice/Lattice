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

// MARK: - Admission, as the node drives a tree

/// A child block's cross-chain inputs as a test builds them: the proof of
/// the work securing it, and the parent-chain continuity link a node would
/// have derived from its parent level.
struct TestChildPackage: Sendable {
    let proof: ChildBlockProof
    let parentStateContinuityLink: ParentStateContinuityLink?

    init(proof: ChildBlockProof, parentStateContinuityLink: ParentStateContinuityLink? = nil) {
        self.proof = proof
        self.parentStateContinuityLink = parentStateContinuityLink
    }

    /// Parent facts that know exactly this package's link.
    var parentFacts: any ParentChainFacts { LinkFacts(link: parentStateContinuityLink) }
}

/// Parent facts that answer one link and nothing else.
struct LinkFacts: ParentChainFacts {
    let link: ParentStateContinuityLink?
    func hasContinuity(_ asked: ParentStateContinuityLink) async -> Bool { asked == link }
}

/// Which steps `admit` takes: the header alone (`.header`, weighing the
/// block), execution alone of a block already weighed (`.execution`), or
/// both (`.full`).
enum TestAdmitMode: Sendable {
    case full
    case header
    case execution
}

extension ChainTree {
    /// Admit `block` as a node does: its header (`insertRootHeader`, or
    /// `insertChildHeader` with the evidence `child`'s proof verifies), then
    /// `connectJob` → `connect` → `applyConnect`. Returns the admission of the
    /// last step taken: a header that is refused, or lands excluded, is not
    /// executed, and nor is a block already executed. A child's parent facts
    /// are `parentFacts`, else `child`'s link.
    mutating func admit(
        _ block: Block,
        mode: TestAdmitMode = .full,
        fetcher: any Fetcher,
        child: TestChildPackage? = nil,
        parentFacts: (any ParentChainFacts)? = nil,
        validationContext: ValidationContext = .current
    ) async throws -> ChainTreeAdmission {
        let blockHash = try BlockHeader(node: block).rawCID
        var header: ChainTreeAdmission?
        if mode != .execution {
            guard let childIndex = try? await block.children.resolve(fetcher: fetcher).node else {
                return .rejected(.unavailableEvidence)
            }
            let inserted: ChainTreeAdmission
            if context?.isRoot ?? true {
                inserted = insertRootHeader(block, childIndex: childIndex, validationContext: validationContext)
            } else if let child, let context {
                switch child.proof.verifySecuringWork(child: block, chainPath: context.path) {
                case .failure(let failure):
                    return .rejected(ChainTree.headerFailure(failure))
                case .success(let evidence):
                    inserted = insertChildHeader(
                        block, childIndex: childIndex, evidence: evidence, validationContext: validationContext
                    )
                }
            } else {
                return .rejected(.crossChainEvidenceRequired(.childProof(
                    chainPath: context?.path ?? [], childCID: blockHash
                )))
            }
            if mode == .header || inserted.failure != nil || inserted.update?.excluded == true {
                return inserted
            }
            if case .duplicate = inserted, isExecuted(blockHash: blockHash) { return inserted }
            header = inserted
        }
        guard let job = connectJob(for: blockHash) else {
            return header ?? .rejected(.notAcceptedAtCurrentChain)
        }
        let verdict = await ChainTree.connect(
            job,
            fetcher: fetcher,
            parentFacts: parentFacts ?? child?.parentFacts,
            validationContext: validationContext
        )
        return applyConnect(verdict)
    }

    /// ``admit(_:mode:fetcher:child:parentFacts:validationContext:)`` of the
    /// block `header` names, resolved from `fetcher`.
    mutating func admit(
        _ header: BlockHeader,
        mode: TestAdmitMode = .full,
        fetcher: any Fetcher,
        child: TestChildPackage? = nil,
        parentFacts: (any ParentChainFacts)? = nil,
        validationContext: ValidationContext = .current
    ) async throws -> ChainTreeAdmission {
        switch await BlockImport.resolveBlock(header, fetcher: fetcher) {
        case .failure(let failure): return .rejected(failure)
        case .success(let resolved):
            return try await admit(
                resolved.block, mode: mode, fetcher: fetcher, child: child,
                parentFacts: parentFacts, validationContext: validationContext
            )
        }
    }
}

// MARK: - Shared fixtures and stubs

func chainLocalSpec(wasmPolicies: [WasmPolicyRef] = []) -> ChainSpec {
    ChainSpec.test(wasmPolicies: wasmPolicies)
}

enum ChainLocalTestError: Error, Sendable {
    case unexpectedFailure
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

    /// A root chain seeded by `genesis` (built with `chainLocalSpec`), on a
    /// context pinned to it.
    static func makeChain(genesis: Block, spec: ChainSpec = chainLocalSpec()) throws -> ChainTree {
        try ChainTree.fromGenesis(block: genesis, context: testChainContext(genesis: genesis), spec: spec)
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
        childChain: ChainTree,
        candidate: Block,
        package: TestChildPackage
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
        let childChain = try ChainTree.fromGenesis(
            block: childGenesis,
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"]),
            spec: chainLocalSpec()
        )

        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrierWithChild),
            childDirectory: "Child",
            fetcher: fetcher
        )
        return (fetcher, childChain, candidate, TestChildPackage(proof: proof))
    }
}
