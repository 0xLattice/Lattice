import Foundation
import XCTest
import UInt256
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport

@MainActor
final class OnDemandWorkTotalsTests: XCTestCase {
    /// Adding a contribution to a block costs the same however many the block
    /// already holds: the run's delta is the one contribution's rise, never
    /// a re-sum of the block. Ratio, not stopwatch: twenty times the
    /// contributions must not cost several times more per addition.
    func testAddingContributionsToOneBlockIsLinear() throws {
        let genesis = testCID("linear-add:genesis")
        let state = testCID("linear-add:state")
        let batch = BlockImportBatch.staged([
            .block(ChainBlockFact(
                blockHash: genesis, parentBlockHash: nil, blockHeight: 0,
                postStateCID: state, prevStateCID: state, specCID: testCID("linear-add:spec"),
                target: "ff", nextTarget: "ff", timestamp: 0, stateDiff: .empty
            )),
            .work(ChainWorkFact(
                blockHash: genesis,
                contribution: VerifiedWorkContribution(id: genesis, work: UInt256(1))
            )),
        ])
        func perAddition(_ count: Int) throws -> Double {
            var tree = try ChainTree.restoreWithoutContext(replaying: [batch])
            tree.serveRuns(for: "child")
            let contributions = (0..<count).map {
                VerifiedWorkContribution(id: testCID("linear-add:\(count):\($0)"), work: UInt256(2))
            }
            let start = DispatchTime.now().uptimeNanoseconds
            for contribution in contributions {
                XCTAssertTrue(tree.addWorkContribution(contribution, to: genesis).addedContribution)
            }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / Double(count)
        }
        _ = try perAddition(500)
        let few = try perAddition(500)
        let many = try perAddition(10_000)
        XCTAssertLessThan(many / few, 3, "per-addition cost grew with the block's contributions")
    }

    /// The diagnostic totals are derived on demand: no block carries them.
    func testLinearAdmissionsAnswerLocalTotalsOnDemand() async throws {
        let (chain, hashes) = try await lazyCacheLinearChain(count: 6)
        let rootHash = hashes[0]
        let tipHash = hashes[5]

        let rootWeight = await chain.subtreeWeight(forHash: rootHash)
        XCTAssertEqual(rootWeight, WorkSum(UInt256(21)))
        let tipWork = await chain.getCumulativeWork(forHash: tipHash)
        XCTAssertEqual(tipWork, WorkSum(UInt256(21)))
    }

    func testFactReplayRebuildsDerivedLocalTotalsWithoutMutatingSource() async throws {
        let (chain, hashes) = try await lazyCacheLinearChain(count: 6)
        let rootHash = hashes[0]
        let tipHash = hashes[5]

        let restored = try await ChainState.restoreWithoutContext(replaying: hashes.indices.map {
            lazyCacheAdmission(
                index: $0,
                hash: hashes[$0],
                parentHash: $0 == 0 ? nil : hashes[$0 - 1]
            )
        })
        let restoredTip = await restored.canonicalTip
        let restoredRootWork = await restored.subtreeWeight(forHash: rootHash)
        let restoredTipWork = await restored.getCumulativeWork(forHash: tipHash)
        let liveRootWork = await chain.subtreeWeight(forHash: rootHash)
        XCTAssertEqual(restoredTip, tipHash)
        XCTAssertEqual(restoredRootWork, WorkSum(UInt256(21)))
        XCTAssertEqual(restoredTipWork, WorkSum(UInt256(21)))
        XCTAssertEqual(liveRootWork, restoredRootWork)
    }

    /// Crediting further grinds to held blocks, asking first whether each is
    /// credited, moves fork choice exactly as a rebuild from the facts does —
    /// through an equal-work tie.
    func testCreditingGrindsMatchesAFullRebuildWithoutRebuildingLocalTotals() async throws {
        let fork = try await lazyCacheFork(branchLength: 12)
        var facts = fork.facts
        // Left leads, right overtakes, left draws level: the last is a tie.
        let credits: [(branch: [String], depth: Int, work: UInt64)] = [
            (fork.left, 3, 5), (fork.right, 11, 9), (fork.left, 0, 2),
            (fork.right, 6, 1), (fork.left, 11, 3),
        ]
        for (index, credit) in credits.enumerated() {
            let block = credit.branch[credit.depth]
            let id = testCID("lazy-local-cache-credit-\(index)")
            let held = await fork.chain.workContribution(id: id, at: block)
            XCTAssertNil(held)
            let batch = lazyCacheWork(blockHash: block, id: id, work: credit.work)
            _ = try await fork.chain.applyStaged(batch)
            facts.append(batch)
            let credited = await fork.chain.workContribution(id: id, at: block)
            XCTAssertEqual(credited?.work, UInt256(credit.work))

            let rebuilt = try await ChainState.restoreWithoutContext(replaying: facts)
            let snapshot = await fork.chain.forkChoiceSnapshot(startingAt: fork.root)
            let rebuiltSnapshot = await rebuilt.forkChoiceSnapshot(startingAt: fork.root)
            XCTAssertNotNil(snapshot)
            XCTAssertEqual(snapshot, rebuiltSnapshot)
            let tip = await fork.chain.canonicalTip
            let rebuiltTip = await rebuilt.canonicalTip
            XCTAssertEqual(tip, rebuiltTip)
        }
        // The tie: equal work under the two siblings, the smaller CID wins.
        let leftWeight = await fork.chain.forkChoice.weight(of: fork.left[0])
        let rightWeight = await fork.chain.forkChoice.weight(of: fork.right[0])
        XCTAssertEqual(leftWeight, rightWeight)
        let winner = forkChoicePrefersBlock(fork.left[0], over: fork.right[0]) ? fork.left : fork.right
        let tip = await fork.chain.canonicalTip
        XCTAssertEqual(tip, winner.last)

        // Fork choice's weights are the full recompute's, block by block.
        for hash in [fork.root] + fork.left + fork.right {
            let weight = await fork.chain.forkChoice.weight(of: hash)
            let recomputed = await fork.chain.subtreeWeight(forHash: hash)
            XCTAssertEqual(weight, recomputed)
            // The public read is the snapshot's weight, without the descent.
            let read = await fork.chain.forkChoiceWeight(of: hash)
            let snapshot = await fork.chain.forkChoiceSnapshot(startingAt: hash)
            XCTAssertEqual(read, snapshot?.subtreeWork)
            XCTAssertEqual(read, weight)
        }
        // The direct question answers as the block's full view does, for every
        // grind at every block, a grind asked at another block, and an unknown
        // grind or block.
        let ids = credits.indices.map { testCID("lazy-local-cache-credit-\($0)") } + [testCID("lazy-local-cache-unknown")]
        for hash in [fork.root] + fork.left + fork.right + [testCID("lazy-local-cache-no-block")] {
            let view = await fork.chain.getConsensusBlock(hash: hash)
            if view == nil {
                let read = await fork.chain.forkChoiceWeight(of: hash)
                let snapshot = await fork.chain.forkChoiceSnapshot(startingAt: hash)
                XCTAssertNil(read)
                XCTAssertNil(snapshot)
            }
            for id in ids {
                let direct = await fork.chain.workContribution(id: id, at: hash)
                XCTAssertEqual(direct != nil, view?.workContributions[id] != nil, "\(id) at \(hash)")
            }
        }
    }

    func testCreditingAGrindDoesNotScaleWithTheTree() async throws {
        var cells: [UInt64] = []
        for branchLength in [16, 256] {
            let fork = try await lazyCacheFork(branchLength: branchLength)
            let cellsBefore = await fork.chain.segmentWorkUpdateCellCount
            for index in 0..<8 {
                let block = (index.isMultiple(of: 2) ? fork.left : fork.right)[index]
                let id = testCID("lazy-local-cache-credit-\(index)")
                let held = await fork.chain.workContribution(id: id, at: block)
                XCTAssertNil(held)
                _ = try await fork.chain.applyStaged(
                    lazyCacheWork(blockHash: block, id: id, work: UInt64(index + 1))
                )
            }
            let cellsAfter = await fork.chain.segmentWorkUpdateCellCount
            cells.append(cellsAfter - cellsBefore)
        }
        // Sixteen times the blocks, and the weight update grows by a few tree
        // levels, not with the blocks.
        XCTAssertGreaterThan(cells[0], 0)
        XCTAssertLessThan(cells[1], cells[0] * 2)
    }
}

/// A root with two sibling branches of `branchLength` blocks, one unit of work
/// per block, so the branches weigh the same until something is credited.
private func lazyCacheFork(
    branchLength: Int
) async throws -> (chain: ChainState, facts: [BlockImportBatch], root: String, left: [String], right: [String]) {
    let root = testCID("lazy-local-cache-fork-root")
    func block(_ hash: String, parent: String?, height: Int) -> BlockImportBatch {
        BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: hash,
                parentBlockHash: parent,
                blockHeight: UInt64(height),
                postStateCID: testCID("lazy-local-cache-post-\(hash)"),
                prevStateCID: testCID("lazy-local-cache-prev-\(hash)"),
                specCID: testCID("lazy-local-cache-spec"),
                target: "1",
                nextTarget: "1",
                timestamp: Int64(height),
                stateDiff: .empty
            )),
            .work(ChainWorkFact(blockHash: hash, contribution: VerifiedWorkContribution(
                id: testCID("lazy-local-cache-work-\(hash)"),
                work: UInt256(1)
            ))),
        ])
    }
    var facts = [block(root, parent: nil, height: 0)]
    let chain = try await ChainState.restoreWithoutContext(replaying: facts)
    var branches: [[String]] = []
    for side in ["left", "right"] {
        var parent = root
        var hashes: [String] = []
        for depth in 0..<branchLength {
            let hash = testCID("lazy-local-cache-fork-\(side)-\(depth)")
            let batch = block(hash, parent: parent, height: depth + 1)
            _ = try await chain.applyStaged(batch)
            facts.append(batch)
            hashes.append(hash)
            parent = hash
        }
        branches.append(hashes)
    }
    return (chain, facts, root, branches[0], branches[1])
}

private func lazyCacheWork(blockHash: String, id: String, work: UInt64) -> BlockImportBatch {
    BlockImportBatch(facts: [
        .work(ChainWorkFact(
            blockHash: blockHash,
            contribution: VerifiedWorkContribution(id: id, work: UInt256(work))
        )),
    ])
}

private func lazyCacheLinearChain(
    count: Int
) async throws -> (ChainState, [String]) {
    precondition(count > 0)
    let hashes = (0..<count).map { testCID("lazy-local-cache-\($0)") }
    let chain = try await ChainState.restoreWithoutContext(replaying: [
        lazyCacheAdmission(index: 0, hash: hashes[0], parentHash: nil),
    ])
    for index in 1..<count {
        _ = try await chain.applyStaged(lazyCacheAdmission(
            index: index,
            hash: hashes[index],
            parentHash: hashes[index - 1]
        ))
    }
    return (chain, hashes)
}

private func lazyCacheAdmission(
    index: Int,
    hash: String,
    parentHash: String?
) -> BlockImportBatch {
    let contribution = VerifiedWorkContribution(
        id: testCID("lazy-local-cache-work-\(index)"),
        work: UInt256(index + 1)
    )
    return BlockImportBatch(facts: [
        .block(ChainBlockFact(
            blockHash: hash,
            parentBlockHash: parentHash,
            blockHeight: UInt64(index),
            postStateCID: testCID("lazy-local-cache-post-\(index)"),
            prevStateCID: testCID("lazy-local-cache-prev-\(index)"),
            specCID: testCID("lazy-local-cache-spec-\(index)"),
            target: "1",
            nextTarget: "1",
            timestamp: Int64(index),
            stateDiff: .empty
        )),
        .work(ChainWorkFact(blockHash: hash, contribution: contribution)),
    ])
}
