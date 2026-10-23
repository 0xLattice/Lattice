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
        guard let canonical = CIDIdentity.canonicalString(stateCID) else {
            return false
        }
        return frontier.chainProduced(stateCID: canonical)
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
            return frontier.chainProduced(stateCID: to)
        }
        return forkChoice.anyIsAncestorOrSelf(
            frontier.anchoredProducers(of: from),
            of: frontier.anchoredProducers(of: to)
        )
    }

    /// Whether `blockHash` is a proven-invalid subtree root. Its work still
    /// weighs; the fork-choice descent never steps into it.
    public func isExcludedRoot(_ blockHash: String) -> Bool {
        forkChoice.excludedRoots.contains(blockHash)
    }

    /// Whether this chain executed `blockHash`'s transition and found it
    /// valid. Irrevocable: execution is a fact about immutable bytes, so an
    /// executed block is never later proven invalid (`applyConnect`).
    public func isExecuted(blockHash: String) -> Bool {
        frontier.validated.contains(blockHash)
    }

    /// The recorded header fields of a held block (post/prev state, spec,
    /// target, next target, height, timestamp): what header linkage reads for
    /// a parent.
    public func headerSnapshot(of blockHash: String) -> TipBlockSnapshot? {
        frontier.snapshot(of: blockHash)
    }

    /// The parent CID a held block names, held or not.
    package func parentHash(of blockHash: String) -> String? {
        graph.parent(of: blockHash)
    }

    /// Whether the grind `id` may be credited at `blockHash`: a grind has one
    /// location in a chain.
    package func acceptsWorkLocation(of id: String, at blockHash: String) -> Bool {
        forkChoice.acceptsLocation(of: id, at: blockHash)
    }

    /// The block's strongest own grind (ties to the smaller ID) — never an
    /// attributed run or a fold.
    package func strongestGrind(of blockHash: String) -> VerifiedWorkContribution? {
        guard let work = graph.work(of: blockHash) else { return nil }
        return work.contributions.values
            .filter { work.isGrind($0.id) }
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
