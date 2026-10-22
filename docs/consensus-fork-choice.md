# Hierarchical Work And Fork Choice

[Specification section 9](spec.md#9-consensus) is normative. This document
explains the model operationally.

## The Rule

A physical grind has one identity, one quantity, and exactly one terminal
location in each chain it reaches:

```text
identity = CID(root)
quantity = root-most beaten accepted-target bound along the proof,
           raised if greater by the terminal child's own target,
           then strongest across repeated observations
location = exact terminal block in this chain
```

One block may contain many independent grinds. One grind cannot be placed at
two blocks in the same chain. Ordinary same-chain ancestry makes work at a
descendant support that descendant's ancestors; the grind is not copied to
those ancestors.

Fork choice asks one local question:

> Which competing same-chain subtree contains the greatest total quantity of
> uniquely located grinds?

Parent canonicity, carrier validity, arrival order, and tip target are
not inputs.

## From A Root To A Candidate

Let `R` be the mined root and `C` the candidate for this chain. A
`ChildBlockProof` supplies the exact sparse path from `R` to `C`.

Work verification:

1. recomputes `CID(R)` and the proof-of-work hash;
2. verifies the sparse path and requires its terminal CID to equal `CID(C)`;
3. verifies every vertical `child.parentState == carrier.prevState` binding
   — a structural check on the committed path, NOT an anchor: a carrier need
   not be imported, connected, valid or canonical, so both sides may be chosen
   by one party. A block's `parentState` is anchored by import instead
   (spec §5.3 step 6, at every height including block 1);
4. checks the same hash against the terminal target; and
5. derives the target-derived quantity of the ROOT-MOST block on the committed
   directory path whose target that hash beat, raised if greater by the
   terminal child's own target.

A carrier may fail its own chain's target or validity rules and still prove real
work for the terminal child. The work affects fork choice only after `C` is
independently accepted and connected.

## Parent-State Continuity

For every candidate `C`, genesis included, define:

```text
old = emptyHeader     (the parent chain's genesis pre-state)
new = C.parentState
```

Continuity holds when `new == old` (a non-genesis block that commits no parent
state), or when the immediate parent's executed set contains a transitive state
path from `old` to `new`, i.e. the parent executed `new` on some branch. Each
block proves its own anchor; nothing is inherited from the predecessor's
`parentState`, because a weighed predecessor proved nothing (spec §5.3 step 6).
A noncanonical parent branch may prove the fact; an unexecuted or disconnected
one cannot.

So consecutive child blocks may anchor backward or sideways between parent
branches. For receipts this means a withdrawal can settle against a receipt that
exists only on a stale parent branch, and child fork choice keeps it. Consensus
does not close that; see spec §8.1, "Receipt canonicity".

This reachability fact is distinct from the directory proof. The configured
immediate parent authenticates the exact parent path and state pair, but it
asserts no work and commands no child fork choice.

## Exact Work Algebra

`WorkMeasure` is a map from grind identity to quantity:

```text
(A union B)[id] = max(A[id], B[id])
total(A)        = exactSum(A.values)
```

Union is associative, commutative, and idempotent. It combines duplicate
observations of the same grind at the same location and prevents recursive
inheritance from counting the same physical work twice. A snapshot that places
one identity at different blocks in the same chain is invalid and is rejected
atomically.

Snapshots join monotonically. New unique facts and stronger quantities at the
same location may be added; facts cannot be retracted or moved. Revision is a
progress watermark, so an older or equal revision may still carry a previously
unseen monotonic fact.

## GHOST

For a connected same-chain block `B`:

```text
effectiveSubtree(B) = own(B)
                      union each effectiveSubtree(C)
                            for C in sameChainChildren(B)

trueCumWork(B) = total(effectiveSubtree(B))
```

Fork choice starts at an accepted height-zero root and repeatedly chooses the
same-chain child block with greatest `trueCumWork`. An exact tie selects the smaller
canonical CID bytes.

Holding the incumbent on an exact tie is deliberately not part of consensus.
It would make the result depend on arrival order or on a persisted canonical
cache, so peers with the same facts—and the same peer before and after
recovery—could select different tips. A miner can grind the deterministic CID
tie-break after matching the incumbent's work, but the tie-break contributes no
weight and any strictly heavier branch still wins.

Canonicity is an output of this descent, never a filter on work. Consequently a
grind on a connected noncanonical branch remains eligible, and moving only a
canonical pointer cannot change any weight.

Subtree totals are kept so that new work never walks its ancestors, at cost
logarithmic in graph size, not proportional to height; GHOST reads weights only
at forks. The immutable block graph and unique grind locations remain the source
of truth; the totals are a rebuildable cache.

## Connectivity And Recovery

Only a block connected through validated same-chain predecessor edges to an
accepted height-zero root participates in GHOST or parent export. A disconnected
accepted block retains its authenticated fact but has no route until its missing
predecessor attaches.

Persistence records the accepted graph, proof-derived work locations, and
authenticated parent-state facts. Recovery replays the same immutable facts and
rebuilds the work index. A persisted canonical tip is only a cache.
