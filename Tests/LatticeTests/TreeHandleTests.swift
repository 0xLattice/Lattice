import XCTest
import UInt256
@testable import Lattice
@testable import LatticeBlockTree
@testable import LatticeImport

/// A block's and a grind's handle name it for the tree's lifetime: later
/// blocks, later grinds and stronger work never renumber them, and a copy
/// answers the same.
final class TreeHandleTests: XCTestCase {
    private static func block(_ hash: String, parent: String?, height: UInt64) -> ChainFact {
        let state = testCID("handles:state")
        return .block(ChainBlockFact(
            blockHash: hash, parentBlockHash: parent, blockHeight: height,
            postStateCID: state, prevStateCID: state, specCID: testCID("handles:spec"),
            target: "ff", nextTarget: "ff", timestamp: Int64(height), stateDiff: .empty
        ))
    }

    private static func work(_ id: String, _ work: UInt64, at hash: String) -> ChainFact {
        .work(ChainWorkFact(blockHash: hash, contribution: VerifiedWorkContribution(id: id, work: UInt256(work))))
    }

    func testHandlesStayFixedAsTheTreeGrows() throws {
        let genesis = testCID("handles:genesis")
        let child = testCID("handles:child")
        let sibling = testCID("handles:sibling")
        let grindA = testCID("handles:grind-a")
        let grindB = testCID("handles:grind-b")
        var tree = try ChainTree.restoreWithoutContext(replaying: [
            .staged([Self.block(genesis, parent: nil, height: 0), Self.work(genesis, 1, at: genesis)]),
            .staged([Self.block(child, parent: genesis, height: 1), Self.work(grindA, 1, at: child)]),
        ])

        let genesisHandle = try XCTUnwrap(tree.handle(of: genesis))
        let childHandle = try XCTUnwrap(tree.handle(of: child))
        let grindHandle = try XCTUnwrap(tree.grindHandle(of: grindA, at: child))
        XCTAssertNotEqual(genesisHandle, childHandle)
        XCTAssertNil(tree.handle(of: sibling), "a block not held has no handle")
        XCTAssertNil(tree.grindHandle(of: grindA, at: genesis), "a grind has a handle only where it is credited")
        XCTAssertNil(tree.grindHandle(of: grindB, at: child))

        let copy = tree.detached()
        _ = try tree.applyStaged(.staged([Self.block(sibling, parent: genesis, height: 1), Self.work(grindB, 1, at: sibling)]))
        _ = try tree.applyStaged(.staged([Self.work(grindA, 5, at: child)]))

        XCTAssertEqual(tree.handle(of: genesis), genesisHandle)
        XCTAssertEqual(tree.handle(of: child), childHandle)
        XCTAssertEqual(tree.grindHandle(of: grindA, at: child), grindHandle, "stronger work keeps the grind's handle")
        let siblingHandle = try XCTUnwrap(tree.handle(of: sibling))
        XCTAssertFalse([genesisHandle, childHandle].contains(siblingHandle))
        XCTAssertNotEqual(tree.grindHandle(of: grindB, at: sibling), grindHandle)
        XCTAssertEqual(copy.handle(of: child), childHandle, "a copy answers the same")
        XCTAssertEqual(copy.grindHandle(of: grindA, at: child), grindHandle)
        XCTAssertNil(copy.handle(of: sibling))
    }
}
