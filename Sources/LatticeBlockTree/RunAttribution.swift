import cashew
import CID
import UInt256
import LatticePrimitives
import LatticePoW

// Parent-attributed run work (§9.10): the runs a parent keeps per served
// child directory, and the derivation that credits them at the child.

/// The identity under which a parent's attributed run work is credited at a
/// child block: keyed by the committing parent block and the directory — one
/// run, one identity — so a committer mined under several grinds is credited
/// once, not once per grind. A SEPARATE identity from any grind, deliberately:
/// crediting the run by strengthening the grind itself is not idempotent (a
/// second derivation would count the first attribution as the child's own
/// price and add it again), whereas a separate contribution ratchets on its
/// own value.
public struct AttributedRunIdentity: Hashable, Scalar {
    public let carrierBlockHash: String
    public let directory: String

    /// The encoded key stays `committerBlockHash`: this value's DAG-CBOR CID
    /// is the contribution ID credited on parent and child, so renaming the
    /// key would change every attributed-run ID.
    private enum CodingKeys: String, CodingKey {
        case carrierBlockHash = "committerBlockHash"
        case directory
    }

    public init(carrierBlockHash: String, directory: String) {
        self.carrierBlockHash = carrierBlockHash
        self.directory = directory
    }

    public var contributionID: String? {
        try? HeaderImpl<AttributedRunIdentity>(node: self).rawCID
    }
}

/// Parent-attributed run work (§9.10) over the graph's arrays: the served
/// directories, one accumulator per run (`runWork`), and each settled block's
/// nearest committer per served directory (`nearestCarrier`, by handle). It
/// stores no parent or child edge — its two walks read the graph's — so a run
/// is exactly one accumulator cell plus a per-block pointer inherited from
/// the parent, never a second representation of the tree.
///
/// `served` is the child directories this node keeps runs for — the child
/// chains it hosts. Operator choice, so the per-block run cost is bounded by
/// what this node asked for, not by what any block commits into. `runWork` is
/// the sum of credited work — grinds and attributed runs alike — over
/// CONNECTED blocks whose nearest committer into that directory is the key:
/// insert-only, independent of exclusion, maintained by the one reducer live
/// admission and replay both use, and read by the child (`applyParentRun`);
/// never a fork-choice input on THIS chain. `committers` is its inverse:
/// directory → committed child block → the connected blocks committing it.
extension BlockGraph {
    /// The nearest block at or above `block`, by parent pointer, that commits
    /// into `directory` — the block itself where it commits — or `none` when
    /// the directory is not served, the block is not settled, or nothing
    /// above it commits there.
    func carrier(of block: UInt32, directory: String) -> UInt32 {
        guard let carriers = nearestCarrier[directory], Int(block) < carriers.count else { return Self.none }
        return carriers[Int(block)]
    }

    private func setCarrier(_ carrier: UInt32, of block: UInt32, directory: String) {
        let count = nearestCarrier[directory]?.count ?? 0
        if Int(block) >= count {
            nearestCarrier[directory, default: []].append(
                contentsOf: repeatElement(Self.none, count: Int(block) + 1 - count)
            )
        }
        nearestCarrier[directory]![Int(block)] = carrier
    }

    /// Start serving `directory`: settle every connected block's nearest
    /// committer and run for that one directory, parent before child, over
    /// the UNFILTERED graph. Idempotent.
    func serve(_ directory: String) {
        guard served.insert(directory).inserted else { return }
        var stack = roots
        while let block = stack.popLast() {
            guard isRouted(block) else { continue }
            settle(block, directories: [directory])
            stack.append(contentsOf: children(of: block))
        }
    }

    /// Settle a block that just routed and every descendant that routed with
    /// it: its nearest committers and runs for every served directory, parent
    /// before child. Nothing below a just-routed block can have been settled
    /// before — a block never routes under an unrouted parent. Unfiltered on
    /// purpose: an excluded descendant is still connected and still credited.
    func connect(rootedAt root: UInt32) {
        var stack = [root]
        while let block = stack.popLast() {
            settle(block, directories: served)
            stack.append(contentsOf: children(of: block))
        }
    }

    /// The one per-block step of run attribution, for a connected block whose
    /// parent is already settled: for each directory, the nearest committer is
    /// this block if it commits there, else the parent's; the block's credited
    /// work — grinds and attributed runs alike — is credited to that run.
    /// Used both by live connection (every served directory) and by `serve`
    /// (one directory over the whole graph), so a run has exactly one
    /// definition.
    private func settle(_ block: UInt32, directories: Set<String>) {
        let parent = self[block].parent
        let committed = commitments[block]
        var credited: [(directory: String, committer: UInt32)] = []
        for directory in directories {
            let child = committed?[directory]
            if let child {
                committers[directory, default: [:]][
                    CIDIdentity.canonicalString(child) ?? child, default: []
                ].insert(block)
            }
            let committer = child != nil
                ? block
                : parent == Self.none ? Self.none : carrier(of: parent, directory: directory)
            guard committer != Self.none else { continue }
            setCarrier(committer, of: block, directory: directory)
            credited.append((directory, committer))
        }
        credit(work(of: block), to: credited)
    }

    /// A connected block's own work rose by `delta`: its runs rise by exactly
    /// that much.
    func credit(_ delta: WorkSum, at block: UInt32) {
        credit(delta, to: served.compactMap { directory in
            let committer = carrier(of: block, directory: directory)
            return committer == Self.none ? nil : (directory, committer)
        })
    }

    private func credit(_ work: WorkSum, to runs: [(directory: String, committer: UInt32)]) {
        for (directory, committer) in runs {
            runWork[directory, default: [:]][committer, default: .zero] = (runWork[directory]?[committer] ?? .zero) + work
#if DEBUG
            runUpdateCount &+= 1
#endif
        }
    }
}

extension ChainTree {
#if DEBUG
    var runAttributionUpdateCount: UInt64 { graph.runUpdateCount }
#endif

    /// Start keeping runs for `directory` — the node hosts a child
    /// chain there. Settles every connected block's nearest committer and run
    /// for that one directory, parent before child, over the UNFILTERED graph:
    /// O(N) once, at the operator's choice, and idempotent. Which directories a
    /// node serves is its own choice, so a stranger's block committing into ten
    /// thousand directories costs this node nothing it did not ask for.
    ///
    /// The served set is NOT persisted: the node must call this for every
    /// directory it hosts after every restart, and it runs synchronously on
    /// the actor — one whole-graph walk per directory.
    public mutating func serveRuns(for directory: String) {
        // Idempotent, and serving an already-served directory changes nothing.
        guard !graph.served.contains(directory) else { return }
        mutableGraph.serve(directory)
    }

    mutating func connectForRunAttribution(rootedAt root: UInt32) {
        mutableGraph.connect(rootedAt: root)
    }

    /// The nearest block at or above `blockHash`, by parent pointer, that
    /// commits into `directory` — the block itself where it commits — as run
    /// attribution settled it. Answers only for a directory this node serves
    /// (`serveRuns(for:)`) and a connected block; nil otherwise, never "none".
    /// The hash is looked up as given, not canonicalized.
    public func nearestCarrier(of blockHash: String, directory: String) -> String? {
        guard graph.served.contains(directory), let block = graph.handle(blockHash) else { return nil }
        let carrier = graph.carrier(of: block, directory: directory)
        return carrier == BlockGraph.none ? nil : graph.hash(carrier)
    }

    /// The run of `committer` into `directory`: the credited work of the
    /// connected blocks whose nearest committer it is. Nil when it has none.
    func runWork(of committer: String, directory: String) -> WorkSum? {
        graph.handle(committer).flatMap { graph.runWork[directory]?[$0] }
    }

    /// The credited work of a held block's own grinds alone.
    func grindWork(of blockHash: String) -> WorkSum? {
        graph.handle(blockHash).map(graph.grindWork(of:))
    }

    /// Credit this chain with its parent's attributed runs into `directory`
    /// (§9.10): for each committer `P` of `parent` into `directory` whose
    /// committed block `C = P.childCommitments[directory]` this chain holds,
    /// `C` is credited `runWork(P, d) − grindWork(P)` under
    /// `AttributedRunIdentity(P, d)` when that is a strict increase.
    ///
    /// A DERIVATION, never a fact: nothing here is persisted, and a restore
    /// re-derives it (`restore(replaying:…parent:)`). The quantity is monotone
    /// — a run only grows, and a stronger grind at `P` raises both terms
    /// alike — so the credited value is the ratchet of a non-decreasing
    /// function of the parent, and the fixed point depends on neither weigh
    /// order nor replay order. Crediting is unconditional: exclusion or
    /// validity on either level changes no run (§9.9).
    ///
    /// `parent` must serve `directory` (`serveRuns(for:)`); a host applies
    /// parent levels first, so a run attributed at `P` by ITS parent is in
    /// `runWork(P, d)` and reaches the next level down.
    ///
    /// A step derives exactly the runs it can have moved, from what the
    /// mutating code itself reported — never from what a host remembered:
    /// `parentBlocks` is the parent level's result, forwarded unchanged
    /// (`ChainTreeUpdate.weighed`, or the `raised` of the parent's own
    /// `applyParentRun`), whose runs are derived; `held` is this level's
    /// `ChainTreeUpdate.weighed`, whose committers' runs are derived. With
    /// `parentBlocks` nil every run is derived, as restore does. Returns the
    /// blocks credited, in order, and the canonical change, if the
    /// projection moved.
    @discardableResult
    public mutating func applyParentRun(
        from parent: ChainTree,
        directory: String,
        parentBlocks: Set<String>? = nil,
        held: Set<String> = []
    ) -> (raised: [String], commit: ChainCommit?) {
        let source = parent.graph
        guard let parentRuns = source.runWork[directory] else { return ([], nil) }
        var scope = Set(parentRuns.keys)
        if let parentBlocks {
            let carriers = parentBlocks.compactMap(source.handle).map {
                source.carrier(of: $0, directory: directory)
            }.filter { $0 != BlockGraph.none }
            let committersOfHeld = held.flatMap { source.committers[directory]?[$0] ?? [] }
            scope = Set(carriers).union(committersOfHeld)
        }
        let deferred = deferProjectionForReplay
        deferProjectionForReplay = true
        var raised: [String] = []
        for (committerHash, committer) in scope.map({ (source.hash($0), $0) }).sorted(by: { $0.0 < $1.0 }) {
            guard let run = parentRuns[committer],
                  let childBlock = source.commitments[committer]?[directory],
                  let hash = CIDIdentity.canonicalString(childBlock),
                  let block = graph.handle(hash),
                  let value = run.subtracting(source.grindWork(of: committer))?.uint256Value,
                  let id = AttributedRunIdentity(
                      carrierBlockHash: committerHash, directory: directory
                  ).contributionID,
                  value > (workContribution(id: id, at: hash)?.work ?? .zero) else { continue }
            let submission = addWorkContribution(
                VerifiedWorkContribution(id: id, work: value), to: block, attributed: true
            )
            // A strict increase at a held block, at the one location its ID
            // can have, is refused only when revisions are exhausted: never
            // drop a derivation silently.
            precondition(
                submission.addedContribution,
                "attributed run \(id) at \(hash) refused: mutation revisions exhausted"
            )
            raised.append(hash)
        }
        deferProjectionForReplay = deferred
        guard !deferred, !raised.isEmpty else { return (raised, nil) }
        let change = projectCanonicalChain(
            increasedAt: raised.count == 1 ? graph.handle(raised[0]) : nil
        )
        return (raised, change?.atRevision(mutationGeneration))
    }

    /// The commitments recorded for a held block (§9.10), or nil when the
    /// block is unknown.
    public func recordedChildCommitments(of blockHash: String) -> [String: String]? {
        CIDIdentity.canonicalString(blockHash).flatMap(graph.handle).map { graph.commitments[$0] ?? [:] }
    }
}
