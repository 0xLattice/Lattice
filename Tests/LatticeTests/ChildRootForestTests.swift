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

private func childForestSpec() -> ChainSpec {
    ChainSpec.test()
}

private func childForestHash(_ block: Block) -> String {
    try! BlockHeader(node: block).rawCID
}

private func preferredChildForestHash(_ first: String, _ second: String) -> String {
    forkChoicePrefersBlock(first, over: second) ? first : second
}

@discardableResult
private func submitChildForestBlock(_ block: Block, to chain: inout ChainTree) -> SubmissionResult {
    chain.submitTestBlock(blockHeader: try! BlockHeader(node: block), block: block)
}

private func makeChildForestRoots() async throws -> (StorableFetcher, Block, Block) {
    let fetcher = StorableFetcher()
    let first = try await buildAndStoreGenesis(
        spec: childForestSpec(),
        timestamp: 1_000_000,
        target: UInt256.max,
        nonce: 1,
        fetcher: fetcher
    )
    let second = try await buildAndStoreGenesis(
        spec: childForestSpec(),
        timestamp: 1_001_000,
        target: UInt256.max,
        nonce: 2,
        fetcher: fetcher
    )
    return (fetcher, first, second)
}

@MainActor
final class ChildRootForestTests: XCTestCase {
    func testExactTieChoosesTheSameRootByCID() async throws {
        let (_, first, second) = try await makeChildForestRoots()
        let firstHash = childForestHash(first)
        let secondHash = childForestHash(second)
        let expectedTip = preferredChildForestHash(firstHash, secondHash)
        var firstIncumbent = ChainTree.fromGenesis(block: first)
        var secondIncumbent = ChainTree.fromGenesis(block: second)

        let firstResult = submitChildForestBlock(second, to: &firstIncumbent)
        let secondResult = submitChildForestBlock(first, to: &secondIncumbent)
        let firstTip = firstIncumbent.canonicalTip
        let secondTip = secondIncumbent.canonicalTip
        let firstContainsSecond = firstIncumbent.contains(blockHash: secondHash)
        let secondContainsFirst = secondIncumbent.contains(blockHash: firstHash)

        XCTAssertTrue(firstResult.addedBlock)
        XCTAssertTrue(secondResult.addedBlock)
        XCTAssertEqual(firstTip, expectedTip)
        XCTAssertEqual(secondTip, expectedTip)
        XCTAssertTrue(firstContainsSecond)
        XCTAssertTrue(secondContainsFirst)
    }

    func testEqualWorkIgnoresNextTargetAndChoosesSegmentBaseCID() async throws {
        let (fetcher, genesis, _) = try await makeChildForestRoots()
        let harder = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 1_000,
            target: UInt256.max,
            nextTarget: UInt256.max / UInt256(2),
            nonce: 10,
            fetcher: fetcher
        )
        let easier = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 2_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            nonce: 11,
            fetcher: fetcher
        )
        let expectedTip = preferredChildForestHash(
            childForestHash(harder),
            childForestHash(easier)
        )
        var harderFirst = ChainTree.fromGenesis(block: genesis)
        var easierFirst = ChainTree.fromGenesis(block: genesis)

        submitChildForestBlock(harder, to: &harderFirst)
        submitChildForestBlock(easier, to: &harderFirst)
        submitChildForestBlock(easier, to: &easierFirst)
        submitChildForestBlock(harder, to: &easierFirst)

        let harderFirstTip = harderFirst.canonicalTip
        let easierFirstTip = easierFirst.canonicalTip
        let restoredHarderFirst = try ChainTree.restoreWithoutContext(replaying: [
            testAdmissionBatch(for: genesis),
            testAdmissionBatch(for: harder),
            testAdmissionBatch(for: easier),
        ])
        let restoredEasierFirst = try ChainTree.restoreWithoutContext(replaying: [
            testAdmissionBatch(for: genesis),
            testAdmissionBatch(for: easier),
            testAdmissionBatch(for: harder),
        ])
        let restoredHarderFirstTip = restoredHarderFirst.canonicalTip
        let restoredEasierFirstTip = restoredEasierFirst.canonicalTip
        XCTAssertEqual(harderFirstTip, expectedTip)
        XCTAssertEqual(easierFirstTip, expectedTip)
        XCTAssertEqual(restoredHarderFirstTip, expectedTip)
        XCTAssertEqual(restoredEasierFirstTip, expectedTip)
    }

    func testEqualWorkChoosesTheSameSegmentBaseByCID() async throws {
        let (fetcher, genesis, _) = try await makeChildForestRoots()
        let first = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 1_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            nonce: 12,
            fetcher: fetcher
        )
        let second = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 2_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            nonce: 13,
            fetcher: fetcher
        )
        let expectedTip = preferredChildForestHash(
            childForestHash(first),
            childForestHash(second)
        )
        var firstOrder = ChainTree.fromGenesis(block: genesis)
        var secondOrder = ChainTree.fromGenesis(block: genesis)

        submitChildForestBlock(first, to: &firstOrder)
        submitChildForestBlock(second, to: &firstOrder)
        submitChildForestBlock(second, to: &secondOrder)
        submitChildForestBlock(first, to: &secondOrder)

        let firstTip = firstOrder.canonicalTip
        let secondTip = secondOrder.canonicalTip
        XCTAssertEqual(firstTip, expectedTip)
        XCTAssertEqual(secondTip, expectedTip)
    }

    func testTieBreakComparesSegmentBasesNotTips() async throws {
        let (fetcher, genesis, _) = try await makeChildForestRoots()
        let firstBase = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 1_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            nonce: 14,
            fetcher: fetcher
        )
        let secondBase = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 2_000,
            target: UInt256.max,
            nextTarget: UInt256.max / UInt256(2),
            nonce: 15,
            fetcher: fetcher
        )
        let firstLeaf = try await buildAndStoreBlock(
            previous: firstBase,
            timestamp: genesis.timestamp + 3_000,
            target: UInt256.max,
            nextTarget: UInt256.max / UInt256(4),
            nonce: 16,
            fetcher: fetcher
        )
        let secondLeaf = try await buildAndStoreBlock(
            previous: secondBase,
            timestamp: genesis.timestamp + 4_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            nonce: 17,
            fetcher: fetcher
        )
        var chain = ChainTree.fromGenesis(block: genesis)

        for block in [secondBase, secondLeaf, firstBase, firstLeaf] {
            submitChildForestBlock(block, to: &chain)
        }

        let preferredBaseHash = preferredChildForestHash(
            childForestHash(firstBase),
            childForestHash(secondBase)
        )
        let expectedTip = preferredBaseHash == childForestHash(firstBase)
            ? childForestHash(firstLeaf)
            : childForestHash(secondLeaf)
        let tip = chain.canonicalTip
        XCTAssertEqual(tip, expectedTip)
    }

    func testGreaterTrueCumWorkWinsBeforeEasierTarget() async throws {
        let (fetcher, genesis, _) = try await makeChildForestRoots()
        let greaterWork = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 1_000,
            target: UInt256.max / UInt256(2),
            nextTarget: UInt256(1),
            nonce: 18,
            fetcher: fetcher
        )
        let easierNext = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: genesis.timestamp + 2_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            nonce: 19,
            fetcher: fetcher
        )
        var greaterFirst = ChainTree.fromGenesis(block: genesis)
        var easierFirst = ChainTree.fromGenesis(block: genesis)

        submitChildForestBlock(greaterWork, to: &greaterFirst)
        submitChildForestBlock(easierNext, to: &greaterFirst)
        submitChildForestBlock(easierNext, to: &easierFirst)
        submitChildForestBlock(greaterWork, to: &easierFirst)

        let expectedTip = childForestHash(greaterWork)
        let greaterFirstTip = greaterFirst.canonicalTip
        let easierFirstTip = easierFirst.canonicalTip
        XCTAssertEqual(greaterFirstTip, expectedTip)
        XCTAssertEqual(easierFirstTip, expectedTip)
    }

    func testStrictlyHeavierRootForestIsIndependentOfInsertionOrder() async throws {
        let (fetcher, incumbentRoot, sideRoot) = try await makeChildForestRoots()
        let sideChild = try await buildAndStoreBlock(
            previous: sideRoot,
            timestamp: sideRoot.timestamp + 1_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            nonce: 3,
            fetcher: fetcher
        )
        let expectedTip = childForestHash(sideChild)
        var parentFirst = ChainTree.fromGenesis(block: incumbentRoot)
        var childFirst = ChainTree.fromGenesis(block: incumbentRoot)

        submitChildForestBlock(sideRoot, to: &parentFirst)
        submitChildForestBlock(sideChild, to: &parentFirst)

        submitChildForestBlock(sideChild, to: &childFirst)
        let requirements = childFirst.unresolvedSameChainPredecessors()
        XCTAssertEqual(
            requirements,
            [SameChainPredecessorRequirement(
                descendantCID: childForestHash(sideChild),
                predecessorCID: childForestHash(sideRoot)
            )]
        )
        submitChildForestBlock(sideRoot, to: &childFirst)

        let parentFirstTip = parentFirst.canonicalTip
        let childFirstTip = childFirst.canonicalTip
        XCTAssertEqual(parentFirstTip, expectedTip)
        XCTAssertEqual(childFirstTip, expectedTip)
    }

    func testRootArrivalKeepsSelectedDescendantSnapshot() async throws {
        let (fetcher, incumbentRoot, sideRoot) = try await makeChildForestRoots()
        let child = try await buildAndStoreBlock(
            previous: sideRoot,
            timestamp: sideRoot.timestamp + 1_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            nonce: 5,
            fetcher: fetcher
        )
        var chain = ChainTree.fromGenesis(block: incumbentRoot)

        submitChildForestBlock(child, to: &chain)
        submitChildForestBlock(sideRoot, to: &chain)

        let snapshot = chain.tipSnapshot
        let tip = chain.canonicalTip
        XCTAssertEqual(tip, childForestHash(child))
        XCTAssertEqual(snapshot?.tipHeight, child.height)
        XCTAssertEqual(snapshot?.postStateCID, child.postState.rawCID)
        XCTAssertEqual(snapshot?.prevStateCID, child.prevState.rawCID)
    }

    func testForestFactReplayRestoresEveryRootAndCanonicalTip() async throws {
        let (fetcher, incumbentRoot, sideRoot) = try await makeChildForestRoots()
        let sideChild = try await buildAndStoreBlock(
            previous: sideRoot,
            timestamp: sideRoot.timestamp + 1_000,
            target: UInt256.max,
            nextTarget: UInt256.max,
            nonce: 4,
            fetcher: fetcher
        )
        var chain = ChainTree.fromGenesis(block: incumbentRoot)
        submitChildForestBlock(sideRoot, to: &chain)
        submitChildForestBlock(sideChild, to: &chain)
        let canonicalTip = chain.canonicalTip

        let restored = try ChainTree.restoreWithoutContext(replaying: [
            testAdmissionBatch(for: incumbentRoot),
            testAdmissionBatch(for: sideRoot),
            testAdmissionBatch(for: sideChild),
        ])

        let restoredTip = restored.canonicalTip
        let containsIncumbent = restored.contains(blockHash: childForestHash(incumbentRoot))
        let containsSideRoot = restored.contains(blockHash: childForestHash(sideRoot))
        let containsSideChild = restored.contains(blockHash: childForestHash(sideChild))
        XCTAssertEqual(restoredTip, canonicalTip)
        XCTAssertTrue(containsIncumbent)
        XCTAssertTrue(containsSideRoot)
        XCTAssertTrue(containsSideChild)
    }

}
