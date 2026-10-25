import Foundation
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

private func bucketFetcher() -> StorableFetcher { StorableFetcher() }

private func bucketSpec() -> ChainSpec {
    ChainSpec.test()
}

final class ConsensusForkChoiceBucketATests: XCTestCase {
    private var forkMainSet: Set<String> { [blockCID("G"), blockCID("M1"), blockCID("M2")] }

    private func forkDag() -> [BlockMeta] {
        let mainWork = UInt256(2)
        let forkWork = UInt256(1)
        return [
            makeBlockMeta(hash: blockCID("G"), height: 0, childHashes: [blockCID("M1"), blockCID("F1")], work: forkWork),
            makeBlockMeta(hash: blockCID("M1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("M2")], work: mainWork),
            makeBlockMeta(hash: blockCID("M2"), previousHash: blockCID("M1"), height: 2, work: mainWork),
            makeBlockMeta(hash: blockCID("F1"), previousHash: blockCID("G"), height: 1, childHashes: [blockCID("F2")], work: forkWork),
            makeBlockMeta(hash: blockCID("F2"), previousHash: blockCID("F1"), height: 2, childHashes: [blockCID("F3")], work: forkWork),
            makeBlockMeta(hash: blockCID("F3"), previousHash: blockCID("F2"), height: 3, childHashes: [blockCID("F4")], work: forkWork),
            makeBlockMeta(hash: blockCID("F4"), previousHash: blockCID("F3"), height: 4, childHashes: [blockCID("F5")], work: forkWork),
            makeBlockMeta(hash: blockCID("F5"), previousHash: blockCID("F4"), height: 5, work: forkWork),
        ]
    }

    func testStrictlyHeavierFullyAvailableBranchWins() async {
        let chain = makeChain(blocks: forkDag(), canonicalHashes: forkMainSet)
        _ = await chain.reevaluateForkChoice()

        let tip = await chain.canonicalTip
        XCTAssertEqual(tip, blockCID("F5"))
    }

    func testTipCumulativeWorkIsExactBeyondUInt256() async throws {
        let fetcher = bucketFetcher()
        let base = Int64(Date().timeIntervalSince1970 * 1_000) - 50_000
        let target = UInt256(1)
        let genesis = try await buildAndStoreGenesis(
            spec: bucketSpec(),
            timestamp: base,
            target: target,
            fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)
        let block = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: base + 1_000,
            target: target,
            nextTarget: target,
            nonce: 1,
            fetcher: fetcher
        )

        _ = await chain.submitTestBlock(blockHeader: try BlockHeader(node: block), block: block)

        // Two blocks at target 1 each carry workForTarget(1) = 2^255, so the
        // cumulative work is 2^256 — beyond a single UInt256 (exercises WorkSum's
        // wide accumulation). Track the formula rather than a hardcoded literal.
        let unit = workForTarget(target)
        let cumulativeWork = await chain.getTipCumulativeWork()
        XCTAssertEqual(cumulativeWork, WorkSum(unit) + unit)
        XCTAssertGreaterThan(cumulativeWork, WorkSum(UInt256.max))
    }

}
