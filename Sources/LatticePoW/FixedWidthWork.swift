import UInt256

/// A 256-bit value held inline as four words, least significant first: a
/// target, or one verified work contribution. `UInt256` keeps its words in a
/// heap array, which every block held in memory paid once per value.
package struct Fixed256: Sendable, Hashable, Comparable {
    package var w0: UInt64
    package var w1: UInt64
    package var w2: UInt64
    package var w3: UInt64

    package static let zero = Fixed256(w0: 0, w1: 0, w2: 0, w3: 0)

    package init(w0: UInt64, w1: UInt64, w2: UInt64, w3: UInt64) {
        self.w0 = w0
        self.w1 = w1
        self.w2 = w2
        self.w3 = w3
    }

    package init(_ value: UInt256) {
        self = .zero
        let wordsPerLimb = UInt64.bitWidth / UInt.bitWidth
        for (index, word) in value.words.enumerated() {
            let shifted = UInt64(word) << ((index % wordsPerLimb) * UInt.bitWidth)
            switch index / wordsPerLimb {
            case 0: w0 |= shifted
            case 1: w1 |= shifted
            case 2: w2 |= shifted
            default: w3 |= shifted
            }
        }
    }

    package var uint256: UInt256 {
        // `UInt256([UInt64])` takes its words most significant first.
        UInt256([w3, w2, w1, w0])
    }

    package static func < (lhs: Fixed256, rhs: Fixed256) -> Bool {
        (lhs.w3, lhs.w2, lhs.w1, lhs.w0) < (rhs.w3, rhs.w2, rhs.w1, rhs.w0)
    }
}

/// An exact sum held inline at 320 bits, least significant word first.
///
/// Sums of `Fixed256` contributions are stored this way. An addition that
/// would leave 320 bits reports overflow instead of wrapping; the caller then
/// keeps that one sum as a growable `WorkSum` in a side table, so every sum
/// stays exact however many contributions it holds (§9.2).
package struct Work320: Sendable, Hashable, Comparable {
    package var w0: UInt64
    package var w1: UInt64
    package var w2: UInt64
    package var w3: UInt64
    package var w4: UInt64

    package static let zero = Work320(w0: 0, w1: 0, w2: 0, w3: 0, w4: 0)

    package init(w0: UInt64, w1: UInt64, w2: UInt64, w3: UInt64, w4: UInt64) {
        self.w0 = w0
        self.w1 = w1
        self.w2 = w2
        self.w3 = w3
        self.w4 = w4
    }

    package init(_ value: Fixed256) {
        self.init(w0: value.w0, w1: value.w1, w2: value.w2, w3: value.w3, w4: 0)
    }

    /// Nil when `value` needs more than 320 bits.
    package init?(_ value: WorkSum) {
        let limbs = value.limbs
        guard limbs.count <= 5 else { return nil }
        func limb(_ index: Int) -> UInt64 { index < limbs.count ? limbs[index] : 0 }
        self.init(w0: limb(0), w1: limb(1), w2: limb(2), w3: limb(3), w4: limb(4))
    }

    package var workSum: WorkSum {
        WorkSum(limbs: [w0, w1, w2, w3, w4])
    }

    package func addingReportingOverflow(_ other: Work320) -> (partialValue: Work320, overflow: Bool) {
        var carry = false
        func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
            let (partial, first) = a.addingReportingOverflow(b)
            let (sum, second) = partial.addingReportingOverflow(carry ? 1 : 0)
            carry = first || second
            return sum
        }
        let result = Work320(
            w0: add(w0, other.w0), w1: add(w1, other.w1), w2: add(w2, other.w2),
            w3: add(w3, other.w3), w4: add(w4, other.w4)
        )
        return (result, carry)
    }

    package func subtractingReportingOverflow(_ other: Work320) -> (partialValue: Work320, overflow: Bool) {
        var borrow = false
        func subtract(_ a: UInt64, _ b: UInt64) -> UInt64 {
            let (partial, first) = a.subtractingReportingOverflow(b)
            let (difference, second) = partial.subtractingReportingOverflow(borrow ? 1 : 0)
            borrow = first || second
            return difference
        }
        let result = Work320(
            w0: subtract(w0, other.w0), w1: subtract(w1, other.w1), w2: subtract(w2, other.w2),
            w3: subtract(w3, other.w3), w4: subtract(w4, other.w4)
        )
        return (result, borrow)
    }

    package static func < (lhs: Work320, rhs: Work320) -> Bool {
        if lhs.w4 != rhs.w4 { return lhs.w4 < rhs.w4 }
        return (lhs.w3, lhs.w2, lhs.w1, lhs.w0) < (rhs.w3, rhs.w2, rhs.w1, rhs.w0)
    }
}

/// An exact running total: inline while it fits 320 bits, a `WorkSum` from the
/// first addition that does not. A local while summing, never stored.
package struct WorkTotal: Sendable {
    package private(set) var inline: Work320? = .zero
    private var grown: WorkSum = .zero

    package init() {}

    package init(_ value: Work320) {
        inline = value
    }

    package init(_ value: WorkSum) {
        if let fits = Work320(value) {
            inline = fits
        } else {
            inline = nil
            grown = value
        }
    }

    package mutating func add(_ value: Work320) {
        if let current = inline {
            let (sum, overflow) = current.addingReportingOverflow(value)
            if !overflow {
                inline = sum
                return
            }
            grown = current.workSum
            inline = nil
        }
        grown = grown + value.workSum
    }

    package mutating func add(_ value: WorkSum) {
        if let fits = Work320(value) {
            add(fits)
        } else {
            if let current = inline {
                grown = current.workSum
                inline = nil
            }
            grown = grown + value
        }
    }

    package mutating func add(_ value: Fixed256) {
        add(Work320(value))
    }

    package var exact: WorkSum {
        inline?.workSum ?? grown
    }
}

extension WorkSum {
    package init(_ value: Fixed256) {
        self.init(limbs: [value.w0, value.w1, value.w2, value.w3])
    }
}
