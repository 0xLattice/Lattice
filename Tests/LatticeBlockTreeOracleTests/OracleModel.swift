import cashew
import UInt256
import LatticePrimitives
import LatticePoW

// The module-neutral vocabulary of the oracle harness. Nothing here imports
// either block-tree module: a fact stream is described once, here, and each
// subject (`LiveSubject`, `ReferenceSubject`) translates it into its own
// module's types, applies it, and renders what it observes as plain strings.

/// One durable fact, mirroring `ChainFact`.
enum OracleFact: Equatable {
    case block(OracleBlockFact)
    case work(blockHash: String, grindID: String, work: UInt256)
    case exclusion(String)
    case validation(String)
}

/// The fields of a `ChainBlockFact`.
struct OracleBlockFact: Equatable {
    var hash: String
    var parent: String?
    var height: UInt64
    var postState: String
    var prevState: String
    var spec: String
    var target: String
    var nextTarget: String
    var timestamp: Int64
    var childCommitments: [String: String]?
}

/// One `BlockImportBatch`.
struct OracleBatch: Equatable {
    var facts: [OracleFact]
}

/// What one mutation returned, rendered. `weighed` is kept apart, sorted,
/// because the driver forwards it to the run derivation.
struct OracleOutcome: Equatable {
    var rendered: String
    var weighed: [String] = []

    var threw: Bool { rendered.hasPrefix("throw:") }
}

/// What to ask a tree after every step.
struct OracleProbe {
    /// Every block the stream planned for this chain, delivered or not, plus
    /// one that never exists.
    var hashes: [String]
    /// Every grind the stream issued for this chain, at the block it named.
    var grinds: [(id: String, hash: String)]
    /// The state CIDs blocks declare, plus the empty state.
    var states: [String]
    var directories: [String]
    var maxHeight: UInt64
}

/// The operations the driver needs from a block tree. The two conformances
/// are line-for-line twins over different modules.
protocol OracleSubject {
    static func restoreRoot(
        _ log: [OracleBatch], specs: [ChainSpec]
    ) -> Result<Self, OracleRestoreFailure>
    static func restoreChild(
        _ log: [OracleBatch],
        context: ChainRuntimeContext,
        specs: [ChainSpec],
        parent: Self
    ) -> Result<Self, OracleRestoreFailure>
    mutating func apply(_ batch: OracleBatch, reserved: Bool) -> OracleOutcome
    mutating func serveRuns(_ directory: String)
    mutating func applyParentRun(
        from parent: Self,
        directory: String,
        parentBlocks: Set<String>?,
        held: Set<String>
    ) -> OracleOutcome
    mutating func reevaluate() -> OracleOutcome
    mutating func observe(_ probe: OracleProbe) -> [String: String]
}

struct OracleRestoreFailure: Error, Equatable {
    let text: String
}

// MARK: - Rendering of module-neutral values

func render(_ value: WorkSum?) -> String {
    value.map { $0.toHexString() } ?? "nil"
}

func render(_ anchor: DifficultyAnchor?) -> String {
    guard let anchor else { return "nil" }
    return "h\(anchor.blockHeight)@\(anchor.timestamp)/\(anchor.target.toHexString())"
}

func render(_ contribution: VerifiedWorkContribution?) -> String {
    guard let contribution else { return "nil" }
    return "\(contribution.id)=\(contribution.work.toHexString())"
}

func render(_ commitments: [String: String]?) -> String {
    guard let commitments else { return "nil" }
    return commitments.sorted { $0.key < $1.key }.map { "\($0.key)→\($0.value)" }
        .joined(separator: ",")
}

// MARK: - Deterministic randomness

/// SplitMix64: a seed fully determines a run, on every host.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A canonical CID for an arbitrary label.
func oracleCID(_ label: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: label)).rawCID
}

func oracleSpec(targetBlockTime: UInt64) -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: 0,
        targetBlockTime: targetBlockTime,
        initialReward: 1024,
        halvingInterval: 10_000,
        halfLife: 5,
        wasmPolicies: []
    )
}

func specCID(_ spec: ChainSpec) -> String {
    try! VolumeImpl<ChainSpec>(node: spec).rawCID
}
