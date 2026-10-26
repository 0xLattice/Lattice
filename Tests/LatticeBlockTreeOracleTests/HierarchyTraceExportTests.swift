import Foundation
import cashew
import XCTest
import UInt256
import LatticePrimitives
import LatticePoW
@testable import LatticeBlockTree
@testable import LatticeImport

/// Seeded two-level (parent + child chain) fork-choice traces for checking a
/// formal model of spec §5.1 rule 4, §5.3, §9.9 and §9.10 step by step
/// against the live `ChainTree`s: each trace records a random parent tree, a
/// random child tree, which parent block commits which child block, each
/// child block's parent anchor, the validity verdicts, and every fact applied
/// with what both trees reported afterwards. Nothing here judges the trees;
/// it records what they did.
///
/// A child block's continuity is decided by the connect path's own
/// `BlockImport.validateParentFacts` against `ParentLevelFacts` of the live
/// parent tree. After every apply on either tree, attributed runs are
/// re-derived as the node does (`applyParentRun`, scoped by what the apply
/// weighed).
///
/// Set `LATTICE_TRACE_DIR` to write `trace-<seed>.json` for seeds
/// 1...`LATTICE_TRACE_COUNT` (default 20). Without it the traces are built
/// and sanity-checked only.
final class HierarchyTraceExportTests: XCTestCase {
    func testExportHierarchyTraces() async throws {
        let environment = ProcessInfo.processInfo.environment
        let count = environment["LATTICE_TRACE_COUNT"].flatMap(UInt64.init) ?? 20
        let directory = environment["LATTICE_TRACE_DIR"].map { URL(fileURLWithPath: $0) }
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Over the whole seed set: traces showing each continuity outcome,
        // continuity decisions taken at validation, and attributed credits.
        var tracesShowing: [String: Int] = [:]
        var decisions: [String: Int] = [:]
        var credits = 0
        for seed in 1...max(count, 1) {
            let trace = HierarchyTrace(seed: seed)
            await trace.run()
            trace.checkSanity()
            for outcome in trace.continuityOutcomesSeen { tracesShowing[outcome, default: 0] += 1 }
            decisions.merge(trace.decisions, uniquingKeysWith: +)
            credits += trace.attributedCredits
            if let directory {
                try trace.json().write(to: directory.appendingPathComponent("trace-\(seed).json"))
            }
        }
        print("hierarchy traces: traces showing \(tracesShowing.sorted { $0.key < $1.key }),"
              + " validate decisions \(decisions.sorted { $0.key < $1.key }),"
              + " attributed credits > 0: \(credits)")
        for outcome in ["proven", "held", "invalid"] {
            XCTAssertGreaterThan(tracesShowing[outcome] ?? 0, 0, "no trace shows continuity \(outcome)")
        }
        XCTAssertGreaterThan(credits, 0, "no trace credits an attributed run")
    }

    func testTraceIsDeterministic() async throws {
        let first = HierarchyTrace(seed: 1), second = HierarchyTrace(seed: 1)
        await first.run()
        await second.run()
        XCTAssertEqual(try first.json(), try second.json())
    }
}

// MARK: - One seeded trace

private enum Level: String { case P, C }

private final class HierarchyTrace {
    let seed: UInt64
    var rng: SplitMix64
    let spec = oracleSpec(targetBlockTime: 1_000)
    let childContext = try! ChainRuntimeContext(path: [DEFAULT_ROOT_DIRECTORY, childDirectory])
    let empty = LatticeState.emptyHeader.rawCID

    /// Labels `p0`… and `c0`… in creation order; a parent always precedes
    /// its children. `p0` is the parent chain's one genesis.
    var labels: [Level: [String]] = [.P: [], .C: []]
    var parent: [String: String] = [:]
    var valid: [String: Bool] = [:]
    var facts: [String: OracleBlockFact] = [:]
    var labelOfHash: [String: String] = [:]
    /// `<<p, c>>`: parent block `p` commits child block `c` into the child
    /// directory. Each child block has at most one committer.
    var commits: [(p: String, c: String)] = []
    var committer: [String: String] = [:]
    /// The parent block whose post-state is the child block's `parentState`;
    /// absent for `emptyHeader`.
    var anchor: [String: String] = [:]
    var parentState: [String: String] = [:]
    /// A child block never delivered (so never admitted).
    var withheld: Set<String> = []
    /// Each block's first grind, by label: `g_<block>`, or for a merged
    /// child block its committer's `g_<p>`.
    var firstGrind: [String: String] = [:]
    var initialQuantity: [String: UInt64] = [:]

    var parentTree: ChainTree?
    var childTree: ChainTree?
    var held: [Level: [String]] = [.P: [], .C: []]
    var executed: Set<String> = []
    var excluded: Set<String> = []
    /// Root exclusions refused for want of another executed root on that
    /// chain: not attempted again until some root there executes.
    var refusedRootExclusions: [Level: Set<String>] = [.P: [], .C: []]
    var events: [[String: Any]] = []
    /// Refusals outside the two this generator expects; the test fails on any.
    var unexpectedRefusals: [String] = []
    /// Continuity outcomes decided at child validation, by outcome.
    var decisions: [String: Int] = [:]
    var continuityOutcomesSeen: Set<String> = []
    /// Commits whose attributed run is credited above zero at the end.
    var attributedCredits = 0

    func level(_ label: String) -> Level { label.hasPrefix("p") ? .P : .C }
    func hash(_ label: String) -> String { oracleCID("hierarchy-\(seed)-\(label)") }
    func grindID(_ grindLabel: String) -> String { oracleCID("hierarchy-\(seed)-\(grindLabel)") }
    func isRoot(_ label: String) -> Bool { parent[label] == nil }
    func parentExecuted(_ label: String) -> Bool { parent[label].map(executed.contains) ?? true }
    func chance(_ numerator: Int, in denominator: Int) -> Bool {
        Int.random(in: 0..<denominator, using: &rng) < numerator
    }

    init(seed: UInt64) {
        self.seed = seed
        rng = SplitMix64(seed: seed)
        // Shapes: one parent genesis; one or two child geneses.
        let parentCount = Int.random(in: 5...8, using: &rng)
        for index in 0..<parentCount {
            let label = "p\(index)"
            parent[label] = index == 0 ? nil : labels[.P]!.randomElement(using: &rng)
            // The parent genesis is valid, so the child has something to anchor on.
            valid[label] = index == 0 || !chance(1, in: 6)
            labels[.P]!.append(label)
        }
        let childCount = Int.random(in: 5...8, using: &rng)
        let childRoots = Int.random(in: 1...2, using: &rng)
        for index in 0..<childCount {
            let label = "c\(index)"
            parent[label] = index < childRoots ? nil : labels[.C]!.randomElement(using: &rng)
            valid[label] = !chance(1, in: 6)
            labels[.C]!.append(label)
        }
        if chance(1, in: 2) {
            let parents = Set(parent.values)
            let leaves = labels[.C]!.filter { !isRoot($0) && !parents.contains($0) }
            if let leaf = leaves.randomElement(using: &rng) { withheld.insert(leaf) }
        }

        // Commits first: a committed child block's anchor is its carrier's
        // prevState (§5.3 step 3), the post-state of the carrier's parent.
        // The parent genesis's prevState is empty, so it commits only a
        // second child genesis, which is then anchored at empty (invalid,
        // §5.1 rule 4).
        var uncommitted = labels[.C]!
        for p in labels[.P]! {
            let pool = p == "p0" ? uncommitted.filter { isRoot($0) && $0 != "c0" } : uncommitted
            guard chance(1, in: p == "p0" ? 3 : 2), let c = pool.randomElement(using: &rng) else { continue }
            commits.append((p, c))
            committer[c] = p
            uncommitted.removeAll { $0 == c }
        }

        // Parent facts: every parent block a unique post-state, so an anchor
        // names exactly one parent block.
        for (index, label) in labels[.P]!.enumerated() {
            let parentFact = parent[label].flatMap { facts[$0] }
            let committed = commits.first { $0.p == label }?.c
            addFact(label, OracleBlockFact(
                hash: hash(label), parent: parentFact?.hash,
                height: parentFact.map { $0.height + 1 } ?? 0,
                postState: oracleCID("hierarchy-\(seed)-post-\(label)"),
                prevState: parentFact?.postState ?? empty, spec: specCID(spec),
                target: "ffff", nextTarget: "ffff",
                timestamp: Int64(index + 1) * 1_000,
                childCommitments: committed.map { [childDirectory: hash($0)] }
            ))
        }

        // Anchors: derived for committed child blocks; otherwise random, so
        // all three continuity outcomes occur — forward (proven), sideways or
        // not yet executed (held), and genesis at empty or back to empty
        // (invalid).
        for (index, label) in labels[.C]!.enumerated() {
            let chosen: String?
            if let p = committer[label] {
                chosen = parent[p]
            } else if isRoot(label) {
                chosen = label != "c0" && chance(1, in: 4) ? nil : labels[.P]!.randomElement(using: &rng)
            } else if let old = anchor[parent[label]!] {
                let roll = Int.random(in: 0..<20, using: &rng)
                if roll < 11 {
                    chosen = labels[.P]!.filter { ancestry($0).contains(old) }.randomElement(using: &rng)
                } else if roll < 17 {
                    chosen = labels[.P]!.randomElement(using: &rng)
                } else {
                    chosen = nil
                }
            } else {
                chosen = chance(3, in: 10) ? nil : labels[.P]!.randomElement(using: &rng)
            }
            anchor[label] = chosen
            parentState[label] = chosen.map { facts[$0]!.postState } ?? empty
            let parentFact = parent[label].flatMap { facts[$0] }
            addFact(label, OracleBlockFact(
                hash: hash(label), parent: parentFact?.hash,
                height: parentFact.map { $0.height + 1 } ?? 0,
                postState: oracleCID("hierarchy-\(seed)-post-\(label)"),
                prevState: parentFact?.postState ?? empty, spec: specCID(spec),
                target: "ffff", nextTarget: "ffff",
                timestamp: Int64(index + 1) * 1_000, childCommitments: nil
            ))
        }

        // Grinds: one per block. A committed child block sometimes carries
        // its committer's grind — one grind id on both chains, credited with
        // a different quantity at each (merged mining).
        for label in labels[.P]! + labels[.C]! {
            if let p = committer[label], chance(1, in: 2) {
                firstGrind[label] = "g_\(p)"
            } else {
                firstGrind[label] = "g_\(label)"
            }
            initialQuantity[label] = UInt64.random(in: 1...3, using: &rng)
        }
    }

    func addFact(_ label: String, _ fact: OracleBlockFact) {
        facts[label] = fact
        labelOfHash[fact.hash] = label
    }

    func ancestry(_ label: String) -> [String] {
        var path: [String] = []
        var current: String? = label
        while let block = current {
            path.append(block)
            current = parent[block]
        }
        return path
    }

    // MARK: Actions

    enum Action {
        case admit(String), observe(String), validate(String), exclude(String)
    }

    var legalActions: [Action] {
        var actions: [Action] = []
        for chain in [Level.P, .C] {
            for label in labels[chain]! {
                let isHeld = held[chain]!.contains(label)
                if !isHeld, !withheld.contains(label),
                   parent[label].map(held[chain]!.contains) ?? true,
                   chain == .P || parentTree != nil {
                    actions.append(.admit(label))
                }
                guard isHeld else { continue }
                actions.append(.observe(label))
                let executable = !executed.contains(label) && !excluded.contains(label) && parentExecuted(label)
                let refused = refusedRootExclusions[chain]!.contains(label)
                // A child validation may exclude on continuity, so it waits
                // out a refused root exclusion as an exclusion does.
                if valid[label]!, executable, chain == .P || !refused {
                    actions.append(.validate(label))
                }
                if !valid[label]!, executable, !refused {
                    actions.append(.exclude(label))
                }
            }
        }
        return actions
    }

    func run() async {
        for _ in 0..<80 {
            guard let action = legalActions.randomElement(using: &rng) else { break }
            await perform(action)
        }
        if let childTree {
            for (p, c) in commits where held[.C]!.contains(c) {
                if let value = attributed(p, at: c, in: childTree), value != "0" { attributedCredits += 1 }
            }
        }
    }

    func perform(_ action: Action) async {
        var event: [String: Any]
        switch action {
        case .admit(let label):
            let chain = level(label)
            let quantity = initialQuantity[label]!
            let batch = OracleBatch(facts: [
                .block(facts[label]!),
                .work(blockHash: facts[label]!.hash, grindID: grindID(firstGrind[label]!), work: UInt256(quantity)),
            ])
            let accepted: Bool
            if chain == .P, parentTree == nil {
                // A tree is restored from a log holding a genesis; the node
                // hosts the child, so the parent keeps its runs.
                do {
                    parentTree = try ChainTree.restoreWithoutContext(
                        replaying: [LiveSubject.batch(batch)], specs: [spec]
                    )
                    parentTree!.serveRuns(for: childDirectory)
                } catch {
                    unexpectedRefusals.append("admit \(label): \(error)")
                }
                accepted = parentTree != nil
            } else if chain == .C, childTree == nil {
                // The child is restored under its parent, which derives every run.
                do {
                    childTree = try ChainTree.restore(
                        replaying: [LiveSubject.batch(batch)], context: childContext,
                        specs: [spec], parent: parentTree!
                    )
                } catch {
                    unexpectedRefusals.append("admit \(label): \(error)")
                }
                accepted = childTree != nil
            } else {
                accepted = apply(chain, batch)
            }
            if accepted { held[chain]!.append(label) }
            event = [
                "kind": "admit", "ch": chain.rawValue, "block": label,
                "grind": firstGrind[label]!, "qty": quantity, "accepted": accepted,
            ]
        case .observe(let label):
            // Mostly the block's own grind; one in five times, when there is
            // one, a grind already located at another held block of the chain.
            let chain = level(label)
            let elsewhere = held[chain]!.filter { $0 != label }
            let grindLabel = !elsewhere.isEmpty && chance(1, in: 5)
                ? firstGrind[elsewhere.randomElement(using: &rng)!]!
                : firstGrind[label]!
            let quantity = UInt64.random(in: 1...4, using: &rng)
            let refusable = grindLabel != firstGrind[label]!
            let accepted = apply(chain, OracleBatch(facts: [
                .work(blockHash: facts[label]!.hash, grindID: grindID(grindLabel), work: UInt256(quantity)),
            ]), mayRefuse: refusable)
            event = [
                "kind": "observe", "ch": chain.rawValue, "block": label,
                "grind": grindLabel, "qty": quantity, "accepted": accepted,
            ]
            if !accepted, refusable { event["reason"] = "grindElsewhere" }
        case .validate(let label):
            let chain = level(label)
            if chain == .P {
                event = ["kind": "validate", "ch": "P", "block": label, "accepted": recordValidation(label)]
            } else {
                // The transition is valid; continuity decides (§5.3 as
                // amended: the transition before continuity).
                let continuity = await self.continuity(label)
                decisions[continuity, default: 0] += 1
                switch continuity {
                case "proven":
                    event = ["kind": "validate", "ch": "C", "block": label, "accepted": recordValidation(label)]
                case "invalid":
                    event = recordExclusion(label)
                    event["cause"] = "continuity"
                default:
                    event = ["kind": "validate", "ch": "C", "block": label, "accepted": false, "reason": "continuity"]
                }
                event["continuity"] = continuity
            }
        case .exclude(let label):
            event = recordExclusion(label)
            if level(label) == .C { event["cause"] = "transition" }
        }
        event["after"] = await after()
        events.append(event)
    }

    func recordValidation(_ label: String) -> Bool {
        let chain = level(label)
        let accepted = apply(chain, OracleBatch(facts: [.validation(facts[label]!.hash)]))
        if accepted {
            executed.insert(label)
            if isRoot(label) { refusedRootExclusions[chain]!.removeAll() }
        }
        return accepted
    }

    func recordExclusion(_ label: String) -> [String: Any] {
        let chain = level(label)
        let standsOnAnotherRoot = executed.contains { level($0) == chain && isRoot($0) && $0 != label }
        let refusable = isRoot(label) && !standsOnAnotherRoot
        let accepted = apply(chain, OracleBatch(facts: [.exclusion(facts[label]!.hash)]), mayRefuse: refusable)
        var event: [String: Any] = ["kind": "exclude", "ch": chain.rawValue, "block": label, "accepted": accepted]
        if accepted {
            excluded.insert(label)
        } else if isRoot(label) {
            refusedRootExclusions[chain]!.insert(label)
            if refusable { event["reason"] = "rootExclusion" }
        }
        return event
    }

    /// Whether the chain's tree took the batch, as the single-chain
    /// exporter judges it. Then, as the node does after every apply on
    /// either level, the child's attributed runs are re-derived: scoped by
    /// the parent's weighed blocks after a parent apply, by the child's after
    /// a child apply.
    ///
    /// `mayRefuse` marks the two refusals expected to throw
    /// `corruptConsensusGraph`: work for a grind located at another block,
    /// and excluding a root with no other executed root. Any other throw is
    /// recorded as unexpected.
    func apply(_ chain: Level, _ batch: OracleBatch, mayRefuse: Bool = false) -> Bool {
        let result: SubmissionResult?
        do {
            if chain == .P {
                result = try parentTree!.apply(LiveSubject.batch(batch))
            } else {
                result = try childTree!.apply(LiveSubject.batch(batch))
            }
        } catch ChainStateRestoreError.corruptConsensusGraph where mayRefuse {
            return false
        } catch {
            unexpectedRefusals.append("\(chain.rawValue) \(batch.facts): \(error)")
            return false
        }
        if childTree != nil {
            let weighed = Set(result?.weighed ?? [])
            childTree!.applyParentRun(
                from: parentTree!, directory: childDirectory,
                parentBlocks: chain == .P ? weighed : [],
                held: chain == .C ? weighed : []
            )
        }
        switch batch.facts.first {
        case .validation: return true
        case .exclusion: return result != nil
        default: return result.map { $0.addedBlock || $0.addedContribution } ?? false
        }
    }

    /// The child block's parent-state continuity (§5.3 step 6), decided by
    /// the connect path's own check against the live parent tree's facts.
    /// Only `parent == nil` and `parentState` of the block are read by it;
    /// the remaining fields are placeholders.
    func continuity(_ label: String) async -> String {
        let fact = facts[label]!
        let parentFacts = ParentLevelFacts(tree: parentTree!, path: [DEFAULT_ROOT_DIRECTORY])
        let placeholder = oracleCID("hierarchy-placeholder")
        let block = Block(
            parent: fact.parent.map { VolumeImpl<Block>(rawCID: $0) },
            transactions: HeaderImpl(rawCID: placeholder),
            target: UInt256.max, nextTarget: UInt256.max,
            spec: VolumeImpl(rawCID: fact.spec),
            parentState: LatticeStateHeader(rawCID: parentState[label]!),
            prevState: LatticeStateHeader(rawCID: fact.prevState),
            postState: LatticeStateHeader(rawCID: fact.postState),
            children: HeaderImpl(rawCID: placeholder),
            height: fact.height, timestamp: fact.timestamp, rewardRecipient: nil, nonce: 0
        )
        let failure = await BlockImport.validateParentFacts(
            BlockImport.parentFactLookup(parentFacts),
            child: block, childCID: fact.hash,
            predecessorParentState: parent[label].map { parentState[$0]! },
            context: childContext
        )
        guard let failure else { return "proven" }
        // The connect path's own split: a deterministic invalidity is a
        // verdict; a missing parent fact is retried.
        if BlockImport.isDeterministicInvalidity(failure) { return "invalid" }
        if case .crossChainEvidenceRequired(.parentStateContinuity) = failure { return "held" }
        unexpectedRefusals.append("continuity \(label): \(failure)")
        return "unexpected"
    }

    /// The attributed run of committer `p` credited at child block `c`.
    func attributed(_ p: String, at c: String, in tree: ChainTree) -> String? {
        AttributedRunIdentity(carrierBlockHash: facts[p]!.hash, directory: childDirectory).contributionID
            .flatMap { tree.workContribution(id: $0, at: facts[c]!.hash) }
            .map { decimal($0.work.toHexString()) }
    }

    func after() async -> [String: Any] {
        func tips(_ tree: ChainTree?, _ chain: Level) -> [String: Any] {
            guard let tree else {
                return ["canonicalTip": NSNull(), "validatedTip": NSNull(), "weights": [String: String]()]
            }
            func label(_ hash: String) -> Any { hash.isEmpty ? NSNull() : labelOfHash[hash]! }
            // What fork choice compares: the block's whole subtree, attributed
            // runs included.
            var weights: [String: String] = [:]
            for label in held[chain]! {
                weights[label] = tree.forkChoiceWeight(of: facts[label]!.hash)
                    .map { decimal($0.toHexString()) } ?? "nil"
            }
            return [
                "canonicalTip": label(tree.canonicalTip),
                "validatedTip": label(tree.heaviestExecutedTip()),
                "weights": weights,
            ]
        }
        var child = tips(childTree, .C)
        var continuity: [String: String] = [:]
        var attributedRuns: [String: String] = [:]
        if let childTree {
            for label in held[.C]! {
                let outcome = await self.continuity(label)
                continuity[label] = outcome
                continuityOutcomesSeen.insert(outcome)
            }
            for (p, c) in commits where held[.C]!.contains(c) {
                attributedRuns[p] = attributed(p, at: c, in: childTree) ?? "0"
            }
        }
        child["continuity"] = continuity
        // Keyed by committer: the attributed run it credits at its child block.
        child["attributed"] = attributedRuns
        return ["P": tips(parentTree, .P), "C": child]
    }

    /// Ranks of all block CIDs, both chains, under the tree's own
    /// tie-break, 0 preferred. Only same-chain ranks are ever compared.
    var cidRanks: [String: Int] {
        let all = labels[.P]! + labels[.C]!
        let ordered = all.sorted { forkChoicePrefersBlock(facts[$0]!.hash, over: facts[$1]!.hash) }
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, $0) })
    }

    func json() throws -> Data {
        let ranks = cidRanks
        func blocks(_ chain: Level) -> [[String: Any]] {
            labels[chain]!.map { label in
                var block: [String: Any] = [
                    "label": label, "parent": parent[label] ?? NSNull(), "valid": valid[label]!,
                    "cidRank": ranks[label]!, "hash": facts[label]!.hash,
                ]
                if chain == .P {
                    block["postState"] = facts[label]!.postState
                } else {
                    block["parentState"] = parentState[label]!
                    block["withheld"] = withheld.contains(label)
                }
                return block
            }
        }
        var anchors: [String: Any] = [:]
        for label in labels[.C]! { anchors[label] = anchor[label] ?? NSNull() }
        let trace: [String: Any] = [
            "seed": seed,
            "emptyState": empty,
            "chains": ["P": ["blocks": blocks(.P)], "C": ["blocks": blocks(.C)]],
            "commits": commits.map { [$0.p, $0.c] },
            "anchor": anchors,
            "grinds": (labels[.P]! + labels[.C]!).filter { !withheld.contains($0) }.map { label -> [String: Any] in
                ["label": firstGrind[label]!, "ch": level(label).rawValue, "block": label, "qty": initialQuantity[label]!]
            },
            "events": events,
        ]
        return try JSONSerialization.data(withJSONObject: trace, options: [.sortedKeys])
    }

    func checkSanity() {
        XCTAssertFalse(events.isEmpty, "seed \(seed)")
        XCTAssertEqual(unexpectedRefusals, [], "seed \(seed)")
        var admitted: Set<String> = []
        for event in events {
            guard let after = event["after"] as? [String: [String: Any]] else {
                return XCTFail("seed \(seed): no after")
            }
            if event["kind"] as? String == "admit", event["accepted"] as? Bool == true,
               let chain = event["ch"] as? String {
                admitted.insert(chain)
            }
            for chain in admitted {
                XCTAssertTrue(after[chain]?["canonicalTip"] is String, "seed \(seed): no \(chain) canonical tip")
            }
            for chain in ["P", "C"] {
                guard let weights = after[chain]?["weights"] as? [String: String] else {
                    return XCTFail("seed \(seed): no \(chain) weights")
                }
                for (label, weight) in weights {
                    guard let value = UInt64(weight) else { return XCTFail("seed \(seed) \(label): \(weight)") }
                    XCTAssertGreaterThanOrEqual(value, initialQuantity[label]!, "seed \(seed) \(label)")
                }
            }
            let continuity = after["C"]?["continuity"] as? [String: String] ?? [:]
            XCTAssertTrue(continuity.values.allSatisfy { ["proven", "held", "invalid"].contains($0) }, "seed \(seed)")
        }
    }
}

/// Work as a decimal string. Trace work is a few small grinds, so it fits.
private func decimal(_ hexDigits: String) -> String {
    String(UInt64(hex(hexDigits), radix: 16)!)
}
