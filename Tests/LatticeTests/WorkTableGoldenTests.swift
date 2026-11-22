import XCTest
import UInt256
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport

/// `workForTarget` and `calculateAsertTarget` over a fixed table of inputs,
/// results pinned as hex. These are consensus arithmetic: an off-by-one at an
/// edge changes which chain is heavier or which target a block must beat.
/// The `workForHash` column is the hash-based work Lattice no longer ships
/// (consensus prices work from the target); it is kept, from the 56.3
/// reference, so the checked-in golden stays byte-identical.
struct WorkTableGolden: Codable, Equatable {
    struct WorkEntry: Codable, Equatable {
        let name: String
        let input: String
        let workForTarget: String
        let workForHash: String
    }

    struct AsertEntry: Codable, Equatable {
        let name: String
        let targetBlockTime: UInt64
        let halfLife: UInt64
        let anchorTarget: String
        let anchorTimestamp: Int64
        let anchorHeight: UInt64
        let blockTimestamp: Int64
        let blockHeight: UInt64
        let target: String
    }

    let work: [WorkEntry]
    let asert: [AsertEntry]

    static func diff(expected: WorkTableGolden, actual: WorkTableGolden) -> [String] {
        var lines: [String] = []
        let actualWork = Dictionary(uniqueKeysWithValues: actual.work.map { ($0.name, $0) })
        for entry in expected.work {
            guard let other = actualWork[entry.name] else {
                lines.append("work \(entry.name): missing from actual")
                continue
            }
            lines += GoldenFile.fieldDiff("work \(entry.name)", [
                ("input", entry.input, other.input),
                ("workForTarget", entry.workForTarget, other.workForTarget),
                ("workForHash", entry.workForHash, other.workForHash),
            ])
        }
        let actualAsert = Dictionary(uniqueKeysWithValues: actual.asert.map { ($0.name, $0) })
        for entry in expected.asert {
            guard let other = actualAsert[entry.name] else {
                lines.append("asert \(entry.name): missing from actual")
                continue
            }
            lines += GoldenFile.fieldDiff("asert \(entry.name)", [
                ("inputs", "\(entry.targetBlockTime)/\(entry.halfLife)/\(entry.anchorTarget)/\(entry.anchorTimestamp)/\(entry.anchorHeight)/\(entry.blockTimestamp)/\(entry.blockHeight)",
                 "\(other.targetBlockTime)/\(other.halfLife)/\(other.anchorTarget)/\(other.anchorTimestamp)/\(other.anchorHeight)/\(other.blockTimestamp)/\(other.blockHeight)"),
                ("target", entry.target, other.target),
            ])
        }
        for name in Set(actualWork.keys).subtracting(expected.work.map(\.name)).sorted() {
            lines.append("work \(name): unexpected in actual")
        }
        for name in Set(actualAsert.keys).subtracting(expected.asert.map(\.name)).sorted() {
            lines.append("asert \(name): unexpected in actual")
        }
        return lines
    }
}

final class WorkTableGoldenTests: XCTestCase {
    static let goldenName = "work-table.json"

    private static let workInputs: [(String, UInt256)] = [
        ("zero", .zero),
        ("one", UInt256(1)),
        ("two", UInt256(2)),
        ("three", UInt256(3)),
        ("thousand", UInt256(1_000)),
        ("2^64", UInt256(1) << UInt256(64)),
        ("2^64-1", UInt256(UInt64.max)),
        ("2^128", UInt256(1) << UInt256(128)),
        ("2^224-1", (UInt256(1) << UInt256(224)) - UInt256(1)),
        ("2^255", UInt256(1) << UInt256(255)),
        ("max/2", UInt256.max / UInt256(2)),
        ("max-1", UInt256.max - UInt256(1)),
        ("max", UInt256.max),
    ]

    private struct AsertCase {
        let name: String
        var targetBlockTime: UInt64 = 1_000
        var halfLife: UInt64 = 120
        var anchorTarget: UInt256 = UInt256(1) << UInt256(200)
        var anchorTimestamp: Int64 = 1_000_000
        var anchorHeight: UInt64 = 1
        let blockTimestamp: Int64
        let blockHeight: UInt64
    }

    /// Half-life = 120 blocks × 1 s = 120 000 ms. "Ahead" means elapsed time
    /// below schedule (target hardens); "behind" means above (target eases).
    private static let asertCases: [AsertCase] = [
        AsertCase(name: "onSchedule", blockTimestamp: 1_000_000 + 200_000, blockHeight: 201),
        AsertCase(name: "oneHalfLifeAhead", blockTimestamp: 1_000_000 + 80_000, blockHeight: 201),
        AsertCase(name: "oneHalfLifeBehind", blockTimestamp: 1_000_000 + 320_000, blockHeight: 201),
        AsertCase(name: "halfAHalfLifeBehind", blockTimestamp: 1_000_000 + 260_000, blockHeight: 201),
        AsertCase(name: "halfAHalfLifeAhead", blockTimestamp: 1_000_000 + 140_000, blockHeight: 201),
        AsertCase(name: "oneMillisecondBehind", blockTimestamp: 1_000_000 + 200_001, blockHeight: 201),
        AsertCase(name: "oneMillisecondAhead", blockTimestamp: 1_000_000 + 199_999, blockHeight: 201),
        AsertCase(name: "nextBlockOnSchedule", blockTimestamp: 1_000_000 + 1_000, blockHeight: 2),
        AsertCase(name: "atAnchorHeight", blockTimestamp: 1_000_000 + 5_000, blockHeight: 1),
        AsertCase(name: "belowAnchorHeight", anchorHeight: 5, blockTimestamp: 1_000_000, blockHeight: 2),
        AsertCase(name: "timestampBeforeAnchor", blockTimestamp: 999_000, blockHeight: 201),
        AsertCase(name: "anchorAtMax_onSchedule", anchorTarget: .max, blockTimestamp: 1_000_000 + 200_000, blockHeight: 201),
        AsertCase(name: "anchorAtMax_oneBlockAhead", anchorTarget: .max, blockTimestamp: 1_000_000 + 1_000, blockHeight: 3),
        AsertCase(name: "anchorAtMax_behind", anchorTarget: .max, blockTimestamp: 1_000_000 + 320_000, blockHeight: 201),
        AsertCase(name: "anchorAtOne_ahead", anchorTarget: UInt256(1), blockTimestamp: 1_000_000 + 80_000, blockHeight: 201),
        AsertCase(name: "anchorAtOne_behind", anchorTarget: UInt256(1), blockTimestamp: 1_000_000 + 320_000, blockHeight: 201),
        AsertCase(name: "anchorAtZero", anchorTarget: .zero, blockTimestamp: 1_000_000 + 200_000, blockHeight: 201),
        AsertCase(name: "saturatingDriftBehind", blockTimestamp: Int64.max, blockHeight: 201),
        AsertCase(name: "clampedElapsedAtTimestampExtremes", anchorTimestamp: Int64.max, blockTimestamp: Int64.min, blockHeight: 201),
        AsertCase(name: "heightOverflow", blockTimestamp: 1_000_000 + 200_000, blockHeight: UInt64.max),
        AsertCase(name: "negativeAnchorTimestamp", anchorTimestamp: -500_000, blockTimestamp: -300_000, blockHeight: 201),
        AsertCase(name: "halfLifeOverflow", targetBlockTime: UInt64.max, halfLife: UInt64.max, blockTimestamp: 1_000_000 + 200_000, blockHeight: 201),
        // 60 half-lives of drift each way: 2^60 doublings saturate; 2^-60 halvings stay exact.
        AsertCase(name: "sixtyHalfLivesBehind", blockTimestamp: 1_000_000 + 200_000 + 120_000 * 60, blockHeight: 201),
        AsertCase(name: "sixtyHalfLivesAhead", blockTimestamp: 1_000_000 + 200_000, blockHeight: 201 + 120 * 60),
        AsertCase(name: "threeHundredHalfLivesAhead", blockTimestamp: 1_000_000 + 200_000, blockHeight: 201 + 120 * 300),
    ]

    func testWorkFunctionsMatchGolden() throws {
        let work = Self.workInputs.map { name, input in
            WorkTableGolden.WorkEntry(
                name: name,
                input: input.toHexString(),
                workForTarget: workForTarget(input).toHexString(),
                workForHash: ArithmeticDifferentialTests.referenceWorkForHash(input).toHexString()
            )
        }
        let asert = Self.asertCases.map { asertCase in
            let spec = ChainSpec.test(
                targetBlockTime: asertCase.targetBlockTime,
                initialReward: 1,
                halvingInterval: 1,
                halfLife: asertCase.halfLife
            )
            return WorkTableGolden.AsertEntry(
                name: asertCase.name,
                targetBlockTime: asertCase.targetBlockTime,
                halfLife: asertCase.halfLife,
                anchorTarget: asertCase.anchorTarget.toHexString(),
                anchorTimestamp: asertCase.anchorTimestamp,
                anchorHeight: asertCase.anchorHeight,
                blockTimestamp: asertCase.blockTimestamp,
                blockHeight: asertCase.blockHeight,
                target: spec.calculateAsertTarget(
                    anchorTarget: asertCase.anchorTarget,
                    anchorTimestamp: asertCase.anchorTimestamp,
                    anchorHeight: asertCase.anchorHeight,
                    blockTimestamp: asertCase.blockTimestamp,
                    blockHeight: asertCase.blockHeight
                ).toHexString()
            )
        }
        try GoldenFile.assert(
            WorkTableGolden(work: work, asert: asert),
            matches: Self.goldenName,
            diff: WorkTableGolden.diff
        )
    }
}
