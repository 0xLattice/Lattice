# Fee Policy And Majority-Reorg Cost

This note separates consensus-enforced accounting from node fee policy, then
gives a narrow cost model for a majority-work reorganization of Nexus. It is
not a complete economic-security model.

For issuance and supply, see [Nexus Tokenomics](nexus-tokenomics.md).

## What Consensus Enforces

A block names the account that collects its reward and fees in the header
field `rewardRecipient`, which the proof-of-work preimage binds. There is no
reward transaction and no fee field on transactions.

Block validation evaluates the explicit account, deposit, and withdrawal
actions of its transactions:

```text
fee rule:  totalCredits + totalDeposited <= totalDebits + totalWithdrawn
fees:      F = totalDebits + totalWithdrawn - totalCredits - totalDeposited
coinbase:  M = rewardAtBlock(h) + F
```

Therefore:

- the block reward funds no transaction; a transaction set that creates value
  is invalid;
- a transaction's fee is its surplus: what it debits and withdraws beyond what
  it credits and deposits;
- the recipient is credited exactly `M`, with no under-claim path;
- a block without a recipient burns `M`, both reward and fees.

Only `rewardAtBlock(h)` is new issuance. `F` is redistribution from payers to
the recipient. The consensus rule and its tests live in
[`Block+Coinbase.swift`](../../Sources/LatticeValidation/Block/Block+Coinbase.swift)
and [`CoinbaseTests.swift`](../../Tests/LatticeTests/CoinbaseTests.swift).

## What The Node May Enforce

Fee policy stays with the node. A mempool can rank transactions by
`TransactionBody.minerSurplus()` and should refuse a transaction whose surplus
is negative (`nil`), since no block can include it without another transaction
paying for it. WASM chain policies see transactions, not the coinbase credit,
so a chain policy that restricts credits cannot govern the reward.

Paying fees to the block author adds the standard fee-sniping incentive: a
high-fee block is worth more to reorganize. The cost model below prices only
the hash spend; it does not net out the fees a reorganization could capture.

## Nexus Difficulty Inputs

| Parameter | Value |
|---|---:|
| Target block time `T` | `3,600` seconds |
| Half-life | `120` blocks, about 5 days |
| Per-block target clamp | none (the schedule is absolute) |

A block's target is `parent.nextTarget` or voluntarily harder, never easier.
There is no minimum-target floor and no below-floor recovery path. Retarget steps
are unclamped: one step may correct by an arbitrary factor in either direction.

Let `D` be the expected hashes represented by the current target, approximately
`U256_MAX / target`. At steady state, the observed honest hashrate is

```text
H ~= D / T
```

The absolute schedule tracks sustained changes in `H`; it does not make a short
attack free to choose an easier target. Both directions are bounded without a
clamp: a block's timestamp may not exceed the validating node's clock, so easing
is limited to `2^(Δ / halfLife)` on the single successor and does not compound
(see [specification §5.5](../spec.md#55-target-adjustment-retargeting)), and
moving a timestamp backwards hardens the target rather than easing it, so the
retarget cannot be ground down to mint cheap work.

## Majority-Reorg Estimate

Let:

- `c` be the external all-in cost per hash;
- `k` be the number of same-target blocks of work the attacker must replace.

A first-order direct-cost estimate is

```text
costMajorityReorg ~= c * D * k
```

Equivalently, for an attack lasting `t` seconds:

```text
costMajorityReorg ~= c * H * t
```

This estimates the hash spend needed to outwork an honest branch. It does not
price hardware scarcity, market impact, opportunity cost, varying targets,
network position, proof-derived work on nested child paths, or the deterministic
CID tie-break. Those inputs must be modeled separately.
[Merged-Mining Security](merged-mining-security.md) prices a child chain
secured by merged mining.

## Not A Complete Security Threshold

Majority reorg safety is not the same as the earliest profitable deviation.
The deterministic [adversarial model](../consensus-simulator.md#adversarial-model)
also models selfish mining and balancing attacks; in its assumptions, the
selfish-mining profitability threshold is lower than the majority threshold.
Security-budget analysis must state which attack and assumptions it prices.
