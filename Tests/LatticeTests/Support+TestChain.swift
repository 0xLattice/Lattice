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
