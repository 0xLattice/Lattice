# Nexus Tokenomics

The configured economics of Nexus, Lattice's single outermost chain: its
parameters, emission, premine and supply. This page is not normative.

The configuration lives in `lattice-node`, in
[`NexusGenesis.swift`](https://github.com/0xLattice/lattice-node/blob/main/Sources/LatticeNodeConfig/NexusGenesis.swift).
Lattice interprets it using
[`ChainSpec.swift`](../../Sources/LatticePrimitives/Block/ChainSpec.swift) and the generic
[economic rules](../spec.md#10-economic-model).

This page does not list the premine recipient, the genesis timestamp, or the
genesis CID. Those identity-bearing values have one home, `NexusGenesis.swift`;
read them there.

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

Two parameters have similar names and unrelated jobs:

| Parameter | Governs | Counts | Effect |
|---|---|---|---|
| `halvingInterval` | Issuance | Blocks between reward halvings | Every 876,600 blocks the block reward halves ([Emission](#emission)) |
| `halfLife` | Difficulty | Blocks of drift per doubling of the target | When the chain runs 120 block times behind or ahead of schedule, the target doubles or halves ([Cadence](#cadence)) |

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

## Cadence

Nexus retargets every block by an **absolute schedule (ASERT)** measured from
the height-1 anchor of the block's own branch, not by a window over recent
intervals. A block's target is its parent's `nextTarget` or voluntarily harder,
never easier — there is no minimum-target floor and no recovery exception.

The schedule holds difficulty steady at exactly one-hour spacing, and moves one
doubling per half-life of accumulated drift, where the half-life is
`halfLife × targetBlockTime` = 120 hours.

- Because the target depends only on the anchor and the present block, a
  stretch of unusual block times stops mattering the moment it stops
  happening. There is no window to drain.
- Moving a timestamp backwards hardens the target.
- Moving a timestamp forwards is capped by the validating node's clock and
  eases only the single successor, without compounding.

See [specification §5.5](../spec.md#55-target-adjustment-retargeting).

## Fees

A transaction has no fee field. Its fee is its surplus: what it debits and
withdraws beyond what it credits and deposits. Lattice enforces the block-wide
bound that transactions create no value, and credits the block's reward plus
its fees to the header's `rewardRecipient`. See
[Fee Policy And Majority-Reorg Cost](fee-market-and-51pct.md).

## Sources

| Fact | Canonical home |
|---|---|
| Nexus parameters and genesis identity | `lattice-node/Sources/LatticeNodeConfig/NexusGenesis.swift` |
| Reward and premine arithmetic | `Sources/LatticePrimitives/Block/ChainSpec.swift` |
| Generic consensus rules | [Protocol specification](../spec.md) |
| Fee accounting | [Fee policy and majority-reorg cost](fee-market-and-51pct.md) |
| Adversarial fork-choice model | [Adversarial security report](../consensus/adversarial-report.md) |
