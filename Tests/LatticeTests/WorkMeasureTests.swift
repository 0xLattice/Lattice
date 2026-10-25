import XCTest
import UInt256
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport

final class WorkMeasureTests: XCTestCase {
    private func contribution(_ id: String, _ work: UInt64) -> VerifiedWorkContribution {
        VerifiedWorkContribution(id: id, work: UInt256(work))
    }

    func testRepeatedObservationsAtOneLocationCountOnce() {
        let grind = contribution("grind", 7)
        var many = WorkMeasure([grind])
        many.formUnion(WorkMeasure([grind]))
        many.formUnion(WorkMeasure([grind]))

        XCTAssertEqual(Set(many.entries.keys), ["grind"])
        XCTAssertEqual(many.total, WorkSum(UInt256(7)))
    }

    func testStrongestVerifiedValueWinsForOneGrind() {
        let weaker = WorkMeasure([contribution("grind", 7)])
        let stronger = WorkMeasure([contribution("grind", 11)])
        var weakThenStrong = weaker
        var strongThenWeak = stronger
        weakThenStrong.formUnion(stronger)
        strongThenWeak.formUnion(weaker)

        XCTAssertEqual(weakThenStrong.total, WorkSum(UInt256(11)))
        XCTAssertEqual(strongThenWeak.total, WorkSum(UInt256(11)))
    }

    func testInsertReportsWhetherTheMeasureChanged() {
        var measure = WorkMeasure.zero

        XCTAssertTrue(measure.insert(contribution("grind", 11)))
        XCTAssertFalse(measure.insert(contribution("grind", 7)))
        XCTAssertEqual(measure.entries["grind"], UInt256(11))
    }

    func testWorkSumCodableRoundTripAndRejectsMalformedHex() throws {
        let original = WorkSum(UInt256.max) + UInt256(1)
        let encoded = try JSONEncoder().encode(original)

        XCTAssertEqual(try JSONDecoder().decode(WorkSum.self, from: encoded), original)
        XCTAssertEqual(WorkSum(hex: "A"), WorkSum(UInt256(10)))
        XCTAssertNil(WorkSum(hex: ""))
        XCTAssertNil(WorkSum(hex: "not-hex"))
        XCTAssertThrowsError(
            try JSONDecoder().decode(WorkSum.self, from: Data(#""not-hex""#.utf8))
        )
    }

    func testIndependentGrindsSumExactly() {
        let measure = WorkMeasure([
            contribution("first", 7),
            contribution("second", 11),
        ])

        XCTAssertEqual(measure.total, WorkSum(UInt256(18)))
    }

    func testBlockMetadataKeepsStrongestDuplicateRegardlessOfOrder() {
        let weaker = contribution("grind", 7)
        let stronger = contribution("grind", 11)

        for observations in [[weaker, stronger], [stronger, weaker]] {
            let metadata = BlockMeta(
                blockHash: "block",
                parentBlockHash: nil,
                blockHeight: 0,
                childHashes: [],
                workContributions: observations
            )

            XCTAssertEqual(metadata.workContributions["grind"], stronger)
            XCTAssertEqual(metadata.work, WorkSum(UInt256(11)))
        }
    }

    func testBlockMetadataReplacesOnlyTheStrengthenedQuantity() throws {
        var graph = BlockGraph(["block": BlockMeta(
            blockHash: "block",
            parentBlockHash: nil,
            blockHeight: 0,
            childHashes: [],
            workContributions: [
                contribution("shared", 7),
                contribution("independent", 11),
            ]
        )])

        XCTAssertTrue(graph.setWorkContribution(
            contribution("shared", 13), attributed: false, at: "block"
        ))
        let metadata = try XCTUnwrap(graph.meta(of: "block", difficultyAnchor: nil))
        XCTAssertEqual(metadata.workContributions["shared"]?.work, UInt256(13))
        XCTAssertEqual(metadata.work, WorkSum(UInt256(24)))
    }

    func testStrengtheningAtTheSameBlockUpdatesPathOnce() async {
        let original = contribution("strengthened", 2)
        let stronger = contribution("strengthened", 13)
        var root = BlockMeta(
            blockHash: "root",
            parentBlockHash: nil,
            blockHeight: 0,
            childHashes: ["child"],
            workContributions: [contribution("root-work", 1)]
        )
        let child = BlockMeta(
            blockHash: "child",
            parentBlockHash: "root",
            blockHeight: 1,
            childHashes: [],
            workContributions: [original]
        )
        root.childHashes = ["child"]
        let chain = makeChain(blocks: [root, child])
        let result = await chain.addWorkContribution(stronger, to: "child")

        let cumulative = await chain.getCumulativeWork(forHash: "child")
        let subtree = await chain.subtreeWeight(forHash: "root")

        XCTAssertTrue(result.addedContribution)
        XCTAssertEqual(cumulative, WorkSum(UInt256(14)))
        XCTAssertEqual(subtree, WorkSum(UInt256(14)))
    }
}
