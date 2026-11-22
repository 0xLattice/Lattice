import XCTest
import UInt256
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeBlockTree
@testable import LatticeImport

/// A tree a host holds as a value: serving a directory it already serves
/// leaves the tree untouched.
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
                timestamp: Int64(height)
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

    /// Serving a directory already served is a no-op and writes nothing:
    /// with a second holder of the tree, a write would trap in DEBUG.
    func testServingAServedDirectoryAgainWritesNothing() throws {
        var tree = try Self.tree(blocks: 3)
        tree.serveRuns(for: "kid")
        let held = tree
        tree.serveRuns(for: "kid")
        XCTAssertEqual(held.canonicalTip, tree.canonicalTip)
    }
}
