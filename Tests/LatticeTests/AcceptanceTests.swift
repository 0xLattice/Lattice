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

private let fetcher = ThrowingFetcher()

private func acceptanceSpec() -> ChainSpec {
    ChainSpec.test()
}

// MARK: - Full Pipeline Acceptance Test

@MainActor
final class FullPipelineAcceptanceTests: XCTestCase {

    func testBuildMineSubmitBroadcastCycle() async throws {
        let spec = acceptanceSpec()
        let genesis = try await buildAndStoreGenesis(
            spec: spec, timestamp: 1_000_000, target: UInt256.max, fetcher: fetcher
        )
        var chain = ChainTree.fromGenesis(block: genesis)

        let block1 = try await buildAndStoreBlock(
            previous: genesis, timestamp: 2_000_000,
            target: UInt256.max, nonce: 1, fetcher: fetcher
        )
        let mined = BlockBuilder.mine(block: block1, target: UInt256.max, maxAttempts: 10)
        XCTAssertNotNil(mined)

        let header = try! VolumeImpl<Block>(node: mined!)
        let result = chain.submitTestBlock(
            blockHeader: header, block: mined!
        )
        XCTAssertTrue(result.extendsCanonical)

        let tip = chain.canonicalTip
        XCTAssertEqual(tip, header.rawCID)
    }

}
