# Lattice Architecture

This document explains who decides, who stores, and how facts cross process
boundaries. The [protocol specification](spec.md) is normative. The work algebra
and fork-choice rationale live in
[consensus-fork-choice.md](consensus-fork-choice.md).

## Mental Model

A mined root and a running chain are different things.

```text
mined root R -> nested CID paths -> candidates for many chains

process Nexus          -> validates and chooses Nexus
process Nexus/Payments -> validates and chooses Nexus/Payments
node                   -> authenticates, routes, persists, and retains
```

Think of `R` as a content-addressed envelope containing sparse routes to many
chain candidates. The node delivers one route and its authenticated supporting
facts to the process responsible for that path. Lattice verifies the evidence,
updates only that path's accepted forest, and returns only that path's canonical
delta.

The content graph may recurse to arbitrary depth. A Lattice runtime never does.

## Manifesto

1. **One process, one chain.** One runtime owns one absolute path, one accepted
   forest, and one canonical projection.
2. **The hierarchy is data.** Content commitments connect chains; runtimes do not
   recursively contain other runtimes.
3. **Each child decides.** Parent evidence may prove facts, but cannot validate a
   child or choose its tip.
4. **One grind, one quantity.** Coverage may grow without multiplying physical
   work.
5. **Work is not canonicity.** Physical work comes from a verified directory
   proof; no chain's preferred pointer creates or removes it.
6. **State is not ancestry.** `parentState` commits the carrier's `prevState`; it
   is not a parent-block backlink.
7. **The node owns operations.** Acquisition, process authentication, durability,
   pruning, pinning, routing, and projections are node policy.
8. **Durability precedes visibility.** The staged immutable batch is the record
   applied by both live import and recovery.

## Runtime Boundary

An absolute path such as `Nexus/Payments` is the chain identity. A child genesis
CID is one root in that path's accepted forest, not a new runtime identity. Any
genesis carried by a valid proof is a competing root; the child process chooses
among them with its own fork choice. Only the root chain pins one genesis: its
configured CID, carried by its `ChainRuntimeContext`.

Each process owns:

```text
ChainLevel
|- ChainRuntimeContext  absolute chain path
`- ChainState           accepted same-chain forest + canonical projection
```

`ChainLevel` contains no child runtimes. Lattice has no cross-chain
reorganization call and no multi-chain fork-choice loop.

## Evidence Boundary

A child candidate arrives with a sparse proof from one mined root to that exact
candidate. Lattice verifies the content-bound root and work hash, the unique
directory path, vertical state bindings, and the terminal target. It validates
the candidate's own transition separately.

At a vertical edge, the nested child commits the carrier's `prevState` as
`parentState`. It does not commit the carrier CID. Therefore:

- same-chain predecessors are explicit block links and unresolved predecessors
  (absent or accepted-but-unconnected) are derived from the accepted graph;
- cross-chain acquisition asks only the authenticated immediate-parent process
  for an exact parent-state continuity fact — the genesis included;
- Lattice never tries to invert `parentState` into a parent block.

### Why Parent Continuity Is Required

A content address proves exact bytes, and proof of work proves effort over
those bytes. Neither proves that a parent chain legitimately moved from the
state referenced by one child block to the state referenced by its successor.
For a non-genesis child candidate `C` with predecessor `P`, Lattice therefore
requires:

```text
P.parentState == C.parentState
or
P.parentState -> ... -> C.parentState
through connected accepted blocks in the immediate parent
```

This is reflexive, transitive state reachability—not direct adjacency. Without
it, mined bytes could jump a child backward or sideways to a parent state that
does not continue its prior dependency. The immediate-parent process answers
the exact state-pair question from its accepted graph. A connected
noncanonical branch is sufficient; canonicity cannot revoke the immutable
fact. The node authenticates and may cache or relay the answer.

The state proof itself remains content-addressed rather than becoming another
parent assertion. Receipt-state keys are fixed-depth, domain-separated hashes,
and a block carries at most 64 withdrawals, so a cold child peer can obtain the
complete parent-receipt witness from the exact same-chain advertiser within a
history-independent bound.

Securing-work verification is deliberately independent of carrier validity. A
carrier may fail its own target, transition, timestamp rule, or proposed
`nextTarget` while the root grind still commits uniquely to a deeper child and
beats that child's target. Those carrier-local rules do not become descendant
dependencies.

A child genesis weighs by its `ChildBlockProof` and executes like any child
block (spec §5.3, §9.9 genesis admission); no parent record authorizes it. A
target miss is a proof-of-work failure that creates no runtime or durable
local consensus fact. The same bytes may still sit on a descendant's proof
path: a grind reaches a descendant only inside that descendant's
`ChildBlockProof`.

The proof-derived contribution becomes ordinary same-chain work only after the
terminal child is accepted and connected. See
[work and fork choice](consensus-fork-choice.md) for the exact model.

## Import And Recovery

Every external candidate follows one boundary:

```text
acquire
  -> verify
  -> targeted store
  -> atomically stage one immutable batch
  -> apply that exact batch
  -> project one chain
```

The node's single stage callback receives `BlockImportStagingContext`, so the
consensus batch and its verified hierarchy links cross one atomic durability
boundary. Returning means the whole context is durable; throwing means none of
its facts became visible. An existing runtime reserves one
commit revision before staging so another actor mutation cannot consume the last
available revision while the batch is becoming durable.

Live import does not reacquire or rebuild a candidate after staging. Recovery
replays already-authenticated staged batches through the same reducer. Replaying
an identical batch is a no-op; conflicting immutable metadata fails closed.
Root and child bootstrap expose no runtime until the genesis batch has been
stored, staged, and restored.

A target miss is a proof-of-work failure. It creates no local consensus
fact, executes no local transition, and causes no implicit Lattice retention.
When an explicit predecessor is not connected, duplicate and non-verdict
rejected outcomes expose that exact typed backfill requirement so the node can
retry. The node may retain an exact child path when its availability policy
calls for it.

## Ownership

| Component | Owns |
|---|---|
| Lattice | Validation, deterministic state transitions, accepted graph, proof-derived work algebra, fork choice, parent-state reachability, `ChainCommit` |
| lattice-node | Acquisition, process authentication and supervision, atomic fact durability, pruning, pin counts, projections, RPC |
| cashew | Generic content-addressed structures and matching targeted resolve/store traversal |
| VolumeBroker | Complete selected Volumes, node-selected pinning, and eviction |
| Ivy | Transport, discovery, authenticated sessions, and delivery attribution |
| Tally | Provider observations and policy, never protocol validity |

Storage presence is not validity. Peer identity is not validity. Authenticating a
parent process establishes who may speak for that parent path, not which child
branch must win.

Nested Volumes remain independent availability units. Storing or pinning an
outer Volume creates no implicit retention relationship with another Volume
merely referenced by CID. Operators choose acquisition, transport, and
retention ceilings locally; exceeding one means that node declines or retries
through another strategy, not that the content is objectively invalid.

## Pruning

Lattice never loses counted work. A node may fold dead side branches beyond a
window it chooses into their fork point (spec §9.7). Otherwise Lattice retains
the complete accepted consensus graph and verified local grind coverage, and
does not prune consensus inputs according to a node storage budget.

The node decides how long to retain block bodies, materialized state,
`StateDiff` payloads, proof Volumes, and CAS pins. `StateDiff` is local
lifecycle metadata carried by the durable block fact; it is not committed in a
block or stored in `BlockMeta`.

## Review Contract

A change preserves the architecture only if all of these remain true:

1. One process owns one path and never recursively runs another chain.
2. Securing work depends on a content-bound directory commitment and target
   hit, not carrier validity or canonicity.
3. Work is joined by grind identity before quantities are totaled.
4. Non-genesis parent-state movement is reflexive or transitively forward
   through the immediate parent's connected accepted graph.
5. Fork choice compares effective `trueCumWork`, then same-chain child block CID.
6. External ingress uses one import boundary; recovery replays durable facts.
7. Durable facts precede visible mutation.
9. Lattice retains consensus inputs except folded side branches, whose work
   stays counted at their fork point; the node owns payload pruning.
10. Cross-chain interfaces carry proofs and exact parent facts, never trusted
    work totals or canonical-tip commands.
