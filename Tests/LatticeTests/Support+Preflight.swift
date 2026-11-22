import Foundation
import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticeValidation
@testable import LatticeBlockTree
@testable import LatticeImport
import cashew

/// A chain seeded by `genesis`, holding the genesis's own spec: on `path`,
/// a root's context pinned to `genesis`.
func testChain(
    genesis: Block,
    path: [String] = [DEFAULT_ROOT_DIRECTORY],
    fetcher: any Fetcher
) async throws -> ChainTree {
    let resolved = try await genesis.spec.resolve(fetcher: fetcher).node
    let spec = try XCTUnwrap(resolved)
    return try ChainTree.fromGenesis(
        block: genesis,
        context: path.count == 1 ? testChainContext(genesis: genesis) : testChainContext(path: path),
        spec: spec
    )
}

extension ChainTree {
    /// Transaction preflight as a node runs it on this chain: classified on
    /// `transactionPreflightTip(at:)` (the canonical tip when nil), on the
    /// chain's path.
    func preflightTransaction(
        _ transaction: Transaction,
        at tipCID: String? = nil,
        parentState: LatticeStateHeader? = nil,
        fetcher: any Fetcher,
        validationContext: ValidationContext = .current
    ) async -> TransactionPreflightResult {
        let tip = transactionPreflightTip(at: tipCID)
        return await TransactionPreflight.classify(
            transaction,
            tipCID: tip.cid,
            snapshot: tip.snapshot,
            chainPath: context!.path,
            parentState: parentState,
            fetcher: fetcher,
            validationContext: validationContext
        )
    }
}
