# Hierarchical Work And Fork Choice

This document explains how Lattice counts proof of work across a tree of
chains and how one chain picks its tip. It teaches the model with examples and
is not normative: the rules are in
[specification section 9](spec.md#9-consensus), and each part below links to
the section that states them.

## The Idea

A miner searches for one nonce over one root block. That search is a **grind**.
The root can commit blocks of many chains, so one grind can secure a block in
each chain it reaches. Lattice gives every grind three properties:

| Property | Value | Why |
|---|---|---|
| Identity | The root block's CID | The same grind is recognised wherever it is seen |
| Quantity | One number, fixed by the proof | Seeing a grind twice never doubles it |
| Location | Exactly one block in each chain it reaches | A grind cannot support two competing blocks of one chain |

Fork choice then asks one local question:

> Which competing same-chain subtree contains the greatest total quantity of
> uniquely located grinds?

Parent canonicity, carrier validity, arrival order, and tip target are not
inputs.

## Worked Example: One Grind, Two Chains

A miner builds a Nexus block `R` that commits a block `C` of the child chain
`Nexus/Payments`. Suppose the targets are worth this much work:

```text
Nexus target            -> 1000 units of work
Nexus/Payments target   ->   10 units of work   (easier)
```

The miner finds a nonce and `R` hashes to `h`. Every level compares the same
`h` with its own target
([spec §5.4](spec.md#54-proof-of-work)). Two outcomes matter:

| `h` beats | At Nexus | At `Nexus/Payments` |
|---|---|---|
| Both targets | `R` is a Nexus block carrying 1000 | `C` receives a contribution of 1000 |
| Only the Payments target | `R` is not a Nexus block | `C` receives a contribution of 10 |

In the first row the grind is priced by Nexus's target, because Nexus is the
root-most chain whose target the hash beat. In the second row no chain above
`C` was beaten, so the grind is priced by `C`'s own target. In both rows the
contribution has the same identity, `CID(R)`, and one location in
`Nexus/Payments`: the block `C`.

In the second row `R` failed Nexus's own target. It still proves real work for
`C`. A block that carries a child on its proof path is a **carrier**, and a
carrier does not have to be a valid, accepted, or canonical block of its own
chain. Its exact bytes and its commitment to the child are enough.

The rule this example illustrates, including deeper paths and the case where a
middle chain has a harder target than its parent, is stated once in
[spec §9.1](spec.md#91-verified-work-contributions). The reason for pricing by
the root-most beaten carrier, not the hardest one, is in
[spec §9.5](spec.md#95-cross-chain-evidence-independence).

## From A Root To A Candidate

`C` arrives with a `ChildBlockProof`: the exact sparse path from `R` down to
`C`. Verifying it answers four questions, in this order
([spec §5.3](spec.md#53-child-chain-block-validation), steps 1 to 4):

1. Are these the bytes of `R`, and what do they hash to?
2. Does the path lead from `R`, directory by directory, to exactly `C`?
3. Does each nested block commit the entering state of the block that carries
   it (`child.parentState == carrier.prevState`)?
4. Does the hash beat `C`'s target, and how much work does it contribute?

Question 3 is a structural check on the committed path. It is **not** an
anchor: because a carrier need not be valid, one party may have chosen both
sides of that equality. What anchors a block's `parentState` is the next
section.

The work affects fork choice only after `C` is independently accepted and
connected to its own chain.

## Parent-State Continuity

A child block names a parent state, `parentState`, and settles withdrawals
against it. So the child must know that the parent chain really produced that
state. The proof of work does not show that, and neither does question 3
above.

Every child block, genesis included, therefore proves **continuity**
([spec §5.3](spec.md#53-child-chain-block-validation), step 6). Call the
states:

```text
old = P.parentState   (P the same-chain predecessor; emptyHeader, the parent
                       chain's genesis pre-state, for a genesis)
new = C.parentState
```

Continuity holds when the immediate parent's executed set produced `new` at a
block that is, or descends from, a block that produced `old`.

| Situation | Is continuity proven? |
|---|---|
| `new` was produced on a noncanonical but executed parent branch | Yes |
| `new == old` | Only by showing that the parent executed `new`. Equality is never evidence on its own, because a weighed predecessor proved nothing |
| `new` is `emptyHeader` on a non-genesis block | Only while the predecessor commits none either |
| `new` was produced on an unexecuted or disconnected parent branch | No |
| `new` lies behind or beside `old` in the parent's history | No |

So child anchors only advance along the parent's history. That has a
consequence worth seeing once:

1. The parent reorganizes and abandons a branch.
2. A miner on the canonical parent anchors at the parent's canonical state.
3. That state cannot advance from the abandoned branch, so the miner cannot
   extend a child block anchored there.
4. The child chain therefore reorganizes with the parent.

A withdrawal settled against a receipt that only an abandoned parent branch
holds stands only with a majority of child hashrate
([spec §8.1](spec.md#81-protocol-phases), "Receipt canonicity").

Two properties of the continuity fact:

- It is cheap. It is an ancestry test on the parent's fork-choice tour,
  logarithmic in the parent's size whatever the distance between `old` and
  `new`.
- It is distinct from the directory proof. The immediate parent answers for
  the exact parent path and state pair, but it asserts no work and commands
  no child fork choice
  ([spec §9.5](spec.md#95-cross-chain-evidence-independence)).

## Adding Work Up

A `WorkMeasure` is a map from grind identity to quantity
([spec §9.1](spec.md#91-verified-work-contributions)). Two measures combine by
taking the larger quantity for each identity, and only then is the map summed:

```text
(A union B)[id] = max(A[id], B[id])
total(A)        = exactSum(A.values)
```

For example:

```text
A = { g1: 10, g2: 8 }
B = { g2: 9,  g3: 5 }

A union B        = { g1: 10, g2: 9, g3: 5 }
total(A union B) = 24        (not 10 + 8 + 9 + 5 = 32)
```

`g2` was seen twice, once with a stronger verified quantity. It counts once,
at the stronger value.

Union is associative, commutative, and idempotent. That is what makes the
result independent of the order in which evidence arrives, and what prevents
recursive inheritance from counting the same physical work twice.

Facts only accumulate. New grinds and stronger quantities at the same location
may be added; a fact cannot be retracted or moved. A snapshot that places one
identity at different blocks in the same chain is invalid and is rejected
atomically.

## Choosing A Tip: GHOST

Each block's weight is the total of its own grinds joined with the grinds of
every block built on it in the same chain
([spec §9.2](spec.md#92-chain-state-and-hierarchical-ghost)):

```text
effectiveSubtree(B) = own(B)
                      union each effectiveSubtree(C)
                            for C in sameChainChildren(B)

trueCumWork(B) = total(effectiveSubtree(B))
```

Fork choice starts at an accepted height-zero root and repeatedly chooses the
same-chain child block with the greatest `trueCumWork`
([spec §9.4](spec.md#94-fork-choice-and-reorganization)).

For example, with each block's own grind in brackets:

```text
A ── B1 [g1: 10]
 └── B2 [g2: 8] ── D [g3: 5]

trueCumWork(B1) = 10
trueCumWork(B2) = 8 + 5 = 13     -> B2 wins; the tip is D
```

`B1` alone outweighs `B2` alone. `B2` wins because work at a descendant
supports its ancestors. The grind `g3` is not copied to `B2`; it stays located
at `D`.

### Ties

An exact tie selects the block with the smaller canonical CID bytes.

Holding the incumbent on an exact tie is deliberately not part of consensus.
It would make the result depend on arrival order or on a persisted canonical
cache, so peers with the same facts, and the same peer before and after
recovery, could select different tips.

A miner can grind the deterministic CID tie-break after matching the
incumbent's work. The tie-break contributes no weight, and any strictly
heavier branch still wins. Its measured effect on selfish mining is in the
[adversarial security report](consensus/adversarial-report.md).

### Canonicity Is An Output

Canonicity is the result of this descent, never a filter on work. A grind on a
connected noncanonical branch remains eligible, and moving only a canonical
pointer cannot change any weight.

### Cost

Subtree totals are kept so that new work never walks its ancestors, at a cost
logarithmic in graph size, not proportional to height. GHOST reads weights only
at forks. The immutable block graph and unique grind locations remain the
source of truth; the totals are a rebuildable cache.

## Connectivity And Recovery

Only a block connected through validated same-chain predecessor edges to an
accepted height-zero root participates in GHOST or parent export. A
disconnected accepted block retains its authenticated fact but has no route
until its missing predecessor attaches.

Persistence records the accepted graph, proof-derived work locations, and
authenticated parent-state facts. Recovery replays the same immutable facts and
rebuilds the work index. A persisted canonical tip is only a cache
([spec §9.8](spec.md#98-persistence)).

## Where The Rules Are

| Topic | Specification |
|---|---|
| The proof-of-work hash and `workForTarget` | [§5.4](spec.md#54-proof-of-work) |
| Verifying a child's proof, step by step | [§5.3](spec.md#53-child-chain-block-validation) |
| The quantity and location of a grind | [§9.1](spec.md#91-verified-work-contributions) |
| `WorkMeasure`, `trueCumWork` | [§9.2](spec.md#92-chain-state-and-hierarchical-ghost) |
| Fork choice, ties, reorganization | [§9.4](spec.md#94-fork-choice-and-reorganization) |
| Why work does not depend on the carrier, and who attests continuity | [§9.5](spec.md#95-cross-chain-evidence-independence) |
| Weighing a block before executing it | [§9.9](spec.md#99-deferred-execution-weighed-and-validated-tiers) |
| Parent work that reaches a child after its carrier | [§9.10](spec.md#910-parent-attributed-run-work) |
| The invariants all of this must keep | [§12.5](spec.md#125-fork-choice-invariants) |
