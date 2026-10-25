import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
@testable import LatticeSimulation
import UInt256

final class ConsensusSimulatorTests: XCTestCase {
    /// The seed-42 adversarial report, computed once per test process and
    /// shared by the tests that only read it (each run takes minutes in debug).
    private static let sharedAdversarialReportSeed42 = Task {
        await LatticeConsensusSimulator.runAdversarialReport(seed: 42)
    }

    private static func adversarialReportSeed42() async -> AdversarialReport {
        await sharedAdversarialReportSeed42.value
    }

    func testDefaultSimulatorTraceIsDeterministicForSeed() async throws {
        let first = await LatticeConsensusSimulator.runDefaultScenarios(seed: 42)
        let second = await LatticeConsensusSimulator.runDefaultScenarios(seed: 42)

        XCTAssertEqual(first, second)
        let firstJSON = try LatticeConsensusSimulator.encodeJSON(first)
        let secondJSON = try LatticeConsensusSimulator.encodeJSON(second)
        XCTAssertEqual(firstJSON, secondJSON)
    }

    func testSimulatorUsesCurrentProtocolScenarios() async throws {
        let traces = await LatticeConsensusSimulator.runDefaultScenarios(seed: 42)
        XCTAssertEqual(Set(traces.map(\.scenario)), [
            "equal-work-tie-stable-base",
            "seeded-withhold-release",
            "asert-schedule-one-hour",
        ])
        let tie = try XCTUnwrap(traces.first { $0.scenario == "equal-work-tie-stable-base" })
        XCTAssertEqual(tie.events.map(\.reorged), [true])
    }

    func testSimulatorPinsHandCheckedForkChoiceFixtures() async throws {
        let traces = await LatticeConsensusSimulator.runDefaultScenarios(seed: 42)
        let byScenario = Dictionary(uniqueKeysWithValues: traces.map { ($0.scenario, $0) })

        let tie = try XCTUnwrap(byScenario["equal-work-tie-stable-base"])
        XCTAssertEqual(tie.finalTip, "F1")
        XCTAssertEqual(tie.events.first?.reorged, true)
        XCTAssertEqual(tie.events.first?.candidateSubtreeWork, "0000000000000000000000000000000000000000000000000000000000000001")
        XCTAssertEqual(tie.events.first?.mainSubtreeWork, "0000000000000000000000000000000000000000000000000000000000000001")

        let withheld = try XCTUnwrap(byScenario["seeded-withhold-release"])
        XCTAssertEqual(withheld.events.map(\.candidateTip), ["F1", "F2", "F3"])
        XCTAssertEqual(withheld.events.map(\.tip), ["M2", "F2", "F3"])
        XCTAssertEqual(withheld.events.map(\.reorged), [false, true, true])

        let retarget = try XCTUnwrap(byScenario["asert-schedule-one-hour"])
        XCTAssertTrue(retarget.events.first?.label.contains("target=3600000ms") ?? false)
        XCTAssertTrue(retarget.events.first?.label.contains("onTarget=00000000000000000000000000000000000000000000000000000000000003e8") ?? false)
        XCTAssertTrue(retarget.events.first?.label.contains("slow=00000000000000000000000000000000000000000000000000000000000007d0") ?? false)
    }

    func testSeededWithholdReleaseTraceIsStableAndConvergesToHeavierFork() async throws {
        let traces = await LatticeConsensusSimulator.runDefaultScenarios(seed: 0x1234)
        let withheld = try XCTUnwrap(traces.first { $0.scenario == "seeded-withhold-release" })

        XCTAssertEqual(withheld.finalTip, "F3")
        XCTAssertEqual(withheld.events.count, 3)
        XCTAssertTrue(withheld.finalMainChain.contains("F1"))
        XCTAssertTrue(withheld.finalMainChain.contains("F2"))
        XCTAssertTrue(withheld.finalMainChain.contains("F3"))
    }

    // MARK: — no-finality adversarial scenarios

    func testAdversarialReportIsDeterministicForSeed() async throws {
        // One side is the shared run, the other is computed fresh here, so
        // this still compares two independent runs of seed 42.
        let first = await Self.adversarialReportSeed42()
        let second = await LatticeConsensusSimulator.runAdversarialReport(seed: 42)
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            try LatticeConsensusSimulator.encodeAdversarialJSON(first),
            try LatticeConsensusSimulator.encodeAdversarialJSON(second)
        )
    }

    /// The committed `docs/consensus/adversarial-report.{md,json}` artifacts must
    /// be byte-for-byte reproducible from `--seed 42`. Regenerate the report in-memory and
    /// byte-compare both committed files so a drift between the code and the checked-in
    /// report (or a regeneration with a different seed) fails CI.
    func testCommittedReportIsByteReproducibleFromSeed42() async throws {
        // Repo root is three directories up from this source file
        // (Tests/LatticeTests/ConsensusSimulatorTests.swift).
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let docsDir = repoRoot.appendingPathComponent("docs/consensus")
        let committedJSON = try Data(contentsOf: docsDir.appendingPathComponent("adversarial-report.json"))
        let committedMD = try Data(contentsOf: docsDir.appendingPathComponent("adversarial-report.md"))

        let report = await Self.adversarialReportSeed42()
        let regeneratedJSON = try LatticeConsensusSimulator.encodeAdversarialJSON(report)
        let regeneratedMD = Data(LatticeConsensusSimulator.renderAdversarialMarkdown(report).utf8)

        XCTAssertEqual(regeneratedJSON, committedJSON,
            "docs/consensus/adversarial-report.json is out of date; regenerate with `swift run LatticeSim --seed 42`")
        XCTAssertEqual(regeneratedMD, committedMD,
            "docs/consensus/adversarial-report.md is out of date; regenerate with `swift run LatticeSim --seed 42`")
    }

    func testDeepReorgProbabilityGrowsWithHashrateAndIsNegligibleBelowMajority() async throws {
        let report = await Self.adversarialReportSeed42()
        let deep = report.deepReorg.sorted { $0.hashrateFraction < $1.hashrateFraction }

        // Monotone non-decreasing in f everywhere: more hashrate never reduces achievable
        // reorg depth.
        for (lo, hi) in zip(deep, deep.dropFirst()) {
            XCTAssertLessThanOrEqual(lo.reorgProbability, hi.reorgProbability,
                "reorg probability must not drop as f rises (\(lo.hashrateFraction) -> \(hi.hashrateFraction))")
            XCTAssertLessThanOrEqual(lo.meanReorgDepth, hi.meanReorgDepth,
                "mean reorg depth must not drop as f rises (\(lo.hashrateFraction) -> \(hi.hashrateFraction))")
        }

        // In the active region (f >= 0.4, where deep reorgs are no longer trial-noise) the
        // signal must grow STRICTLY with f — equal plateaus are only acceptable below this
        // band, where a finite trial count (200) cannot distinguish two near-zero
        // probabilities (e.g. 0.30 and 0.33 both round to a single observed reorg).
        let active = deep.filter { $0.hashrateFraction >= 0.4 }
        XCTAssertGreaterThanOrEqual(active.count, 3, "need several samples in the active region")
        for (lo, hi) in zip(active, active.dropFirst()) {
            XCTAssertLessThan(lo.reorgProbability, hi.reorgProbability,
                "reorg probability must strictly increase with f in the active region (\(lo.hashrateFraction) -> \(hi.hashrateFraction))")
            XCTAssertLessThan(lo.meanReorgDepth, hi.meanReorgDepth,
                "mean reorg depth must strictly increase with f in the active region (\(lo.hashrateFraction) -> \(hi.hashrateFraction))")
        }

        // Well below majority, deep reorgs are rare; at/above majority they dominate.
        let lowF = try XCTUnwrap(deep.first { $0.hashrateFraction == 0.25 })
        XCTAssertLessThan(lowF.reorgProbability, 0.05)
        let highF = try XCTUnwrap(deep.first { $0.hashrateFraction == 0.6 })
        XCTAssertGreaterThan(highF.reorgProbability, 0.5)
    }

    /// Equal targets fall through to independent block hashes, so either miner wins half the
    /// matched ties: γ = 1/2 and the Eyal–Sirer threshold is exactly f = 1/4.
    func testSelfishMiningThresholdIsExactlyOneQuarterForGammaHalf() async throws {
        let report = await Self.adversarialReportSeed42()

        let measuredGamma = await LatticeConsensusSimulator.measuredTieAdoptionGamma(seed: 42, fraction: 0.3)
        XCTAssertEqual(measuredGamma, 0.5, "stable independent hashes imply γ = 1/2")
        let threshold = 0.25

        for p in report.selfishMining {
            let expected = LatticeConsensusSimulator.eyalSirerRevenueShare(fraction: p.hashrateFraction, gamma: 0.5)
            XCTAssertEqual(p.attackerRevenueShare, expected, accuracy: 1e-9,
                "selfish revenue must be the closed-form Eyal–Sirer value at f=\(p.hashrateFraction)")
            if p.hashrateFraction < threshold {
                XCTAssertLessThan(p.relativeGain, 0,
                    "selfish gain must be negative below the 1/4 threshold at f=\(p.hashrateFraction)")
            } else if p.hashrateFraction > threshold {
                XCTAssertGreaterThan(p.relativeGain, 0,
                    "selfish gain must be positive above the 1/4 threshold at f=\(p.hashrateFraction)")
            }
        }

        let belowGain = LatticeConsensusSimulator.eyalSirerRevenueShare(fraction: threshold - 1e-4, gamma: 0.5) - (threshold - 1e-4)
        let atGain = LatticeConsensusSimulator.eyalSirerRevenueShare(fraction: threshold, gamma: 0.5) - threshold
        let aboveGain = LatticeConsensusSimulator.eyalSirerRevenueShare(fraction: threshold + 1e-4, gamma: 0.5) - (threshold + 1e-4)
        XCTAssertLessThan(belowGain, 0, "gain must be negative just below f = 1/4")
        XCTAssertEqual(atGain, 0, accuracy: 1e-9, "gain must be zero at exactly f = 1/4")
        XCTAssertGreaterThan(aboveGain, 0, "gain must be positive just above f = 1/4")

        // Revenue share is monotone non-decreasing in f.
        let sorted = report.selfishMining.sorted { $0.hashrateFraction < $1.hashrateFraction }
        for (lo, hi) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThanOrEqual(lo.attackerRevenueShare, hi.attackerRevenueShare)
        }
    }

    func testBalancingSurvivalIsNegligibleAcrossSampledHorizon() async throws {
        let report = await Self.adversarialReportSeed42()
        for p in report.balancing {
            // At horizon 64, f^64 is negligible throughout the sampled range.
            XCTAssertEqual(p.survivalProbability, 0,
                "balancing should not survive the sampled horizon at f=\(p.hashrateFraction)")
            // And the cost (attacker blocks burned) is bounded by the stall it bought.
            XCTAssertLessThanOrEqual(p.meanAttackerBlocksSpent, p.meanStallRounds + 1e-9)
        }
    }

    /// The cost of stalling convergence must grow with the attacker's work: a higher `f`
    /// lets the attacker win more re-balancing PoW races, so it both sustains a longer
    /// stall and burns strictly more of its own blocks doing it. Assert both the per-step
    /// monotonicity of cost in `f` and an end-to-end strict growth across the curve so the
    /// scenario measures cost-as-a-function-of-`f`, not just feasibility.
    func testBalancingCostGrowsWithAttackerWork() async throws {
        let report = await Self.adversarialReportSeed42()
        let sorted = report.balancing.sorted { $0.hashrateFraction < $1.hashrateFraction }
        XCTAssertGreaterThanOrEqual(sorted.count, 3, "need several balancing points to test cost growth")

        // Monotone non-decreasing in f everywhere: more attacker work never lowers the
        // blocks it must spend (nor the stall it can buy) to keep the branches tied.
        for (lo, hi) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThanOrEqual(lo.meanAttackerBlocksSpent, hi.meanAttackerBlocksSpent,
                "attacker cost must not drop as f rises (\(lo.hashrateFraction) -> \(hi.hashrateFraction))")
            XCTAssertLessThanOrEqual(lo.meanStallRounds, hi.meanStallRounds,
                "stall length must not drop as f rises (\(lo.hashrateFraction) -> \(hi.hashrateFraction))")
        }

        // End-to-end the cost must grow STRICTLY: the lowest-f attacker spends materially
        // fewer blocks than the highest-f one (cost is a real, increasing function of f,
        // not a constant).
        let lowest = try XCTUnwrap(sorted.first)
        let highest = try XCTUnwrap(sorted.last)
        XCTAssertLessThan(lowest.meanAttackerBlocksSpent, highest.meanAttackerBlocksSpent,
            "attacker cost must strictly increase from f=\(lowest.hashrateFraction) to f=\(highest.hashrateFraction)")
    }

    func testAdversarialMarkdownRendersAllThreeScenarios() async throws {
        let report = await Self.adversarialReportSeed42()
        let md = LatticeConsensusSimulator.renderAdversarialMarkdown(report)
        XCTAssertTrue(md.contains("(a) Deep reorg"))
        XCTAssertTrue(md.contains("(b) Selfish mining"))
        XCTAssertTrue(md.contains("(c) Balancing attack"))
        XCTAssertTrue(md.contains("## Security-budget thresholds"))
    }

    func testDiscreteEventScenarioHonorsConfiguredTopologyLatencyAndWork() async throws {
        let spec = ConsensusSimScenarioSpec(
            scenario: "configured-work-latency",
            seed: 7,
            blocks: [
                ConsensusSimBlockSpec(hash: "G", height: 0),
                ConsensusSimBlockSpec(hash: "M1", parent: "G", height: 1),
                ConsensusSimBlockSpec(hash: "F1", parent: "G", height: 1, work: UInt256(3))
            ],
            initiallyVisible: ["G", "M1"],
            initialMain: ["G", "M1"],
            releases: [ConsensusSimRelease(atMillis: 250, blockHash: "F1")]
        )

        let trace = await LatticeConsensusSimulator.runDiscreteEventScenario(spec)

        XCTAssertEqual(trace.scenario, "configured-work-latency")
        XCTAssertEqual(trace.finalTip, "F1")
        XCTAssertEqual(trace.events.first?.label, "t=250ms release F1")
        XCTAssertEqual(trace.events.first?.candidateSubtreeWork, "0000000000000000000000000000000000000000000000000000000000000003")
        XCTAssertEqual(trace.events.first?.reorged, true)
    }
}
