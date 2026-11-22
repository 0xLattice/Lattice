import Foundation
import cashew
import UInt256
import LatticePrimitives

public struct GenesisConfig: Sendable {
    public let spec: ChainSpec
    /// The chain's real launch time (a child deploy: the current time). It
    /// is the only lower bound on block 1's timestamp, which anchors the
    /// difficulty schedule, so it has no default: an early genesis would let
    /// block 1 anchor the schedule in the past and saturate every target.
    public let timestamp: Int64

    public init(spec: ChainSpec, timestamp: Int64) {
        self.spec = spec
        self.timestamp = timestamp
    }
}

public struct GenesisResult: Sendable {
    public let block: Block
    public let blockHash: String

    public init(block: Block, blockHash: String) {
        self.block = block
        self.blockHash = blockHash
    }
}

package enum GenesisCeremony {

    /// Build a deterministic root-genesis candidate. A chain is made from it
    /// by `ChainTree.bootstrap`.
    package static func create(
        config: GenesisConfig,
        fetcher: Fetcher
    ) async throws -> GenesisResult {
        // The target is irrelevant to the genesis block: it is not mined against a
        // parent's scheduled difficulty. Every genesis uses the canonical maximum
        // (easiest) target — the chain self-calibrates from block 1 via the
        // retarget — so it is not a creator-configurable field.
        let block = try await BlockBuilder.buildGenesis(
            spec: config.spec,
            timestamp: config.timestamp,
            target: UInt256.max,
            fetcher: fetcher
        )
        let blockHash = try VolumeImpl<Block>(node: block).rawCID
        return GenesisResult(block: block, blockHash: blockHash)
    }

    package static func verify(block: Block, config: GenesisConfig) -> Bool {
        guard block.hasGenesisShape(isRoot: true) else { return false }
        guard block.timestamp == config.timestamp else { return false }
        guard block.spec.node != nil else { return false }
        guard block.target == UInt256.max else { return false }
        // known-valid local node; CID computation cannot fail (no Float/Double fields)
        guard block.spec.rawCID == (try! VolumeImpl<ChainSpec>(node: config.spec).rawCID) else { return false }
        return true
    }
}
