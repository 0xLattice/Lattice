// FROZEN REFERENCE — DO NOT EDIT.
//
// A verbatim copy of Sources/LatticeBlockTree as of Lattice 50.0.1 (commit
// 6c839fd), compiled as its own module (`LatticeBlockTreeReference`) so its
// types sit beside the live ones under the same names. It is the equivalence
// oracle for the compact-index rewrite of the in-memory block tree: the
// randomized differential test in Tests/LatticeBlockTreeOracleTests drives
// this copy and the live `LatticeBlockTree` with the same fact streams and
// requires identical observable behavior after every step. Changing this file
// changes the oracle, not the implementation under test.

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

/// Parent-attributed run work (§9.10) as a value: the served directories,
/// one accumulator per run, and each settled block's nearest committer per
/// served directory. It stores no parent or child edge — its two walks take
/// the block graph as a parameter — so a run is exactly one accumulator cell
/// plus a per-block pointer inherited from the parent, never a second
/// representation of the tree.
struct RunAttribution: Sendable {
    /// The child directories this node keeps runs for — the child chains it
    /// hosts. Operator choice, so the per-block run cost is bounded
    /// by what this node asked for, not by what any block commits into.
    private(set) var served: Set<String> = []
    /// Run work per child directory per committing block (§9.10): the sum of
    /// credited work — grinds and attributed runs alike — over CONNECTED
    /// blocks whose nearest committer into that directory is the key.
    /// Insert-only, independent of exclusion, and maintained by the one
    /// reducer live admission and replay both use.
    /// Read by the child (`applyParentRun`); never a fork-choice input on
    /// THIS chain.
    private(set) var runWork: [String: [String: WorkSum]] = [:]
    /// The inverse of the commitments behind `runWork`: directory → child
    /// block → the connected blocks committing it, settled with them. The
    /// key set of each inner map's values is exactly `runWork[directory]`'s.
    private(set) var committers: [String: [String: Set<String>]] = [:]
    /// Block → directory → the nearest block at or above that block, by
    /// parent pointer, that commits into that directory — the block itself
    /// where it commits. Held only for the directories this node SERVES runs
    /// for (the child chains it hosts — an operator choice), so it costs
    /// O(#served) per block, never O(#directories ever committed); inherited
    /// from the parent like `difficultyAnchor`, and absent until the block is
    /// connected.
    private(set) var nearestCarrier: [String: [String: String]] = [:]
#if DEBUG
    /// Run-bucket updates. Each connected block costs one per directory it
    /// has a nearest committer for, so this is O(#directories) per block —
    /// asserted by ratio, never by stopwatch.
    private(set) var updateCount: UInt64 = 0
#endif

    /// Start serving `directory`: settle every connected block's nearest
    /// committer and run for that one directory, parent before child, over
    /// the UNFILTERED graph. Idempotent.
    mutating func serve(
        _ directory: String,
        in graph: BlockGraph,
        isRouted: (String) -> Bool
    ) {
        guard served.insert(directory).inserted else { return }
        var stack = graph.records
            .filter { $0.parentBlockHash == nil && $0.blockHeight == 0 }
            .map(\.blockHash)
        while let hash = stack.popLast() {
            guard isRouted(hash), graph.contains(hash) else { continue }
            settle(hash, in: graph, directories: [directory])
            stack.append(contentsOf: graph.children(of: hash))
        }
    }

    /// Settle a block that just routed and every descendant that routed with
    /// it: its nearest committers and runs for every served directory, parent
    /// before child. Nothing below a just-routed block can have been settled
    /// before — a block never routes under an unrouted parent — so the walk
    /// needs no record of what it has settled. Unfiltered on purpose: an
    /// excluded descendant is still connected and still credited.
    mutating func connect(
        rootedAt rootHash: String,
        in graph: BlockGraph
    ) {
        var stack = [rootHash]
        var visited = Set<String>()
        while let hash = stack.popLast() {
            guard graph.contains(hash), visited.insert(hash).inserted else { continue }
            settle(hash, in: graph, directories: served)
            stack.append(contentsOf: graph.children(of: hash))
        }
    }

    /// The one per-block step of run attribution, for a connected block whose
    /// parent is already settled: for each directory, the nearest committer is
    /// this block if it commits there, else the parent's; the block's credited
    /// work — grinds and attributed runs alike — is credited to that run.
    /// Used both by live connection (every served directory) and by
    /// `serve` (one directory over the whole graph), so a run has exactly one
    /// definition.
    private mutating func settle(
        _ hash: String,
        in graph: BlockGraph,
        directories: Set<String>
    ) {
        guard let meta = graph[hash], let work = graph.work(of: hash) else { return }
        let inherited = meta.parentBlockHash
            .flatMap { nearestCarrier[$0] } ?? [:]
        var nearest = nearestCarrier[hash] ?? [:]
        var credited: [String: String] = [:]
        for directory in directories {
            if let child = meta.childCommitments[directory] {
                committers[directory, default: [:]][
                    CIDIdentity.canonicalString(child) ?? child, default: []
                ].insert(hash)
            }
            let committer = meta.childCommitments[directory] != nil ? hash : inherited[directory]
            guard let committer else { continue }
            nearest[directory] = committer
            credited[directory] = committer
        }
        nearestCarrier[hash] = nearest
        credit(work.work, nearest: credited)
    }

    /// A connected block's own work rose by `delta`: its runs rise by exactly
    /// that much.
    mutating func credit(_ delta: WorkSum, at hash: String) {
        credit(delta, nearest: nearestCarrier[hash] ?? [:])
    }

    private mutating func credit(_ work: WorkSum, nearest: [String: String]) {
        for (directory, committer) in nearest {
            let current = runWork[directory]?[committer] ?? .zero
            runWork[directory, default: [:]][committer] = current + work
#if DEBUG
            updateCount &+= 1
#endif
        }
    }
}

extension ChainTree {
#if DEBUG
    var runAttributionUpdateCount: UInt64 { runs.updateCount }
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
        let forkChoice = self.forkChoice
        runs.serve(directory, in: graph, isRouted: { forkChoice.isRouted($0) })
    }

    mutating func connectForRunAttribution(rootedAt rootHash: String) {
        runs.connect(rootedAt: rootHash, in: graph)
    }

    /// The nearest block at or above `blockHash`, by parent pointer, that
    /// commits into `directory` — the block itself where it commits — as run
    /// attribution settled it. Answers only for a directory this node serves
    /// (`serveRuns(for:)`) and a connected block; nil otherwise, never "none".
    /// The hash is looked up as given, not canonicalized.
    public func nearestCarrier(of blockHash: String, directory: String) -> String? {
        guard runs.served.contains(directory) else { return nil }
        return runs.nearestCarrier[blockHash]?[directory]
    }

    /// The connected blocks that commit `child` into `directory`, as run
    /// attribution settled them; empty for an unserved directory. Sorted.
    /// The CID is looked up as given, not canonicalized.
    public func committers(of child: String, directory: String) -> [String] {
        guard runs.served.contains(directory) else { return [] }
        return (runs.committers[directory]?[child] ?? []).sorted()
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
    /// order nor replay order. Exclusion or validity on either level changes
    /// no run (§9.9); a run credits the committed block only when its
    /// `parentState` is the carrier's `prevState` (§9.10).
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
        guard let parentRuns = parent.runs.runWork[directory] else { return ([], nil) }
        var scope = Set(parentRuns.keys)
        if let parentBlocks {
            let carriers = parentBlocks.compactMap { parent.runs.nearestCarrier[$0]?[directory] }
            let committersOfHeld = held.flatMap { parent.runs.committers[directory]?[$0] ?? [] }
            scope = Set(carriers).union(committersOfHeld)
        }
        let deferred = deferProjectionForReplay
        deferProjectionForReplay = true
        var raised: [String] = []
        for committer in scope.sorted() {
            guard let run = parentRuns[committer],
                  let childBlock = parent.graph[committer]?.childCommitments[directory],
                  let hash = CIDIdentity.canonicalString(childBlock),
                  graph.contains(hash),
                  // The run's counterpart of §5.3 step 3: only a block anchored
                  // at the committer's entering state takes its run.
                  let anchor = frontier.snapshot(of: hash)?.parentStateCID,
                  anchor == parent.frontier.snapshot(of: committer)?.prevStateCID,
                  let own = parent.graph.work(of: committer)?.grindWork,
                  let value = run.subtracting(own)?.uint256Value,
                  let id = AttributedRunIdentity(
                      carrierBlockHash: committer, directory: directory
                  ).contributionID,
                  value > (workContribution(id: id, at: hash)?.work ?? .zero) else { continue }
            let submission = addWorkContribution(
                VerifiedWorkContribution(id: id, work: value), to: hash, attributed: true
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
            monotoneIncreaseAt: raised.count == 1 ? raised[0] : nil
        )
        if change != nil {
            frontier.refreshTipSnapshot()
        }
        return (raised, change?.atRevision(mutationGeneration))
    }

    /// The commitments recorded for a held block (§9.10), or nil when the
    /// block is unknown.
    public func recordedChildCommitments(of blockHash: String) -> [String: String]? {
        CIDIdentity.canonicalString(blockHash).flatMap { graph[$0]?.childCommitments }
    }
}
