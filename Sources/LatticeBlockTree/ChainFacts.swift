import Foundation
import cashew
import LatticePrimitives
import LatticePoW
import UInt256

public struct SameChainPredecessorRequirement: Sendable, Equatable {
    public let descendantCID: String
    public let predecessorCID: String

    public init(descendantCID: String, predecessorCID: String) {
        self.descendantCID = descendantCID
        self.predecessorCID = predecessorCID
    }
}

public struct ChainBlockFact: Codable, Sendable, Equatable {
    public let blockHash: String
    public let parentBlockHash: String?
    public let blockHeight: UInt64
    public let postStateCID: String
    public let prevStateCID: String
    public let specCID: String
    public let target: String
    public let nextTarget: String
    public let timestamp: Int64
    public let stateDiff: StateDiff
    /// Directory → child block CID this block commits, from its PoW-bound
    /// `children` index (§9.10). Absent means it commits nothing.
    public let childCommitments: [String: String]?

    /// Explicit so `childCommitments` can default to nil: a defaulted `let`
    /// would drop it from the synthesized memberwise init entirely, and the
    /// one real construction site (`PreparedImport.facts`) must set it.
    public init(
        blockHash: String,
        parentBlockHash: String?,
        blockHeight: UInt64,
        postStateCID: String,
        prevStateCID: String,
        specCID: String,
        target: String,
        nextTarget: String,
        timestamp: Int64,
        stateDiff: StateDiff,
        childCommitments: [String: String]? = nil
    ) {
        self.blockHash = blockHash
        self.parentBlockHash = parentBlockHash
        self.blockHeight = blockHeight
        self.postStateCID = postStateCID
        self.prevStateCID = prevStateCID
        self.specCID = specCID
        self.target = target
        self.nextTarget = nextTarget
        self.timestamp = timestamp
        self.stateDiff = stateDiff
        self.childCommitments = childCommitments
    }
}

/// A block's state transition was EXECUTED and its declared `postState`
/// reproduced. Separate from the block fact because the tiers are separate in
/// time: the weighed tier possesses and connects a block from its header alone
/// and records its `postState` as an unverified claim (§9.9); execution is a
/// later, independent judgment.
///
/// It is its own immutable fact rather than a field on `ChainBlockFact` because
/// the block fact is keyed by block hash and is never rewritten — deferred
/// execution keeps it as the state-blind consensus-replay record — so a tier
/// marker stored there could never be updated, and every block would stay
/// unverified across a restart.
///
/// This gates parent-state attestation: a child chain settles cross-chain
/// withdrawals against an attested parent state, so attesting a state the
/// parent never produced lets a forged `receiptState` settle a withdrawal that
/// was never paid.
public struct ChainValidationFact: Codable, Sendable, Equatable {
    public let blockHash: String

    public init(blockHash: String) {
        self.blockHash = blockHash
    }
}

public struct ChainWorkFact: Codable, Sendable, Equatable {
    public let blockHash: String
    public let contribution: VerifiedWorkContribution

    public init(blockHash: String, contribution: VerifiedWorkContribution) {
        self.blockHash = blockHash
        self.contribution = contribution
    }
}

/// A deterministic, replayable judgment that a possessed block is invalid — its
/// execution completed and FAILED (a `postState` mismatch or a committed
/// validity rule). Recording it removes the block's subtree from THIS chain's
/// own effective weight so fork choice re-projects onto the heaviest VALID
/// chain. It is not pruning: the excluded facts stay in the graph, served and
/// exported unchanged; only this node's own weighting stops counting them.
public struct ChainExclusionFact: Codable, Sendable, Equatable {
    public let blockHash: String

    public init(blockHash: String) {
        self.blockHash = blockHash
    }
}

/// A run (§9.10) whose carrier was folded: its final attributed value,
/// `runWork(P, d) − grindWork(P)`, and the child block it credits. A folded
/// run cannot grow — its blocks are gone and a branch attaching beyond the
/// window is tallied, not weighed — so the value it had is the value it keeps.
public struct FrozenRun: Codable, Sendable, Equatable, Hashable {
    public let carrierBlockHash: String
    public let directory: String
    public let childBlockHash: String
    public let value: UInt256

    public init(carrierBlockHash: String, directory: String, childBlockHash: String, value: UInt256) {
        self.carrierBlockHash = carrierBlockHash
        self.directory = directory
        self.childBlockHash = childBlockHash
        self.value = value
    }
}

/// Dead side branches folded into the held block they fork from (§9.7).
/// `work` is the total credited work of every subtree ever folded at the
/// block — cumulative, so a later fold ratchets it like any work fact.
/// Credited there as one contribution, it keeps every comparison fork choice
/// can still make exact: the block's subtree and its ancestors' include it, and
/// the subtree of no held child ever did.
///
/// `covered` is, per directory, the part of `work` that sat under a folded
/// carrier into that directory: that work was in the carrier's run, not in the
/// run of this block's nearest carrier, so it is subtracted from what this
/// block credits to that run. `frozenRuns` are those folded carriers' runs.
public struct ChainFoldFact: Codable, Sendable, Equatable {
    public let blockHash: String
    public let work: UInt256
    public let covered: [String: UInt256]
    public let frozenRuns: [FrozenRun]

    public init(blockHash: String, work: UInt256, covered: [String: UInt256], frozenRuns: [FrozenRun]) {
        self.blockHash = blockHash
        self.work = work
        self.covered = covered
        self.frozenRuns = frozenRuns
    }
}

/// The contribution identity a fold is credited under at its block: one per
/// block, so successive folds there ratchet one value.
public struct FoldIdentity: Hashable, Scalar {
    public let foldedAtBlockHash: String

    public init(foldedAtBlockHash: String) {
        self.foldedAtBlockHash = foldedAtBlockHash
    }

    public var contributionID: String? {
        try? HeaderImpl<FoldIdentity>(node: self).rawCID
    }
}

public enum ChainFactID: Codable, Hashable, Sendable {
    case block(String)
    case work(blockHash: String, grindID: String, work: String)
    case exclusion(String)
    case validation(String)
    case fold(blockHash: String, work: String)
}

public enum ChainFact: Codable, Sendable, Equatable {
    case block(ChainBlockFact)
    case work(ChainWorkFact)
    case exclusion(ChainExclusionFact)
    case validation(ChainValidationFact)
    case fold(ChainFoldFact)

    public var id: ChainFactID {
        switch self {
        case .block(let fact): .block(fact.blockHash)
        case .work(let fact): .work(
            blockHash: fact.blockHash,
            grindID: fact.contribution.id,
            work: fact.contribution.work.toHexString()
        )
        case .exclusion(let fact): .exclusion(fact.blockHash)
        case .validation(let fact): .validation(fact.blockHash)
        case .fold(let fact): .fold(blockHash: fact.blockHash, work: fact.work.toHexString())
        }
    }

    /// The held block this fact is about.
    public var blockHash: String {
        switch self {
        case .block(let fact): fact.blockHash
        case .work(let fact): fact.blockHash
        case .exclusion(let fact): fact.blockHash
        case .validation(let fact): fact.blockHash
        case .fold(let fact): fact.blockHash
        }
    }
}

/// One node-atomic durability unit. New blocks stage their block and first work
/// observations together; later work or a stronger observation appends another
/// immutable fact.
public struct BlockImportBatch: Codable, Sendable, Equatable {
    public let facts: [ChainFact]

    init(facts: [ChainFact]) {
        self.facts = facts
    }

    /// A batch staged by the import funnel in another module. The initializer
    /// itself stays internal, so general batch construction is not public API.
    package static func staged(_ facts: [ChainFact]) -> BlockImportBatch {
        BlockImportBatch(facts: facts)
    }

    /// The one batch shape a node may author: "this block's transition was
    /// executed here".
    ///
    /// Deliberately a narrow factory rather than a public initializer. Every
    /// other fact is a claim Lattice must derive for itself from content —
    /// exposing general batch construction would let a caller turn wire claims
    /// into consensus facts. Execution is different in kind: it is a judgment
    /// the node's own validate walk reaches locally, and the node must be able
    /// to make it durable, because the durable batch log is the only recovery
    /// authority and an execution the log forgets is an execution that never
    /// happened.
    public static func validation(blockHash: String) -> BlockImportBatch {
        BlockImportBatch(facts: [
            .validation(ChainValidationFact(blockHash: blockHash)),
        ])
    }
}
