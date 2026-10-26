import Foundation
import XCTest
import UInt256
@testable import LatticePrimitives
@testable import LatticePoW

/// ASERT vectors for checking a formal model of spec §5.5 against the real
/// `ChainSpec.calculateAsertTarget`.
///
/// Each vector is one call: the spec's `targetBlockTime` and `halfLife`, the
/// anchor's target, timestamp and height, the block's timestamp and height,
/// and the target the implementation returns. Integers are written as decimal
/// strings and targets as 64 hex digits, so no JSON reader rounds them.
///
/// The named vectors cover the edges: drift of zero and of whole half-lives in
/// both directions (up to and past both saturations), one millisecond either
/// side of them, half a half-life, every anchor from zero to the maximum,
/// heights equal or reversed, a zero or overflowing half-life, timestamps at
/// the `Int64` bounds, a schedule past `Int64.max`, and the drift clamp. The
/// seeded sweep that follows draws every input from wide, mixed scales.
///
/// Set `LATTICE_ASERT_VECTOR_DIR` to write `asert-vectors.json`, with
/// `LATTICE_ASERT_VECTOR_COUNT` (default 1000) seeded vectors after the named
/// ones.
final class AsertVectorExportTests: XCTestCase {
    func testAsertVectorsCoverEveryRegime() throws {
        let environment = ProcessInfo.processInfo.environment
        let count = environment["LATTICE_ASERT_VECTOR_COUNT"].flatMap(Int.init) ?? 1000
        let vectors = AsertVectors.named() + AsertVectors.sweep(count: count)
        XCTAssertEqual(Set(vectors.map(\.name)).count, vectors.count, "vector names must be unique")

        var coverage: [String: Int] = [:]
        for v in vectors {
            for label in v.regimes { coverage[label, default: 0] += 1 }
        }
        print("asert vectors: \(vectors.count), \(coverage.sorted { $0.key < $1.key })")
        for regime in ["held", "hardened", "eased", "floor", "ceiling", "zeroAnchor", "noSchedule"] {
            XCTAssertGreaterThan(coverage[regime] ?? 0, 0, "no vector shows \(regime)")
            XCTAssertGreaterThan(coverage["sweep:" + regime] ?? 0, 0, "no seeded vector shows \(regime)")
        }

        if let directory = environment["LATTICE_ASERT_VECTOR_DIR"].map({ URL(fileURLWithPath: $0) }) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(vectors).write(to: directory.appendingPathComponent("asert-vectors.json"))
        }
    }

    func testAsertVectorsAreDeterministic() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(AsertVectors.sweep(count: 100))
        let second = try encoder.encode(AsertVectors.sweep(count: 100))
        XCTAssertEqual(first, second)
    }
}

struct AsertVector: Codable, Equatable {
    let name: String
    let targetBlockTime: String
    let halfLife: String
    let anchorTarget: String
    let anchorTimestamp: String
    let anchorHeight: String
    let blockTimestamp: String
    let blockHeight: String
    let nextTarget: String

    /// Which outcomes this vector shows, for the coverage check only.
    fileprivate var labels: [String] = []
    var regimes: [String] { labels }

    enum CodingKeys: String, CodingKey {
        case name, targetBlockTime, halfLife, anchorTarget, anchorTimestamp, anchorHeight
        case blockTimestamp, blockHeight, nextTarget
    }
}

enum AsertVectors {
    static func vector(
        _ name: String,
        targetBlockTime: UInt64, halfLife: UInt64,
        anchorTarget: UInt256, anchorTimestamp: Int64, anchorHeight: UInt64,
        blockTimestamp: Int64, blockHeight: UInt64
    ) -> AsertVector {
        let spec = ChainSpec.test(targetBlockTime: targetBlockTime, halfLife: halfLife)
        let next = spec.calculateAsertTarget(
            anchorTarget: anchorTarget, anchorTimestamp: anchorTimestamp,
            anchorHeight: anchorHeight, blockTimestamp: blockTimestamp, blockHeight: blockHeight
        )
        var labels: [String] = []
        if anchorTarget == .zero { labels.append("zeroAnchor") }
        if blockHeight <= anchorHeight || spec.halfLifeMilliseconds() <= 0 { labels.append("noSchedule") }
        if next == anchorTarget { labels.append("held") }
        if next < anchorTarget { labels.append("hardened") }
        if next > anchorTarget { labels.append("eased") }
        if next == UInt256(1) && anchorTarget > UInt256(1) { labels.append("floor") }
        if next == UInt256.max && anchorTarget < UInt256.max { labels.append("ceiling") }
        if name.hasPrefix("sweep") { labels += labels.map { "sweep:" + $0 } }
        var v = AsertVector(
            name: name,
            targetBlockTime: String(targetBlockTime), halfLife: String(halfLife),
            anchorTarget: anchorTarget.toHexString(),
            anchorTimestamp: String(anchorTimestamp), anchorHeight: String(anchorHeight),
            blockTimestamp: String(blockTimestamp), blockHeight: String(blockHeight),
            nextTarget: next.toHexString()
        )
        v.labels = labels
        return v
    }

    static let anchors: [(String, UInt256)] = [
        ("0", .zero),
        ("1", UInt256(1)),
        ("2", UInt256(2)),
        ("3", UInt256(3)),
        ("2^64-1", UInt256(UInt64.max)),
        ("2^200", UInt256(1) << UInt256(200)),
        ("2^215", UInt256(1) << UInt256(215)),
        ("2^255-1", (UInt256(1) << UInt256(255)) - UInt256(1)),
        ("2^255", UInt256(1) << UInt256(255)),
        ("max-1", UInt256.max - UInt256(1)),
        ("max", UInt256.max),
    ]

    /// Edge cases, each named for what it pins.
    static func named() -> [AsertVector] {
        var out: [AsertVector] = []
        // A ten-minute block, a 120-block half-life, 40,000 blocks since the
        // anchor: enough schedule that drift can reach -257 half-lives with
        // elapsed still positive.
        let t: UInt64 = 600_000
        let hl: UInt64 = 120
        let halfLife = Int64(t * hl)
        let at: Int64 = 1_700_000_000_000
        let heights: UInt64 = 40_000
        let scheduled = Int64(heights * t)
        let multiples: [Int64] = [-257, -256, -255, -241, -240, -239, -226, -225, -224, -223,
                                  -200, -64, -8, -2, -1, 0, 1, 2, 8, 64, 200, 254, 255, 256, 257]
        for (an, a) in anchors {
            for k in multiples {
                let drifts: [(String, Int64)] = [
                    ("", k * halfLife),
                    ("-1ms", k * halfLife - 1),
                    ("+1ms", k * halfLife + 1),
                    ("+half", k * halfLife + halfLife / 2),
                ]
                for (dn, drift) in drifts {
                    out.append(vector("anchor \(an) drift \(k)hl\(dn)",
                                      targetBlockTime: t, halfLife: hl,
                                      anchorTarget: a, anchorTimestamp: at, anchorHeight: 1,
                                      blockTimestamp: at + scheduled + drift, blockHeight: 1 + heights))
                }
            }
            // On schedule at many depths.
            for h: UInt64 in [1, 2, 3, 1_000, 1 << 20] {
                out.append(vector("anchor \(an) on schedule h\(h)",
                                  targetBlockTime: t, halfLife: hl,
                                  anchorTarget: a, anchorTimestamp: at, anchorHeight: 1,
                                  blockTimestamp: at + Int64(h * t), blockHeight: 1 + h))
            }
            // No schedule: the block at or below the anchor, no half-life.
            out.append(vector("anchor \(an) same height", targetBlockTime: t, halfLife: hl,
                              anchorTarget: a, anchorTimestamp: at, anchorHeight: 1,
                              blockTimestamp: at + 1_000_000_000, blockHeight: 1))
            out.append(vector("anchor \(an) lower height", targetBlockTime: t, halfLife: hl,
                              anchorTarget: a, anchorTimestamp: at, anchorHeight: 7,
                              blockTimestamp: at + 1_000_000_000, blockHeight: 3))
            out.append(vector("anchor \(an) halfLife 0", targetBlockTime: t, halfLife: 0,
                              anchorTarget: a, anchorTimestamp: at, anchorHeight: 1,
                              blockTimestamp: at + 1_000_000_000, blockHeight: 9))
            out.append(vector("anchor \(an) targetBlockTime 0", targetBlockTime: 0, halfLife: hl,
                              anchorTarget: a, anchorTimestamp: at, anchorHeight: 1,
                              blockTimestamp: at + 1_000_000_000, blockHeight: 9))
            // Timestamps at the Int64 bounds.
            let stamps: [(String, Int64, Int64)] = [
                ("min..max", .min, .max),
                ("max..min", .max, .min),
                ("min..-1", .min, -1),
                ("-1..0", -1, 0),
                ("-5..max", -5, .max),
                ("min..0", .min, 0),
                ("min+1..max", .min + 1, .max),
                ("0..max", 0, .max),
                ("equal", at, at),
                ("backwards", at, at - 1),
            ]
            for (sn, a0, b0) in stamps {
                for h: UInt64 in [1, 1 << 20, UInt64.max - 1] {
                    out.append(vector("anchor \(an) stamps \(sn) h\(h)",
                                      targetBlockTime: t, halfLife: hl,
                                      anchorTarget: a, anchorTimestamp: a0, anchorHeight: 1,
                                      blockTimestamp: b0, blockHeight: 1 &+ h))
                }
            }
        }
        // Heights at the UInt64 bounds; the schedule past Int64.max.
        for (an, a) in anchors where an == "2^215" || an == "max" || an == "1" {
            for (tn, tt): (String, UInt64) in [("1", 1), ("2", 2), ("2^63", 1 << 63), ("max", .max)] {
                out.append(vector("anchor \(an) heights max t\(tn)", targetBlockTime: tt, halfLife: 1,
                                  anchorTarget: a, anchorTimestamp: 0, anchorHeight: 0,
                                  blockTimestamp: .max, blockHeight: .max))
                out.append(vector("anchor \(an) heights max-1 t\(tn)", targetBlockTime: tt, halfLife: 1,
                                  anchorTarget: a, anchorTimestamp: .min, anchorHeight: 1,
                                  blockTimestamp: .max, blockHeight: .max))
            }
            // Half-life products at and past Int64.max.
            for (hn, ht, ttt): (String, UInt64, UInt64) in [
                ("2^63-1", UInt64(Int64.max), 1), ("2^63", 1 << 62, 2), ("overflow", .max, .max),
                ("2^62", 1 << 61, 2), ("1", 1, 1),
            ] {
                for drift: Int64 in [0, 1, -1, 1 << 40, -(1 << 40), Int64.max / 65536, Int64.max / 65536 + 1,
                                     -(Int64.max / 65536), -(Int64.max / 65536) - 1, .max] {
                    let heights: UInt64 = 3
                    let sched = heights.multipliedReportingOverflow(by: ttt)
                    let s = sched.overflow ? Int64.max : Int64(clamping: sched.partialValue)
                    let anchorTime: Int64 = drift < 0 ? 0 : .min
                    let (bt, o) = anchorTime.addingReportingOverflow(s)
                    let (bt2, o2) = bt.addingReportingOverflow(drift)
                    out.append(vector("anchor \(an) halfLifeMs \(hn) drift \(drift)",
                                      targetBlockTime: ttt, halfLife: ht,
                                      anchorTarget: a, anchorTimestamp: anchorTime, anchorHeight: 5,
                                      blockTimestamp: o || o2 ? .max : bt2, blockHeight: 5 + heights))
                }
            }
        }
        return out
    }

    /// Seeded vectors with every input drawn across wide, mixed scales.
    static func sweep(count: Int) -> [AsertVector] {
        var rng = SeededRNG(seed: 0xA5E7)
        var out: [AsertVector] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let t: UInt64 = [1, 1_000, 600_000, 3_600_000, rng.next() % 10_000_000 + 1, rng.next()][Int(rng.next() % 6)]
            let hl: UInt64 = [1, 2, 120, 288, rng.next() % 10_000 + 1, rng.next()][Int(rng.next() % 6)]
            let bits = Int(rng.next() % 257)
            let raw = UInt256([rng.next(), rng.next(), rng.next(), rng.next()])
            let a = bits == 0 ? UInt256.zero : raw >> UInt256(256 - bits)
            let ah = rng.next() % 2 == 0 ? 1 : rng.next() >> Int(rng.next() % 64)
            let span = rng.next() >> Int(rng.next() % 64)
            let bh = rng.next() % 16 == 0 ? ah &- (span % 3) : ah &+ span
            let at = Int64(bitPattern: rng.next()) >> Int(rng.next() % 64)
            // Aim near the schedule plus some half-lives of drift, so the whole
            // exponent range is hit; fall back to a raw stamp on overflow.
            let halfLifeMs = hl.multipliedReportingOverflow(by: t)
            let hlms = halfLifeMs.overflow ? Int64.max : Int64(clamping: halfLifeMs.partialValue)
            let sched = (bh &- ah).multipliedReportingOverflow(by: t)
            let s = sched.overflow ? Int64.max : Int64(clamping: sched.partialValue)
            let k = Int64(rng.next() % 601) - 300
            let frac = Int64(bitPattern: rng.next() % UInt64(max(hlms, 1)))
            let drift = k.multipliedReportingOverflow(by: hlms)
            var bt: Int64
            if drift.overflow {
                bt = Int64(bitPattern: rng.next())
            } else {
                let (x, o1) = at.addingReportingOverflow(s)
                let (y, o2) = x.addingReportingOverflow(drift.partialValue)
                let (z, o3) = y.addingReportingOverflow(rng.next() % 2 == 0 ? 0 : frac)
                bt = o1 || o2 || o3 ? Int64(bitPattern: rng.next()) : z
            }
            out.append(vector("sweep \(i)", targetBlockTime: t, halfLife: hl,
                              anchorTarget: a, anchorTimestamp: at, anchorHeight: ah,
                              blockTimestamp: bt, blockHeight: bh))
        }
        return out
    }
}
