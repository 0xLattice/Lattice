import OrderedCollections
import UInt256
import LatticePrimitives
import LatticePoW

/// One block as held: every per-block fact the tree keeps, inline, named by
/// its handle — the block's index in `BlockGraph.ids`, process-local and
/// never persisted or put on the wire.
///
/// An entry exists for every block the graph NAMES, held or not: a parent
/// named before it arrives is interned as an unheld entry, so the orphans
/// waiting on it hang off it as children and connect when it lands.
struct BlockEntry: Sendable {
    struct Flags: OptionSet, Sendable {
        let rawValue: UInt16
        /// The block itself is held; unset for a parent named before it arrived.
        static let held = Flags(rawValue: 1 << 0)
        /// Its header fields (states, spec, targets, timestamp) are recorded.
        static let hasSnapshot = Flags(rawValue: 1 << 1)
        /// Executed (`ExecutionFrontier`'s validated set).
        static let validated = Flags(rawValue: 1 << 2)
        /// Executed from genesis through executed blocks.
        static let anchored = Flags(rawValue: 1 << 3)
        static let excludedRoot = Flags(rawValue: 1 << 4)
        /// Its parent is held but did not take it as a child: it arrived
        /// before its parent at a height its parent cannot have.
        static let unlinked = Flags(rawValue: 1 << 5)
        /// `directWork` outgrew 320 bits and is held in `spilledDirectWork`.
        static let spilledWork = Flags(rawValue: 1 << 6)
    }

    /// The credited work of every contribution here, grinds and attributed
    /// runs alike: what the block's OPEN element in the weights carries.
    var directWork: Work320 = .zero
    var target: Fixed256 = .zero
    var nextTarget: Fixed256 = .zero
    var height: UInt64 = 0
    var timestamp: Int64 = 0
    /// The block named as parent, held or not; `none` for a root or for a
    /// parent that is not a canonical CID (`BlockGraph.foreignParents`).
    var parent: UInt32 = BlockGraph.none
    var firstChild: UInt32 = BlockGraph.none
    var nextSibling: UInt32 = BlockGraph.none
    /// The height-1 block this block's difficulty anchor is read from.
    var anchor: UInt32 = BlockGraph.none
    var postState: UInt32 = BlockGraph.none
    var prevState: UInt32 = BlockGraph.none
    /// The next block declaring the same post-state, among those whose
    /// transition changes state.
    var nextProducer: UInt32 = BlockGraph.none
    var firstGrind: UInt32 = BlockGraph.none
    var spec: UInt32 = BlockGraph.none
    var flags: Flags = []
}

/// One contribution's one location: its block, its strongest work, and
/// whether it is a parent's attributed run (§9.10) rather than a grind.
/// The single home of "a grind has one location in a chain, and its work
/// only ratchets up".
struct Grind: Sendable {
    var work: Fixed256
    var block: UInt32
    /// The next contribution at the same block.
    var nextAtBlock: UInt32
    var isAttributed: Bool
}

/// The immutable identity of one held block, as a read view.
struct BlockRecord: Sendable, Equatable {
    let blockHash: String
    let parentBlockHash: String?
    let blockHeight: UInt64
    /// See `BlockMeta.childCommitments`.
    let childCommitments: [String: String]
}

/// One chain's whole block tree, in arrays sharing one handle space: the
/// block entries, the contributions, the interned states and specs, the
/// GHOST weights, the canonical path and the run attribution. The ONE
/// representation of the tree — fork choice, the execution frontier and run
/// attribution are extensions over these arrays, never a second copy.
///
/// A class so `ChainTree` copies it by reference; `ChainTree` mutates it only
/// while it holds the one reference (`ChainTree.mutableGraph`).
final class BlockGraph: @unchecked Sendable {
    static let none = UInt32.max
    /// Marks a state handle as an index into `otherStates`.
    static let otherState: UInt32 = 1 << 31

    // MARK: Identities

    private(set) var ids: OrderedSet<BlockID> = []
    var blocks: ContiguousArray<BlockEntry> = []
    /// Parents named by something other than a canonical CID, by the block
    /// naming them: such a parent is never held, so the block never connects.
    var foreignParents: [UInt32: String] = [:]
    /// Blocks naming a held parent at the wrong height: never its children,
    /// but their anchor is still read through it, so `propagateAnchor`
    /// reaches them from here.
    var unlinkedChildren: [UInt32: [UInt32]] = [:]
    var grindIDs: OrderedSet<GrindID> = []
    var grinds: ContiguousArray<Grind> = []
    /// Direct work past 320 bits, for blocks flagged `spilledWork`.
    var spilledDirectWork: [UInt32: WorkSum] = [:]
    /// Declared states that are canonical CIDs, and the head of each one's
    /// producer list.
    var states: OrderedSet<StateID> = []
    var firstProducer: ContiguousArray<UInt32> = []
    /// Declared states that are not canonical CIDs, by their canonical text,
    /// kept apart so such a state never meets a canonical digest. Decoding
    /// refuses a header with any non-standard link (spec §3.1), so only a
    /// fact recorded outside that boundary can name one.
    var otherStates: OrderedSet<String> = []
    var otherFirstProducer: ContiguousArray<UInt32> = []
    var specIDs: OrderedSet<String> = []
    /// Directory → child block CID, for the blocks that commit any.
    var commitments: [UInt32: [String: String]] = [:]
    /// Blocks whose declared spec is not their root's, mapped to their root's
    /// spec (`ChainTree.scheduleSpec(underParent:)`).
    var offRootSpec: [UInt32: UInt32] = [:]
    /// The parentless height-0 blocks, in arrival order.
    var roots: [UInt32] = []
    private(set) var heldCount = 0

    // MARK: Fork choice

    /// The GHOST weights: one Euler range per routed block (`ForkChoice.swift`).
    var weights: EulerWorkIndex = .empty

    // MARK: Execution frontier

    var canonicalTip = BlockGraph.none
    /// The canonical path from its root, in height order.
    var canonical: [UInt32] = []
    var projectedGeneration: UInt64?

    // MARK: Run attribution

    var served: Set<String> = []
    /// Per served directory, each settled block's nearest committer.
    var nearestCarrier: [String: ContiguousArray<UInt32>] = [:]
    var runWork: [String: [UInt32: WorkSum]] = [:]
    var committers: [String: [String: Set<UInt32>]] = [:]

#if DEBUG
    var workUpdateCellCount: UInt64 = 0
    var graftCount: UInt64 = 0
    var graftBlockVisitCount: UInt64 = 0
    var fullCanonicalProjectionCount: UInt64 = 0
    var truncatedCanonicalProjectionCount: UInt64 = 0
    var canonicalProjectionBlockVisitCount: UInt64 = 0
    var canonicalProjectionSegmentVisitCount: UInt64 = 0
    var runUpdateCount: UInt64 = 0
#endif

    init() {}

    /// A second, independent graph with the same contents. Every table is a
    /// value, so this copies references and each table is copied on its
    /// first write.
    func copy() -> BlockGraph {
        let copy = BlockGraph()
        copy.ids = ids
        copy.blocks = blocks
        copy.foreignParents = foreignParents
        copy.unlinkedChildren = unlinkedChildren
        copy.grindIDs = grindIDs
        copy.grinds = grinds
        copy.spilledDirectWork = spilledDirectWork
        copy.states = states
        copy.firstProducer = firstProducer
        copy.otherStates = otherStates
        copy.otherFirstProducer = otherFirstProducer
        copy.specIDs = specIDs
        copy.commitments = commitments
        copy.offRootSpec = offRootSpec
        copy.roots = roots
        copy.heldCount = heldCount
        copy.weights = weights
        copy.canonicalTip = canonicalTip
        copy.canonical = canonical
        copy.projectedGeneration = projectedGeneration
        copy.served = served
        copy.nearestCarrier = nearestCarrier
        copy.runWork = runWork
        copy.committers = committers
#if DEBUG
        copy.workUpdateCellCount = workUpdateCellCount
        copy.graftCount = graftCount
        copy.graftBlockVisitCount = graftBlockVisitCount
        copy.fullCanonicalProjectionCount = fullCanonicalProjectionCount
        copy.truncatedCanonicalProjectionCount = truncatedCanonicalProjectionCount
        copy.canonicalProjectionBlockVisitCount = canonicalProjectionBlockVisitCount
        copy.canonicalProjectionSegmentVisitCount = canonicalProjectionSegmentVisitCount
        copy.runUpdateCount = runUpdateCount
#endif
        return copy
    }

    // MARK: Handles

    /// The held block `hash` names, looked up as given: only a canonical CID
    /// in its canonical spelling names one.
    func handle(_ hash: String) -> UInt32? {
        guard let id = BlockID(hash), let index = ids.firstIndex(of: id),
              blocks[index].flags.contains(.held) else { return nil }
        return UInt32(index)
    }

    /// The entry `id` names, held or not, interning it when new.
    func intern(_ id: BlockID) -> UInt32 {
        let (inserted, index) = ids.append(id)
        if inserted { blocks.append(BlockEntry()) }
        return UInt32(index)
    }

    func hash(_ block: UInt32) -> String {
        ids[Int(block)].string
    }

    func isHeld(_ block: UInt32) -> Bool {
        blocks[Int(block)].flags.contains(.held)
    }

    subscript(block: UInt32) -> BlockEntry {
        get { blocks[Int(block)] }
        _modify { yield &blocks[Int(block)] }
    }

    /// Every held block, in handle order.
    var held: some Collection<UInt32> {
        (0..<UInt32(blocks.count)).lazy.filter { self.blocks[Int($0)].flags.contains(.held) }
    }

    var count: Int { heldCount }

    // MARK: Graph queries

    /// The parent a held block names, held or not; nil for a root.
    func parentHash(of block: UInt32) -> String? {
        let parent = self[block].parent
        if parent != Self.none { return hash(parent) }
        return foreignParents[block]
    }

    /// The held parent `block` hangs under, or `none`: a parent that does not
    /// list it (`unlinked`) is not one.
    func linkedParent(of block: UInt32) -> UInt32 {
        let entry = self[block]
        guard entry.parent != Self.none, isHeld(entry.parent),
              !entry.flags.contains(.unlinked) else { return Self.none }
        return entry.parent
    }

    /// The held children of `block`, newest first.
    func children(of block: UInt32) -> [UInt32] {
        guard isHeld(block) else { return [] }
        var result: [UInt32] = []
        var child = self[block].firstChild
        while child != Self.none {
            result.append(child)
            child = self[child].nextSibling
        }
        return result
    }

    /// `block` and every held descendant, parent before child.
    func subtree(of block: UInt32) -> [UInt32] {
        var result: [UInt32] = []
        var stack = [block]
        while let next = stack.popLast() {
            result.append(next)
            stack.append(contentsOf: children(of: next))
        }
        return result
    }

    func record(of block: UInt32) -> BlockRecord {
        BlockRecord(
            blockHash: hash(block),
            parentBlockHash: parentHash(of: block),
            blockHeight: self[block].height,
            childCommitments: commitments[block] ?? [:]
        )
    }

    // MARK: Work

    /// The contributions at `block`, newest first.
    func grinds(at block: UInt32) -> [UInt32] {
        var result: [UInt32] = []
        var grind = self[block].firstGrind
        while grind != Self.none {
            result.append(grind)
            grind = grinds[Int(grind)].nextAtBlock
        }
        return result
    }

    func grindHandle(_ id: String) -> UInt32? {
        GrindID(id).flatMap { grindIDs.firstIndex(of: $0) }.map(UInt32.init)
    }

    func contribution(_ grind: UInt32) -> VerifiedWorkContribution {
        VerifiedWorkContribution(
            heldID: grindIDs[Int(grind)].string, work: grinds[Int(grind)].work.uint256
        )
    }

    /// The block's credited work: every contribution, exactly.
    func work(of block: UInt32) -> WorkSum {
        var total = WorkTotal()
        addDirectWork(of: block, to: &total)
        return total.exact
    }

    /// The credited work of the block's grinds alone.
    func grindWork(of block: UInt32) -> WorkSum {
        var total = WorkTotal()
        for grind in grinds(at: block) where !grinds[Int(grind)].isAttributed {
            total.add(grinds[Int(grind)].work)
        }
        return total.exact
    }

    /// Credit `work` under `id` at `block`: a new location, or a strictly
    /// stronger observation at the grind's one location. The caller has
    /// checked the location and the ratchet.
    func setWork(_ id: GrindID, _ work: Fixed256, attributed: Bool, at block: UInt32) {
        let (inserted, index) = grindIDs.append(id)
        let grind = UInt32(index)
        let old: Fixed256
        if inserted {
            grinds.append(Grind(
                work: work, block: block, nextAtBlock: self[block].firstGrind, isAttributed: attributed
            ))
            self[block].firstGrind = grind
            old = .zero
        } else {
            precondition(grinds[index].block == block && grinds[index].work < work)
            old = grinds[index].work
            grinds[index].work = work
            if attributed { grinds[index].isAttributed = true }
        }
        let (rise, _) = Work320(work).subtractingReportingOverflow(Work320(old))
        var total = WorkTotal()
        addDirectWork(of: block, to: &total)
        total.add(rise)
        if let inline = total.inline {
            self[block].directWork = inline
            if self[block].flags.contains(.spilledWork) {
                self[block].flags.remove(.spilledWork)
                spilledDirectWork.removeValue(forKey: block)
            }
        } else {
            self[block].directWork = .zero
            self[block].flags.insert(.spilledWork)
            spilledDirectWork[block] = total.exact
        }
    }

    // MARK: States and specs

    /// The handle of a declared state, interning it when new.
    func internState(_ cid: String) -> UInt32 {
        if let id = StateID(cid) {
            let (inserted, index) = states.append(id)
            if inserted { firstProducer.append(Self.none) }
            return UInt32(index)
        }
        let (inserted, index) = otherStates.append(cid)
        if inserted { otherFirstProducer.append(Self.none) }
        return Self.otherState | UInt32(index)
    }

    /// The handle of a state already declared by some block, or nil.
    func stateHandle(_ cid: String) -> UInt32? {
        if let id = StateID(cid) {
            return states.firstIndex(of: id).map(UInt32.init)
        }
        return otherStates.firstIndex(of: cid).map { Self.otherState | UInt32($0) }
    }

    func stateString(_ state: UInt32) -> String {
        state & Self.otherState == 0
            ? states[Int(state)].string
            : otherStates[Int(state & ~Self.otherState)]
    }

    /// The blocks declaring `state` as post-state, among those whose
    /// transition changes state.
    func producers(of state: UInt32) -> [UInt32] {
        var result: [UInt32] = []
        var block = state & Self.otherState == 0
            ? firstProducer[Int(state)]
            : otherFirstProducer[Int(state & ~Self.otherState)]
        while block != Self.none {
            result.append(block)
            block = self[block].nextProducer
        }
        return result
    }

    /// The spec of `block`'s root: its own declared spec unless it sits
    /// under a spec mismatch (`offRootSpec`); nil with no header recorded.
    func rootSpec(of block: UInt32) -> UInt32? {
        if let spec = offRootSpec[block] { return spec }
        let entry = self[block]
        return entry.flags.contains(.hasSnapshot) ? entry.spec : nil
    }

    func internSpec(_ cid: String) -> UInt32 {
        UInt32(specIDs.append(cid).index)
    }

    func specString(_ spec: UInt32) -> String {
        specIDs[Int(spec)]
    }

    /// The recorded header fields of a block, or nil without them.
    func snapshot(of block: UInt32) -> TipBlockSnapshot? {
        let entry = self[block]
        guard entry.flags.contains(.hasSnapshot) else { return nil }
        return TipBlockSnapshot(
            postStateCID: stateString(entry.postState),
            prevStateCID: stateString(entry.prevState),
            specCID: specString(entry.spec),
            target: entry.target.uint256,
            nextTarget: entry.nextTarget.uint256,
            tipHeight: entry.height,
            timestamp: entry.timestamp
        )
    }

    /// Record a held block's header fields, once: a block's committed fields
    /// never change, and the callers compare before re-recording.
    func recordSnapshot(_ snapshot: TipBlockSnapshot, at block: UInt32) {
        guard !self[block].flags.contains(.hasSnapshot) else { return }
        let post = internState(snapshot.postStateCID)
        let prev = internState(snapshot.prevStateCID)
        self[block].postState = post
        self[block].prevState = prev
        self[block].spec = internSpec(snapshot.specCID)
        self[block].target = Fixed256(snapshot.target)
        self[block].nextTarget = Fixed256(snapshot.nextTarget)
        self[block].timestamp = snapshot.timestamp
        self[block].flags.insert(.hasSnapshot)
        guard post != prev else { return }
        if post & Self.otherState == 0 {
            self[block].nextProducer = firstProducer[Int(post)]
            firstProducer[Int(post)] = block
        } else {
            let index = Int(post & ~Self.otherState)
            self[block].nextProducer = otherFirstProducer[index]
            otherFirstProducer[index] = block
        }
    }

    // MARK: Insertion

    /// The children already held for a block not yet held: the blocks
    /// naming it at the height above it. Empty when nothing names it.
    func pendingChildren(of id: BlockID, height: UInt64) -> [UInt32] {
        guard let index = ids.firstIndex(of: id) else { return [] }
        let (childHeight, overflow) = height.addingReportingOverflow(1)
        guard !overflow else { return [] }
        var result: [UInt32] = []
        var child = blocks[index].firstChild
        while child != Self.none {
            if self[child].height == childHeight { result.append(child) }
            child = self[child].nextSibling
        }
        return result
    }

    /// Hold a newly admitted block with no work yet. The orphans already
    /// naming it at the height above become its children; any other block
    /// naming it never will. It joins its held parent's children, or waits
    /// under the parent's unheld entry.
    func insert(
        _ id: BlockID,
        parent: String?,
        height: UInt64,
        childCommitments: [String: String]
    ) -> UInt32 {
        let block = intern(id)
        precondition(!isHeld(block))
        // The orphans already naming it: those at the height above become its
        // children, in the order they wait; any other never will. One pass,
        // however many wait.
        let (childHeight, overflow) = height.addingReportingOverflow(1)
        var children: [UInt32] = []
        var waiting = self[block].firstChild
        while waiting != Self.none {
            if !overflow, self[waiting].height == childHeight {
                children.append(waiting)
            } else {
                self[waiting].flags.insert(.unlinked)
                unlinkedChildren[block, default: []].append(waiting)
            }
            waiting = self[waiting].nextSibling
        }
        self[block].firstChild = Self.none
        for child in children.reversed() {
            self[child].nextSibling = self[block].firstChild
            self[block].firstChild = child
        }
        self[block].height = height
        self[block].flags.insert(.held)
        heldCount += 1
        if !childCommitments.isEmpty {
            commitments[block] = childCommitments
        }
        if let parent {
            if let parentID = BlockID(parent) {
                let parentBlock = intern(parentID)
                self[block].parent = parentBlock
                appendChild(block, to: parentBlock)
            } else {
                foreignParents[block] = parent
            }
        } else {
            roots.append(block)
        }
        return block
    }

    /// Hand `block`'s anchor down to the descendants it just connected that
    /// have none yet — its children and the blocks naming it at the wrong
    /// height alike, since the anchor walk (`ChainTree.difficultyAnchor`)
    /// reads through a held parent either way. Each block's anchor is written
    /// once, so over a chain's life this is O(blocks), and every read is O(1).
    func propagateAnchor(from block: UInt32) {
        let anchor = self[block].anchor
        guard anchor != Self.none else { return }
        var pending = [block]
        func reach(_ child: UInt32) {
            if self[child].anchor == Self.none, self[child].height > 1 {
                self[child].anchor = anchor
                pending.append(child)
            }
        }
        while let next = pending.popLast() {
            var child = self[next].firstChild
            while child != Self.none {
                reach(child)
                child = self[child].nextSibling
            }
            for child in unlinkedChildren[next] ?? [] { reach(child) }
        }
    }

    /// Record `child` first among `parent`'s children: O(1) however many
    /// siblings it has. Child order decides nothing.
    private func appendChild(_ child: UInt32, to parent: UInt32) {
        self[child].nextSibling = self[parent].firstChild
        self[parent].firstChild = child
    }
}

extension BlockGraph: DirectWorkSource {
    func addDirectWork(of block: UInt32, to total: inout WorkTotal) {
        let entry = blocks[Int(block)]
        if entry.flags.contains(.spilledWork), let spilled = spilledDirectWork[block] {
            total.add(spilled)
        } else {
            total.add(entry.directWork)
        }
    }
}
