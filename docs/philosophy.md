# Lattice Design Philosophy

This document explains why Lattice is shaped the way it is. It is not a second
protocol definition. Exact rules live in the
[protocol specification](spec.md), while runtime ownership lives in
[the architecture](foundational-architecture.md).

## The Problem

Multi-chain systems usually sacrifice either sovereignty or shared security.
Chains that share one validator or execution layer compete for its capacity and
governance. Chains with independent validator sets have to bootstrap their own
security. Moving value between independently validated systems then introduces a
new trust boundary.

Lattice asks a different question: can chains stay operationally independent
while sharing verifiable physical work and committed state proofs?

## The Hierarchical Insight

A mined root can commit a nested content-addressed tree of chain candidates. A
child may commit its own children, so the data model is self-similar at every
level.

The runtimes are deliberately not self-similar. One process validates one sparse
path and runs fork choice for one absolute chain identity. The node supervises
other paths. This keeps the useful recursion in immutable data and keeps
authority local:

```text
recursive commitments, independent decisions
```

Each chain defines its own target, economics, transaction policies, and state.
Parent evidence can add verified work or prove continuity, but cannot declare a
child valid or choose its preferred branch.

## Shared Work Without Multiplication

The root CID identifies one physical grind. At each chain level that grind has
one terminal block location; an exact parent-child commitment may project the
same identity to the next level. Its quantity is fixed by the root-most level
whose target it beat, raised by the terminal's own target; across repeated
observations at one location Lattice keeps the strongest verified value. It
sums only distinct identities.

This is the central economic abstraction: miners may reuse one nonce search
across subscribed chains, while consensus never treats repeated evidence as
repeated energy.

Inherited work is also independent from parent canonicity. Work from a connected,
accepted parent branch may secure a child even when that branch is not the
parent's current projection. Moving only a parent's preferred pointer adds no
physical work and therefore cannot move the child tip.

## A Light Root, Optional Edges

The hierarchy lets the outer root optimize for accessibility rather than maximum
throughput. Applications that need different block times, capacity, policies, or
economics can run child chains whose participants choose to acquire and retain
their data.

This does not make data free. Deeper paths require more proof material and more
availability coordination. More child content increases trie and serving load.
The point is that those costs are paid by the processes that opt into the paths,
not by recursive consensus runtimes hidden inside every root node.

## Content Addressing As The Trust Boundary

Blocks, transactions, chain specifications, and state structures are addressed
by CID. Any provider may supply bytes; the consumer recomputes the CID and
verifies the exact path it needs.

That gives Lattice three useful properties:

- unchanged state and transaction data can be structurally shared;
- validators can resolve sparse paths instead of whole graphs;
- storage and transport policy stay outside protocol validity.

Volumes make availability boundaries explicit. Storing one Volume does not imply
ownership, pinning, or retention of another Volume merely referenced by CID.

## Committed State Transitions

A block commits three state roles:

- `prevState`: this chain's state before the block;
- `postState`: the state after applying the block's actions;
- `parentState`: for a child, the carrier's committed `prevState`.

Validation deterministically applies the actions to `prevState` and requires the
derived root to equal `postState`. `parentState` lets the child prove parent-state
facts, but it is not a backlink to a parent block and cannot be inverted into one.

State is partitioned into independent content-addressed radix tries for
accounts, general data, deposits, and receipts. Inclusion and exclusion
proofs make absence, uniqueness, and exact mutation protocol facts rather than
database assumptions.

## Parent-Child Value Exchange

The transfer protocol is an exchange between independently validated chains:

1. A demander authorizes a child transaction that locks value and states the
   desired parent payment.
2. A withdrawer authorizes that payment on the parent, producing a receipt.
3. The child returns the locked value to its block-wide credit budget only after
   proving both its deposit and the matching receipt committed through
   `parentState`.

The parent validates its own signed transfer. It does not need to execute or
trust the child. The child independently validates the conjunction that makes a
withdrawal safe. See the [cross-chain guide](cross-chain.md) for the walkthrough.

## Policies, Not A Shared World Computer

Each chain may attach content-addressed WASM policies to its `ChainSpec`. Policies
receive deterministic context and may accept or reject a transaction or action.
They cannot mutate state directly.

This keeps application-specific validity at the chain boundary without creating
one shared contract runtime that every chain must execute. Automation may live in
applications above the protocol; consensus remains a deterministic validator of
declared state transitions.

## Explicit Tradeoffs

Lattice does not remove the basic costs of distributed consensus:

- there is no explicit finality; a strictly heavier subtree may reorganize a
  chain at any depth;
- shared mining does not make unproven or disconnected work count;
- deeper hierarchies increase proof and availability coordination;
- miners observing several chains may have cross-chain ordering advantages;
- each chain still has finite throughput and state-growth limits;
- node operators must choose which paths and payloads to retain and serve.

## Design Principles

1. **Verify locally.** Providers supply availability, not validity.
2. **Do not invent cross-volume ownership.** A CID reference supports traversal,
   but does not imply retention or pinning. Same-chain accepted-forest indexes
   remain durable consensus state.
3. **Keep identity separate from quantity and location.** This prevents work
   multiplication.
4. **Keep accepted evidence separate from canonical projection.** This prevents a
   parent pointer from becoming child authority.
5. **Fail early and cheaply.** Check content binding and structural proof before
   expensive resolution and execution; operators may apply stricter local
   acquisition policy.
6. **Put lifecycle policy in the node.** Consensus should not encode one storage
   budget, process topology, or retention strategy.
