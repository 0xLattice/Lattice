import LatticePoW

/// The direct work of each block, as the Euler index reads it: a block's
/// OPEN element carries it, its CLOSE carries zero. The index stores no
/// per-block value of its own, so the block table is the one home of a
/// block's work.
protocol DirectWorkSource {
    func addDirectWork(of block: UInt32, to total: inout WorkTotal)
}

/// Exact subtree work as a RANGE over an Euler tour of the routed block tree.
///
/// The structure this replaces stored one subtree total per segment base and
/// kept those totals true by walking from the mutated block to the root on
/// every admission — O(depth) per event, and depth is chain length, which is
/// the quadratic in adalinxx/lattice-node#64.
///
/// Here no ancestor total is stored at all. Each block contributes two elements
/// to one sequence, an OPEN carrying its direct work and a CLOSE carrying zero,
/// and a block's subtree is exactly the contiguous run between them. A subtree
/// total is therefore a difference of prefix sums, and the ancestor walk is not
/// made cheaper, it ceases to exist: inserting a leaf, or splicing in a whole
/// grafted component, updates nothing above the insertion point, because every
/// enclosing range now contains the new elements by construction.
///
/// A Fenwick tree is the wrong shape for this one level up, even though the
/// library already uses one for direct work within an origin. Fenwick indexing
/// is defined over a dense static array; blocks arrive as leaves in the MIDDLE
/// of the tour, and a mid-array insert renumbers Θ(n) cells. The dynamic form
/// of "prefix sums over a sequence" is a balanced sequence tree, which is what
/// this is.
///
/// Balance is AVL. Its ±1 balance factor is a structural property of the
/// algorithm, not a tunable ceiling: there is no fanout, node size, load factor
/// or rebalance threshold to pick, so this introduces no configurable number.
/// The tree is INSERT-ONLY — nothing is ever removed from fork choice, an
/// exclusion included (work weighs, §9.9) — which removes the hardest half of
/// the implementation and every case that would need one.
///
/// Blocks are named by handle. Block `h`'s OPEN is node `2h` and its CLOSE is
/// node `2h + 1`, so no map from block to node is kept; a node of height 0 is
/// not in the tree. The one representation limit is that node indices and
/// links are UInt32 with `none` = UInt32.max: `reserve` requires
/// `2h + 2 <= UInt32.max`, so block handles run up to 2^31 - 2. Every other
/// `2h`/`2h + 1` here is checked UInt32 arithmetic on a handle `reserve`
/// already admitted, so it cannot overflow.
struct EulerWorkIndex: Sendable {
    /// One step of an Euler tour, by block handle.
    enum Event: Sendable, Equatable {
        case open(UInt32)
        case close(UInt32)

        var node: UInt32 {
            switch self {
            case .open(let block): block * 2
            case .close(let block): block * 2 + 1
            }
        }
    }

    static let none = UInt32.max

    /// `aggregate` is an inline 320-bit sum; one that outgrows 320 bits is
    /// kept exactly in `spilledAggregate` under its node instead.
    private struct Node: Sendable {
        var aggregate: Work320 = .zero
        var left: UInt32 = EulerWorkIndex.none
        var right: UInt32 = EulerWorkIndex.none
        var parent: UInt32 = EulerWorkIndex.none
        /// AVL height; 0 for a node not in the tree.
        var height: UInt8 = 0
    }

    private var nodes: ContiguousArray<Node> = []
    private var root = EulerWorkIndex.none
    private var spilledAggregate: [UInt32: WorkSum] = [:]

    static var empty: EulerWorkIndex { EulerWorkIndex() }

    var isEmpty: Bool { root == Self.none }

    func contains(_ block: UInt32) -> Bool {
        let node = Int(block) * 2
        return node < nodes.count && nodes[node].height != 0
    }

    private func inTree(_ node: UInt32) -> Bool {
        Int(node) < nodes.count && nodes[Int(node)].height != 0
    }

    // MARK: - Queries

    /// Whether `descendant` is `ancestor` or lies in its subtree, or nil when
    /// either is not routed. A subtree is the run between its block's open and
    /// close, so this is two order comparisons, each O(log n) whatever the
    /// distance between the blocks.
    func encloses(_ ancestor: UInt32, _ descendant: UInt32) -> Bool? {
        guard contains(ancestor), contains(descendant) else { return nil }
        let target = descendant * 2
        return !precedes(target, ancestor * 2) && !precedes(ancestor * 2 + 1, target)
    }

    /// Whether some block of `ancestors` is, or encloses, some block of
    /// `descendants`: exactly `encloses(a, d) == true` for some pair, unrouted
    /// blocks left out, in O((|A| + |D|) log |A| log n) rather than per pair.
    /// Tour ranges never cross, they nest or are disjoint, so the outermost
    /// ancestor ranges are disjoint and ordered, and a descendant can lie only
    /// in the last of them that opens before it.
    func anyEncloses(_ ancestors: [UInt32], _ descendants: [UInt32]) -> Bool {
        var ranges: [(open: UInt32, close: UInt32)] = ancestors.compactMap {
            contains($0) ? ($0 * 2, $0 * 2 + 1) : nil
        }
        guard !ranges.isEmpty else { return false }
        ranges.sort { precedes($0.open, $1.open) }
        var outermost: [(open: UInt32, close: UInt32)] = []
        for range in ranges {
            // Opening inside the last kept range means lying wholly inside it.
            if let last = outermost.last, !precedes(last.close, range.open) { continue }
            outermost.append(range)
        }
        for descendant in descendants where contains(descendant) {
            let target = descendant * 2
            // How many outermost ranges open at or before `target`.
            var low = 0, high = outermost.count
            while low < high {
                let middle = (low + high) / 2
                if precedes(target, outermost[middle].open) { high = middle } else { low = middle + 1 }
            }
            if low > 0, !precedes(outermost[low - 1].close, target) { return true }
        }
        return false
    }

    /// Whether node `a` comes before node `b` in the tour: their sides of
    /// their lowest common ancestor in the sequence tree decide it. O(log n),
    /// allocating nothing.
    private func precedes(_ a: UInt32, _ b: UInt32) -> Bool {
        if a == b { return false }
        func depth(_ node: UInt32) -> Int {
            var depth = 0
            var node = node
            while nodes[Int(node)].parent != Self.none {
                node = nodes[Int(node)].parent
                depth += 1
            }
            return depth
        }
        // Climb both to their common ancestor, remembering the node each
        // path arrived from (none when `a` or `b` is the ancestor itself).
        var x = a, y = b
        var fromA = Self.none, fromB = Self.none
        var depthA = depth(a), depthB = depth(b)
        while depthA > depthB { fromA = x; x = nodes[Int(x)].parent; depthA -= 1 }
        while depthB > depthA { fromB = y; y = nodes[Int(y)].parent; depthB -= 1 }
        while x != y {
            fromA = x; x = nodes[Int(x)].parent
            fromB = y; y = nodes[Int(y)].parent
        }
        // -1: in the left subtree, 0: the common ancestor itself, 1: in the right.
        func side(_ child: UInt32) -> Int {
            child == Self.none ? 0 : (nodes[Int(x)].left == child ? -1 : 1)
        }
        return side(fromA) < side(fromB)
    }

    /// Total work in the subtree rooted at `block`, or nil when the block is
    /// not routed into fork choice.
    func subtreeWork(_ block: UInt32, in work: some DirectWorkSource) -> WorkSum? {
        guard contains(block) else { return nil }
        var visits = 0
        return subtreeWork(of: block, in: work, visits: &visits)
    }

    /// Prefix sums are non-decreasing because work is never negative, so the
    /// close prefix always dominates the open prefix and this cannot fail.
    /// The open element is added back because the difference of prefixes
    /// excludes it and the subtree includes it.
    private func subtreeWork(of block: UInt32, in work: some DirectWorkSource, visits: inout Int) -> WorkSum? {
        let through = prefixThrough(block * 2 + 1, in: work, visits: &visits)
        let before = prefixThrough(block * 2, in: work, visits: &visits)
        var total: WorkTotal
        if let through = through.inline, let before = before.inline {
            let (between, borrow) = through.subtractingReportingOverflow(before)
            guard !borrow else { return nil }
            total = WorkTotal(between)
        } else {
            guard let between = through.exact.subtracting(before.exact) else { return nil }
            total = WorkTotal(between)
        }
        work.addDirectWork(of: block, to: &total)
        return total.exact
    }

    // MARK: - Mutation

    /// The block's direct work changed: refresh the aggregates on the path
    /// from its own element to the tree root — O(log n) — and NO block's stored
    /// total, because no block has one. Nil when the block is not routed.
    @discardableResult
    mutating func directWorkChanged(at block: UInt32, in work: some DirectWorkSource) -> Int? {
        guard contains(block) else { return nil }
        var current = block * 2
        var touched = 0
        while current != Self.none {
            refresh(current, in: work)
            touched += 1
            current = nodes[Int(current)].parent
        }
        return touched
    }

    /// Route a block that has no routed children yet, directly inside its
    /// parent's range. Nothing above the parent is touched.
    @discardableResult
    mutating func insertLeaf(_ block: UInt32, under parent: UInt32, in work: some DirectWorkSource) -> Int? {
        splice([.open(block), .close(block)], under: parent, in: work)
    }

    /// Route the first block of a tree, which has no parent to sit inside. A
    /// second root shares the sequence, placed wholly after the first, so the
    /// tours stay disjoint and no range can span two trees.
    @discardableResult
    mutating func insertRoot(_ block: UInt32, in work: some DirectWorkSource) -> Bool {
        guard !contains(block) else { return false }
        reserve(block)
        appendLast(block * 2, in: work)
        appendLast(block * 2 + 1, in: work)
        return true
    }

    /// Splice a whole connected component into its parent's range in one go.
    /// Every ancestor's total is correct the moment the elements land, so a
    /// graft updates nothing above the parent either.
    @discardableResult
    mutating func splice(
        _ events: [Event],
        under parent: UInt32,
        in work: some DirectWorkSource
    ) -> Int? {
        guard contains(parent) else { return nil }
        let anchor = parent * 2 + 1
        // Validate the whole run BEFORE inserting any of it. This structure has
        // no delete, so bailing mid-loop would strand an OPEN with no CLOSE —
        // the caller turns that into an abort rather than silent corruption, but
        // "fails closed" ought to mean closed, not aborted after half a
        // mutation.
        //
        // The check simulates the nesting rather than testing a list of
        // independent conditions, because the precondition IS "this run is a
        // well-formed tour", and a list cannot express that. It rejects a block
        // already opened here or already held, a block already closed, a close
        // that does not match the innermost open, and a run that does not
        // balance (an unclosed open, or a close out of nesting order, which
        // would otherwise insert silently and leave both ranges garbage).
        var stack: [UInt32] = []
        var opened = Set<UInt32>()
        for event in events {
            switch event {
            case let .open(block):
                guard !contains(block), opened.insert(block).inserted else { return nil }
                stack.append(block)
            case let .close(block):
                guard !inTree(block * 2 + 1), stack.popLast() == block else { return nil }
            }
        }
        // Balances to EMPTY, deliberately — a FOREST is a legitimate input, not
        // just a single properly-nested root: a genesis-rooted graft splices
        // the complete tours of its root's child subtrees under that root.
        guard stack.isEmpty else { return nil }
        var touched = 0
        for event in events {
            if case let .open(block) = event { reserve(block) }
            touched += insert(event.node, before: anchor, in: work)
        }
        return touched
    }

    /// Build the whole index from Euler tours in one linear pass. Recovery
    /// uses this; every live mutation is incremental.
    static func build(events: [Event], in work: some DirectWorkSource) -> EulerWorkIndex {
        var index = EulerWorkIndex()
        var order: [UInt32] = []
        order.reserveCapacity(events.count)
        for event in events {
            if case let .open(block) = event { index.reserve(block) }
            order.append(event.node)
        }
        index.root = index.buildBalanced(order, low: 0, high: order.count, in: work)
        if index.root != Self.none { index.nodes[Int(index.root)].parent = Self.none }
        return index
    }

    // MARK: - Sequence tree

    /// Make room for block `block`'s two nodes.
    private mutating func reserve(_ block: UInt32) {
        let needed = Int(block) * 2 + 2
        precondition(needed <= Int(Self.none), "Euler node links are UInt32: block handles below 2^31")
        if nodes.count < needed {
            nodes.append(contentsOf: repeatElement(Node(), count: needed - nodes.count))
        }
    }

    /// Perfectly balanced from a sorted run, so a rebuild costs one pass and
    /// needs no rotations. The midpoint is derived from the run, not chosen.
    private mutating func buildBalanced(
        _ order: [UInt32],
        low: Int,
        high: Int,
        in work: some DirectWorkSource
    ) -> UInt32 {
        guard low < high else { return Self.none }
        let middle = low + (high - low) / 2
        let node = order[middle]
        let left = buildBalanced(order, low: low, high: middle, in: work)
        let right = buildBalanced(order, low: middle + 1, high: high, in: work)
        nodes[Int(node)].left = left
        nodes[Int(node)].right = right
        if left != Self.none { nodes[Int(left)].parent = node }
        if right != Self.none { nodes[Int(right)].parent = node }
        refresh(node, in: work)
        return node
    }

    private func height(_ node: UInt32) -> UInt8 {
        node == Self.none ? 0 : nodes[Int(node)].height
    }

    /// The element's own value: its block's direct work on an OPEN, zero on
    /// a CLOSE.
    private func addValue(of node: UInt32, to total: inout WorkTotal, in work: some DirectWorkSource) {
        if node & 1 == 0 { work.addDirectWork(of: node / 2, to: &total) }
    }

    private func addAggregate(of node: UInt32, to total: inout WorkTotal) {
        guard node != Self.none else { return }
        if !spilledAggregate.isEmpty, let spilled = spilledAggregate[node] {
            total.add(spilled)
        } else {
            total.add(nodes[Int(node)].aggregate)
        }
    }

    private mutating func refresh(_ node: UInt32, in work: some DirectWorkSource) {
        let index = Int(node)
        nodes[index].height = 1 + max(height(nodes[index].left), height(nodes[index].right))
        var total = WorkTotal()
        addAggregate(of: nodes[index].left, to: &total)
        addValue(of: node, to: &total, in: work)
        addAggregate(of: nodes[index].right, to: &total)
        if let inline = total.inline {
            nodes[index].aggregate = inline
            if !spilledAggregate.isEmpty { spilledAggregate.removeValue(forKey: node) }
        } else {
            nodes[index].aggregate = .zero
            spilledAggregate[node] = total.exact
        }
    }

    private func rightmost(_ node: UInt32) -> UInt32 {
        var current = node
        while nodes[Int(current)].right != Self.none { current = nodes[Int(current)].right }
        return current
    }

    /// Insert `node` immediately BEFORE `anchor` in sequence order.
    ///
    /// This is the only insertion primitive the splice path needs: repeatedly
    /// inserting before a parent's CLOSE lands a whole run at the end of that
    /// parent's range, in the order given, with no cursor to carry and no
    /// predecessor walk to get wrong.
    @discardableResult
    private mutating func insert(_ node: UInt32, before anchor: UInt32, in work: some DirectWorkSource) -> Int {
        nodes[Int(node)].height = 1
        if nodes[Int(anchor)].left == Self.none {
            nodes[Int(anchor)].left = node
            nodes[Int(node)].parent = anchor
            refresh(node, in: work)
            return rebalance(from: anchor, in: work)
        }
        let host = rightmost(nodes[Int(anchor)].left)
        nodes[Int(host)].right = node
        nodes[Int(node)].parent = host
        refresh(node, in: work)
        return rebalance(from: host, in: work)
    }

    /// Append `node` at the very end of the sequence.
    @discardableResult
    private mutating func appendLast(_ node: UInt32, in work: some DirectWorkSource) -> Int {
        nodes[Int(node)].height = 1
        guard root != Self.none else {
            root = node
            refresh(node, in: work)
            return 1
        }
        let host = rightmost(root)
        nodes[Int(host)].right = node
        nodes[Int(node)].parent = host
        refresh(node, in: work)
        return rebalance(from: host, in: work)
    }

    /// AVL rebalancing up to the root. The ±1 balance factor is structural, not
    /// a tunable threshold.
    private mutating func rebalance(from node: UInt32, in work: some DirectWorkSource) -> Int {
        var current = node
        var touched = 0
        while current != Self.none {
            refresh(current, in: work)
            touched += 1
            let parent = nodes[Int(current)].parent
            let balance = Int(height(nodes[Int(current)].left)) - Int(height(nodes[Int(current)].right))
            if balance > 1 {
                let left = nodes[Int(current)].left
                if height(nodes[Int(left)].left) < height(nodes[Int(left)].right) {
                    rotateLeft(left, in: work)
                }
                rotateRight(current, in: work)
            } else if balance < -1 {
                let right = nodes[Int(current)].right
                if height(nodes[Int(right)].right) < height(nodes[Int(right)].left) {
                    rotateRight(right, in: work)
                }
                rotateLeft(current, in: work)
            }
            current = parent
        }
        return touched
    }

    private mutating func replaceChild(of parent: UInt32, old: UInt32, new: UInt32) {
        if parent == Self.none {
            root = new
            if new != Self.none { nodes[Int(new)].parent = Self.none }
            return
        }
        if nodes[Int(parent)].left == old {
            nodes[Int(parent)].left = new
        } else {
            nodes[Int(parent)].right = new
        }
        if new != Self.none { nodes[Int(new)].parent = parent }
    }

    private mutating func rotateLeft(_ node: UInt32, in work: some DirectWorkSource) {
        let pivot = nodes[Int(node)].right
        guard pivot != Self.none else { return }
        let parent = nodes[Int(node)].parent
        nodes[Int(node)].right = nodes[Int(pivot)].left
        if nodes[Int(pivot)].left != Self.none { nodes[Int(nodes[Int(pivot)].left)].parent = node }
        nodes[Int(pivot)].left = node
        nodes[Int(node)].parent = pivot
        replaceChild(of: parent, old: node, new: pivot)
        refresh(node, in: work)
        refresh(pivot, in: work)
    }

    private mutating func rotateRight(_ node: UInt32, in work: some DirectWorkSource) {
        let pivot = nodes[Int(node)].left
        guard pivot != Self.none else { return }
        let parent = nodes[Int(node)].parent
        nodes[Int(node)].left = nodes[Int(pivot)].right
        if nodes[Int(pivot)].right != Self.none { nodes[Int(nodes[Int(pivot)].right)].parent = node }
        nodes[Int(pivot)].right = node
        nodes[Int(node)].parent = pivot
        replaceChild(of: parent, old: node, new: pivot)
        refresh(node, in: work)
        refresh(pivot, in: work)
    }

    /// Sum of every element at or before `node` in sequence order. `visits`
    /// counts sequence-tree nodes touched — compiled out in release — so the
    /// O(log n) claim is asserted as a counter on THIS walk, not on a copy.
    private func prefixThrough(_ node: UInt32, in work: some DirectWorkSource, visits: inout Int) -> WorkTotal {
#if DEBUG
        visits += 1
#endif
        var total = WorkTotal()
        addAggregate(of: nodes[Int(node)].left, to: &total)
        addValue(of: node, to: &total, in: work)
        var current = node
        var up = nodes[Int(current)].parent
        while up != Self.none {
#if DEBUG
            visits += 1
#endif
            if nodes[Int(up)].right == current {
                addAggregate(of: nodes[Int(up)].left, to: &total)
                addValue(of: up, to: &total, in: work)
            }
            current = up
            up = nodes[Int(current)].parent
        }
        return total
    }

    // MARK: - Test seams

#if DEBUG
    /// The subtree total together with the sequence-tree nodes visited to
    /// compute it, through the production walk itself, so the O(log n) claim
    /// is asserted as a COUNTER, never as a stopwatch. Two prefix walks, each
    /// bounded by AVL height.
    func subtreeWorkVisiting(_ block: UInt32, in work: some DirectWorkSource) -> (work: WorkSum, visits: Int)? {
        guard contains(block) else { return nil }
        var visits = 0
        guard let total = subtreeWork(of: block, in: work, visits: &visits) else { return nil }
        return (total, visits)
    }

    /// The sequence in order, as (block, isOpen). Structural tests assert this
    /// is a valid Euler tour rather than trusting the inserts.
    var debugSequence: [(block: UInt32, isOpen: Bool)] {
        var result: [(block: UInt32, isOpen: Bool)] = []
        var stack: [UInt32] = []
        var current = root
        while current != Self.none || !stack.isEmpty {
            while current != Self.none {
                stack.append(current)
                current = nodes[Int(current)].left
            }
            let node = stack.removeLast()
            result.append((node / 2, node & 1 == 0))
            current = nodes[Int(node)].right
        }
        return result
    }

    /// Every node's cached aggregate and height agree with its children, and
    /// the AVL invariant holds. A wrong rotation shows up here rather than as a
    /// mysterious fork-choice divergence.
    func debugInvariantsHold(in work: some DirectWorkSource) -> Bool {
        for index in nodes.indices where nodes[index].height != 0 {
            let node = UInt32(index)
            var expected = WorkTotal()
            addAggregate(of: nodes[index].left, to: &expected)
            addValue(of: node, to: &expected, in: work)
            addAggregate(of: nodes[index].right, to: &expected)
            var stored = WorkTotal()
            addAggregate(of: node, to: &stored)
            if stored.exact != expected.exact { return false }
            let expectedHeight = 1 + max(height(nodes[index].left), height(nodes[index].right))
            if nodes[index].height != expectedHeight { return false }
            let balance = Int(height(nodes[index].left)) - Int(height(nodes[index].right))
            if balance > 1 || balance < -1 { return false }
            if nodes[index].left != Self.none, nodes[Int(nodes[index].left)].parent != node {
                return false
            }
            if nodes[index].right != Self.none, nodes[Int(nodes[index].right)].parent != node {
                return false
            }
        }
        return root == Self.none || nodes[Int(root)].parent == Self.none
    }

    var debugNodeCount: Int { nodes.filter { $0.height != 0 }.count }

    /// Nodes whose aggregate outgrew 320 bits and is held spilled.
    var debugSpilledCount: Int { spilledAggregate.count }
#endif
}
