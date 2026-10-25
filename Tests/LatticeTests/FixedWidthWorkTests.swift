import XCTest
import UInt256
@testable import LatticePoW

/// The inline number types against `UInt256` and the growable `WorkSum`.
final class FixedWidthWorkTests: XCTestCase {
    private struct Random {
        private var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        mutating func value() -> UInt256 {
            // Every width, so each word boundary is crossed.
            let words = [next(), next(), next(), next()]
            let keep = Int(next() % 5)
            return UInt256(Array(repeating: 0, count: 4 - keep) + words.prefix(keep))
        }
    }

    func testFixed256RoundTripsAndOrdersAsUInt256() {
        var random = Random(seed: 1)
        var values: [UInt256] = [.zero, UInt256(1), .max, UInt256.max - UInt256(1)]
        for _ in 0..<200 { values.append(random.value()) }
        for value in values {
            XCTAssertEqual(Fixed256(value).uint256, value)
            XCTAssertEqual(WorkSum(Fixed256(value)), WorkSum(value))
        }
        for (left, right) in zip(values, values.dropFirst()) {
            XCTAssertEqual(Fixed256(left) < Fixed256(right), left < right)
            XCTAssertEqual(Fixed256(left) == Fixed256(right), left == right)
        }
    }

    func testWork320ArithmeticMatchesWorkSum() {
        var random = Random(seed: 2)
        for _ in 0..<200 {
            let a = WorkSum(random.value()) + WorkSum(random.value())
            let b = WorkSum(random.value())
            let (sum, overflow) = Work320(a)!.addingReportingOverflow(Work320(b)!)
            XCTAssertFalse(overflow)
            XCTAssertEqual(sum.workSum, a + b)
            XCTAssertEqual(Work320(a)! < Work320(b)!, a < b)
            let (larger, smaller) = a < b ? (b, a) : (a, b)
            let (difference, borrow) = Work320(larger)!.subtractingReportingOverflow(Work320(smaller)!)
            XCTAssertFalse(borrow)
            XCTAssertEqual(difference.workSum, larger.subtracting(smaller))
        }
        let top = Work320(w0: .max, w1: .max, w2: .max, w3: .max, w4: .max)
        XCTAssertTrue(top.addingReportingOverflow(Work320(Fixed256(UInt256(1)))).overflow)
        XCTAssertTrue(Work320.zero.subtractingReportingOverflow(Work320(Fixed256(UInt256(1)))).overflow)
        XCTAssertNil(Work320(WorkSum(limbs: [0, 0, 0, 0, 0, 1])))
    }

    /// A total of `UInt256.max`-scale contributions stays exact past 2^256
    /// inline, and past 2^320 as a `WorkSum`.
    func testWorkTotalGrowsPast320BitsExactly() {
        var total = WorkTotal()
        var expected = WorkSum.zero
        for _ in 0..<1_000 {
            total.add(Fixed256(.max))
            expected = expected + UInt256.max
        }
        XCTAssertNotNil(total.inline)
        XCTAssertEqual(total.exact, expected)

        let near = WorkSum(limbs: [0, 0, 0, 0, .max])
        total.add(near)
        expected = expected + near
        XCTAssertNil(total.inline, "past 320 bits the total is no longer inline")
        XCTAssertEqual(total.exact, expected)
        total.add(Fixed256(.max))
        expected = expected + UInt256.max
        XCTAssertEqual(total.exact, expected)
        XCTAssertEqual(WorkTotal(expected).exact, expected)
    }
}
