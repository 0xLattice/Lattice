# Lattice Library Architecture

This document explains how the Lattice consensus library is divided: what one
chain's validator decides, what crosses from one chain to another, and what is
left to the node that hosts it.

The [protocol specification](spec.md) is normative. How work becomes
fork-choice weight is explained in
[work and fork choice](consensus-fork-choice.md).

## Mental Model

A mined root and a running chain are different things. Keep three structures
separate:

| Structure | What it contains |
|---|---|
| Content DAG | Sparse root-to-candidate paths across chain levels |
| Same-chain forest | Every accepted root, block, fork, and work fact for one chain path |
| Validators | One `ChainTree` per chain path, hosted by the node |

```text
mined root R -> nested CID paths -> candidates for many chains

ChainTree Nexus          -> validates and chooses Nexus
ChainTree Nexus/Payments -> validates and chooses Nexus/Payments
node                     -> hosts the ChainTrees, routes evidence, persists, and retains
```

Think of `R` as a content-addressed envelope containing sparse routes to many
chain candidates. The node delivers one route and its supporting facts to the
`ChainTree` responsible for that path. Lattice verifies the evidence, updates
only that path's accepted forest, and returns only that path's canonical
delta.

The content graph may recurse to arbitrary depth. A `ChainTree` never does.

How the node arranges its `ChainTree`s is the node's choice. `lattice-node`
hosts every chain of a Nexus-rooted tree in one process and never starts a
separate process per chain.

## Principles

1. **One validator, one chain.** One `ChainTree` owns one absolute path, one
   accepted forest, and one canonical projection.
2. **The hierarchy is data.** Content commitments connect chains; a validator
   does not recursively contain other validators.
3. **Each child decides.** Parent evidence may prove facts, but cannot validate a
   child or choose its tip.
4. **One grind, one quantity.** Coverage may grow without multiplying physical
   work.
5. **Work is not canonicity.** Physical work comes from a verified directory
   proof; no chain's preferred pointer creates or removes it.
6. **State is not ancestry.** `parentState` commits the carrier's `prevState`; it
   is not a parent-block backlink.
7. **The node owns operations.** Acquisition, hosting, durability, pruning,
   pinning, routing, and projections are node policy.
8. **Durability precedes visibility.** The staged immutable batch is the record
   applied by both live import and recovery.
9. **Targeted content.** cashew resolves and stores only requested CID paths,
   and nested Volumes remain independent availability units.
10. **Deterministic transitions.** Validation applies the declared actions to
    `prevState` and requires the derived root to equal `postState`.
11. **Chain-local policies.** Content-addressed WASM policies may accept or
    reject transactions; they do not mutate state directly.

## Chain Boundary

An absolute path such as `Nexus/Payments` is the chain identity. A child genesis
CID is one root in that path's accepted forest, not a new chain identity. Any
genesis carried by a valid proof is a competing root; the child's `ChainTree`
chooses among them with its own fork choice. Only the root chain pins one
genesis: its configured CID, carried by its `ChainRuntimeContext`.

Each `ChainTree` holds its `ChainRuntimeContext` (absolute chain path), its
accepted same-chain forest, and its canonical projection.

A `ChainTree` contains no child validators. Lattice has no cross-chain
reorganization call and no multi-chain fork-choice loop.

## Evidence Boundary

A child candidate arrives with a sparse proof from one mined root to that exact
candidate. Lattice verifies:

- the content-bound root and its work hash;
- the unique directory path;
- the vertical state bindings;
- the terminal target.

It validates the candidate's own transition separately.

At a vertical edge, the nested child commits the carrier's `prevState` as
`parentState`. It does not commit the carrier CID. Therefore:

- same-chain predecessors are explicit block links, and unresolved
  predecessors (absent or accepted-but-unconnected) are derived from the
  accepted graph;
- cross-chain acquisition asks only the immediate parent chain for an exact
  parent-state continuity fact, the genesis included;
- Lattice never tries to invert `parentState` into a parent block.

### Why Parent Continuity Is Required

A content address proves exact bytes, and proof of work proves effort over
those bytes. Neither proves that a parent chain legitimately moved from the
state referenced by one child block to the state referenced by its successor.
For a non-genesis child candidate `C` with predecessor `P`, Lattice therefore
requires:

```text
some block of the immediate parent's executed set produced C.parentState,
and is or descends from a block that produced P.parentState
```

This is forward movement through executed parent history. It is not direct
adjacency, and it is not equality: `P.parentState == C.parentState` still
requires that the executed set produced the state, since equality is never
evidence ([spec §5.3](spec.md#53-child-chain-block-validation) step 6).
Without it, mined bytes could jump a child backward or sideways to a parent
state that does not continue its prior dependency, or carry along an unproven
one.

The immediate parent's `ChainTree` answers the exact state-pair question from
its executed set. An executed noncanonical branch is sufficient; canonicity
cannot revoke the immutable fact. The node carries the answer to the child and
may cache or relay it.

### Receipt Witnesses

The state proof itself remains content-addressed and does not become another
parent assertion. Receipt-state keys are fixed-depth, domain-separated hashes,
and the withdrawals one block can carry are bounded by its `maxBlockSize`, with
one receipt-trie path per withdrawal. A cold child peer can therefore obtain
the complete parent-receipt witness of a block from the same-chain peer that
advertises it, within a bound that does not grow with the parent's history.

### Work Does Not Depend On Carrier Validity

Securing-work verification is deliberately independent of carrier validity. A
carrier may fail its own target, transition, timestamp rule, or proposed
`nextTarget` while the root grind still commits uniquely to a deeper child and
beats that child's target. Those carrier-local rules do not become descendant
dependencies.

A child genesis weighs by its `ChildBlockProof` and executes like any child
block ([spec §5.3](spec.md#53-child-chain-block-validation), and genesis
admission in
[§9.9](spec.md#99-deferred-execution-weighed-and-validated-tiers)); no parent
record authorizes it.

A target miss is a proof-of-work failure that creates no durable local
consensus fact. The same bytes may still sit on a descendant's proof path: a
grind reaches a descendant only inside that descendant's `ChildBlockProof`.

The proof-derived contribution becomes ordinary same-chain work only after the
terminal child is accepted and connected. See
[work and fork choice](consensus-fork-choice.md) for the model.

## Import And Recovery

Every external candidate follows one boundary, all of it on the `ChainTree`
value. A candidate is admitted in two steps, each returning the facts it
applies (`Sources/LatticeImport/ChainTree+Admission.swift`):

| Step | Who | What happens |
|---|---|---|
| Acquire | Node | Obtains the candidate and the content its validation reads |
| Weigh | Lattice | `insertRootHeader` / `insertChildHeader` verifies the grind (a child's by its verified `ChildBlockProof`) and records the block and its work |
| Execute | Lattice | `connectJob` then `ChainTree.connect` runs this chain's transition off the tree; `applyConnect` records the verdict (valid, or excluded) |
| Persist | Node | Persists each update's fact batches atomically, with the content and materialized state it chooses to keep |

Each step returns the immutable facts it adds (`ChainTreeUpdate.batches`). The
node persists them, with whatever block content and state it keeps, in one
transaction of its own.

Recovery replays the persisted batches through the same reducer
(`ChainTree.restore`). Replaying an identical batch is a no-op; conflicting
immutable metadata fails closed.

A target miss is a proof-of-work failure. It creates no local consensus
fact, executes no local transition, and causes no implicit Lattice retention.
A held block whose ancestry is not connected names its parent; fetching that
parent, and retaining any exact child path, is node availability policy.

## Ownership

Lattice and the node have deliberately different jobs:

| Lattice owns | The node owns |
|---|---|
| Protocol and state-transition validation | Acquisition, storage and provider selection |
| Accepted same-chain graph | Hosting one `ChainTree` per chain and routing evidence between them |
| Grind identity and work algebra | Atomic fact durability |
| Chain-local GHOST and reorganizations | Pruning, pinning, projections, and RPC |
| Which content a block's validation reads | Fetching and keeping that content |
| Parent-state reachability, `ChainCommit` | |

Lattice stores nothing. It says which content a block carries and reads
(`Block.carriedContentPaths`, `validationPaths`, `parentReceiptWitnessPaths`,
the `maxBlockSize` bound in `resolveBoundedContent`), and the node fetches and
keeps it.

The components the node builds on:

| Component | Owns |
|---|---|
| lattice-node | Everything in the right-hand column above |
| cashew | Generic content-addressed structures and matching targeted resolve/store traversal |
| VolumeBroker | Complete selected Volumes, node-selected pinning, and eviction |
| Ivy | Transport, discovery, authenticated sessions, and delivery attribution |
| Tally | Provider observations and policy, never protocol validity |

Storage presence is not validity. Peer identity is not validity. Establishing
who may speak for a parent path does not establish which child branch must
win.

Nested Volumes remain independent availability units. Storing or pinning an
outer Volume creates no implicit retention relationship with another Volume
merely referenced by CID. Operators choose acquisition, transport, and
retention ceilings locally; exceeding one means that node declines or retries
through another strategy, not that the content is objectively invalid.

## Pruning

Lattice retains the complete accepted consensus graph and verified local grind
coverage. It does not prune consensus inputs according to a node storage budget.

The node decides how long to retain block bodies, materialized state,
`StateDiff` payloads, proof Volumes, and CAS pins. `StateDiff` is local
lifecycle metadata: an execution output (`ConnectVerdict.stateDiff`,
`ChainTreeUpdate.stateDiff`), not committed in a block, carried by the block
fact, or stored in `BlockMeta`.

## For Contributors

A change to the library must keep the properties listed in the
[review contract](review-contract.md).
