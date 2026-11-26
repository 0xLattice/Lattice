import cashew
import DagCBORMacro
import Foundation
import UInt256

/// The conventional name of the single root chain (Nexus). A chain's directory
/// is positional — the directory its blocks are carried under in its parent's
/// child index (i.e. the last element of its chainPath) — and is therefore NOT
/// stored in the content-addressed `ChainSpec`. This constant is only the
/// fallback used by the validators when no chainPath/directory is supplied,
/// which is the root case; the node always supplies its configured chainPath.
public let DEFAULT_ROOT_DIRECTORY = "Nexus"

@DagCBORCodable
public struct ChainSpec: Scalar {
    public let maxNumberOfTransactionsPerBlock: UInt64
    public let maxStateGrowth: Int
    public let maxBlockSize: Int
    public let premine: UInt64
    public let targetBlockTime: UInt64
    public let initialReward: UInt64
    public let halvingInterval: UInt64
    /// The difficulty schedule's half-life, in blocks: drift of one half-life
    /// of block time away from schedule moves the target by one doubling.
    /// The chain's own committed responsiveness; there is no protocol default.
    public let halfLife: UInt64
    public let wasmPolicies: [WasmPolicyRef]
    enum CodingKeys: String, CodingKey {
        case maxNumberOfTransactionsPerBlock
        case maxStateGrowth
        case maxBlockSize
        case premine
        case targetBlockTime
        case initialReward
        case halvingInterval
        case halfLife
        case wasmPolicies
    }

    enum LegacyCodingKeys: String, CaseIterable {
        case transactionFilters
        case actionFilters
    }

    public init(
        maxNumberOfTransactionsPerBlock: UInt64,
        maxStateGrowth: Int,
        maxBlockSize: Int = 1_000_000,
        premine: UInt64,
        targetBlockTime: UInt64,
        initialReward: UInt64,
        halvingInterval: UInt64,
        halfLife: UInt64,
        wasmPolicies: [WasmPolicyRef] = []
    ) {
        self.maxNumberOfTransactionsPerBlock = maxNumberOfTransactionsPerBlock
        self.maxStateGrowth = maxStateGrowth
        self.maxBlockSize = maxBlockSize
        self.premine = premine
        self.targetBlockTime = targetBlockTime
        self.initialReward = initialReward
        self.halvingInterval = halvingInterval
        self.halfLife = halfLife
        self.wasmPolicies = wasmPolicies
    }

    /// A spec carrying the legacy JavaScript filters is refused rather than
    /// read without them.
    public static var refusedKeys: [String] { LegacyCodingKeys.allCases.map(\.rawValue) }
}

// MARK: - Reward Calculations
public extension ChainSpec {

    func rewardAtBlock(_ blockHeight: UInt64) -> UInt64 {
        guard halvingInterval > 0 else { return 0 }
        // premine is uncapped, so blockHeight + premine can overflow UInt64.
        // An overflowing offset is astronomically past every halving → 0 reward.
        // Stay total so a content-addressed spec can never trap a validator.
        let (offsetBlockIndex, overflow) = blockHeight.addingReportingOverflow(premine)
        guard !overflow else { return 0 }
        let halvings = offsetBlockIndex / halvingInterval
        guard halvings < 64 else { return 0 }
        return initialReward >> halvings
    }

    func totalRewards(upToBlock blockCount: UInt64) -> UInt64 {
        guard blockCount > 0, halvingInterval > 0 else { return 0 }

        var total: UInt64 = 0
        var blocksProcessed: UInt64 = 0

        while blocksProcessed < blockCount {
            // Overflow ⇒ offset past every halving ⇒ no further emission.
            let (offsetBlock, offsetOverflow) = blocksProcessed.addingReportingOverflow(premine)
            guard !offsetOverflow else { break }
            let currentHalving = offsetBlock / halvingInterval
            guard currentHalving < 64 else { break }
            let currentReward = initialReward >> currentHalving

            guard currentReward > 0 else { break }

            // How many blocks remain in this halving period?
            let remainingBlocks = blockCount - blocksProcessed
            let (hPlus1, c1) = currentHalving.addingReportingOverflow(1)
            let (absBoundary, c2) = c1 ? (UInt64.max, true) : hPlus1.multipliedReportingOverflow(by: halvingInterval)
            let blocksInThisPeriod: UInt64
            if c1 || c2 {
                blocksInThisPeriod = remainingBlocks
            } else {
                let (nextHalvingAt, sub) = absBoundary.subtractingReportingOverflow(premine)
                if sub {
                    blocksInThisPeriod = remainingBlocks
                } else {
                    let (blocksUntil, sub2) = nextHalvingAt.subtractingReportingOverflow(blocksProcessed)
                    blocksInThisPeriod = sub2 ? remainingBlocks : min(blocksUntil, remainingBlocks)
                }
            }
            guard blocksInThisPeriod > 0 else { break }

            let (periodRewards, overflow) = currentReward.multipliedReportingOverflow(by: blocksInThisPeriod)
            if overflow { return UInt64.max }
            let (newTotal, addOverflow) = total.addingReportingOverflow(periodRewards)
            if addOverflow { return UInt64.max }
            total = newTotal

            let (newBlocksProcessed, processOverflow) = blocksProcessed.addingReportingOverflow(blocksInThisPeriod)
            if processOverflow { break }
            blocksProcessed = newBlocksProcessed
        }

        return total
    }

    func premineAmount() -> UInt64 {
        guard premine > 0, halvingInterval > 0 else { return 0 }

        var total: UInt64 = 0
        var blocksProcessed: UInt64 = 0

        while blocksProcessed < premine {
            let currentHalving = blocksProcessed / halvingInterval
            guard currentHalving < 64 else { break }
            let currentReward = initialReward >> currentHalving
            guard currentReward > 0 else { break }

            let (hPlus1, c1) = currentHalving.addingReportingOverflow(1)
            let (nextHalvingBoundary, c2) = c1 ? (UInt64.max, true) : hPlus1.multipliedReportingOverflow(by: halvingInterval)
            let nextHalvingAt = c2 ? UInt64.max : nextHalvingBoundary
            let blocksInThisPeriod = min(nextHalvingAt - blocksProcessed, premine - blocksProcessed)

            let (periodRewards, overflow) = currentReward.multipliedReportingOverflow(by: blocksInThisPeriod)
            if overflow { return UInt64.max }
            let (newTotal, addOverflow) = total.addingReportingOverflow(periodRewards)
            if addOverflow { return UInt64.max }
            total = newTotal

            let (newBlocksProcessed, processOverflow) = blocksProcessed.addingReportingOverflow(blocksInThisPeriod)
            if processOverflow { break }
            blocksProcessed = newBlocksProcessed
        }

        return total
    }

    var totalHalvings: UInt64 {
        guard initialReward > 0 else { return 0 }
        return UInt64(UInt64.bitWidth - initialReward.leadingZeroBitCount)
    }
}

public extension ChainSpec {

    func rewardRange(startBlock: UInt64, count: UInt64) -> [UInt64] {
        guard count > 0 else { return [] }

        var rewards: [UInt64] = []
        rewards.reserveCapacity(Int(count))

        for i in 0..<count {
            rewards.append(rewardAtBlock(startBlock + i))
        }

        return rewards
    }
}
