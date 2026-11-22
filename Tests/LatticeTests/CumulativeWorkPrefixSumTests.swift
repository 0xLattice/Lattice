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

private func prefixSpec() -> ChainSpec {
    ChainSpec.test()
}

final class CumulativeWorkPrefixSumTests: XCTestCase {
    func testIncrementalPrefixSumEqualsTotalWork() async throws {
        let fetcher = StorableFetcher()
        let base = Int64(Date().timeIntervalSince1970 * 1_000) - 50_000
        let target = UInt256(1_000)
        let perBlock = workForTarget(target)
        let genesis = try await buildAndStoreGenesis(
            spec: prefixSpec(),
            timestamp: base,
            target: target,
            fetcher: fetcher
        )
        var chain = ChainTree.fromGenesis(block: genesis)

        var previous = genesis
        var expected = WorkSum(perBlock)
        for height in 1...5 {
            let block = try await buildAndStoreBlock(
                previous: previous,
                timestamp: base + Int64(height) * 1_000,
                target: target,
                nonce: UInt64(height),
                fetcher: fetcher
            )
            _ = chain.submitTestBlock(blockHeader: try BlockHeader(node: block), block: block)
            previous = block
            expected = expected + perBlock
            let cumulativeWork = chain.getTipCumulativeWork()
            XCTAssertEqual(cumulativeWork, expected)
        }
    }

    func testPrefixSumSurvivesFactReplay() async throws {
        let fetcher = StorableFetcher()
        let base = Int64(Date().timeIntervalSince1970 * 1_000) - 50_000
        let target = UInt256(1_000)
        let genesis = try await buildAndStoreGenesis(
            spec: prefixSpec(),
            timestamp: base,
            target: target,
            fetcher: fetcher
        )
        var chain = ChainTree.fromGenesis(block: genesis)
        var batches = [try testAdmissionBatch(for: genesis)]
        var previous = genesis
        for height in 1...4 {
            let block = try await buildAndStoreBlock(
                previous: previous,
                timestamp: base + Int64(height) * 1_000,
                target: target,
                nonce: UInt64(height),
                fetcher: fetcher
            )
            _ = chain.submitTestBlock(blockHeader: try BlockHeader(node: block), block: block)
            batches.append(try testAdmissionBatch(for: block))
            previous = block
        }

        let before = chain.getTipCumulativeWork()
        let restored = try ChainTree.restoreWithoutContext(replaying: batches)

        let after = restored.getTipCumulativeWork()
        XCTAssertEqual(after, before)
    }

    func testOutOfOrderInsertRepairsDescendantPrefixSum() async throws {
        let fetcher = StorableFetcher()
        let base = Int64(Date().timeIntervalSince1970 * 1_000) - 50_000
        let target = UInt256(1_000)
        let work = workForTarget(target)
        let genesis = try await buildAndStoreGenesis(
            spec: prefixSpec(),
            timestamp: base,
            target: target,
            fetcher: fetcher
        )
        let parent = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: base + 1_000,
            target: target,
            nonce: 1,
            fetcher: fetcher
        )
        let child = try await buildAndStoreBlock(
            previous: parent,
            timestamp: base + 2_000,
            target: target,
            nonce: 2,
            fetcher: fetcher
        )
        let parentHash = try BlockHeader(node: parent).rawCID
        let childHash = try BlockHeader(node: child).rawCID
        var chain = ChainTree.fromGenesis(block: genesis)

        _ = chain.submitTestBlock(blockHeader: try BlockHeader(node: child), block: child)
        let provisional = chain.getCumulativeWork(forHash: childHash)
        XCTAssertEqual(provisional, WorkSum(work))

        _ = chain.submitTestBlock(blockHeader: try BlockHeader(node: parent), block: parent)

        let parentWork = chain.getCumulativeWork(forHash: parentHash)
        let childWork = chain.getCumulativeWork(forHash: childHash)
        XCTAssertEqual(parentWork, WorkSum(work) + work)
        XCTAssertEqual(childWork, WorkSum(work) + work + work)
    }

    func testWorkSumPreservesOverflowedOrdering() {
        XCTAssertEqual(WorkSum(UInt256(3)) + UInt256(4), WorkSum(UInt256(7)))
        let beyondMax = WorkSum(UInt256.max) + UInt256(1)
        XCTAssertGreaterThan(beyondMax, WorkSum(UInt256.max))
        XCTAssertEqual(
            WorkSum(UInt256.max - UInt256(5)) + UInt256(10),
            beyondMax + UInt256(4)
        )
    }

    func testWorkSumPreservesUInt256WordOrder() {
        let values = [
            UInt256(0),
            UInt256(1),
            UInt256(UInt64.max),
            UInt256.max - UInt256(1),
            UInt256.max
        ]

        for value in values {
            XCTAssertEqual(WorkSum(value).toHexString(), value.toHexString())
        }
    }
}
