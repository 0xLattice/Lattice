import Foundation
import Lattice
import UInt256

public struct ConsensusSimEvent: Codable, Equatable, Sendable {
    public let step: Int
    public let label: String
    public let tip: String
    public let candidate: String?
    public let candidateTip: String?
    public let candidateSubtreeWork: String?
    public let mainSubtreeWork: String?
    public let reorged: Bool?

    public init(
        step: Int,
        label: String,
        tip: String,
        candidate: String? = nil,
        candidateTip: String? = nil,
        candidateSubtreeWork: String? = nil,
        mainSubtreeWork: String? = nil,
        reorged: Bool? = nil
    ) {
        self.step = step
        self.label = label
        self.tip = tip
        self.candidate = candidate
        self.candidateTip = candidateTip
        self.candidateSubtreeWork = candidateSubtreeWork
        self.mainSubtreeWork = mainSubtreeWork
        self.reorged = reorged
    }
}

public struct ConsensusSimTrace: Codable, Equatable, Sendable {
    public let scenario: String
    public let seed: UInt64
    public let finalTip: String
    /// The real main-chain block set after the last release, as resolved by the
    /// REAL `ChainState` fork choice across every released block. Empty for the
    /// hand-checked fixtures that report only a single evaluated candidate; the
    /// discrete-event runner populates it so adversarial scenarios can derive
    /// accepted revenue / convergence from real fork choice rather than a model.
    public let finalMainChain: [String]
    public let events: [ConsensusSimEvent]

    public init(
        scenario: String,
        seed: UInt64,
        finalTip: String,
        finalMainChain: [String] = [],
        events: [ConsensusSimEvent]
    ) {
        self.scenario = scenario
        self.seed = seed
        self.finalTip = finalTip
        self.finalMainChain = finalMainChain
        self.events = events
    }
}

public struct ConsensusSimBlockSpec: Codable, Equatable, Sendable {
    public let hash: String
    public let parent: String?
    public let height: UInt64
    public let work: UInt256

    public init(hash: String, parent: String? = nil, height: UInt64, work: UInt256 = UInt256(1)) {
        self.hash = hash
        self.parent = parent
        self.height = height
        self.work = work
    }
}

public struct ConsensusSimRelease: Codable, Equatable, Sendable {
    public let atMillis: UInt64
    public let blockHash: String

    public init(atMillis: UInt64, blockHash: String) {
        self.atMillis = atMillis
        self.blockHash = blockHash
    }
}

public struct ConsensusSimScenarioSpec: Codable, Equatable, Sendable {
    public let scenario: String
    public let seed: UInt64
    public let blocks: [ConsensusSimBlockSpec]
    public let initiallyVisible: [String]
    public let initialMain: [String]
    public let releases: [ConsensusSimRelease]

    public init(
        scenario: String,
        seed: UInt64,
        blocks: [ConsensusSimBlockSpec],
        initiallyVisible: [String],
        initialMain: [String],
        releases: [ConsensusSimRelease]
    ) {
        self.scenario = scenario
        self.seed = seed
        self.blocks = blocks
        self.initiallyVisible = initiallyVisible
        self.initialMain = initialMain
        self.releases = releases
    }
}

public enum LatticeConsensusSimulator {
    public static let defaultSeed: UInt64 = 0x4c41545449434533

    public static func runDefaultScenarios(seed: UInt64 = defaultSeed) async -> [ConsensusSimTrace] {
        [
            await equalWorkTie(seed: seed),
            await deterministicWithholdRelease(seed: seed),
            await proportionalRetarget(seed: seed)
        ]
    }

    public static func encodeJSON(_ traces: [ConsensusSimTrace]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(traces)
    }

    public static func runDiscreteEventScenario(_ spec: ConsensusSimScenarioSpec) async -> ConsensusSimTrace {
        let blocksByHash = Dictionary(uniqueKeysWithValues: spec.blocks.map { ($0.hash, $0) })
        let allBlocks = Dictionary(uniqueKeysWithValues: spec.blocks.map {
            ($0.hash, simBlock($0.hash, previous: $0.parent, height: $0.height, work: $0.work))
        })
        let names = Dictionary(uniqueKeysWithValues: spec.blocks.map { (simCID($0.hash), $0.hash) })
        func name(_ cid: String) -> String { names[cid] ?? cid }
        var visibleHashes = Set(spec.initiallyVisible)
        var currentMain = Set(spec.initialMain)
        var events: [ConsensusSimEvent] = []

        let releases = spec.releases.sorted {
            if $0.atMillis != $1.atMillis { return $0.atMillis < $1.atMillis }
            return $0.blockHash < $1.blockHash
        }

        for (idx, release) in releases.enumerated() {
            visibleHashes.insert(release.blockHash)
            let visibleBlocks = spec.blocks.compactMap { visibleHashes.contains($0.hash) ? allBlocks[$0.hash] : nil }
            let chain = simChain(blocks: visibleBlocks, main: currentMain)
            let candidateRoot = forkRoot(for: release.blockHash, visible: visibleHashes, currentMain: currentMain, blocksByHash: blocksByHash)
            let commit = await chain.reevaluateForkChoice()
            if let commit {
                currentMain.subtract(commit.canonicalBlocksRemoved.map(name))
                currentMain.formUnion(commit.canonicalBlocksAdded.keys.map(name))
            }

            let tip = await chain.canonicalTip
            let snapshot = await chain.forkChoiceSnapshot(startingAt: simCID(candidateRoot))
            events.append(event(
                idx,
                "t=\(release.atMillis)ms release \(release.blockHash)",
                tip: name(tip),
                candidate: snapshot.map { named($0, name) },
                main: nil,
                reorged: commit != nil
            ))
        }

        let finalTip = currentMain
            .compactMap { blocksByHash[$0] }
            .max { $0.height < $1.height }?
            .hash ?? spec.initialMain.last ?? ""
        let finalMainChain = currentMain.sorted {
            let lh = blocksByHash[$0]?.height ?? 0
            let rh = blocksByHash[$1]?.height ?? 0
            if lh != rh { return lh < rh }
            return $0 < $1
        }
        return ConsensusSimTrace(
            scenario: spec.scenario,
            seed: spec.seed,
            finalTip: finalTip,
            finalMainChain: finalMainChain,
            events: events
        )
    }

    private static func equalWorkTie(seed: UInt64) async -> ConsensusSimTrace {
        let g = simBlock("G", height: 0, children: ["M1", "F1"])
        let m1 = simBlock("M1", previous: "G", height: 1)
        let f1 = simBlock("F1", previous: "G", height: 1)
        let chain = simChain(blocks: [g, m1, f1], main: Set(["G", "M1"]))

        let names = Dictionary(uniqueKeysWithValues: ["G", "M1", "F1"].map { (simCID($0), $0) })
        func name(_ cid: String) -> String { names[cid] ?? cid }
        let candidate = await chain.forkChoiceSnapshot(startingAt: simCID("F1")).map { named($0, name) }
        let main = await chain.forkChoiceSnapshot(startingAt: simCID("M1")).map { named($0, name) }
        let reorg = await chain.reevaluateForkChoice()
        let tip = name(await chain.canonicalTip)

        return ConsensusSimTrace(
            scenario: "equal-work-tie-stable-base",
            seed: seed,
            finalTip: tip,
            events: [
                event(
                    0, "equal work candidate evaluated", tip: tip,
                    candidate: candidate, main: main, reorged: reorg != nil
                )
            ]
        )
    }

    private static func deterministicWithholdRelease(seed: UInt64) async -> ConsensusSimTrace {
        let order = seededOrder(seed: seed, values: ["F1", "F2", "F3"])
        let spec = ConsensusSimScenarioSpec(
            scenario: "seeded-withhold-release",
            seed: seed,
            blocks: [
                ConsensusSimBlockSpec(hash: "G", height: 0),
                ConsensusSimBlockSpec(hash: "M1", parent: "G", height: 1),
                ConsensusSimBlockSpec(hash: "M2", parent: "M1", height: 2),
                ConsensusSimBlockSpec(hash: "F1", parent: "G", height: 1),
                ConsensusSimBlockSpec(hash: "F2", parent: "F1", height: 2),
                ConsensusSimBlockSpec(hash: "F3", parent: "F2", height: 3)
            ],
            initiallyVisible: ["G", "M1", "M2"],
            initialMain: ["G", "M1", "M2"],
            releases: order.enumerated().map { idx, hash in
                ConsensusSimRelease(atMillis: UInt64(idx + 1) * 100, blockHash: hash)
            }
        )
        return await runDiscreteEventScenario(spec)
    }

    private static func proportionalRetarget(seed: UInt64) async -> ConsensusSimTrace {
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            maxBlockSize: 1_000_000,
            premine: 0,
            targetBlockTime: 3_600_000,
            initialReward: 1_048_576,
            halvingInterval: 876_600,
            halfLife: 120
        )
        // Drive the CONSENSUS path: the absolute schedule measured from the
        // height-1 anchor. The windowed retarget this used to call is no longer
        // read by any consensus path, so simulating it simulated nothing.
        let anchorTarget = UInt256(1000)
        let anchorTimestamp: Int64 = 0
        let onTarget = spec.calculateAsertTarget(
            anchorTarget: anchorTarget, anchorTimestamp: anchorTimestamp,
            anchorHeight: 1, blockTimestamp: 7_200_000, blockHeight: 3
        )
        // Exactly one half-life behind schedule, which is exactly one doubling.
        // An hour late would move the target ~1%: under an absolute schedule the
        // unit of easing is the half-life, not the block.
        let slow = spec.calculateAsertTarget(
            anchorTarget: anchorTarget, anchorTimestamp: anchorTimestamp,
            anchorHeight: 1, blockTimestamp: 7_200_000 + 432_000_000, blockHeight: 3
        )
        let previous = anchorTarget
        return ConsensusSimTrace(
            scenario: "asert-schedule-one-hour",
            seed: seed,
            finalTip: "retarget-only",
            events: [
                ConsensusSimEvent(
                    step: 0,
                    label: "target=3600000ms previous=\(previous.toHexString()) onTarget=\(onTarget.toHexString()) slow=\(slow.toHexString())",
                    tip: "retarget-only"
                )
            ]
        )
    }

    /// The block tree holds canonical CIDs only, so a simulated block named
    /// `name` is the CIDv1 dag-cbor sha2-256 whose digest is the name's bytes,
    /// zero-padded: deterministic, and ordered exactly as the names are, so
    /// every equal-work tie-break between names stands.
    static func simCID(_ name: String) -> String {
        let bytes = Array(name.utf8)
        precondition(bytes.count <= 32, "simulated block name too long: \(name)")
        return CIDIdentity.base32Multibase(
            [0x01, 0x71, 0x12, 0x20] + bytes + Array(repeating: 0, count: 32 - bytes.count)
        )
    }

    /// `snapshot` with its CIDs read back as names.
    private static func named(_ snapshot: ForkChoiceSnapshot, _ name: (String) -> String) -> ForkChoiceSnapshot {
        ForkChoiceSnapshot(
            startingHash: name(snapshot.startingHash),
            subtreeWork: snapshot.subtreeWork,
            tipHash: name(snapshot.tipHash),
            canonicalPath: Set(snapshot.canonicalPath.map(name))
        )
    }

    private static func simBlock(
        _ hash: String,
        previous: String? = nil,
        height: UInt64,
        children: [String] = [],
        work: UInt256 = UInt256(1)
    ) -> BlockMeta {
        BlockMeta(
            blockHash: simCID(hash),
            parentBlockHash: previous.map(simCID),
            blockHeight: height,
            childHashes: children.map(simCID),
            workContributions: [VerifiedWorkContribution(
                id: simCID("sim:\(hash)"),
                work: work
            )]
        )
    }

    private static func simChain(
        blocks: [BlockMeta],
        main names: Set<String>
    ) -> ChainState {
        let main = Set(names.map(simCID))
        var index: [UInt64: Set<String>] = [:]
        var byHash: [String: BlockMeta] = [:]
        for block in blocks {
            var block = block
            block.childHashes.append(contentsOf: blocks.compactMap { candidate in
                candidate.parentBlockHash == block.blockHash ? candidate.blockHash : nil
            })
            block.childHashes = Array(Set(block.childHashes)).sorted()
            index[block.blockHeight, default: []].insert(block.blockHash)
            byHash[block.blockHash] = block
        }
        let tip = blocks
            .filter { main.contains($0.blockHash) }
            .max { $0.blockHeight < $1.blockHeight }?
            .blockHash ?? blocks[0].blockHash
        do {
            return try ChainState(
                canonicalTip: tip,
                canonicalHashes: main,
                indexToBlockHash: index,
                hashToBlock: byHash
            )
        } catch {
            fatalError("invalid simulation chain: \(error)")
        }
    }

    private static func seededOrder(seed: UInt64, values: [String]) -> [String] {
        var rng = LCG(seed: seed)
        let scores = Dictionary(uniqueKeysWithValues: values.map { ($0, rng.score($0)) })
        return values.sorted { left, right in
            let l = scores[left] ?? 0
            let r = scores[right] ?? 0
            if l != r { return l < r }
            return left < right
        }
    }

    private static func event(
        _ step: Int,
        _ label: String,
        tip: String,
        candidate: ForkChoiceSnapshot?,
        main: ForkChoiceSnapshot?,
        reorged: Bool?
    ) -> ConsensusSimEvent {
        ConsensusSimEvent(
            step: step,
            label: label,
            tip: tip,
            candidate: candidate?.startingHash,
            candidateTip: candidate?.tipHash,
            candidateSubtreeWork: candidate?.subtreeWork.toHexString(),
            mainSubtreeWork: main?.subtreeWork.toHexString(),
            reorged: reorged
        )
    }

    private static func forkRoot(
        for hash: String,
        visible: Set<String>,
        currentMain: Set<String>,
        blocksByHash: [String: ConsensusSimBlockSpec]
    ) -> String {
        var current = hash
        while let parent = blocksByHash[current]?.parent,
              visible.contains(parent),
              !currentMain.contains(parent) {
            current = parent
        }
        return current
    }
}

private struct LCG {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func score(_ value: String) -> UInt64 {
        var hash = state
        for byte in value.utf8 {
            hash = hash &* 6364136223846793005 &+ UInt64(byte) &+ 1442695040888963407
        }
        return hash
    }
}
