# Consensus Simulator

`LatticeSim` is the deterministic simulator harness for the implemented
Hierarchical-GHOST fork-choice path in `docs/consensus-fork-choice.md`.

Run it from a clean checkout:

```bash
swift run LatticeSim --seed 42
```

The output is sorted JSON. The same seed must produce the same trace byte-for-byte.
The three default scenarios pin the chain-local edges in the current library:

- equal subtree work chooses by canonical same-chain child block CID bytes only;
- a seeded withhold/release schedule converges to the heavier GHOST subtree;
- the 1h absolute schedule uses `ChainSpec.calculateAsertTarget` from a
  height-1 anchor, on time and running slow.

For custom fixtures, `LatticeConsensusSimulator.runDiscreteEventScenario(_:)`
accepts a `ConsensusSimScenarioSpec` with block topology, release times
(`atMillis`), and per-block work weights. The harness turns those inputs into
`BlockMeta` fixtures and still evaluates them through `ChainTree`.

The simulator does not implement a second fork-choice rule. It constructs
`BlockMeta` fixtures and records `ChainTree.forkChoiceSnapshot(startingAt:)`,
which wraps the library's real same-chain GHOST decision. Cross-chain proof and
contribution derivation are tested at import rather than simulated by a live
parent-weight provider.

## Adversarial model

The same run regenerates the checked-in adversarial report
(`docs/consensus/adversarial-report.md` and its `.json`), and
`ConsensusSimulatorTests` fails if the committed files differ from what the
seed produces. Every scenario drives the real chain-local `ChainTree` fork
choice: greatest true cumulative work first, then the smaller canonical CID of
the competing child blocks. Parent canonicity and sibling state are not inputs.
With seed 42 it establishes three results, as a function of the attacker's
share `f` of this chain's root-grind contributions:

- **Deep reorganization.** Racing a 24-block honest segment over 200 seeded
  trials, the attacker's reorganization probability is 0% up to `f` = 30%,
  0.5% at 33%, 7% at 40%, 41.5% at 50%, and 89% at 60%. Deep reorganizations
  become likely only as `f` approaches and exceeds a majority.
- **Selfish mining.** Driving the matched-tie race through the real fork
  choice measures a tie-break advantage of γ = 1/2: with equal targets and
  independent hashes, either miner's block wins half the ties. At that γ the
  Eyal–Sirer revenue share equals `f` at exactly `f` = 1/4. Above it selfish
  mining is profitable.
- **Balancing.** Sustaining two equal-work branches requires winning every
  re-balancing race, so full-horizon survival scales as `f^horizon`. Over a
  64-round horizon no tested `f` survives. This is a cost curve, not a
  separate threshold.

The deterministic tie-break therefore costs no weight, since any strictly
heavier branch still wins, but it sets the selfish-mining threshold at 1/4.
Security-budget analysis must price the lower, economic threshold rather than
the majority point, and must state which attack it prices.
