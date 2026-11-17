import XCTest
import Foundation
import UInt256
@testable import LatticePrimitives
@testable import LatticePoW

/// The target hex in every block encoding and the ASERT schedule ran on
/// UInt256 1.1.0's `String(radix:)` and bit-by-bit long division. Both were
/// replaced for speed (a nibble-wise hex encoding, Knuth division). They must
/// give exactly the 56.3.0 results for every input: the 56.3.0 code is kept
/// below as the oracle, over the 1.1.0 division, on edge values, real chain
/// targets and random values.
final class ArithmeticDifferentialTests: XCTestCase {

    // MARK: - The 56.3.0 code

    /// UInt256 1.1.0 `divisionWithRemainder`, verbatim.
    static func referenceDivision(_ lhs: UInt256, _ rhs: UInt256) -> (UInt256, UInt256) {
        guard rhs > 0 else { return (0, 0) }
        guard lhs > 0 else { return (0, 0) }
        if rhs == UInt256(1) { return (lhs, 0) }

        guard lhs >= rhs else {
            return (0, lhs)
        }

        var quotient: UInt256 = 0
        var remainder: UInt256 = lhs
        var partial: UInt256 = 1
        var chunk: UInt256 = rhs
        var trail: [(UInt256, UInt256)] = [(1, rhs)]

        while remainder - chunk >= chunk {
            chunk = chunk << 1
            partial = partial << 1
            trail.append((partial, chunk))
        }

        for (partial, chunk) in trail.reversed() {
            if remainder >= chunk {
                remainder -= chunk
                quotient += partial
            }
        }

        return (quotient, remainder)
    }

    static func div(_ a: UInt256, _ b: UInt256) -> UInt256 { referenceDivision(a, b).0 }
    static func mod(_ a: UInt256, _ b: UInt256) -> UInt256 { referenceDivision(a, b).1 }

    static func referenceWorkForTarget(_ target: UInt256) -> UInt256 {
        guard target > UInt256.zero else { return UInt256.zero }
        guard target < UInt256.max else { return UInt256(1) }
        return div(UInt256.max - target, target + UInt256(1)) + UInt256(1)
    }

    static func referenceWorkForHash(_ hash: UInt256) -> UInt256 {
        guard hash > UInt256.zero else { return UInt256.max }
        guard hash < UInt256.max else { return UInt256(1) }
        return div(UInt256.max - hash, hash + UInt256(1)) + UInt256(1)
    }

    /// 56.3.0 `ChainSpec.calculateAsertTarget` and its helpers, verbatim but
    /// for `/` and `%`, which go through the 1.1.0 division.
    static func referenceAsert(
        spec: ChainSpec,
        anchorTarget: UInt256,
        anchorTimestamp: Int64,
        anchorHeight: UInt64,
        blockTimestamp: Int64,
        blockHeight: UInt64
    ) -> UInt256 {
        let asertFixedPointBits: Int64 = 16
        let asertFixedPointOne: Int64 = 1 << 16
        let asertMaximumDoublings: Int64 = 256
        let asertCubicA: UInt64 = 195_766_423_245_049
        let asertCubicB: UInt64 = 971_821_376
        let asertCubicC: UInt64 = 5_127
        let asertCubicRounding: UInt64 = 1 << 47

        func elapsedMilliseconds(later: Int64, earlier: Int64) -> UInt64 {
            guard later > earlier else { return 0 }
            if earlier >= 0 || later < 0 {
                return UInt64(later - earlier)
            }
            return UInt64(later) + UInt64(-(earlier + 1)) + 1
        }

        func multiplyDividingSaturating(_ value: UInt256, by numerator: UInt256, over denominator: UInt256) -> UInt256 {
            guard denominator > .zero else { return UInt256.max }
            guard numerator > .zero else { return .zero }

            let quotient = div(value, denominator)
            let remainder = mod(value, denominator)

            let scaledQuotient = quotient > div(UInt256.max, numerator) ? UInt256.max : quotient * numerator
            let scaledRemainderProduct = remainder > div(UInt256.max, numerator) ? UInt256.max : remainder * numerator
            let scaledRemainder = div(scaledRemainderProduct, denominator)

            return scaledQuotient > UInt256.max - scaledRemainder
                ? UInt256.max
                : scaledQuotient + scaledRemainder
        }

        guard blockHeight > anchorHeight else { return anchorTarget }
        let halfLifeMilliseconds = spec.halfLifeMilliseconds()
        guard halfLifeMilliseconds > 0 else { return anchorTarget }
        guard anchorTarget != .zero else { return UInt256(1) }

        let heights = blockHeight - anchorHeight
        let product = heights.multipliedReportingOverflow(by: spec.targetBlockTime)
        let scheduled = Int64(clamping: product.overflow ? UInt64.max : product.partialValue)
        let elapsed = Int64(clamping: elapsedMilliseconds(
            later: blockTimestamp, earlier: anchorTimestamp
        ))
        let deviation = elapsed.subtractingReportingOverflow(scheduled)
        let driftMilliseconds = deviation.overflow
            ? (scheduled > 0 ? Int64.min : Int64.max)
            : deviation.partialValue

        let maximumDrift = Int64.max / asertFixedPointOne
        let boundedDrift = min(max(driftMilliseconds, -maximumDrift), maximumDrift)
        let exponent = (boundedDrift * asertFixedPointOne) / halfLifeMilliseconds

        let doublings = exponent >> asertFixedPointBits
        let fraction = UInt64(exponent & (asertFixedPointOne - 1))

        let cubic = asertCubicA * fraction
            + asertCubicB * fraction * fraction
            + asertCubicC * fraction * fraction * fraction
            + asertCubicRounding
        let factor = UInt64(asertFixedPointOne) + (cubic >> 48)

        if doublings < 0 {
            let halvings = -doublings
            guard halvings < asertMaximumDoublings - Int64(asertFixedPointBits)
            else { return UInt256(1) }
            let scaled = multiplyDividingSaturating(
                anchorTarget,
                by: UInt256(factor),
                over: UInt256(1) << UInt256(UInt64(halvings) + UInt64(asertFixedPointBits))
            )
            return scaled == .zero ? UInt256(1) : scaled
        }
        var scaled = multiplyDividingSaturating(
            anchorTarget,
            by: UInt256(factor),
            over: UInt256(UInt64(asertFixedPointOne))
        )
        if doublings > 0 {
            guard doublings < asertMaximumDoublings else { return UInt256.max }
            let ceiling = div(UInt256.max, UInt256(2))
            for _ in 0..<doublings {
                guard scaled <= ceiling else { return UInt256.max }
                scaled = scaled * UInt256(2)
            }
        }
        return scaled == .zero ? UInt256(1) : scaled
    }

    // MARK: - Inputs

    static let edgeWords: [UInt64] = [
        0, 1, 2, 0x7fff_ffff_ffff_ffff, 0x8000_0000_0000_0000, 0xffff_ffff_ffff_fffe,
        0xffff_ffff_ffff_ffff, 0x0000_0000_ffff_ffff, 0x0000_0001_0000_0000,
    ]

    /// Targets real chains carried (Nexus, testnet, app chains).
    static let chainTargets: [UInt256] = [
        "0x610d3fffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "0x6067bfffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "0xcc4bffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "0xcc2affffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "0x7742bfffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "0x768bffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "0x00000000ffff0000000000000000000000000000000000000000000000000000",
    ].map { UInt256.fromHexString($0)! }

    static func edgeValues() -> [UInt256] {
        var values: [UInt256] = [.zero, UInt256(1), UInt256(2), .max, .max - UInt256(1)]
        for bit in 0..<256 {
            let power = UInt256(1) << bit
            values += [power, power - UInt256(1), power + UInt256(1)]
        }
        for target in chainTargets {
            values += [target, target - UInt256(1), target + UInt256(1), target >> 1, target >> 64]
        }
        return values
    }

    static func randomValue<G: RandomNumberGenerator>(using generator: inout G) -> UInt256 {
        let significantWords = Int.random(in: 0...4, using: &generator)
        var parts: [UInt64] = [0, 0, 0, 0]
        for i in (4 - significantWords)..<4 {
            parts[i] = Bool.random(using: &generator)
                ? edgeWords.randomElement(using: &generator)!
                : UInt64.random(in: 0...UInt64.max, using: &generator)
        }
        let value = UInt256(parts)
        return Bool.random(using: &generator) ? value >> Int.random(in: 0..<256, using: &generator) : value
    }

    static func randomTarget<G: RandomNumberGenerator>(using generator: inout G) -> UInt256 {
        switch Int.random(in: 0..<4, using: &generator) {
        case 0: return chainTargets.randomElement(using: &generator)!
        case 1: return edgeValues().randomElement(using: &generator)!
        case 2:
            // A real-shaped target: a mantissa below a run of ones.
            return UInt256.max >> Int.random(in: 0..<256, using: &generator)
        default: return randomValue(using: &generator)
        }
    }

    // MARK: - Tests

    func testPrefixedHexMatches563() {
        var generator = SplitMix64(seed: 0x1a77_1ce0)
        var values = ArithmeticDifferentialTests.edgeValues()
        for _ in 0..<20_000 {
            values.append(ArithmeticDifferentialTests.randomValue(using: &generator))
        }
        for value in values {
            // 56.3.0's spelling, verbatim.
            let hex = value.toPrefixedHexString()
            XCTAssertEqual(hex, "0x" + String(value, radix: 16))
            XCTAssertEqual(UInt256.fromHexString(hex), value)
            // The encoding a block carries for its targets.
            let encoded = try! JSONEncoder().encode([value])
            XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "[\"\(hex)\"]")
        }
    }

    func testWorkMatches563() {
        var generator = SplitMix64(seed: 0x1a77_1ce1)
        var values = ArithmeticDifferentialTests.edgeValues()
        for _ in 0..<5_000 {
            values.append(ArithmeticDifferentialTests.randomTarget(using: &generator))
        }
        for value in values {
            XCTAssertEqual(workForTarget(value), ArithmeticDifferentialTests.referenceWorkForTarget(value), "\(value)")
            XCTAssertEqual(workForHash(value), ArithmeticDifferentialTests.referenceWorkForHash(value), "\(value)")
        }
    }

    func testAsertMatches563() {
        var generator = SplitMix64(seed: 0x1a77_1ce2)
        let timestamps: [Int64] = [Int64.min, Int64.min + 1, -1, 0, 1, 1_000, 1_700_000_000_000, Int64.max - 1, Int64.max]
        let heights: [UInt64] = [0, 1, 2, 120, 1_000_000, UInt64.max - 1, UInt64.max]
        let specs: [ChainSpec] = [
            ChainSpec.test(),
            ChainSpec.test(targetBlockTime: 10_000, halfLife: 2_880),
            ChainSpec.test(targetBlockTime: 600_000, halfLife: 144),
            ChainSpec.test(targetBlockTime: 1, halfLife: 1),
            ChainSpec.test(targetBlockTime: 0, halfLife: 100),
            ChainSpec.test(targetBlockTime: UInt64.max, halfLife: UInt64.max),
        ]
        var cases = 0
        var outcomes: Set<String> = []
        func check(_ spec: ChainSpec, _ anchorTarget: UInt256, _ anchorTimestamp: Int64,
                   _ anchorHeight: UInt64, _ blockTimestamp: Int64, _ blockHeight: UInt64) {
            let new = spec.calculateAsertTarget(
                anchorTarget: anchorTarget, anchorTimestamp: anchorTimestamp, anchorHeight: anchorHeight,
                blockTimestamp: blockTimestamp, blockHeight: blockHeight
            )
            let old = ArithmeticDifferentialTests.referenceAsert(
                spec: spec, anchorTarget: anchorTarget, anchorTimestamp: anchorTimestamp,
                anchorHeight: anchorHeight, blockTimestamp: blockTimestamp, blockHeight: blockHeight
            )
            XCTAssertEqual(new, old, "\(anchorTarget) \(anchorTimestamp) \(anchorHeight) \(blockTimestamp) \(blockHeight)")
            cases += 1
            outcomes.insert(new == .max ? "max" : new == UInt256(1) ? "one" : new == anchorTarget ? "anchor"
                            : new < anchorTarget ? "harder" : "easier")
        }
        // Edge grid.
        for spec in specs {
            for anchorTarget in ArithmeticDifferentialTests.chainTargets + [.zero, UInt256(1), .max] {
                for anchorTimestamp in timestamps {
                    for blockTimestamp in timestamps {
                        let pairs: [(UInt64, UInt64)] = [
                            (1, 2), (1, 121), (0, UInt64.max),
                            (heights.randomElement(using: &generator)!, heights.randomElement(using: &generator)!),
                        ]
                        for (anchorHeight, blockHeight) in pairs {
                            check(spec, anchorTarget, anchorTimestamp, anchorHeight, blockTimestamp, blockHeight)
                        }
                    }
                }
            }
        }
        // Chain-shaped: near schedule, drifting each way by up to many half-lives.
        for _ in 0..<20_000 {
            let spec = Bool.random(using: &generator) ? specs.randomElement(using: &generator)!
                : ChainSpec.test(targetBlockTime: UInt64.random(in: 1...600_000, using: &generator),
                                 halfLife: UInt64.random(in: 1...10_000, using: &generator))
            let anchorHeight = UInt64.random(in: 0...1_000_000, using: &generator)
            let heights = UInt64.random(in: 0...100_000, using: &generator)
            let anchorTimestamp = Int64.random(in: 0...2_000_000_000_000, using: &generator)
            let scheduled = Int64(clamping: heights.multipliedReportingOverflow(by: spec.targetBlockTime).partialValue)
            let halfLife = max(spec.halfLifeMilliseconds(), 1)
            let drift = Int64.random(in: -300...300, using: &generator) &* (halfLife / 37 + 1)
            check(spec, ArithmeticDifferentialTests.randomTarget(using: &generator), anchorTimestamp, anchorHeight,
                  anchorTimestamp &+ scheduled &+ drift, anchorHeight &+ heights)
        }
        // Uniform over the whole input space.
        for _ in 0..<5_000 {
            check(specs.randomElement(using: &generator)!,
                  ArithmeticDifferentialTests.randomValue(using: &generator),
                  Int64.random(in: Int64.min...Int64.max, using: &generator),
                  UInt64.random(in: 0...UInt64.max, using: &generator),
                  Int64.random(in: Int64.min...Int64.max, using: &generator),
                  UInt64.random(in: 0...UInt64.max, using: &generator))
        }
        print("ArithmeticDifferential: \(cases) ASERT cases, outcomes \(outcomes.sorted())")
        XCTAssertEqual(outcomes, ["max", "one", "anchor", "harder", "easier"])
    }
}

/// A seeded generator, so a failure replays.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
