import XCTest
import UInt256
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeBlockTree
@testable import LatticeImport

/// `ChainLevel(tree:)` hands a host job its own level: independent of the
/// source, and at a cost that does not grow with the chain's history.
final class ChainLevelFromTreeTests: XCTestCase {
    private static func batch(_ height: UInt64, tag: String = "") -> BlockImportBatch {
        let name = "\(tag)\(height)"
        let parent: String? = height == 0 ? nil : testCID("level-copy:\(height - 1)")
        let hash = testCID(tag.isEmpty ? "level-copy:\(height)" : "level-copy:\(name)")
        return BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: hash,
                parentBlockHash: parent,
                blockHeight: height,
                postStateCID: testCID("level-copy:post:\(name)"),
                prevStateCID: testCID("level-copy:prev:\(name)"),
                specCID: testCID("level-copy:spec"),
                target: "1",
                nextTarget: "1",
                timestamp: Int64(height),
                stateDiff: .empty
            )),
            .work(ChainWorkFact(
                blockHash: hash,
                contribution: VerifiedWorkContribution(
                    id: testCID("level-copy:work:\(name)"), work: UInt256(1)
                )
            )),
        ])
    }

    private static func tree(blocks: UInt64) throws -> ChainTree {
        let context = try ChainRuntimeContext(path: [DEFAULT_ROOT_DIRECTORY, "Payments"])
        return try ChainTree.restore(
            replaying: (0..<blocks).map { batch($0) }, context: context
        )
    }

    /// A level takes over the tree it is given: the caller hands its one
    /// reference over, and the level mutates it in place. (A tree still held
    /// elsewhere must not be mutated — the runtime owns one live tree — which
    /// traps in DEBUG.)
    func testALevelMutatesTheTreeItWasHanded() async throws {
        let level = try XCTUnwrap(ChainLevel(tree: try Self.tree(blocks: 10)))

        _ = try await level.chain.applyStaged(Self.batch(10))

        let height = await level.chain.getHighestBlockHeight()
        XCTAssertEqual(height, 10)
    }

    func testATreeWithoutContextHasNoLevel() throws {
        XCTAssertNil(ChainLevel(tree: try ChainTree.restoreWithoutContext(
            replaying: [Self.batch(0)]
        )))
    }

    /// Ratio, not stopwatch: 100x the history must not cost ~100x per copy.
    func testCopyCostDoesNotGrowWithHistory() async throws {
        let small = try Self.tree(blocks: 20)
        let large = try Self.tree(blocks: 2_000)
        func cost(_ tree: ChainTree) async -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<2_000 {
                let level = ChainLevel(tree: tree)!
                _ = await level.chain.canonicalTip
            }
            return Double(DispatchTime.now().uptimeNanoseconds - start)
        }
        _ = await cost(small)
        let smallCost = await cost(small)
        let largeCost = await cost(large)
        XCTAssertLessThan(largeCost / smallCost, 10, "copy cost grew with history")
    }
}
