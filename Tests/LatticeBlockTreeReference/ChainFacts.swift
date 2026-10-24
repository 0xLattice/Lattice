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

import Foundation
import cashew
import LatticePrimitives
import LatticePoW

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

public enum ChainFactID: Codable, Hashable, Sendable {
    case block(String)
    case work(blockHash: String, grindID: String, work: String)
    case exclusion(String)
    case validation(String)
}

public enum ChainFact: Codable, Sendable, Equatable {
    case block(ChainBlockFact)
    case work(ChainWorkFact)
    case exclusion(ChainExclusionFact)
    case validation(ChainValidationFact)

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
