@testable import LatticePoW
@testable import LatticeBlockTree

/// `EulerWorkIndex` under string names, with each block's direct work held
/// beside it: the shape the structure tests are written in. The index names
/// blocks by handle and reads direct work from its source; this keeps both.
struct NamedEulerIndex {
    enum Event {
        case open(String, WorkSum)
        case close(String)
    }

    private struct Work: DirectWorkSource {
        var values: [WorkSum] = []

        func addDirectWork(of block: UInt32, to total: inout WorkTotal) {
            if Int(block) < values.count { total.add(values[Int(block)]) }
        }
    }

    private(set) var index = EulerWorkIndex.empty
    private var work = Work()
    private var handles: [String: UInt32] = [:]
    private var names: [String] = []

    static var empty: NamedEulerIndex { NamedEulerIndex() }

    private mutating func handle(_ name: String) -> UInt32 {
        if let handle = handles[name] { return handle }
        let handle = UInt32(names.count)
        handles[name] = handle
        names.append(name)
        work.values.append(.zero)
        return handle
    }

    func handleIfKnown(_ name: String) -> UInt32? { handles[name] }

    mutating func insertRoot(_ name: String) -> Bool {
        let block = handle(name)
        let work = self.work
        return index.insertRoot(block, in: work)
    }

    mutating func insertLeaf(_ name: String, under parent: String) -> Int? {
        guard let parent = handles[parent] else { return nil }
        let block = handle(name)
        let work = self.work
        return index.insertLeaf(block, under: parent, in: work)
    }

    /// Raise a routed block's direct work by `delta`.
    mutating func add(_ delta: WorkSum, at name: String) -> Int? {
        guard let block = handles[name], index.contains(block) else { return nil }
        work.values[Int(block)] = work.values[Int(block)] + delta
        let work = self.work
        return index.directWorkChanged(at: block, in: work)
    }

    private mutating func events(_ events: [Event]) -> [EulerWorkIndex.Event] {
        events.map {
            switch $0 {
            case let .open(name, value):
                let block = handle(name)
                // A block already in the tree keeps its work: the splice
                // refuses it and must leave everything as it was.
                if !index.contains(block) { work.values[Int(block)] = value }
                return .open(block)
            case let .close(name):
                return .close(handle(name))
            }
        }
    }

    mutating func splice(_ named: [Event], under parent: String) -> Int? {
        guard let parent = handles[parent] else { return nil }
        let events = events(named)
        let work = self.work
        return index.splice(events, under: parent, in: work)
    }

    static func build(events named: [Event]) -> NamedEulerIndex {
        var result = NamedEulerIndex()
        let events = result.events(named)
        result.index = EulerWorkIndex.build(events: events, in: result.work)
        return result
    }

    func subtreeWork(_ name: String) -> WorkSum? {
        handles[name].flatMap { index.subtreeWork($0, in: work) }
    }

    func encloses(_ ancestor: String, _ descendant: String) -> Bool? {
        guard let ancestor = handles[ancestor], let descendant = handles[descendant] else { return nil }
        return index.encloses(ancestor, descendant)
    }

    func anyEncloses(_ ancestors: [String], _ descendants: [String]) -> Bool {
        index.anyEncloses(ancestors.compactMap { handles[$0] }, descendants.compactMap { handles[$0] })
    }

    func subtreeWorkVisiting(_ name: String) -> (work: WorkSum, visits: Int)? {
        handles[name].flatMap { index.subtreeWorkVisiting($0, in: work) }
    }

    var debugInvariantsHold: Bool { index.debugInvariantsHold(in: work) }

    var debugSequence: [(hash: String, isOpen: Bool, value: WorkSum)] {
        index.debugSequence.map {
            (names[Int($0.block)], $0.isOpen, $0.isOpen ? work.values[Int($0.block)] : .zero)
        }
    }

    var debugNodeCount: Int { index.debugNodeCount }
    var debugSpilledCount: Int { index.debugSpilledCount }
}
