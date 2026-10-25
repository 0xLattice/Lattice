import XCTest
import UInt256
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport

/// The Euler range structure on its own, against a brute-force oracle.
///
/// Fork choice is the wrong place to first learn this structure is wrong: a bad
/// rotation or a stale aggregate surfaces there as an unexplained path
/// divergence. These tests hold the graph trivial and the structure under
/// suspicion, so a failure names the defect directly.
final class EulerWorkIndexTests: XCTestCase {
    /// The naive answer: walk the block tree and add work up. This is what the
    /// range query has to reproduce exactly, at every step.
    private struct Model {
        private(set) var childrenOf: [String: [String]] = [:]
        private(set) var work: [String: WorkSum] = [:]
        private(set) var blocks: [String] = []

        mutating func add(_ hash: String, parent: String?) {
            blocks.append(hash)
            childrenOf[hash] = []
            work[hash] = .zero
            if let parent { childrenOf[parent, default: []].append(hash) }
        }

        mutating func addWork(_ delta: WorkSum, to hash: String) {
            work[hash] = (work[hash] ?? .zero) + delta
        }

        func subtreeWork(_ hash: String) -> WorkSum {
            var total = work[hash] ?? .zero
            for child in childrenOf[hash] ?? [] {
                total = total + subtreeWork(child)
            }
            return total
        }
    }

    private struct Random {
        private var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next(_ bound: Int) -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return bound <= 0 ? 0 : Int(state % UInt64(bound))
        }
    }

    private func work(_ value: UInt64) -> WorkSum {
        WorkSum(UInt256(value))
    }

    private func assertMatchesModel(
        _ index: NamedEulerIndex,
        _ model: Model,
        _ event: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            index.debugInvariantsHold,
            "\(event): tree invariants (aggregate, height, balance, parent)",
            file: file, line: line
        )
        assertValidEulerTour(index, model, event, file: file, line: line)
        for hash in model.blocks {
            XCTAssertEqual(
                index.subtreeWork(hash),
                model.subtreeWork(hash),
                "\(event): subtree work at \(hash)",
                file: file, line: line
            )
        }
    }

    /// Every block opens once, closes once, and closes in the reverse order it
    /// opened — the property that makes a subtree a contiguous range at all.
    private func assertValidEulerTour(
        _ index: NamedEulerIndex,
        _ model: Model,
        _ event: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var stack: [String] = []
        var opened = Set<String>()
        for step in index.debugSequence {
            if step.isOpen {
                XCTAssertTrue(
                    opened.insert(step.hash).inserted,
                    "\(event): \(step.hash) opened twice",
                    file: file, line: line
                )
                stack.append(step.hash)
            } else {
                XCTAssertEqual(
                    stack.popLast(),
                    step.hash,
                    "\(event): close out of order at \(step.hash)",
                    file: file, line: line
                )
            }
        }
        XCTAssertTrue(stack.isEmpty, "\(event): unclosed blocks", file: file, line: line)
        XCTAssertEqual(
            opened.count,
            model.blocks.count,
            "\(event): block count",
            file: file, line: line
        )
    }

    func testRandomGrowthAndWorkMatchBruteForce() {
        for seed: UInt64 in [1, 2, 3, 0xBEEF, 0xC0FFEE] {
            var random = Random(seed: seed)
            var index = NamedEulerIndex.empty
            var model = Model()

            XCTAssertTrue(index.insertRoot("root"))
            model.add("root", parent: nil)
            assertMatchesModel(index, model, "seed \(seed): root")

            for step in 0..<60 {
                if random.next(100) < 65 {
                    let parent = model.blocks[random.next(model.blocks.count)]
                    let hash = "b-\(seed)-\(step)"
                    XCTAssertNotNil(
                        index.insertLeaf(hash, under: parent),
                        "seed \(seed): insert \(hash)"
                    )
                    model.add(hash, parent: parent)
                } else {
                    let target = model.blocks[random.next(model.blocks.count)]
                    let delta = work(UInt64(random.next(9) + 1))
                    XCTAssertNotNil(
                        index.add(delta, at: target),
                        "seed \(seed): add at \(target)"
                    )
                    model.addWork(delta, to: target)
                }
                assertMatchesModel(index, model, "seed \(seed): step \(step)")
            }
        }
    }

    func testSplicedComponentMatchesBruteForce() {
        var index = NamedEulerIndex.empty
        var model = Model()
        XCTAssertTrue(index.insertRoot("root"))
        model.add("root", parent: nil)
        for step in 0..<5 {
            let hash = "chain-\(step)"
            let parent = step == 0 ? "root" : "chain-\(step - 1)"
            XCTAssertNotNil(index.insertLeaf(hash, under: parent))
            model.add(hash, parent: parent)
            XCTAssertNotNil(index.add(work(3), at: hash))
            model.addWork(work(3), to: hash)
        }

        // A component of its own: root c0 with two children, spliced under a
        // block in the middle of the existing chain.
        let events: [NamedEulerIndex.Event] = [
            .open("c0", work(5)),
            .open("c1", work(7)),
            .close("c1"),
            .open("c2", work(11)),
            .close("c2"),
            .close("c0"),
        ]
        XCTAssertNotNil(index.splice(events, under: "chain-2"))
        model.add("c0", parent: "chain-2")
        model.addWork(work(5), to: "c0")
        model.add("c1", parent: "c0")
        model.addWork(work(7), to: "c1")
        model.add("c2", parent: "c0")
        model.addWork(work(11), to: "c2")

        assertMatchesModel(index, model, "spliced component")

        // And work landing inside the spliced component still reaches every
        // enclosing range.
        XCTAssertNotNil(index.add(work(13), at: "c1"))
        model.addWork(work(13), to: "c1")
        assertMatchesModel(index, model, "work inside spliced component")
    }

    func testBulkBuildAgreesWithIncrementalOnAnswers() {
        var incremental = NamedEulerIndex.empty
        var model = Model()
        XCTAssertTrue(incremental.insertRoot("root"))
        model.add("root", parent: nil)
        var random = Random(seed: 0xA11CE)
        for step in 0..<40 {
            let parent = model.blocks[random.next(model.blocks.count)]
            let hash = "n-\(step)"
            XCTAssertNotNil(incremental.insertLeaf(hash, under: parent))
            model.add(hash, parent: parent)
            let delta = work(UInt64(random.next(5) + 1))
            XCTAssertNotNil(incremental.add(delta, at: hash))
            model.addWork(delta, to: hash)
        }

        // A rebuild walks children in sorted order, so its tour differs from the
        // incremental one, which appends each new child last. Subtree sums are
        // order-independent, so the ANSWERS must agree even though the
        // sequences need not — and that is the only property fork choice reads.
        var events: [NamedEulerIndex.Event] = []
        func walk(_ hash: String) {
            events.append(.open(hash, model.work[hash] ?? .zero))
            for child in (model.childrenOf[hash] ?? []).sorted() { walk(child) }
            events.append(.close(hash))
        }
        walk("root")
        let rebuilt = NamedEulerIndex.build(events: events)

        XCTAssertTrue(rebuilt.debugInvariantsHold, "rebuild invariants")
        for hash in model.blocks {
            XCTAssertEqual(
                rebuilt.subtreeWork(hash),
                model.subtreeWork(hash),
                "rebuilt subtree work at \(hash)"
            )
            XCTAssertEqual(
                rebuilt.subtreeWork(hash),
                incremental.subtreeWork(hash),
                "rebuilt vs incremental at \(hash)"
            )
        }
    }

    /// A malformed run must leave the structure EXACTLY as it was, not half
    /// spliced. There is no delete here, so a partial splice is unrecoverable;
    /// the caller turns a nil into an abort, which is a crash rather than silent
    /// corruption, but the guarantee should be that nothing was written at all.
    ///
    /// Every case below passed the first version of the pre-validation, which
    /// tested independent conditions instead of simulating the nesting.
    func testMalformedSpliceLeavesTheIndexUntouched() {
        var index = NamedEulerIndex.empty
        var model = Model()
        XCTAssertTrue(index.insertRoot("root"))
        model.add("root", parent: nil)
        for step in 0..<4 {
            let hash = "m-\(step)"
            let parent = step == 0 ? "root" : "m-\(step - 1)"
            XCTAssertNotNil(index.insertLeaf(hash, under: parent))
            model.add(hash, parent: parent)
            XCTAssertNotNil(index.add(work(3), at: hash))
            model.addWork(work(3), to: hash)
        }
        func snapshot(_ index: NamedEulerIndex) -> [String] {
            index.debugSequence.map { "\($0.hash)|\($0.isOpen)|\($0.value)" }
        }
        let before = snapshot(index)

        let malformed: [(name: String, events: [NamedEulerIndex.Event])] = [
            ("duplicate close", [
                .open("x", work(1)), .close("x"), .close("x"),
            ]),
            ("unclosed open", [.open("y", work(1))]),
            ("close out of nesting order", [
                .open("a", work(1)), .open("b", work(1)),
                .close("a"), .close("b"),
            ]),
            ("reopen a block already held", [
                .open("m-0", work(1)), .close("m-0"),
            ]),
            ("close a block already closed", [.close("root")]),
        ]
        for case let (name, events) in malformed {
            XCTAssertNil(
                index.splice(events, under: "m-1"),
                "\(name): must be refused"
            )
            XCTAssertEqual(
                snapshot(index),
                before,
                "\(name): nothing may have been written"
            )
            XCTAssertTrue(index.debugInvariantsHold, "\(name): invariants")
        }
        assertMatchesModel(index, model, "after refused splices")
    }

    /// Sums held inline at 320 bits spill to an exact `WorkSum` when they
    /// outgrow them, and stay exact: values and aggregates past 2^320 — far
    /// past anything 2^64 contributions of 2^256 could reach, so the spill is
    /// driven at this seam — answer every subtree as the naive sum does,
    /// through inserts, rotations and splices.
    func testSumsPast320BitsSpillAndStayExact() {
        // Values of 2^318..2^322: a couple of these on one path leave 320 bits.
        func huge(_ random: inout Random) -> WorkSum {
            WorkSum(limbs: [UInt64(random.next(1 << 30)), 0, 0, 0, 1 << 62, UInt64(random.next(4))])
        }
        for seed: UInt64 in [7, 8, 0xD1CE] {
            var random = Random(seed: seed)
            var index = NamedEulerIndex.empty
            var model = Model()
            XCTAssertTrue(index.insertRoot("root"))
            model.add("root", parent: nil)
            var spilled = false
            for step in 0..<80 {
                switch random.next(100) {
                case 0..<55:
                    let parent = model.blocks[random.next(model.blocks.count)]
                    let hash = "s-\(seed)-\(step)"
                    XCTAssertNotNil(index.insertLeaf(hash, under: parent))
                    model.add(hash, parent: parent)
                case 55..<70:
                    // A small component, one huge value inside, spliced in.
                    let parent = model.blocks[random.next(model.blocks.count)]
                    let top = "c-\(seed)-\(step)", leaf = "c-\(seed)-\(step)-leaf"
                    let topWork = huge(&random), leafWork = work(UInt64(random.next(9) + 1))
                    XCTAssertNotNil(index.splice([
                        .open(top, topWork), .open(leaf, leafWork), .close(leaf), .close(top),
                    ], under: parent))
                    model.add(top, parent: parent)
                    model.addWork(topWork, to: top)
                    model.add(leaf, parent: top)
                    model.addWork(leafWork, to: leaf)
                default:
                    let target = model.blocks[random.next(model.blocks.count)]
                    let delta = random.next(2) == 0 ? huge(&random) : work(UInt64(random.next(9) + 1))
                    XCTAssertNotNil(index.add(delta, at: target))
                    model.addWork(delta, to: target)
                }
                spilled = spilled || index.debugSpilledCount > 0
                assertMatchesModel(index, model, "seed \(seed): step \(step)")
            }
            XCTAssertTrue(spilled, "seed \(seed): no sum ever left 320 bits")
        }
    }

    /// A rebuild from a tour whose values outgrow 320 bits answers exactly.
    func testBulkBuildPast320BitsIsExact() {
        let big = WorkSum(limbs: [3, 0, 0, 0, UInt64.max])
        var model = Model()
        var events: [NamedEulerIndex.Event] = []
        model.add("root", parent: nil)
        model.addWork(big, to: "root")
        events.append(.open("root", big))
        for step in 0..<20 {
            let hash = "b-\(step)"
            model.add(hash, parent: "root")
            model.addWork(big, to: hash)
            events += [.open(hash, big), .close(hash)]
        }
        events.append(.close("root"))
        let index = NamedEulerIndex.build(events: events)
        XCTAssertGreaterThan(index.debugSpilledCount, 0)
        assertMatchesModel(index, model, "rebuilt past 320 bits")
    }

    /// The point of the whole structure: the cost of recording work does NOT
    /// grow with how deep in the block tree it lands, because no ancestor total
    /// exists to update. A per-ancestor structure would grow linearly here.
    func testCostDoesNotGrowWithBlockDepth() {
        var touchedByDepth: [Int: Int] = [:]
        for depth in [200, 400, 800] {
            var index = NamedEulerIndex.empty
            XCTAssertTrue(index.insertRoot("root"))
            var previous = "root"
            for step in 0..<depth {
                let hash = "d-\(step)"
                XCTAssertNotNil(index.insertLeaf(hash, under: previous))
                previous = hash
            }
            // Work on the DEEPEST block: maximally far from the root in the
            // block tree, which is exactly the case that used to cost O(depth).
            let touched = index.add(work(7), at: previous)
            XCTAssertNotNil(touched, "depth \(depth): work must be recorded")
            touchedByDepth[depth] = touched ?? .max
        }

        let measured = "touched \(touchedByDepth)"
        // Quadrupling the depth must not quadruple the cost. Logarithmic growth
        // adds a couple of nodes; a per-ancestor walk would go 200 -> 800.
        XCTAssertLessThanOrEqual(
            touchedByDepth[800]!,
            touchedByDepth[200]! * 2,
            "recording work must not scale with block depth: \(measured)"
        )
        // Logarithmic growth, stated as a relation between the measurements
        // rather than an absolute literal: doubling twice adds a couple of
        // nodes, so the deepest case stays under the sum of the two shallower
        // ones. A per-ancestor structure would be 800 against 600 here.
        XCTAssertLessThanOrEqual(
            touchedByDepth[800]!,
            touchedByDepth[400]! + touchedByDepth[200]!,
            "cost must grow logarithmically, not linearly: \(measured)"
        )
    }
}
