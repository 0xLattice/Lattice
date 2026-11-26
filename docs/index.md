# Lattice Library Documentation

The documents of the Lattice consensus library, by what each one is for. They
are published at [lattice.build/docs](https://lattice.build/docs/) at the
version `lattice-node` pins. Edit them here.

## Start Here

1. [README](../README.md): what the library is and how to build and use it.
2. [Architecture](foundational-architecture.md): the mental model, what one
   chain's validator owns, and what the node owns.
3. [Work and fork choice](consensus-fork-choice.md): how verified grinds
   become chain-local weight.
4. [Cross-chain transfers](cross-chain.md): a worked parent-child exchange.
5. [Protocol specification](spec.md): the exact consensus rules.

Terms are defined in the
[glossary](https://lattice.build/docs/learn/glossary/).

## Document Roles

| Document | Kind | Role |
|---|---|---|
| [Protocol specification](spec.md) | Reference | Normative consensus definition |
| [Conformance vectors](../Vectors/README.md) | Reference | Test vectors for SDKs in other languages |
| [Architecture](foundational-architecture.md) | Explanation | Validator and component boundaries |
| [Work and fork choice](consensus-fork-choice.md) | Explanation | How work is counted and a tip is chosen |
| [Cross-chain transfers](cross-chain.md) | Explanation | A transfer, step by step |
| [Philosophy](philosophy.md) | Explanation | Motivation, design choices, and limits |
| [Consensus simulator](consensus-simulator.md) | Guide | Running deterministic fork scenarios |
| [Adversarial security report](consensus/adversarial-report.md) | Record | Generated results of the adversarial scenarios |
| [Nexus tokenomics](economics/nexus-tokenomics.md) | Reference | Configured Nexus parameters, emission and supply |
| [Fee policy and majority-reorg cost](economics/fee-market-and-51pct.md) | Explanation | What consensus enforces about fees; a reorg cost model |
| [Merged-mining security of a child chain](economics/merged-mining-security.md) | Explanation | What it costs to attack a merged-mined child |
| [Review contract](review-contract.md) | Reference | Properties a change to the library must keep |
| `Sources/` and `Tests/` | | Implementation and executable conformance evidence |

Only the specification is normative. A disagreement between it, the other
documents and the code is a defect to resolve, not wording to paper over.
