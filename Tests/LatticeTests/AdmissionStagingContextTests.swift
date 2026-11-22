import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import Foundation
import UInt256
import cashew

final class AdmissionStagingContextTests: XCTestCase {
    func testRootBootstrapBatchRecordsItsExecution() async throws {
        let fetcher = StorableFetcher()
        let spec = ChainSpec.test()
        let genesis = try await buildAndStoreGenesis(
            spec: spec,
            timestamp: Int64(Date().timeIntervalSince1970 * 1_000),
            target: UInt256.max,
            fetcher: fetcher
        )

        let bootstrapped = try await ChainTree.bootstrap(
            genesis: try BlockHeader(node: genesis),
            fetcher: fetcher,
            context: testChainContext(genesis: genesis)
        ).get()

        // block + work + validation: bootstrap weighs and executes the
        // genesis in one batch, so it records execution alongside possession.
        let facts = bootstrapped.facts.facts
        XCTAssertEqual(facts.count, 3)
        guard facts.count == 3, case .validation = facts[2] else {
            return XCTFail("bootstrap must record that it executed the genesis")
        }
    }
}
