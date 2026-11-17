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

/// Drives a `ChainTree` through its value API the way a core would: the
/// block's own child index resolved first, then one synchronous
/// `insertRootHeader`/`insertChildHeader`; `connectJob` → `connect` → `applyConnect` for execution.
enum TreeDriver {
    static func headerInputs(
        _ block: Block,
        fetcher: any Fetcher
    ) async throws -> (spec: ChainSpec, childIndex: FlatDictionary<BlockHeader>) {
        let spec = try await block.spec.resolve(fetcher: fetcher).node
        let childIndex = try await block.children.resolve(fetcher: fetcher).node
        return (try XCTUnwrap(spec), try XCTUnwrap(childIndex))
    }

    /// Test-built evidence of `work` securing exactly `block`.
    static func evidence(
        for block: Block,
        work: VerifiedWorkContribution
    ) throws -> VerifiedChildEvidence {
        VerifiedChildEvidence(
            grindID: work.id,
            rootHash: .zero,
            creditedAncestorWork: work.work,
            childCID: try BlockHeader(node: block).rawCID,
            terminalCarrierCID: work.id,
            contribution: work
        )
    }

    /// `insertRootHeader` on a root tree; `insertChildHeader` on a child
    /// tree, with `evidence`, or test evidence of `work` for this block.
    static func insert(
        _ block: Block,
        into tree: inout ChainTree,
        fetcher: any Fetcher,
        evidence: VerifiedChildEvidence? = nil,
        work: VerifiedWorkContribution? = nil
    ) async throws -> ChainTreeAdmission {
        let inputs = try await headerInputs(block, fetcher: fetcher)
        if tree.context?.isRoot == true {
            return tree.insertRootHeader(block, childIndex: inputs.childIndex)
        }
        let childEvidence = try evidence ?? self.evidence(
            for: block, work: try XCTUnwrap(work, "a child block needs work")
        )
        return tree.insertChildHeader(
            block, childIndex: inputs.childIndex, evidence: childEvidence
        )
    }

    /// A tree seeded by `genesis`, holding its spec as bootstrap would.
    static func tree(
        genesis: Block,
        context: ChainRuntimeContext?,
        fetcher: any Fetcher
    ) async throws -> ChainTree {
        let spec = try await genesis.spec.resolve(fetcher: fetcher).node
        guard let context else { return ChainTree.fromGenesis(block: genesis) }
        return try ChainTree.fromGenesis(
            block: genesis, context: context, spec: try XCTUnwrap(spec)
        )
    }

    static func connect(
        _ blockHash: String,
        on tree: inout ChainTree,
        fetcher: any Fetcher,
        parentFacts: (any ParentChainFacts)? = nil,
        grind: String? = nil
    ) async throws -> ChainTreeAdmission {
        let job = try XCTUnwrap(tree.connectJob(for: blockHash, grind: grind))
        let verdict = await ChainTree.connect(
            job, fetcher: fetcher, parentFacts: parentFacts
        )
        // A valid verdict carries the block it executed; no other does.
        if verdict.provesInvalid || verdict.retryFailure != nil {
            XCTAssertNil(verdict.connectedBlock)
        } else {
            XCTAssertEqual(try BlockHeader(node: try XCTUnwrap(verdict.connectedBlock)).rawCID, blockHash)
        }
        return tree.applyConnect(verdict)
    }

    /// A block linked to `valid`'s parent exactly as `valid` is, whose
    /// declared post-state no execution produces: it weighs, and its
    /// execution proves it invalid.
    static func forgedPostState(
        of valid: Block,
        seed: String,
        fetcher: StorableFetcher
    ) async throws -> Block {
        try await storeBuiltBlock(Block(
            version: valid.version,
            parent: valid.parent,
            transactions: valid.transactions,
            target: valid.target,
            nextTarget: valid.nextTarget,
            spec: valid.spec,
            parentState: valid.parentState,
            prevState: valid.prevState,
            postState: LatticeStateHeader(rawCID: testCID("forged-post-\(seed)")),
            children: valid.children,
            height: valid.height,
            timestamp: valid.timestamp,
            rewardRecipient: valid.rewardRecipient,
            nonce: valid.nonce
        ), in: fetcher)
    }
}

/// A test block's own child index: every fixture builds its blocks in memory.
func testChildIndex(_ block: Block) -> FlatDictionary<BlockHeader> {
    block.children.node ?? FlatDictionary<BlockHeader>()
}
