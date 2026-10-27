# Nexus Tokenomics

This non-normative note summarizes the configured economics of Nexus, Lattice's
single outermost chain. The concrete configuration lives in
[`NexusGenesis.swift`](https://github.com/0xLattice/lattice-node/blob/a8fe2b8039e08c048f23da41329a2d791e64a627/Sources/LatticeNode/Architecture/NexusGenesis.swift).
Lattice interprets it using
[`ChainSpec.swift`](../../Sources/LatticePrimitives/Block/ChainSpec.swift) and the generic
[economic rules](../spec.md#10-economic-model).

Do not copy a premine recipient, timestamp, or genesis CID from this page. Those
identity-bearing values have one canonical home in `NexusGenesis.swift`.

## Design Intent

Nexus favors a light, long-lived root:

- one-hour blocks and one-megabyte block bodies limit payload growth;
- bounded state growth limits each transition's expansion;
- a long issuance schedule keeps subsidy available over a long horizon;
- applications needing different capacity or cadence can use child chains.

A child receives only path-bound verified work that actually covers it. It does
not automatically inherit all Nexus hashpower or Nexus canonicity.

## Configured Parameters

| Parameter | Value | Meaning |
|---|---:|---|
| `initialReward` | `1,048,576` | Initial subsidy, `2^20` |
| `halvingInterval` | `876,600` blocks | About 100 years at one-hour blocks |
| `premine` | `175,320` blocks | Front-of-schedule issuance |
| `targetBlockTime` | `3,600,000` ms | One hour |
| `halfLife` | `120` blocks | The schedule's half-life, about five days |
| `maxBlockSize` | `1,000,000` bytes | Unique canonical block + transaction Volume bytes |
| `maxStateGrowth` | `3,000,000` bytes | Per block |
| `maxNumberOfTransactionsPerBlock` | `5,000` | Per block |

There is no per-retarget clamp and no minimum-target floor: the schedule is
absolute. A chain directory is positional path data, not a `ChainSpec` field.

## Emission

The public block subsidy is

```text
rewardAtBlock(height)
    = initialReward >> ((height + premine) / halvingInterval)
```

`premine` advances public mining along the same reward curve. For Nexus, the
first public halving is therefore

```text
876,600 - 175,320 = 701,280 blocks
```

or about 80 years at the target cadence. Later halvings remain 876,600 blocks
apart. Integer shifts eventually reduce the reward to zero; there is no tail
emission.

The implementation returns zero instead of trapping if `height + premine`
overflows or the shift reaches 64 bits.

## Premine

Because the Nexus premine is shorter than one halving interval, every premined
block uses the initial reward:

```text
premineAmount
    = 175,320 * 1,048,576
    = 183,836,344,320
```

The recipient and exact genesis transaction are fixed by
`NexusGenesis.swift`. Generic genesis validation permits total credits up to the
configured `premineAmount`; it does not infer a recipient.

## Supply

The geometric closed-form limit is

```text
2 * halvingInterval * initialReward
    = 1,838,363,443,200
```

The exact integer-terminated schedule is

```text
halvingInterval * (2^21 - 1)
    = 1,838,362,566,600
```

The premine is exactly 10% of the closed-form limit and approximately 10% of the
exact integer-terminated supply. The small difference is the finite tail removed
by integer halving.

## Cadence And Fees

Nexus retargets every block by an **absolute schedule (ASERT)** measured from
the height-1 anchor of the block's own branch, not by a window over recent
intervals. A block's target is its parent's `nextTarget` or voluntarily harder,
never easier — there is no minimum-target floor and no recovery exception.

The schedule holds difficulty steady at exactly one-hour spacing, and moves one
doubling per half-life of accumulated drift, where the half-life is
`halfLife × targetBlockTime` = 120 hours. Because the target depends only
on the anchor and the present block, a stretch of unusual block times stops
mattering the moment it stops happening — there is no window to drain and no
clustered-window attractor to walk back out of. Moving a timestamp backwards
hardens rather than eases, and moving it forwards is capped by the validating
node's clock and eases only the single successor without compounding. See
[specification §5.5](../spec.md#55-target-adjustment-retargeting).

The signed `fee` field does not automatically move value. Lattice enforces the
block-wide non-creation bound over explicit actions. A node may require an
explicit payer debit and construct an author credit as fee policy. See
[Fee Policy And Majority-Reorg Cost](fee-market-and-51pct.md).

## Sources

| Fact | Canonical home |
|---|---|
| Nexus parameters and genesis identity | `lattice-node/Sources/LatticeNode/Architecture/NexusGenesis.swift` |
| Reward and premine arithmetic | `Sources/LatticePrimitives/Block/ChainSpec.swift` |
| Generic consensus rules | [Protocol specification](../spec.md) |
| Adversarial fork-choice model | [Consensus simulator](../consensus-simulator.md#adversarial-model) |
