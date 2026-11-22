import LatticePrimitives
import LatticePoW

/// The reads and the one write the admission tier (`LatticeImport`) needs
/// from a `ChainTree`. Every one is a view onto the existing value structs.
extension ChainTree {
    /// Whether some block of this chain's executed set produced `stateCID`:
    /// a block on ANY branch, executed from genesis and not under an excluded
    /// root, whose post-state is `stateCID`. This is what a child's
    /// `parentState` must be (parent-chain continuity), and it is not a tip
    /// question: a side branch this chain executed counts the same.
    public func executedSetProduced(stateCID: String) -> Bool {
        guard let canonical = CIDIdentity.canonicalString(stateCID),
              let state = graph.stateHandle(canonical) else {
            return false
        }
        return graph.chainProduced(state)
    }

    /// Whether this chain's executed set carried its state forward from
    /// `fromStateCID` to `toStateCID` (§5.3 step 6): some block of the
    /// executed set produced `toStateCID`, and is or descends from a block
    /// that produced `fromStateCID`. From the genesis pre-state, or between
    /// equal states, it is `executedSetProduced(toStateCID)`: equality is never
    /// evidence on its own, so a forged state cannot be carried along by
    /// matching an unproven one. Logarithmic in the parent's size whatever the
    /// distance between the two states, and near-linear in how many blocks
    /// produced each, so many blocks sharing a state cannot make it quadratic.
    public func executedSetAdvanced(from fromStateCID: String, to toStateCID: String) -> Bool {
        guard let from = CIDIdentity.canonicalString(fromStateCID),
              let to = CIDIdentity.canonicalString(toStateCID) else {
            return false
        }
        if from == to || from == LatticeState.emptyHeader.rawCID {
            return executedSetProduced(stateCID: to)
        }
        guard let fromState = graph.stateHandle(from),
              let toState = graph.stateHandle(to) else { return false }
        return graph.weights.anyEncloses(
            graph.anchoredProducers(of: fromState),
            graph.anchoredProducers(of: toState)
        )
    }

    /// This chain's genesis roots: the children of the genesis fork, which
    /// the act-on descent takes like any other fork (`heaviestExecutedTip`).
    public var genesisRoots: [String] {
        graph.roots.map(graph.hash)
    }

    /// Whether `blockHash` is a proven-invalid subtree root. Its work still
    /// weighs; the fork-choice descent never steps into it.
    public func isExcludedRoot(_ blockHash: String) -> Bool {
        graph.handle(blockHash).map(graph.isExcludedRoot) ?? false
    }

    /// Whether this chain executed `blockHash`'s transition and found it
    /// valid. Irrevocable: execution is a fact about immutable bytes, so an
    /// executed block is never later proven invalid (`applyConnect`).
    public func isExecuted(blockHash: String) -> Bool {
        graph.handle(blockHash).map(graph.isValidated) ?? false
    }

    /// The recorded header fields of a held block (post/prev state, spec,
    /// target, next target, height, timestamp): what header linkage reads for
    /// a parent.
    public func headerSnapshot(of blockHash: String) -> TipBlockSnapshot? {
        graph.handle(blockHash).flatMap(graph.snapshot(of:))
    }

    /// The parent CID a held block names, held or not.
    package func parentHash(of blockHash: String) -> String? {
        parent(of: blockHash)
    }

    /// Whether the grind `id` may be credited at `blockHash`: a grind has one
    /// location in a chain.
    package func acceptsWorkLocation(of id: String, at blockHash: String) -> Bool {
        graph.grindHandle(id).map { graph.hash(graph.grinds[Int($0)].block) == blockHash } ?? true
    }

    /// The block's strongest own grind (ties to the smaller ID) — never an
    /// attributed run.
    package func strongestGrind(of blockHash: String) -> VerifiedWorkContribution? {
        guard let block = graph.handle(blockHash) else { return nil }
        return graph.grinds(at: block)
            .filter { !graph.grinds[Int($0)].isAttributed }
            .compactMap(graph.contribution)
            .max {
                $0.work != $1.work ? $0.work < $1.work : $0.id > $1.id
            }
    }

    /// Apply one locally authenticated admission batch through the single
    /// fact reducer that live admission and replay share.
    package mutating func apply(_ batch: BlockImportBatch) throws -> SubmissionResult? {
        try applyStaged(batch)
    }
}
