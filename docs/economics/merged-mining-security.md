# Merged-Mining Security Of A Child Chain

This note prices the direct hash spend of reorganizing a child chain whose
work comes from merged mining. Like the
[majority-reorg estimate](fee-market-and-51pct.md#majority-reorg-estimate), it
is a first-order cost model, not a complete economic-security model. Every rule
it uses is cited from the [specification](../spec.md).

## Inputs

| Symbol | Meaning |
|---|---|
| `H` | honest parent hashrate |
| `h_m` | the part of `H` whose templates commit this child's tip (subscribed) |
| `u = H - h_m` | honest parent hashrate not subscribed to the child |
| `a` | attacker hashrate |
| `D_p`, `D_c` | expected hashes of the parent and child targets, `workForTarget` (§5.4) |
| `B_p` | parent block time; at steady state `D_p ~= H * B_p` |
| `c` | external all-in cost per hash |
| `t` | age of the child span being replaced, in seconds |
| `t_c` | time since a parent block first committed a block of that span (0 if none) |

`h_m` and `u` are not protocol quantities. They are the sum of miners'
subscription and template choices, and every result below inherits that
dependence.

## What One Hash Is Worth To The Child

One root CID is one grind with one quantity (§9.1). Along its proof the
quantity is the target-derived work of the ROOT-MOST carrier whose target the
hash beat, raised if greater by the terminal child's own target (§9.5). Since
a hit at difficulty `D` occurs with probability about `1/D` and is credited
about `D`, every level a hash can beat adds at most one hash-equivalent in
expectation. Let `kappa` be the expected credit per hash at the child:

```text
child easier than parent (D_c <= D_p):  kappa = 2 - D_c / D_p
child harder than parent (D_c >  D_p):  kappa = 1
any proof path of L blocks:             kappa <= L
```

In the first case a parent hit is credited `D_p` and a child-only hit `D_c`; in
the second a child hit also beats the parent target, but the root-most bound
`D_p` is raised to `D_c` and nothing more. A carrier need not be valid, so a
prover who fabricates the root chooses its target (§9.5): an attacker who does
not need a valid parent block can reach `kappa_A -> 2` for a direct child of
Nexus whatever the honest `kappa` is.

Target choice does not change these expectations. A block may be harder than
its scheduled target but never easier (§5.5); a harder target credits more per
hit and hits proportionally less often. Moving a timestamp forward eases only
the one successor, by at most `2^(Δ / halfLife)`, and an easier target is
credited less per hit. Neither mints weight.

## What Parent Work Is Worth To The Child

A parent block that commits child block `C` into directory `d` starts a run.
Every parent block that descends from it, by parent pointer, until the next
block committing into `d`, is in that run, and the run's work less the
carrier's own grind is credited at `C` (§9.10). This holds whoever mined those
blocks: **unsubscribed parent hashrate does secure the child**. Two
consequences follow from the same rule.

- **It arrives only at commitments.** Until a parent block commits a block of
  the span or one of its descendants, the span has only its own grinds. With
  honest committers alone, commitments into `d` arrive every
  `D_p / h_m ~= B_p * H / h_m` seconds.
- **It backs whichever child block was committed last.** The unsubscribed
  miner does not choose. A run is credited at the block its carrier commits,
  and only if the child chain holds that block (§9.10), so whoever wins the
  latest parent block committing into `d` directs the parent work that follows
  it. If committers of two child branches win parent blocks at rates `a` and
  `h_m`, the unsubscribed work divides `a : h_m`.

Runs are also independent of parent canonicity (§9.10): an attacker's parent
work on a losing parent fork still backs the child blocks its carriers commit,
but only that work, since no honest miner extends the losing fork.

## Reorganization Cost

There is no finality: a strictly heavier effective subtree reorganizes the
child at any depth (§9.4, §12.5.10). The honest span's weight is its deficit:

```text
W(t) ~= kappa * h_m * t + u * t_c
```

An attacker mining valid parent templates that commit its own child branch,
and publishing the parent blocks it wins, competes for both terms. While it does, the two branches gain weight at

```text
attacker:  a   * (kappa_A + u / (a + h_m))
honest:    h_m * (kappa   + u / (a + h_m))
```

With `kappa_A = kappa` the ratio is exactly `a / h_m`: the unsubscribed term
amplifies both branches in proportion and moves no threshold. In
expectation the attack succeeds, eventually, if and only if `a > h_m`. With

```text
g(a)        = (a - h_m) * (kappa + u / (a + h_m))      // closing rate
s           = W(t) / g(a)                              // attack duration
hashSpend   = c * a * s
```

two regimes bound the spend.

**Span not yet committed** (`t_c = 0`), attack too short to expect an
attacker commitment (`s << D_p / a`): only grinds race.

```text
hashSpend ~= c * h_m * t * a / (a - h_m)  ->  c * h_m * t   as a grows
```

**Span committed, attack long enough to average over many commitments**:
when `u >> kappa * (a + h_m)`,

```text
hashSpend ~= c * t * (1 + kappa * h_m / u) * a (a + h_m) / (a - h_m)
          >= (3 + 2 sqrt 2) * c * h_m * t     at a = (1 + sqrt 2) * h_m
```

The deficit grows with `u`, but so does the closing rate, and the two cancel to
first order. In both regimes the price of a child span is proportional to
`h_m * t`, the subscribed hashrate times the span's age, never to `H * t`.

The attacker's parent blocks are ordinary parent blocks, so the hash spend
above also earns parent rewards at the attacker's parent share. This estimate
does not net them out; an attacker already mining the parent pays mainly the
child rewards it forgoes.

## Worked Example

```text
H   = 1e19 H/s (10 EH/s)    B_p = 3,600 s    D_p = 3.6e22
h_m = 1e17 H/s (1% of H)    B_c = 60 s       D_c = 6e18
u   = 9.9e18 H/s            kappa = 2 - D_c/D_p ~= 2
c   = 3e-19 per hash
```

Honest commitments into the child arrive every `D_p / h_m = 3.6e5` s, about
100 hours.

- **60 child blocks (one hour), uncommitted.** `W = 7.2e20`. Replacing it costs
  about `h_m * t = 3.6e20` hashes, about 108 at `c`. One Nexus block costs
  `c * D_p ~= 10,800`.
- **12,000 child blocks (200 hours), committed.** `W ~= 7.3e24`. Outworking it
  with grinds alone would need more than `W / 2 = 3.6e24` hashes (1.09 million
  at `c`), since the honest branch keeps gaining `u`; 200 Nexus blocks cost
  2.16 million. Capturing runs, the
  cheapest attacker runs at `a ~= 2.5 h_m` (2.5% of Nexus) for about 445 hours,
  spending about `4.0e23` hashes, about 120,000, while earning about 2.4% of
  Nexus rewards. It wins about 11 parent blocks in that time, so this is an
  average with wide variance.

## No Double Backing

One grind cannot back both sides of a child fork. Its sparse proof has exactly
one terminal block in each chain it reaches, and placing one grind at two
blocks of a chain is rejected (§9.1, §12.5.3). Attributed runs partition the
parent graph: each parent block is in at most one run per directory, so its
work is credited at exactly one committed child block (§9.10). The
[lattice-formal](https://github.com/adalinxx/lattice-formal) Hierarchy model
checks this as `NoDoubleBacking` (the work above that reaches one side of a
lower fork, followed level by level to the root, never backs the other side,
genesis forks included) and `PhysicalWorkOnce` (a child or grandchild block's
weight is the sum over the distinct physical grinds it rests on).

Merged mining therefore has nothing at stake in the proof-of-stake sense: to
back two branches, a miner splits its hashrate between them. What remains is
the weaker property derived above: unsubscribed parent work backs one side,
chosen by the last committer.

The same model checks `ChildrenCannotMoveParent` (no chain below changes a
parent's weights, verdicts or tips, so a child attack never reorganizes the
parent) and `ParentCanonicityIrrelevant` (the chains below see the same
weights and tips whichever parent branch is canonical). These are bounded
model checks of the specification's rules, not of this cost model.

## Inverted Targets And Long Block Times

Weight accrues per hash, not per block, so a longer child block time `B_c`
does not change the cost of replacing `t` seconds of child history; it changes
only how many blocks that is. Confirmations on a child should be counted in
time, not blocks.

`ChainSpec.targetBlockTime` is a free per-chain field, so a child whose
`h_m * B_c` exceeds `H * B_p` retargets to a harder target than its parent: an
inverted hierarchy (§9.5). Then:

- honest `kappa` falls to 1, while a prover with a fabricated root can still
  approach 2 (§9.5), so grind-for-grind the attacker may need about half the
  honest hashrate rather than all of it;
- every honest child block is also a parent hit, so it arrives already
  committed and starts a run at once;
- a parent hit that misses the child target commits a candidate the child never
  holds, so the run it starts is credited nowhere (§9.10). A template that
  commits a fresh candidate gets a chance at a child block; one that commits
  the held tip keeps the run. Each side faces that choice, and the outcome of
  the run race depends on it.

## Confirmation Depth For Transfers

A transfer touches both chains (§8.1), and each side waits on the chain whose
reorganization would hurt it.

- **Withdrawer, before paying the receipt on the parent.** If the child
  deposit is reorganized away after the receipt, the parent payment stands and
  authorizes nothing on the child without a matching deposit (§8.1). The
  deposit's security is the child's: wait until `c * h_m * t` exceeds the value
  at risk. That is the uncommitted bound, the conservative one; a commitment
  raises it by at most a small constant factor. Child depth in blocks is
  meaningless without `h_m`.
- **Demander, receiving the parent payment.** The receipt is an ordinary parent
  transaction; its security is the parent's
  [majority-reorg cost](fee-market-and-51pct.md#majority-reorg-estimate),
  `c * D_p * k` at depth `k`. A parent reorganization can undo the payment
  while the child withdrawal, anchored at a state only the abandoned branch
  holds, stands. Honest child miners cannot extend that withdrawal (anchors
  only advance, §5.3 step 6); they must outweigh it from below, and its
  existing weight, including runs attributed from the abandoned parent branch,
  still counts (§9.10). The withdrawal is undone only once the honest child
  branch is heavier (§8.1, "Receipt canonicity"). The demander does not choose
  when the withdrawal happens, so it cannot wait its way out of this exposure;
  it can only size the transfer against the parent's reorg cost at the depth
  it expects the receipt to reach.

## Not Covered

This prices direct hash spend against an honest, subscribed `h_m`. It does not
model:

- bribery, rented hashrate, or payments that change honest miners'
  subscription or template choices;
- selfish mining or balancing attacks, whose thresholds are lower than the
  majority one (see the [adversarial model](../consensus-simulator.md#adversarial-model));
- variance: commitments are rare, runs arrive in large discrete pieces, and
  every estimate here is an average;
- timestamp games beyond the §5.5 bound, and their effect on block counts and
  rewards rather than on weight;
- the deterministic CID tie-break (§9.4), fee sniping, network position, body
  withholding, and market effects of the attacker's hashrate on either chain.
