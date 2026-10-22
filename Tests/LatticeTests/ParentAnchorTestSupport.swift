import XCTest
import UInt256
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeBlockTree

/// Seeded xorshift: every generated tree is reproducible from its seed.
struct AnchorRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next(_ bound: Int) -> Int {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return bound <= 0 ? 0 : Int(state % UInt64(bound))
    }
    mutating func chance(_ percent: Int) -> Bool { next(100) < percent }
    mutating func pick<T>(_ values: [T]) -> T { values[next(values.count)] }
    mutating func shuffle<T>(_ values: inout [T]) {
        guard values.count > 1 else { return }
        for i in stride(from: values.count - 1, to: 0, by: -1) {
            values.swapAt(i, next(i + 1))
        }
    }
}

/// Real CIDs are expensive to mint, so the generators draw from fixed pools.
enum AnchorCIDPool {
    static let blocks: [String] = (0..<4_096).map { testCID("anchor-prop-block-\($0)") }
    static let grinds: [String] = (0..<4_096).map { testCID("anchor-prop-grind-\($0)") }
    static let states: [String] = (0..<64).map { testCID("anchor-prop-state-\($0)") }
    static let neverSeen = testCID("anchor-prop-never-seen")
    static let spec = testCID("anchor-prop-spec")
    static var empty: String { LatticeState.emptyHeader.rawCID }
}

/// One block of a generated parent tree. A `phantom` block is part of the
/// model's shape but is never delivered, so its descendants stay orphans.
struct AnchorModelBlock {
    let hash: String
    let parent: String?
    let height: UInt64
    let prev: String
    let post: String
    let grind: String
    var phantom = false
    var executed = false
    var excluded = false
    /// Executed, but the validation arrives as its own later batch.
    var separateValidation = false
}

struct AnchorModel {
    var blocks: [AnchorModelBlock] = []
    var byHash: [String: Int] = [:]

    mutating func add(_ block: AnchorModelBlock) {
        byHash[block.hash] = blocks.count
        blocks.append(block)
    }

    subscript(_ hash: String) -> AnchorModelBlock? { byHash[hash].map { blocks[$0] } }

    var delivered: [AnchorModelBlock] { blocks.filter { !$0.phantom } }

    /// Executed, delivered, not excluded, and so is every ancestor up to a
    /// genesis — the executed set, computed independently of the library.
    func anchored() -> Set<String> {
        var memo: [String: Bool] = [:]
        func isAnchored(_ hash: String) -> Bool {
            if let known = memo[hash] { return known }
            guard let block = self[hash], !block.phantom, block.executed, !block.excluded else {
                memo[hash] = false
                return false
            }
            let result = block.parent.map(isAnchored) ?? true
            memo[hash] = result
            return result
        }
        return Set(blocks.map(\.hash).filter(isAnchored))
    }

    func isAncestorOrSelf(_ ancestor: String, _ descendant: String) -> Bool {
        var cursor: String? = descendant
        while let hash = cursor {
            if hash == ancestor { return true }
            cursor = self[hash]?.parent
        }
        return false
    }

    /// §5.3 step 6 in the model's own terms. "Produced" is a transition that
    /// changes state (`prev != post`), which is how the library indexes it.
    func advanced(from: String, to: String, anchored: Set<String>) -> Bool {
        func producers(_ state: String) -> [String] {
            blocks.filter { anchored.contains($0.hash) && $0.post == state && $0.prev != $0.post }.map(\.hash)
        }
        let later = producers(to)
        if from == to || from == AnchorCIDPool.empty { return !later.isEmpty }
        let earlier = producers(from)
        return later.contains { q in earlier.contains { isAncestorOrSelf($0, q) } }
    }

    // MARK: Facts

    func blockFact(_ block: AnchorModelBlock) -> ChainBlockFact {
        ChainBlockFact(
            blockHash: block.hash, parentBlockHash: block.parent, blockHeight: block.height,
            postStateCID: block.post, prevStateCID: block.prev, specCID: AnchorCIDPool.spec,
            target: UInt256.max.toHexString(), nextTarget: UInt256.max.toHexString(),
            timestamp: Int64(block.height), stateDiff: .empty
        )
    }

    func blockBatch(_ block: AnchorModelBlock) -> BlockImportBatch {
        var facts: [ChainFact] = [
            .block(blockFact(block)),
            .work(ChainWorkFact(
                blockHash: block.hash,
                contribution: VerifiedWorkContribution(id: block.grind, work: 1)
            )),
        ]
        if block.executed && !block.separateValidation {
            facts.append(.validation(ChainValidationFact(blockHash: block.hash)))
        }
        return BlockImportBatch(facts: facts)
    }

    /// Every batch the delivered blocks produce, in no particular order.
    func allBatches() -> [BlockImportBatch] {
        var batches: [BlockImportBatch] = []
        for block in delivered {
            batches.append(blockBatch(block))
            if block.executed && block.separateValidation {
                batches.append(.validation(blockHash: block.hash))
            }
            if block.excluded {
                batches.append(BlockImportBatch(facts: [.exclusion(ChainExclusionFact(blockHash: block.hash))]))
            }
        }
        return batches
    }

    /// A live admission order: a delivered genesis first, then blocks in random
    /// order (children before parents included, so orphan components graft),
    /// with separate validations and exclusions landing at random points after
    /// their block.
    func liveOrder(_ rng: inout AnchorRandom, topological: Bool) -> [BlockImportBatch] {
        var order = delivered
        if topological {
            order.sort { $0.height < $1.height }
        } else {
            rng.shuffle(&order)
        }
        if let first = order.firstIndex(where: { $0.parent == nil }) {
            order.insert(order.remove(at: first), at: 0)
        }
        var batches: [BlockImportBatch] = []
        var pending: [BlockImportBatch] = []
        var cursor = 0
        while cursor < order.count || !pending.isEmpty {
            if cursor < order.count, pending.isEmpty || rng.chance(60) {
                let block = order[cursor]
                cursor += 1
                batches.append(blockBatch(block))
                if block.executed && block.separateValidation {
                    pending.append(.validation(blockHash: block.hash))
                }
                if block.excluded {
                    pending.append(BlockImportBatch(facts: [.exclusion(ChainExclusionFact(blockHash: block.hash))]))
                }
            } else {
                batches.append(pending.remove(at: rng.next(pending.count)))
            }
        }
        return batches
    }

    /// Built incrementally through the live reducer, one batch at a time.
    func liveTree(_ batches: [BlockImportBatch]) throws -> ChainTree {
        var tree = try ChainTree.restoreWithoutContext(replaying: [batches[0]])
        for batch in batches.dropFirst() {
            _ = try tree.apply(batch)
        }
        return tree
    }

    /// Built wholesale from block metadata, as the graph-snapshot initializer
    /// does: `ForkChoice.build(from:)` and `seedAnchored`. It carries no
    /// exclusions, so it is only comparable for models without any.
    func wholesaleTree() throws -> ChainTree {
        var children: [String: [String]] = [:]
        for block in delivered {
            if let parent = block.parent, self[parent]?.phantom == false {
                children[parent, default: []].append(block.hash)
            }
        }
        var metas: [String: BlockMeta] = [:]
        var snapshots: [String: TipBlockSnapshot] = [:]
        var validated: Set<String> = []
        for block in delivered {
            metas[block.hash] = BlockMeta(
                blockHash: block.hash, parentBlockHash: block.parent, blockHeight: block.height,
                childHashes: children[block.hash] ?? [],
                workContributions: [VerifiedWorkContribution(id: block.grind, work: 1)]
            )
            snapshots[block.hash] = TipBlockSnapshot(
                postStateCID: block.post, prevStateCID: block.prev, specCID: AnchorCIDPool.spec,
                target: .max, nextTarget: .max, tipHeight: block.height, timestamp: Int64(block.height)
            )
            if block.executed { validated.insert(block.hash) }
        }
        return try ChainTree(
            canonicalTip: "", canonicalHashes: [], indexToBlockHash: [:], hashToBlock: metas,
            tipSnapshotsByHash: snapshots, validatedBlocks: validated
        )
    }

    /// The state CIDs worth asking about: every state a block names, the
    /// genesis pre-state, and one nobody produced.
    var queryStates: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for state in blocks.flatMap({ [$0.prev, $0.post] }) + [AnchorCIDPool.empty, AnchorCIDPool.neverSeen]
        where seen.insert(state).inserted {
            result.append(state)
        }
        return result
    }
}

enum AnchorModelGenerator {
    struct Shape {
        var maxRoots = 3
        var maxBlocks = 40
        var stateCount = 2...8
        var phantomPercent = 8
        var noOpPercent = 30
        var executedPercent = 75
        var excludePercent = 35
        var separateValidationPercent = 40
        /// Percent of new blocks that hang off one of the last few blocks,
        /// which makes long runs (deep chains) as well as bushy forks.
        var extendRecentPercent = 50
    }

    /// A random parent tree whose facts respect §12.1 (`prevState` is the
    /// parent's `postState`) and §5.1 rule 4 (a genesis starts from the empty
    /// state), so every block could be honest.
    static func make(seed: UInt64, shape: Shape = Shape()) -> AnchorModel {
        var rng = AnchorRandom(seed: seed)
        let stateCount = shape.stateCount.lowerBound
            + rng.next(shape.stateCount.count)
        let states = Array(AnchorCIDPool.states.prefix(stateCount))
        let empty = AnchorCIDPool.empty
        var model = AnchorModel()
        let roots = 1 + rng.next(shape.maxRoots)
        let total = roots + 1 + rng.next(shape.maxBlocks)
        for index in 0..<total {
            let hash = AnchorCIDPool.blocks[index]
            let grind = AnchorCIDPool.grinds[index]
            var block: AnchorModelBlock
            if index < roots {
                // A genesis that changes nothing (empty -> empty) is allowed too.
                let post = rng.chance(10) ? empty : rng.pick(states)
                block = AnchorModelBlock(hash: hash, parent: nil, height: 0, prev: empty, post: post, grind: grind)
            } else {
                let parentIndex = rng.chance(shape.extendRecentPercent)
                    ? max(0, model.blocks.count - 1 - rng.next(3))
                    : rng.next(model.blocks.count)
                let parent = model.blocks[parentIndex]
                let post = rng.chance(shape.noOpPercent) ? parent.post : rng.pick(states)
                block = AnchorModelBlock(
                    hash: hash, parent: parent.hash, height: parent.height + 1,
                    prev: parent.post, post: post, grind: grind
                )
            }
            // The first genesis is always delivered: a restore needs one.
            block.phantom = index > 0 && rng.chance(shape.phantomPercent)
            block.executed = rng.chance(shape.executedPercent)
            block.separateValidation = block.executed && rng.chance(shape.separateValidationPercent)
            // Only an unexecuted, non-genesis block may be proven invalid: an
            // executed one never is, and a genesis needs another executed root.
            block.excluded = !block.executed && block.parent != nil && rng.chance(shape.excludePercent)
            model.add(block)
        }
        return model
    }
}
