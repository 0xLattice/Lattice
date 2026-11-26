# Consensus Simulator

`LatticeSim` runs deterministic fork scenarios through the library's real
fork choice. Use it to reproduce a trace, to try a fork topology of your own,
or to regenerate the adversarial security report. The model it exercises is
explained in [work and fork choice](consensus-fork-choice.md).

## Run It

From a clean checkout:

```bash
swift run LatticeSim --seed 42
```

This does two things:

1. Prints the traces of the default scenarios to standard output as sorted
   JSON. The same seed must produce the same trace byte-for-byte.
2. Rewrites `docs/consensus/adversarial-report.md` and
   `docs/consensus/adversarial-report.json`.

| Option | Effect |
|---|---|
| `--seed <n>` | The seed, in decimal or `0x` hex. Without it the simulator's default seed is used. |
| `--adversarial` | Runs only the adversarial report and prints it as Markdown to standard output, or writes both report files to the `--out` directory when one is given. |
| `--out <dir>` | The directory the report files are written to. The default is `docs/consensus`. |

## Default Scenarios

The three default scenarios pin the chain-local edges in the current library:

- equal subtree work chooses by canonical same-chain child block CID bytes only;
- a seeded withhold/release schedule converges to the heavier GHOST subtree;
- the 1h absolute schedule uses `ChainSpec.calculateAsertTarget` from a
  height-1 anchor, on time and running slow.

## Run Your Own Scenario

`LatticeConsensusSimulator.runDiscreteEventScenario(_:)` accepts a
`ConsensusSimScenarioSpec` with:

- the block topology;
- release times (`atMillis`);
- per-block work weights.

The harness turns those inputs into `BlockMeta` fixtures and evaluates them
through `ChainTree`.

## What It Does And Does Not Model

The simulator does not implement a second fork-choice rule. It constructs
`BlockMeta` fixtures and records `ChainTree.forkChoiceSnapshot(startingAt:)`,
which wraps the library's real same-chain GHOST decision.

Cross-chain proof and contribution derivation are tested at import. They are
not simulated by a live parent-weight provider.

## Adversarial model

The simulator also runs three adversarial scenarios against the real
chain-local `ChainTree` fork choice, as a function of the attacker's share `f`
of this chain's root-grind contributions:

| Scenario | Question |
|---|---|
| Deep reorganization | How likely is an attacker to out-work a 24-block honest segment? |
| Selfish mining | At what `f` does withholding blocks earn more than a fair share, given the tie-break advantage the fork choice measures? |
| Balancing | How long can an attacker keep two equal-work branches alive? |

The results, and the thresholds a security budget must price, are in the
[adversarial security report](consensus/adversarial-report.md). That report is
generated: do not edit it by hand.

To regenerate it, run `swift run LatticeSim --seed 42` and commit both files.
`ConsensusSimulatorTests` fails if the committed files differ from what seed
42 produces.
