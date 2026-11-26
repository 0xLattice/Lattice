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
  <a href="https://lattice.build/docs/">Documentation</a> &bull;
  <a href="docs/foundational-architecture.md">Architecture</a> &bull;
  <a href="docs/consensus-fork-choice.md">Fork Choice</a> &bull;
  <a href="docs/spec.md">Protocol Specification</a>
</p>

---

## What Lattice Is

Lattice is a proof-of-work protocol in which one mined root can commit blocks
for many chains through a nested content-addressed DAG. Every chain has its
own state, rules, target, accepted forest, and fork choice.

This repository is the consensus library. It validates blocks and
transactions, verifies proofs of work, and chooses each chain's tip.
Networking, storage, durability, pruning, and RPC belong to node software such
as [`lattice-node`](https://github.com/0xLattice/lattice-node).

Three properties define the protocol:

- **One validator per chain.** A `ChainTree` value validates one absolute
  chain path, such as `Nexus/Payments`, and never another chain. The hierarchy
  is data, not a hierarchy of runtimes. A node hosts one `ChainTree` for each
  chain it follows.
- **Work is counted once.** A physical grind is identified by its root CID. It
  may prove coverage for any number of blocks or chain levels; its quantity is
  fixed by the root-most level whose target it beat (raised by the terminal's
  own target), and is counted once. Distinct grind identities sum.
- **Transfers without a bridge.** A demander authorizes a child transaction
  that locks value, a withdrawer pays the demander on the parent, and the child
  makes the locked value available to explicit child-chain credits only after
  proving both the deposit and the parent receipt. No trusted bridge is part
  of consensus.

The [architecture](docs/foundational-architecture.md#mental-model) develops
the mental model. Terms are defined in the
[glossary](https://lattice.build/docs/learn/glossary/).

## Quickstart

### Requirements

- Swift 6.0+
- macOS 15+

### Build And Test

```bash
swift build
swift test
```

### Use As A Dependency

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/0xLattice/Lattice.git", branch: "main")
]
```

## Using The Library

`import Lattice` brings in all six modules:

| Module | Contents |
|---|---|
| `LatticePrimitives` | Blocks, `ChainSpec`, transactions, actions, state, CIDs |
| `LatticePoW` | Proof-of-work preimage and midstate, work, the ASERT target schedule, `WorkSum` |
| `LatticeValidation` | Block, transaction, state-transition and spec validity; genesis |
| `LatticeProofs` | `ChildBlockProof` and verified child evidence |
| `LatticeBlockTree` | `ChainTree`: block graph, fork choice, execution frontier, run attribution |
| `LatticeImport` | `ChainTree` admission (weigh, connect) |

One `ChainTree` value is one chain: its absolute chain path, its accepted
forest, and its canonical projection. A caller admits a block in two steps,
weigh then execute, and persists the facts each step returns. The steps, the
functions that implement them, and recovery are described in
[Architecture: import and recovery](docs/foundational-architecture.md#import-and-recovery).

Other parts of the package:

| Part | Use |
|---|---|
| `Tools/` (`swift run LatticeSim`) | The [consensus simulator](docs/consensus-simulator.md). Not a product. |
| `DeterminismGoldens`, `lattice-determinism-check` | Pin results byte-for-byte across macOS and Linux |
| `Vectors/` | [Conformance vectors](Vectors/README.md) for SDKs in other languages |

## Documentation

The documents are published at
[lattice.build/docs](https://lattice.build/docs/).

| Goal | Document |
|---|---|
| Learn the vocabulary | [Glossary](https://lattice.build/docs/learn/glossary/) |
| Find a document by its role | [Documentation index](docs/index.md) |
| Understand the model and who owns what | [Architecture](docs/foundational-architecture.md) |
| Understand grind identity and GHOST | [Work and fork choice](docs/consensus-fork-choice.md) |
| Follow a parent-child value exchange | [Cross-chain transfer guide](docs/cross-chain.md) |
| Read exact consensus rules | [Protocol specification](docs/spec.md) |
| Check an SDK against the library | [Conformance vectors](Vectors/README.md) |
| Run deterministic fork scenarios | [Consensus simulator](docs/consensus-simulator.md) |
| Understand why it is shaped this way | [Design philosophy](docs/philosophy.md) |

## Scope And Limits

- Lattice has no explicit finality. A strictly heavier effective subtree may
  reorganize a chain at any depth.
- A child receives only path-bound, verified work covering that child. Parent
  canonicity and unproven parent hashpower are not inherited.
- Deeper hierarchies increase proof and availability work; they do not require
  canonical confirmation at every ancestor level.
- More committed child data increases index and availability load, while a
  block itself commits the child index by one CID-bearing header.
- The library does not define peer transport, filesystem layout, storage
  budgets, or how a node hosts its chains.

## Dependencies

- [`cashew`](https://github.com/0xLattice/cashew) for content-addressed
  structures
- [`swift-crypto`](https://github.com/apple/swift-crypto) for Ed25519 and
  SHA-256
- [`WasmKit`](https://github.com/swiftwasm/WasmKit) for deterministic policy
  execution

## License

See [LICENSE](LICENSE).
