import LatticePoW

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
struct EulerWorkIndex: Sendable {
    /// One step of an Euler tour. `close` carries no work; all of a block's
    /// direct work sits on its `open`, so a subtree range sums each block once.
    enum Event: Sendable, Equatable {
        case open(String, WorkSum)
        case close(String)
    }

    /// `value` and `aggregate` are inline 320-bit sums. One that outgrows 320
    /// bits is kept exactly in `spilledValue` / `spilledAggregate` under its
    /// node instead, and its inline field is unused.
    private struct Node: Sendable {
        var left: Int = -1
        var right: Int = -1
        var parent: Int = -1
        var height: Int = 1
        var value: Work320 = .zero
        var aggregate: Work320 = .zero
    }

    private var nodes: [Node] = []
    private var root = -1
    private var openNode: [String: Int] = [:]
    private var closeNode: [String: Int] = [:]
    private var spilledValue: [Int: WorkSum] = [:]
    private var spilledAggregate: [Int: WorkSum] = [:]

    static var empty: EulerWorkIndex { EulerWorkIndex() }

    var isEmpty: Bool { root < 0 }

    func contains(_ blockHash: String) -> Bool {
        openNode[blockHash] != nil
    }

    // MARK: - Queries

    /// Whether `descendant` is `ancestor` or lies in its subtree, or nil when
    /// either is not routed. A subtree is the run between its block's open and
    /// close, so this is two order comparisons, each O(log n) whatever the
    /// distance between the blocks.
    func encloses(_ ancestor: String, _ descendant: String) -> Bool? {
        guard let open = openNode[ancestor],
              let close = closeNode[ancestor],
              let target = openNode[descendant] else { return nil }
        return !precedes(target, open) && !precedes(close, target)
    }

    /// Whether some block of `ancestors` is, or encloses, some block of
    /// `descendants`: exactly `encloses(a, d) == true` for some pair, unrouted
    /// blocks left out, in O((|A| + |D|) log |A| log n) rather than per pair.
    /// Tour ranges never cross, they nest or are disjoint, so the outermost
    /// ancestor ranges are disjoint and ordered, and a descendant can lie only
    /// in the last of them that opens before it.
    func anyEncloses(_ ancestors: [String], _ descendants: [String]) -> Bool {
        var ranges: [(open: Int, close: Int)] = ancestors.compactMap {
            guard let open = openNode[$0], let close = closeNode[$0] else { return nil }
            return (open, close)
        }
        guard !ranges.isEmpty else { return false }
        ranges.sort { precedes($0.open, $1.open) }
        var outermost: [(open: Int, close: Int)] = []
        for range in ranges {
            // Opening inside the last kept range means lying wholly inside it.
            if let last = outermost.last, !precedes(last.close, range.open) { continue }
            outermost.append(range)
        }
        for descendant in descendants {
            guard let target = openNode[descendant] else { continue }
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
    private func precedes(_ a: Int, _ b: Int) -> Bool {
        if a == b { return false }
        func depth(_ node: Int) -> Int {
            var depth = 0
            var node = node
            while nodes[node].parent >= 0 {
                node = nodes[node].parent
                depth += 1
            }
            return depth
        }
        // Climb both to their common ancestor, remembering the node each
        // path arrived from (-1 when `a` or `b` is the ancestor itself).
        var x = a, y = b
        var fromA = -1, fromB = -1
        var depthA = depth(a), depthB = depth(b)
        while depthA > depthB { fromA = x; x = nodes[x].parent; depthA -= 1 }
        while depthB > depthA { fromB = y; y = nodes[y].parent; depthB -= 1 }
        while x != y {
            fromA = x; x = nodes[x].parent
            fromB = y; y = nodes[y].parent
        }
        // -1: in the left subtree, 0: the common ancestor itself, 1: in the right.
        func side(_ child: Int) -> Int {
            child < 0 ? 0 : (nodes[x].left == child ? -1 : 1)
        }
        return side(fromA) < side(fromB)
    }

    /// Total work in the subtree rooted at `blockHash`, or nil when the block
    /// is not routed into fork choice.
    ///
    /// This is the same quantity the per-base totals held: a segment base's
    /// quotient subtree spans exactly the block subtree rooted at that base, so
    /// every fork-choice comparison sees the value it saw before.
    func subtreeWork(_ blockHash: String) -> WorkSum? {
        guard let open = openNode[blockHash],
              let close = closeNode[blockHash] else { return nil }
        // Prefix sums are non-decreasing because work is never negative, so the
        // close prefix always dominates the open prefix and this cannot fail.
        // The open element is added back because the difference of prefixes
        // excludes it and the subtree includes it.
        var visits = 0
        return subtreeWork(open: open, close: close, visits: &visits)
    }

    private func subtreeWork(open: Int, close: Int, visits: inout Int) -> WorkSum? {
        let through = prefixThrough(close, visits: &visits)
        let before = prefixThrough(open, visits: &visits)
        var total: WorkTotal
        if let through = through.inline, let before = before.inline {
            let (between, borrow) = through.subtractingReportingOverflow(before)
            guard !borrow else { return nil }
            total = WorkTotal(between)
        } else {
            guard let between = through.exact.subtracting(before.exact) else { return nil }
            total = WorkTotal(between)
        }
        addValue(of: open, to: &total)
        return total.exact
    }

    // MARK: - Mutation

    /// Record a strictly positive work increase on one block. Only the path
    /// from that block's own element to the tree root is touched — O(log n)
    /// node aggregates — and NO block's stored total is updated, because no
    /// block has one.
    @discardableResult
    mutating func add(_ delta: WorkSum, at blockHash: String) -> Int? {
        guard let open = openNode[blockHash] else { return nil }
        var total = WorkTotal()
        addValue(of: open, to: &total)
        total.add(delta)
        setValue(total, of: open)
        return repairAggregates(from: open)
    }

    /// Route a block that has no children yet, directly inside its parent's
    /// range. Nothing above the parent is touched.
    @discardableResult
    mutating func insertLeaf(
        _ blockHash: String,
        under parentHash: String
    ) -> Int? {
        splice([.open(blockHash, .zero), .close(blockHash)], under: parentHash)
    }

    /// Route the first block of a tree, which has no parent to sit inside.
    @discardableResult
    mutating func insertRoot(_ blockHash: String) -> Bool {
        guard openNode[blockHash] == nil else { return false }
        // A second root shares the sequence, placed wholly after the first, so
        // the tours stay disjoint and no range can span two trees.
        let open = makeNode()
        openNode[blockHash] = open
        appendLast(open)
        let close = makeNode()
        closeNode[blockHash] = close
        appendLast(close)
        return true
    }

    /// Splice a whole connected component into its parent's range in one go.
    /// Every ancestor's total is correct the moment the elements land, so a
    /// graft updates nothing above the parent either.
    @discardableResult
    mutating func splice(
        _ events: [Event],
        under parentHash: String
    ) -> Int? {
        guard let anchor = closeNode[parentHash] else { return nil }
        // Validate the whole run BEFORE inserting any of it. This structure has
        // no delete, so bailing mid-loop would strand an OPEN with no CLOSE —
        // the caller turns that into an abort rather than silent corruption, but
        // "fails closed" ought to mean closed, not aborted after half a
        // mutation.
        //
        // The check simulates the nesting rather than testing a list of
        // independent conditions, because the precondition IS "this run is a
        // well-formed tour", and a list cannot express that.
        //
        // Do NOT re-derive this from the guards in the loop below. Two malformed
        // runs make that loop SUCCEED and silently insert a corrupt tour, so
        // auditing its guards cannot find them:
        //
        //   - an unclosed open, `[open(Y)]`, inserts an OPEN with no CLOSE;
        //   - a close out of nesting order, `[open(a), open(b), close(a),
        //     close(b)]`, satisfies every guard and inserts
        //     `a_open b_open a_close b_close`, after which the subtree range of
        //     both blocks is garbage.
        //
        // Those are worse than a refusal. The rest are rejections the loop would
        // reach only after mutating: with a pending-opens set alone
        // `[open(A), close(A), close(A)]` validates clean — validation never
        // writes `closeNode`, so the duplicate close sees it still nil — and the
        // loop strands two inserts before bailing.
        //
        // The simulation rejects every malformed run, including the two the loop
        // accepts silently, across four guard classes: a block already opened
        // here or already held (`openNode`), a block already closed
        // (`closeNode`), a close that does not match the innermost open, and a
        // run that does not balance.
        var stack: [String] = []
        var opened = Set<String>()
        for event in events {
            switch event {
            case let .open(hash, _):
                guard openNode[hash] == nil,
                      opened.insert(hash).inserted else { return nil }
                stack.append(hash)
            case let .close(hash):
                guard closeNode[hash] == nil,
                      stack.popLast() == hash else { return nil }
            }
        }
        // Balances to EMPTY, deliberately — a FOREST is a legitimate input, not
        // just a single properly-nested root. `graftConnectedComponent`'s
        // genesis branch splices `events.dropFirst().dropLast()` under the
        // component root, which is the concatenated complete tours of that
        // root's child subtrees. Tightening this to "one root, properly nested"
        // would refuse every genesis-rooted graft, and the caller turns a nil
        // into `precondition(graftConnectedComponent(…))` — a live node abort on
        // entirely valid input.
        guard stack.isEmpty else { return nil }
        var touched = 0
        for event in events {
            switch event {
            case let .open(hash, work):
                guard openNode[hash] == nil else { return nil }
                let node = makeNode(value: work)
                openNode[hash] = node
                touched += insert(node, before: anchor)
            case let .close(hash):
                guard openNode[hash] != nil, closeNode[hash] == nil else {
                    return nil
                }
                let node = makeNode()
                closeNode[hash] = node
                touched += insert(node, before: anchor)
            }
        }
        return touched
    }

    /// Build the whole index from an Euler tour in one linear pass. Recovery
    /// uses this; every live mutation is incremental.
    static func build(events: [Event]) -> EulerWorkIndex {
        var index = EulerWorkIndex()
        index.nodes.reserveCapacity(events.count)
        var order: [Int] = []
        order.reserveCapacity(events.count)
        for event in events {
            switch event {
            case let .open(hash, work):
                let node = index.makeNode(value: work)
                index.openNode[hash] = node
                order.append(node)
            case let .close(hash):
                let node = index.makeNode()
                index.closeNode[hash] = node
                order.append(node)
            }
        }
        index.root = index.buildBalanced(order, low: 0, high: order.count)
        if index.root >= 0 { index.nodes[index.root].parent = -1 }
        return index
    }

    // MARK: - Sequence tree

    private mutating func makeNode(value: WorkSum = .zero) -> Int {
        nodes.append(Node())
        let node = nodes.count - 1
        setValue(WorkTotal(value), of: node)
        refresh(node)
        return node
    }

    /// Store `total` as `node`'s value: inline, or spilled when it outgrows
    /// 320 bits.
    private mutating func setValue(_ total: WorkTotal, of node: Int) {
        if let inline = total.inline {
            nodes[node].value = inline
            if !spilledValue.isEmpty { spilledValue.removeValue(forKey: node) }
        } else {
            nodes[node].value = .zero
            spilledValue[node] = total.exact
        }
    }

    private func addValue(of node: Int, to total: inout WorkTotal) {
        if !spilledValue.isEmpty, let spilled = spilledValue[node] {
            total.add(spilled)
        } else {
            total.add(nodes[node].value)
        }
    }

    private func addAggregate(of node: Int, to total: inout WorkTotal) {
        guard node >= 0 else { return }
        if !spilledAggregate.isEmpty, let spilled = spilledAggregate[node] {
            total.add(spilled)
        } else {
            total.add(nodes[node].aggregate)
        }
    }

    /// Perfectly balanced from a sorted run, so a rebuild costs one pass and
    /// needs no rotations. The midpoint is derived from the run, not chosen.
    private mutating func buildBalanced(
        _ order: [Int],
        low: Int,
        high: Int
    ) -> Int {
        guard low < high else { return -1 }
        let middle = low + (high - low) / 2
        let node = order[middle]
        let left = buildBalanced(order, low: low, high: middle)
        let right = buildBalanced(order, low: middle + 1, high: high)
        nodes[node].left = left
        nodes[node].right = right
        if left >= 0 { nodes[left].parent = node }
        if right >= 0 { nodes[right].parent = node }
        refresh(node)
        return node
    }

    private func height(_ node: Int) -> Int {
        node < 0 ? 0 : nodes[node].height
    }

    private mutating func refresh(_ node: Int) {
        nodes[node].height = 1 + max(height(nodes[node].left), height(nodes[node].right))
        var total = WorkTotal()
        addAggregate(of: nodes[node].left, to: &total)
        addValue(of: node, to: &total)
        addAggregate(of: nodes[node].right, to: &total)
        if let inline = total.inline {
            nodes[node].aggregate = inline
            if !spilledAggregate.isEmpty { spilledAggregate.removeValue(forKey: node) }
        } else {
            nodes[node].aggregate = .zero
            spilledAggregate[node] = total.exact
        }
    }

    private func rightmost(_ node: Int) -> Int {
        var current = node
        while nodes[current].right >= 0 { current = nodes[current].right }
        return current
    }

    /// Insert `node` immediately BEFORE `anchor` in sequence order.
    ///
    /// This is the only insertion primitive the splice path needs: repeatedly
    /// inserting before a parent's CLOSE lands a whole run at the end of that
    /// parent's range, in the order given, with no cursor to carry and no
    /// predecessor walk to get wrong.
    @discardableResult
    private mutating func insert(_ node: Int, before anchor: Int) -> Int {
        if nodes[anchor].left < 0 {
            nodes[anchor].left = node
            nodes[node].parent = anchor
            return rebalance(from: anchor)
        }
        let host = rightmost(nodes[anchor].left)
        nodes[host].right = node
        nodes[node].parent = host
        return rebalance(from: host)
    }

    /// Append `node` at the very end of the sequence.
    @discardableResult
    private mutating func appendLast(_ node: Int) -> Int {
        guard root >= 0 else {
            root = node
            refresh(node)
            return 1
        }
        let host = rightmost(root)
        nodes[host].right = node
        nodes[node].parent = host
        return rebalance(from: host)
    }

    /// Refresh aggregates from `node` to the root without touching structure.
    /// This is the whole cost of a work update: one root-ward path in the
    /// SEQUENCE tree, which is O(log n), not a walk over block ancestors.
    @discardableResult
    private mutating func repairAggregates(from node: Int) -> Int {
        var current = node
        var touched = 0
        while current >= 0 {
            refresh(current)
            touched += 1
            current = nodes[current].parent
        }
        return touched
    }

    /// AVL rebalancing up to the root. The ±1 balance factor is structural, not
    /// a tunable threshold.
    private mutating func rebalance(from node: Int) -> Int {
        var current = node
        var touched = 0
        while current >= 0 {
            refresh(current)
            touched += 1
            let parent = nodes[current].parent
            let balance = height(nodes[current].left) - height(nodes[current].right)
            if balance > 1 {
                let left = nodes[current].left
                if height(nodes[left].left) < height(nodes[left].right) {
                    rotateLeft(left)
                }
                rotateRight(current)
            } else if balance < -1 {
                let right = nodes[current].right
                if height(nodes[right].right) < height(nodes[right].left) {
                    rotateRight(right)
                }
                rotateLeft(current)
            }
            current = parent
        }
        return touched
    }

    private mutating func replaceChild(of parent: Int, old: Int, new: Int) {
        if parent < 0 {
            root = new
            if new >= 0 { nodes[new].parent = -1 }
            return
        }
        if nodes[parent].left == old {
            nodes[parent].left = new
        } else {
            nodes[parent].right = new
        }
        if new >= 0 { nodes[new].parent = parent }
    }

    private mutating func rotateLeft(_ node: Int) {
        let pivot = nodes[node].right
        guard pivot >= 0 else { return }
        let parent = nodes[node].parent
        nodes[node].right = nodes[pivot].left
        if nodes[pivot].left >= 0 { nodes[nodes[pivot].left].parent = node }
        nodes[pivot].left = node
        nodes[node].parent = pivot
        replaceChild(of: parent, old: node, new: pivot)
        refresh(node)
        refresh(pivot)
    }

    private mutating func rotateRight(_ node: Int) {
        let pivot = nodes[node].left
        guard pivot >= 0 else { return }
        let parent = nodes[node].parent
        nodes[node].left = nodes[pivot].right
        if nodes[pivot].right >= 0 { nodes[nodes[pivot].right].parent = node }
        nodes[pivot].right = node
        nodes[node].parent = pivot
        replaceChild(of: parent, old: node, new: pivot)
        refresh(node)
        refresh(pivot)
    }

    /// Sum of every element at or before `node` in sequence order. `visits`
    /// counts sequence-tree nodes touched — compiled out in release — so the
    /// O(log n) claim is asserted as a counter on THIS walk, not on a copy.
    private func prefixThrough(_ node: Int, visits: inout Int) -> WorkTotal {
#if DEBUG
        visits += 1
#endif
        var total = WorkTotal()
        addAggregate(of: nodes[node].left, to: &total)
        addValue(of: node, to: &total)
        var current = node
        var up = nodes[current].parent
        while up >= 0 {
#if DEBUG
            visits += 1
#endif
            if nodes[up].right == current {
                addAggregate(of: nodes[up].left, to: &total)
                addValue(of: up, to: &total)
            }
            current = up
            up = nodes[current].parent
        }
        return total
    }

    // MARK: - Test seams

#if DEBUG
    /// The subtree total together with the sequence-tree nodes visited to
    /// compute it, through the production walk itself, so the O(log n) claim
    /// is asserted as a COUNTER (like `stateContinuityBlockVisitCount`), never
    /// as a stopwatch. Two prefix walks, each bounded by AVL height.
    func subtreeWorkVisiting(_ blockHash: String) -> (work: WorkSum, visits: Int)? {
        guard let open = openNode[blockHash],
              let close = closeNode[blockHash] else { return nil }
        var visits = 0
        guard let work = subtreeWork(open: open, close: close, visits: &visits) else { return nil }
        return (work, visits)
    }
#endif

#if DEBUG
    /// The sequence in order, as (blockHash, isOpen, value). Structural tests
    /// assert this is a valid Euler tour rather than trusting the inserts.
    var debugSequence: [(hash: String, isOpen: Bool, value: WorkSum)] {
        var hashByOpen: [Int: String] = [:]
        var hashByClose: [Int: String] = [:]
        for (hash, node) in openNode { hashByOpen[node] = hash }
        for (hash, node) in closeNode { hashByClose[node] = hash }
        var result: [(hash: String, isOpen: Bool, value: WorkSum)] = []
        var stack: [Int] = []
        var current = root
        while current >= 0 || !stack.isEmpty {
            while current >= 0 {
                stack.append(current)
                current = nodes[current].left
            }
            let node = stack.removeLast()
            var value = WorkTotal()
            addValue(of: node, to: &value)
            if let hash = hashByOpen[node] {
                result.append((hash, true, value.exact))
            } else if let hash = hashByClose[node] {
                result.append((hash, false, value.exact))
            }
            current = nodes[node].right
        }
        return result
    }

    /// Every node's cached aggregate and height agree with its children, and
    /// the AVL invariant holds. A wrong rotation shows up here rather than as a
    /// mysterious fork-choice divergence.
    var debugInvariantsHold: Bool {
        for node in nodes.indices {
            var expected = WorkTotal()
            addAggregate(of: nodes[node].left, to: &expected)
            addValue(of: node, to: &expected)
            addAggregate(of: nodes[node].right, to: &expected)
            var stored = WorkTotal()
            addAggregate(of: node, to: &stored)
            if stored.exact != expected.exact { return false }
            let expectedHeight = 1 + max(
                height(nodes[node].left),
                height(nodes[node].right)
            )
            if nodes[node].height != expectedHeight { return false }
            let balance = height(nodes[node].left) - height(nodes[node].right)
            if balance > 1 || balance < -1 { return false }
            if nodes[node].left >= 0, nodes[nodes[node].left].parent != node {
                return false
            }
            if nodes[node].right >= 0, nodes[nodes[node].right].parent != node {
                return false
            }
        }
        return root < 0 || nodes[root].parent == -1
    }

    var debugNodeCount: Int { nodes.count }

    /// Nodes whose value or aggregate outgrew 320 bits and is held spilled.
    var debugSpilledCount: Int { spilledValue.count + spilledAggregate.count }
#endif
}
