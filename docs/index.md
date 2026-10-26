# Lattice Documentation

These documents are read at [lattice.build/docs](https://lattice.build/docs/), which
publishes them at the version `lattice-node` pins. Edit them here.

Lattice has two shapes that must not be confused:

- one mined root commits a nested, content-addressed tree of chain candidates;
- one Lattice process validates and chooses a tip for exactly one chain path.

The node runs those processes, moves authenticated evidence between them, and
decides what content to acquire and retain.

## Start Here

1. [README](../README.md) - build the library and learn the model in one minute.
2. [Architecture](foundational-architecture.md) - process boundaries, ownership,
   import, recovery, and pruning.
3. [Work and fork choice](consensus-fork-choice.md) - how verified grinds become
   chain-local weight.
4. [Cross-chain transfers](cross-chain.md) - a worked parent-child exchange.
5. [Protocol specification](spec.md) - exact consensus rules.

Read [Philosophy](philosophy.md) for motivation and tradeoffs, not protocol
definitions.

## Document Roles

| Document | Role |
|---|---|
| [Protocol specification](spec.md) | Normative consensus definition |
| [Architecture](foundational-architecture.md) | Runtime and component boundaries |
| [Work and fork choice](consensus-fork-choice.md) | Intuitive consensus rationale |
| [Cross-chain transfers](cross-chain.md) | Non-normative transfer walkthrough |
| [Philosophy](philosophy.md) | Motivation, design choices, and limits |
| `Sources/` and `Tests/` | Implementation and executable conformance evidence |

A disagreement between these layers is a defect to resolve, not wording to
paper over.

## Mental Model

A recursive content DAG supplies sparse evidence to independent chain-local
forests, each owned by one node-supervised process. The
[architecture guide](foundational-architecture.md) develops those three
structures and their ownership boundaries.

## Vocabulary

Terms are defined in the [glossary](https://lattice.build/docs/learn/glossary/).

## Reference

- [Consensus simulator](consensus-simulator.md)
- [Nexus tokenomics](economics/nexus-tokenomics.md)
- [Fee policy and majority-reorg model](economics/fee-market-and-51pct.md)
- [Merged-mining security of a child chain](economics/merged-mining-security.md)
