import Foundation
import XCTest
import UInt256
import LatticePrimitives
import LatticePoW
@testable import LatticeBlockTree

/// Seeded single-chain fork-choice traces for checking a formal model of
/// spec §9.1–9.4 and §9.9 step by step against the live `ChainTree`: each
/// trace records a random block tree, its validity verdicts, and every fact
/// applied with what the tree reported afterwards. Nothing here judges the
/// tree; it records what it did.
///
/// Set `LATTICE_TRACE_DIR` to write `trace-<seed>.json` for seeds
/// 1...`LATTICE_TRACE_COUNT` (default 20). Without it the traces are built
/// and sanity-checked only.
final class ForkChoiceTraceExportTests: XCTestCase {
    func testExportForkChoiceTraces() throws {
        let environment = ProcessInfo.processInfo.environment
        let count = environment["LATTICE_TRACE_COUNT"].flatMap(UInt64.init) ?? 20
        let directory = environment["LATTICE_TRACE_DIR"].map { URL(fileURLWithPath: $0) }
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for seed in 1...max(count, 1) {
            let trace = ForkChoiceTrace(seed: seed)
            trace.run()
            trace.checkSanity(self)
            if let directory {
                try trace.json().write(to: directory.appendingPathComponent("trace-\(seed).json"))
            }
        }
    }

    func testTraceIsDeterministic() throws {
        let first = ForkChoiceTrace(seed: 1), second = ForkChoiceTrace(seed: 1)
        first.run()
        second.run()
        XCTAssertEqual(try first.json(), try second.json())
    }
}

// MARK: - One seeded trace

private final class ForkChoiceTrace {
    let seed: UInt64
    var rng: SplitMix64
    let spec = oracleSpec(targetBlockTime: 1_000)

    /// Labels `b0`… in creation order; a parent always precedes its children.
    var labels: [String] = []
    var parent: [String: String] = [:]
    var valid: [String: Bool] = [:]
    var facts: [String: OracleBlockFact] = [:]
    var initialQuantity: [String: UInt64] = [:]
    var labelOfHash: [String: String] = [:]

    var subject: LiveSubject?
    var held: [String] = []
    var executed: Set<String> = []
    var excluded: Set<String> = []
    /// Root exclusions refused for want of another executed root: not
    /// attempted again until some root executes.
    var refusedRootExclusions: Set<String> = []
    var events: [[String: Any]] = []
    /// Refusals outside the two this generator expects; the test fails on any.
    var unexpectedRefusals: [String] = []

    init(seed: UInt64) {
        self.seed = seed
        rng = SplitMix64(seed: seed)
        let blockCount = Int.random(in: 5...8, using: &rng)
        let rootCount = Int.random(in: 1...2, using: &rng)
        for index in 0..<blockCount {
            let label = "b\(index)"
            let parentLabel = index < rootCount ? nil : labels.randomElement(using: &rng)
            let parentFact = parentLabel.flatMap { facts[$0] }
            let rootState = oracleCID("trace-\(seed)-state-0")
            let fact = OracleBlockFact(
                hash: oracleCID("trace-\(seed)-\(label)"), parent: parentFact?.hash,
                height: parentFact.map { $0.height + 1 } ?? 0,
                postState: parentFact == nil ? rootState : oracleCID("trace-\(seed)-post-\(label)"),
                prevState: parentFact?.postState ?? rootState, spec: specCID(spec),
                target: "ffff", nextTarget: "ffff",
                timestamp: (parentFact?.timestamp ?? 0) + 1_000, childCommitments: nil
            )
            labels.append(label)
            parent[label] = parentLabel
            valid[label] = Int.random(in: 0..<4, using: &rng) != 0
            facts[label] = fact
            initialQuantity[label] = UInt64.random(in: 1...3, using: &rng)
            labelOfHash[fact.hash] = label
        }
    }

    /// Block `bN`'s one grind, located at it.
    func grind(_ label: String) -> String { "g" + label.dropFirst() }
    func grindID(_ grindLabel: String) -> String { oracleCID("trace-\(seed)-\(grindLabel)") }
    func block(ofGrind grindLabel: String) -> String { "b" + grindLabel.dropFirst() }

    func isRoot(_ label: String) -> Bool { parent[label] == nil }
    func parentExecuted(_ label: String) -> Bool { parent[label].map(executed.contains) ?? true }

    // MARK: Actions

    enum Action {
        case admit(String), observe(String), validate(String), exclude(String)
    }

    var legalActions: [Action] {
        var actions: [Action] = []
        for label in labels {
            let isHeld = held.contains(label)
            if !isHeld, parent[label].map(held.contains) ?? true {
                actions.append(.admit(label))
            }
            guard isHeld else { continue }
            actions.append(.observe(label))
            if valid[label]!, !executed.contains(label), !excluded.contains(label), parentExecuted(label) {
                actions.append(.validate(label))
            }
            if !valid[label]!, !excluded.contains(label), parentExecuted(label),
               !refusedRootExclusions.contains(label) {
                actions.append(.exclude(label))
            }
        }
        return actions
    }

    func run() {
        for _ in 0..<40 {
            guard let action = legalActions.randomElement(using: &rng) else { return }
            perform(action)
        }
    }

    func perform(_ action: Action) {
        var event: [String: Any]
        switch action {
        case .admit(let label):
            let quantity = initialQuantity[label]!
            let batch = OracleBatch(facts: [
                .block(facts[label]!),
                .work(blockHash: facts[label]!.hash, grindID: grindID(grind(label)), work: UInt256(quantity)),
            ])
            let accepted: Bool
            if subject == nil {
                // A tree is restored from a log holding a genesis: the first
                // admission (always a root) is that log.
                switch LiveSubject.restoreRoot([batch], specs: [spec]) {
                case .success(let restored):
                    subject = restored
                case .failure(let failure):
                    unexpectedRefusals.append("admit \(label): \(failure.text)")
                }
                accepted = subject != nil
            } else {
                accepted = apply(batch)
            }
            if accepted { held.append(label) }
            event = ["kind": "admit", "block": label, "grind": grind(label), "qty": quantity, "accepted": accepted]
        case .observe(let label):
            // Mostly the block's own grind; one in five times, when there is
            // one, a grind already located at another held block.
            let elsewhere = held.filter { $0 != label }
            let grindLabel = !elsewhere.isEmpty && Int.random(in: 0..<5, using: &rng) == 0
                ? grind(elsewhere.randomElement(using: &rng)!)
                : grind(label)
            let quantity = UInt64.random(in: 1...4, using: &rng)
            let accepted = apply(OracleBatch(facts: [
                .work(blockHash: facts[label]!.hash, grindID: grindID(grindLabel), work: UInt256(quantity)),
            ]), mayRefuse: grindLabel != grind(label))
            event = ["kind": "observe", "block": label, "grind": grindLabel, "qty": quantity, "accepted": accepted]
        case .validate(let label):
            let accepted = apply(OracleBatch(facts: [.validation(facts[label]!.hash)]))
            if accepted {
                executed.insert(label)
                if isRoot(label) { refusedRootExclusions.removeAll() }
            }
            event = ["kind": "validate", "block": label, "accepted": accepted]
        case .exclude(let label):
            let standsOnAnotherRoot = executed.contains { isRoot($0) && $0 != label }
            let accepted = apply(
                OracleBatch(facts: [.exclusion(facts[label]!.hash)]),
                mayRefuse: isRoot(label) && !standsOnAnotherRoot
            )
            if accepted {
                excluded.insert(label)
            } else if isRoot(label) {
                refusedRootExclusions.insert(label)
            }
            event = ["kind": "exclude", "block": label, "accepted": accepted]
        }
        event["after"] = after()
        events.append(event)
    }

    /// Whether the tree took the batch. A throw is a refusal. A block or work
    /// batch must also return a result that added the block or contribution:
    /// nil is the tree discarding work no stronger than what it holds. A
    /// validation returns nil on success, and an exclusion returns nil only
    /// as a duplicate, which this generator never sends.
    ///
    /// `mayRefuse` marks the two refusals expected to throw
    /// `corruptConsensusGraph`: work for a grind located at another block,
    /// and excluding a root with no other executed root. Any other throw is
    /// recorded as unexpected.
    func apply(_ batch: OracleBatch, mayRefuse: Bool = false) -> Bool {
        let result: SubmissionResult?
        do {
            result = try subject!.tree.apply(LiveSubject.batch(batch))
        } catch ChainStateRestoreError.corruptConsensusGraph where mayRefuse {
            return false
        } catch {
            unexpectedRefusals.append("\(batch.facts): \(error)")
            return false
        }
        switch batch.facts.first {
        case .validation: return true
        case .exclusion: return result != nil
        default: return result.map { $0.addedBlock || $0.addedContribution } ?? false
        }
    }

    func after() -> [String: Any] {
        guard let tree = subject?.tree else {
            return [
                "canonicalTip": NSNull(), "validatedTip": NSNull(),
                "weights": [String: String](), "cumulative": [String: String](),
            ]
        }
        func label(_ hash: String) -> Any { hash.isEmpty ? NSNull() : labelOfHash[hash]! }
        // `weights` is what fork choice compares (`BlockGraph.preferred` reads
        // the same index): the block's whole subtree. `cumulative` is the
        // block plus its ancestors (spec §9.2 `cumulativeWork`).
        var weights: [String: String] = [:], cumulative: [String: String] = [:]
        for label in held {
            let hash = facts[label]!.hash
            weights[label] = tree.forkChoiceWeight(of: hash).map(decimal) ?? "nil"
            cumulative[label] = tree.getCumulativeWork(forHash: hash).map(decimal) ?? "nil"
        }
        return [
            "canonicalTip": label(tree.canonicalTip),
            "validatedTip": label(tree.heaviestExecutedTip()),
            "weights": weights,
            "cumulative": cumulative,
        ]
    }

    /// Ranks of the block CIDs under the tree's own tie-break, 0 preferred.
    var cidRanks: [String: Int] {
        let ordered = labels.sorted { forkChoicePrefersBlock(facts[$0]!.hash, over: facts[$1]!.hash) }
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, $0) })
    }

    func json() throws -> Data {
        let ranks = cidRanks
        let trace: [String: Any] = [
            "seed": seed,
            "blocks": labels.map { label -> [String: Any] in
                ["id": label, "parent": parent[label] ?? NSNull(), "cidRank": ranks[label]!]
            },
            "valid": valid,
            "events": events,
        ]
        return try JSONSerialization.data(withJSONObject: trace, options: [.sortedKeys])
    }

    func checkSanity(_ test: XCTestCase) {
        XCTAssertFalse(events.isEmpty, "seed \(seed)")
        XCTAssertEqual(unexpectedRefusals, [], "seed \(seed)")
        var admitted = false
        for event in events {
            let after = event["after"] as? [String: Any]
            if event["kind"] as? String == "admit", event["accepted"] as? Bool == true { admitted = true }
            if admitted {
                XCTAssertTrue(after?["canonicalTip"] is String, "seed \(seed): no canonical tip")
            }
            guard let weights = after?["weights"] as? [String: String],
                  let cumulative = after?["cumulative"] as? [String: String] else {
                return XCTFail("seed \(seed): no weights")
            }
            XCTAssertEqual(Set(weights.keys), Set(cumulative.keys), "seed \(seed)")
            for (label, weight) in weights.map({ $0 }) + cumulative.map({ $0 }) {
                guard let value = UInt64(weight) else { return XCTFail("seed \(seed) \(label): \(weight)") }
                XCTAssertGreaterThanOrEqual(value, initialQuantity[label]!, "seed \(seed) \(label)")
            }
        }
    }
}

/// Work as a decimal string. Trace work is a few small grinds, so it fits.
private func decimal(_ work: WorkSum) -> String {
    String(UInt64(hex(work.toHexString()), radix: 16)!)
}
