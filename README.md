<p align="center">
  <h1 align="center">Lattice</h1>
  <p align="center">
    <strong>One mined root, many independently validated chains.</strong>
    <br />
    A hierarchical proof-of-work consensus library for Swift.
  </p>
</p>

<p align="center">
  <a href="#quickstart">Quickstart</a> &bull;
  <a href="https://lattice.build/docs/protocol/spec/">Documentation</a> &bull;
  <a href="docs/foundational-architecture.md">Architecture</a> &bull;
  <a href="docs/consensus-fork-choice.md">Fork Choice</a> &bull;
  <a href="docs/spec.md">Protocol Specification</a>
</p>

---

## What Is Lattice?

Lattice is a proof-of-work protocol in which a mined root can commit blocks for
many chains through a nested content-addressed DAG. Every chain has its own
state, rules, target, accepted forest, and fork choice. A chain process validates
one sparse vertical path plus the same-chain history required by its candidate.

The hierarchy is data, not runtime ownership. One Lattice process owns one
absolute chain path, such as `Nexus/Payments`. Node software runs additional
processes and moves authenticated evidence between them.

A physical grind is identified by its root CID. It may prove coverage for any
number of blocks or chain levels; its quantity is fixed by the root-most level
whose target it beat (raised by the terminal's own target), and is counted once.
Distinct grind identities sum.

Lattice also defines a parent-child transfer protocol: a demander authorizes a
child transaction that locks value, a withdrawer pays the demander on the
parent, and the child makes the locked value available to explicit child-chain
credits only after proving both the deposit and the parent receipt. No trusted
bridge is part of consensus.

This repository is the consensus library. Networking, process supervision,
durability, pruning, and RPC belong to node software such as
[`lattice-node`](https://github.com/adalinxx/lattice-node).

## Mental Model

Keep these three structures separate:

| Structure | What it contains |
|---|---|
| Content DAG | Sparse root-to-candidate paths across chain levels |
| Same-chain forest | Every accepted root, block, fork, and work fact for one path |
| Process graph | Independent chain processes supervised by the node |

```text
one mined root -> nested CID paths -> candidates for many chains

process Nexus          -> validates and chooses Nexus
process Nexus/Payments -> validates and chooses Nexus/Payments
node                   -> routes evidence and owns lifecycle policy
```

The content DAG may recurse. A Lattice runtime does not.

## Quickstart

### Requirements

- Swift 6.0+
- macOS 15+

### Build And Test

```bash
swift build
swift test
swift run LatticeDemo
```

### Use As A Dependency

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/adalinxx/Lattice.git", branch: "main")
]
```

## Architecture

One `ChainLevel` combines immutable runtime context with one actor-isolated
`ChainState`:

```text
ChainLevel
|- ChainRuntimeContext  absolute chain path
`- ChainState           one accepted forest + one canonical projection
```

Lattice and the node have deliberately different jobs:

| Lattice owns | The node owns |
|---|---|
| Protocol and state-transition validation | Acquisition and provider selection |
| Accepted same-chain graph | Process authentication and supervision |
| Grind identity and work algebra | Atomic fact durability |
| Chain-local GHOST and reorganizations | Pruning, pinning, projections, and RPC |

Every external candidate enters one import boundary (`ChainLevel.importBlock`):

```text
acquire
  -> verify the root floor and sparse path
  -> execute this chain's transition if its target accepts the grind
  -> store targeted content and materialized state
  -> atomically stage one immutable fact batch
  -> apply that exact batch to ChainState
  -> return the chain-local canonical delta
```

Recovery applies the same staged batches through the same reducer. A target miss
creates no local consensus fact and does not tell Lattice to retain the carrier.

## Core Ideas

- **One process, one chain.** A runtime cannot recursively mutate another chain.
- **One grind, one quantity.** Coverage may grow without multiplying work.
- **Work is not canonicity.** Accepted parent work may affect child weight; the
  parent's preferred pointer cannot choose the child tip.
- **State is not ancestry.** `parentState` commits the carrier's `prevState`; it
  is not a parent-block backlink.
- **Targeted content.** Cashew resolves and stores only requested CID paths, and
  nested Volumes remain independent availability units.
- **Deterministic transitions.** Validation applies the declared actions to
  `prevState` and requires the derived root to equal `postState`.
- **Chain-local policies.** Content-addressed WASM policies may accept or reject
  transactions; they do not mutate state directly.

## Read Next

| Goal | Document |
|---|---|
| Learn the vocabulary | [Glossary](https://lattice.build/docs/learn/glossary/) |
| Understand process and ownership boundaries | [Architecture](docs/foundational-architecture.md) |
| Understand grind identity and GHOST | [Work and fork choice](docs/consensus-fork-choice.md) |
| Follow a parent-child value exchange | [Cross-chain transfer guide](docs/cross-chain.md) |
| Read exact consensus rules | [Protocol specification](docs/spec.md) |
| Run deterministic fork scenarios | [Consensus simulator](docs/consensus-simulator.md) |

## Scope And Limits

- Lattice has no explicit finality. A strictly heavier effective subtree may
  reorganize a chain at any depth.
- A child receives only path-bound, verified work covering that child. Parent
  canonicity and unproven parent hashpower are not inherited.
- Deeper hierarchies increase proof, availability, and process-coordination work;
  they do not require canonical confirmation at every ancestor level.
- More committed child data increases index and availability load, while a
  block itself commits the child index by one CID-bearing header.
- The library does not define peer transport, filesystem layout, storage budgets,
  or process topology.

## Project Structure

```text
Sources/
|- LatticePrimitives/  blocks, ChainSpec, transactions, actions, state, CIDs
|- LatticePoW/         proof-of-work preimage, work, ASERT schedule, WorkSum
|- LatticeValidation/  block, transaction, state-transition and spec validity, genesis
|- LatticeProofs/      ChildBlockProof and child validation packages
|- LatticeBlockTree/   block graph, fork choice, execution frontier, run attribution, ChainState
|- LatticeImport/      the import funnel, ChainLevel, transaction preflight
`- Lattice/            umbrella module that re-exports the six above
```

`import Lattice` brings in all six modules.

Important dependencies are
[`cashew`](https://github.com/adalinxx/cashew) for content-addressed structures,
[`swift-crypto`](https://github.com/apple/swift-crypto) for Ed25519 and SHA-256,
and [`WasmKit`](https://github.com/swiftwasm/WasmKit) for deterministic policy
execution.

## License

See [LICENSE](LICENSE).
