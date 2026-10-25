import UInt256
import LatticePrimitives

/// An exact, growable sum of fixed-width proof-of-work contributions.
/// Individual targets remain `UInt256`; cumulative and subtree work must not
/// clamp because fork choice depends on strict ordering after every addition.
public struct WorkSum: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    /// Least significant first, with no trailing zero limb.
    package private(set) var limbs: [UInt64]

    public static let zero = WorkSum(limbs: [])

    package init(limbs: [UInt64]) {
        self.limbs = limbs
        while self.limbs.last == 0 { self.limbs.removeLast() }
    }

    public init(_ value: UInt256) {
        let words = value.words
        let wordsPerLimb = UInt64.bitWidth / UInt.bitWidth
        var parsed: [UInt64] = []
        parsed.reserveCapacity((words.count + wordsPerLimb - 1) / wordsPerLimb)
        for index in stride(from: 0, to: words.count, by: wordsPerLimb) {
            var limb = UInt64(words[index])
            for offset in 1..<min(wordsPerLimb, words.count - index) {
                limb |= UInt64(words[index + offset]) << (offset * UInt.bitWidth)
            }
            parsed.append(limb)
        }
        self.init(limbs: parsed)
    }

    public init?(hex: String) {
        guard !hex.isEmpty,
              hex.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
              }) else { return nil }

        var parsed: [UInt64] = []
        var end = hex.endIndex
        while end > hex.startIndex {
            let width = min(16, hex.distance(from: hex.startIndex, to: end))
            let start = hex.index(end, offsetBy: -width)
            guard let limb = UInt64(hex[start..<end], radix: 16) else { return nil }
            parsed.append(limb)
            end = start
        }
        self.init(limbs: parsed)
    }

    public static func < (lhs: WorkSum, rhs: WorkSum) -> Bool {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count
        }
        for index in lhs.limbs.indices.reversed() {
            if lhs.limbs[index] != rhs.limbs[index] {
                return lhs.limbs[index] < rhs.limbs[index]
            }
        }
        return false
    }

    public static func + (lhs: WorkSum, rhs: WorkSum) -> WorkSum {
        let count = max(lhs.limbs.count, rhs.limbs.count)
        var result: [UInt64] = []
        result.reserveCapacity(count + 1)
        var carry = false
        for index in 0..<count {
            let left = index < lhs.limbs.count ? lhs.limbs[index] : 0
            let right = index < rhs.limbs.count ? rhs.limbs[index] : 0
            let (partial, firstOverflow) = left.addingReportingOverflow(right)
            let (sum, secondOverflow) = partial.addingReportingOverflow(carry ? 1 : 0)
            result.append(sum)
            carry = firstOverflow || secondOverflow
        }
        if carry { result.append(1) }
        return WorkSum(limbs: result)
    }

    public static func + (lhs: WorkSum, rhs: UInt256) -> WorkSum {
        lhs + WorkSum(rhs)
    }

    public func subtracting(_ other: WorkSum) -> WorkSum? {
        guard self >= other else { return nil }
        var result: [UInt64] = []
        result.reserveCapacity(limbs.count)
        var borrow = false
        for index in limbs.indices {
            let right = index < other.limbs.count ? other.limbs[index] : 0
            let (partial, firstBorrow) = limbs[index].subtractingReportingOverflow(right)
            let (difference, secondBorrow) = partial.subtractingReportingOverflow(borrow ? 1 : 0)
            result.append(difference)
            borrow = firstBorrow || secondBorrow
        }
        return borrow ? nil : WorkSum(limbs: result)
    }

    public var uint64Value: UInt64? {
        limbs.count <= 1 ? (limbs.first ?? 0) : nil
    }

    /// The value as one `UInt256`, or nil when it does not fit. Mirrors
    /// `uint64Value`. A caller that must produce a fixed-width quantity (a
    /// `VerifiedWorkContribution`) uses this to REFUSE rather than saturate:
    /// a saturated sum ties with every other saturated sum and erases the
    /// ordering fork choice depends on (§9.2).
    public var uint256Value: UInt256? {
        guard limbs.count <= UInt256.bitWidth / UInt64.bitWidth else { return nil }
        var value = UInt256.zero
        for limb in limbs.reversed() {
            value = (value << UInt64.bitWidth) | UInt256(limb)
        }
        return value
    }

    public func toHexString() -> String {
        guard let mostSignificant = limbs.last else {
            return String(repeating: "0", count: 64)
        }
        var result = String(mostSignificant, radix: 16)
        for limb in limbs.dropLast().reversed() {
            let encoded = String(limb, radix: 16)
            result += String(repeating: "0", count: 16 - encoded.count) + encoded
        }
        return result.count < 64
            ? String(repeating: "0", count: 64 - result.count) + result
            : result
    }

    public var description: String { toHexString() }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        guard let value = WorkSum(hex: encoded) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid hexadecimal work sum"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(toHexString())
    }
}

/// Exact proof-of-work keyed by physical grind identity. A grind has one block
/// location per chain, but may appear once at every level of the hierarchy.
/// If several levels observe its difficulty, the strongest verified value wins.
package struct WorkMeasure: Sendable, Equatable {
    private var workByGrind: [String: UInt256]

    package static let zero = WorkMeasure()

    package init() {
        workByGrind = [:]
    }

    package init(_ contributions: some Sequence<VerifiedWorkContribution>) {
        workByGrind = [:]
        for contribution in contributions {
            insert(contribution)
        }
    }

    package var total: WorkSum {
        workByGrind.values.reduce(.zero) { $0 + $1 }
    }

    package var entries: [String: UInt256] {
        workByGrind
    }

    @discardableResult
    package mutating func insert(_ contribution: VerifiedWorkContribution) -> Bool {
        let id = CIDIdentity.canonicalString(contribution.id) ?? contribution.id
        guard contribution.work > (workByGrind[id] ?? .zero) else {
            return false
        }
        workByGrind[id] = contribution.work
        return true
    }

    package mutating func formUnion(_ other: WorkMeasure) {
        for (id, work) in other.workByGrind where work > (workByGrind[id] ?? .zero) {
            workByGrind[id] = work
        }
    }
}
