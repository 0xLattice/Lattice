import XCTest
import UInt256
@testable import LatticePoW
@testable import LatticeBlockTree

/// `EulerWorkIndex.encloses` — the ancestry test behind parent-anchor
/// monotonicity — against a naive parent walk, under every way the index is
/// built: leaf insertion (AVL rotations), multiple roots, spliced components
/// and forests (orphan grafts, genesis-rooted grafts), and the linear rebuild
/// recovery uses.
final class EulerEnclosureConstructionTests: XCTestCase {
    private struct Forest {
        var parent: [String: String] = [:]
        var nodes: [String] = []

        mutating func add(_ hash: String, under parentHash: String?) {
            nodes.append(hash)
            if let parentHash { parent[hash] = parentHash }
        }

        func isAncestorOrSelf(_ ancestor: String, _ descendant: String) -> Bool {
            var cursor: String? = descendant
            while let hash = cursor {
                if hash == ancestor { return true }
                cursor = parent[hash]
            }
            return false
        }

        func ancestors(of hash: String) -> [String] {
            var result: [String] = []
            var cursor: String? = hash
            while let current = cursor {
                result.append(current)
                cursor = parent[current]
            }
            return result
        }

        /// A tour of the forest, children in a random order, roots too.
        func tour(_ rng: inout AnchorRandom) -> [NamedEulerIndex.Event] {
            var children: [String: [String]] = [:]
            var roots: [String] = []
            for node in nodes {
                if let p = parent[node] { children[p, default: []].append(node) } else { roots.append(node) }
            }
            rng.shuffle(&roots)
            var events: [NamedEulerIndex.Event] = []
            for root in roots {
                var stack: [(String, [String], Int)] = []
                var kids = children[root] ?? []
                rng.shuffle(&kids)
                events.append(.open(root, WorkSum(UInt256(1))))
                stack.append((root, kids, 0))
                while var frame = stack.popLast() {
                    guard frame.2 < frame.1.count else { events.append(.close(frame.0)); continue }
                    let child = frame.1[frame.2]
                    frame.2 += 1
                    stack.append(frame)
                    var grand = children[child] ?? []
                    rng.shuffle(&grand)
                    events.append(.open(child, WorkSum(UInt256(1))))
                    stack.append((child, grand, 0))
                }
            }
            return events
        }
    }

    /// All pairs when small; otherwise every (ancestor, node) pair on every
    /// node's root path — all the TRUE answers — plus random pairs.
    @discardableResult
    private func assertEncloses(
        _ index: NamedEulerIndex, _ forest: Forest, _ rng: inout AnchorRandom,
        randomPairs: Int = 100_000, _ what: String
    ) -> Int {
        XCTAssertTrue(index.debugInvariantsHold, "\(what): AVL invariants")
        var checked = 0
        func check(_ a: String, _ b: String) -> Bool {
            checked += 1
            let got = index.encloses(a, b)
            let expected = forest.isAncestorOrSelf(a, b)
            if got != expected {
                XCTFail("\(what): encloses(\(a), \(b)) = \(String(describing: got)), expected \(expected)")
                return false
            }
            return true
        }
        if forest.nodes.count <= 700 {
            for a in forest.nodes { for b in forest.nodes { guard check(a, b) else { return checked } } }
        } else {
            for b in forest.nodes {
                for a in forest.ancestors(of: b) { guard check(a, b) else { return checked } }
            }
            for _ in 0..<randomPairs {
                guard check(rng.pick(forest.nodes), rng.pick(forest.nodes)) else { return checked }
            }
        }
        XCTAssertNil(index.encloses(forest.nodes[0], "absent"))
        XCTAssertNil(index.encloses("absent", forest.nodes[0]))
        return checked
    }

    func testLeafInsertionWithManyRotationsAndRoots() {
        var total = 0
        for seed in 1...UInt64(6) {
            var rng = AnchorRandom(seed: seed)
            var index = NamedEulerIndex.empty
            var forest = Forest()
            let count = seed <= 3 ? 600 : 3_000
            for i in 0..<count {
                let hash = "n\(i)"
                if forest.nodes.isEmpty || rng.chance(1) {
                    XCTAssertTrue(index.insertRoot(hash))
                    forest.add(hash, under: nil)
                    continue
                }
                // Long runs (deep chains insert at the tour's interior end)
                // and bushy forks both.
                let under = rng.chance(60)
                    ? forest.nodes[max(0, forest.nodes.count - 1 - rng.next(2))]
                    : rng.pick(forest.nodes)
                XCTAssertNotNil(index.insertLeaf(hash, under: under))
                forest.add(hash, under: under)
            }
            total += assertEncloses(index, forest, &rng, "leaves seed \(seed)")
            // The linear rebuild of the same forest, in another tour order.
            let rebuilt = NamedEulerIndex.build(events: forest.tour(&rng))
            total += assertEncloses(rebuilt, forest, &rng, "rebuild seed \(seed)")
        }
        print("[euler-leaves] encloses checks \(total)")
    }

    func testSplicedComponentsAndForests() {
        var total = 0
        for seed in 1...UInt64(8) {
            var rng = AnchorRandom(seed: seed &* 31)
            var index = NamedEulerIndex.empty
            var forest = Forest()
            var next = 0
            func fresh() -> String { next += 1; return "s\(next)" }
            XCTAssertTrue(index.insertRoot(fresh()))
            forest.add("s1", under: nil)
            while forest.nodes.count < (seed <= 4 ? 600 : 2_500) {
                switch rng.next(4) {
                case 0:
                    let hash = fresh(), under = rng.pick(forest.nodes)
                    XCTAssertNotNil(index.insertLeaf(hash, under: under))
                    forest.add(hash, under: under)
                case 1, 2:
                    // An orphan component (or a forest of them) arriving
                    // before its parent and spliced in whole.
                    var component = Forest()
                    let roots = 1 + rng.next(3)
                    for _ in 0..<roots { component.add(fresh(), under: nil) }
                    for _ in 0..<rng.next(40) {
                        component.add(fresh(), under: rng.pick(component.nodes))
                    }
                    let under = rng.pick(forest.nodes)
                    XCTAssertNotNil(index.splice(component.tour(&rng), under: under))
                    for node in component.nodes {
                        forest.add(node, under: component.parent[node] ?? under)
                    }
                default:
                    // A genesis-rooted graft: a new root, then its children's
                    // tours spliced as a forest under it.
                    let root = fresh()
                    XCTAssertTrue(index.insertRoot(root))
                    forest.add(root, under: nil)
                    var inner = Forest()
                    for _ in 0..<(1 + rng.next(3)) { inner.add(fresh(), under: nil) }
                    for _ in 0..<rng.next(30) { inner.add(fresh(), under: rng.pick(inner.nodes)) }
                    XCTAssertNotNil(index.splice(inner.tour(&rng), under: root))
                    for node in inner.nodes { forest.add(node, under: inner.parent[node] ?? root) }
                }
            }
            total += assertEncloses(index, forest, &rng, "splice seed \(seed)")
            total += assertEncloses(NamedEulerIndex.build(events: forest.tour(&rng)), forest, &rng, "rebuild seed \(seed)")
        }
        print("[euler-splice] encloses checks \(total)")
    }
}
