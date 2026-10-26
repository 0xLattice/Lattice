import Foundation
import cashew
import XCTest
import UInt256
import LatticePrimitives
@testable import LatticePoW
@testable import LatticeBlockTree
@testable import LatticeImport
@testable import LatticeValidation

/// Seeded hierarchy (parent P, child C, grandchild G) fork-choice traces for
/// checking a formal model of spec §5.1 rule 4, §5.3, §9.9 and §9.10 step by
/// step against the live `ChainTree`s: each trace records a random tree per
/// chain, which block commits which block of the chain below, each child
/// block's anchor one level up, the header-rule and validity verdicts, and
/// every fact applied with what every tree reported afterwards. Nothing here
/// judges the trees; it records what they did.
///
/// A child block's continuity is decided by the connect path's own
/// `BlockImport.validateParentFacts` against `ParentLevelFacts` of the live
/// tree one level up. A non-genesis block's header rules (§9.9: `spec` and
/// `prevState` against its parent) are decided by header admission's own
/// `Block.headerAdmission`; a block it excludes is admitted with its
/// exclusion and never validated. Every non-genesis block is admitted by the
/// tree's own header admission (`ChainTree.insertHeader`), and an admit's
/// `headerExcluded` is what that tree then reports of the block
/// (`isExcludedRoot`), checked against the header rule generated for it.
/// After every apply, attributed runs are re-derived level by level,
/// parents first, as the node's
/// `NodeCore.attributeRuns` does: a level's scope is the weighed blocks one
/// level up plus the blocks that level's own derivation raised.
///
/// Three-level traces (`"levels": 3`) carry G and header-rule exclusions;
/// two-level traces are the original P/C traces, byte for byte. Set
/// `LATTICE_TRACE_DIR` to write `trace-<seed>.json` for seeds
/// 1...`LATTICE_TRACE_COUNT` (default 20), at `LATTICE_TRACE_LEVELS` levels
/// (default 3). Without it the traces are built and sanity-checked only.
final class HierarchyTraceExportTests: XCTestCase {
    func testExportHierarchyTraces() async throws {
        let environment = ProcessInfo.processInfo.environment
        let count = environment["LATTICE_TRACE_COUNT"].flatMap(UInt64.init) ?? 20
        let written = environment["LATTICE_TRACE_LEVELS"].flatMap(Int.init) ?? 3
        let directory = environment["LATTICE_TRACE_DIR"].map { URL(fileURLWithPath: $0) }
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for levels in [2, 3] {
            var tally = Tally()
            for seed in 1...max(count, 1) {
                let trace = HierarchyTrace(seed: seed, levels: levels)
                await trace.run()
                trace.checkSanity()
                tally.add(trace)
                if let directory, levels == written {
                    try trace.json().write(to: directory.appendingPathComponent("trace-\(seed).json"))
                }
            }
            print("hierarchy traces (\(levels) levels): \(tally)")
            let lower: [Level] = levels == 3 ? [.C, .G] : [.C]
            for chain in lower {
                for outcome in ["proven", "held", "invalid"] {
                    XCTAssertGreaterThan(tally.tracesShowing[chain]?[outcome] ?? 0, 0,
                                         "no \(levels)-level trace shows \(chain) continuity \(outcome)")
                }
                XCTAssertGreaterThan(tally.credits[chain] ?? 0, 0, "no \(levels)-level trace credits a run at \(chain)")
            }
            guard levels == 3 else { continue }
            for chain in [Level.P, .C, .G] {
                XCTAssertGreaterThan(tally.headerBad[chain] ?? 0, 0, "no header-bad block on \(chain)")
            }
            for chain in [Level.P, .C] {
                XCTAssertGreaterThan(tally.headerBadCarriers[chain] ?? 0, 0, "no header-bad carrier on \(chain)")
            }
            XCTAssertGreaterThan(tally.headerExcludedAdmits, 0, "no header-bad block admitted")
            XCTAssertGreaterThan(tally.recursiveCredits, 0, "no G credit includes work P attributed into C")
            for path in ["PCG", "PC", "CG", "PG"] {
                XCTAssertGreaterThan(tally.mergedGrinds[path] ?? 0, 0, "no merged grind on \(path)")
            }
        }
    }

    func testTraceIsDeterministic() async throws {
        for levels in [2, 3] {
            let first = HierarchyTrace(seed: 1, levels: levels), second = HierarchyTrace(seed: 1, levels: levels)
            await first.run()
            await second.run()
            XCTAssertEqual(try first.json(), try second.json())
        }
    }
}

/// What a seed set showed, summed over its traces.
private struct Tally: CustomStringConvertible {
    var tracesShowing: [Level: [String: Int]] = [:]
    var decisions: [Level: [String: Int]] = [:]
    var credits: [Level: Int] = [:]
    var headerBad: [Level: Int] = [:]
    var headerBadCarriers: [Level: Int] = [:]
    var headerExcludedAdmits = 0
    var recursiveCredits = 0
    var mergedGrinds: [String: Int] = [:]

    mutating func add(_ trace: HierarchyTrace) {
        for (chain, outcomes) in trace.continuityOutcomesSeen {
            for outcome in outcomes { tracesShowing[chain, default: [:]][outcome, default: 0] += 1 }
        }
        for (chain, counts) in trace.decisions {
            decisions[chain, default: [:]].merge(counts, uniquingKeysWith: +)
        }
        credits.merge(trace.attributedCredits, uniquingKeysWith: +)
        for (label, _) in trace.headerBad {
            headerBad[trace.level(label), default: 0] += 1
            if trace.carries(label) { headerBadCarriers[trace.level(label), default: 0] += 1 }
        }
        headerExcludedAdmits += trace.events.filter { $0["headerExcluded"] as? Bool == true }.count
        recursiveCredits += trace.recursiveCredits
        mergedGrinds.merge(trace.mergedGrinds, uniquingKeysWith: +)
    }

    var description: String {
        func sorted<V>(_ d: [Level: V]) -> String {
            d.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        }
        return "traces showing \(sorted(tracesShowing.mapValues { $0.sorted { $0.key < $1.key } })),"
            + " validate decisions \(sorted(decisions.mapValues { $0.sorted { $0.key < $1.key } })),"
            + " attributed credits > 0: \(sorted(credits)),"
            + " header-bad \(sorted(headerBad)) (carriers \(sorted(headerBadCarriers))),"
            + " header-excluded admits \(headerExcludedAdmits),"
            + " recursive G credits \(recursiveCredits),"
            + " merged grinds \(mergedGrinds.sorted { $0.key < $1.key })"
    }
}

// MARK: - One seeded trace

private enum Level: String { case P, C, G }

private let grandchildDirectory = "grandkid"

private final class HierarchyTrace {
    let seed: UInt64
    let levels: Int
    var rng: SplitMix64
    let spec = oracleSpec(targetBlockTime: 1_000)
    /// The spec a spec-rule-breaking block declares, unless its parent
    /// already declares it (then the root's).
    let otherSpec = specCID(oracleSpec(targetBlockTime: 2_000))
    let contexts: [Level: ChainRuntimeContext] = [
        .C: try! ChainRuntimeContext(path: [DEFAULT_ROOT_DIRECTORY, childDirectory]),
        .G: try! ChainRuntimeContext(path: [DEFAULT_ROOT_DIRECTORY, childDirectory, grandchildDirectory]),
    ]
    let empty = LatticeState.emptyHeader.rawCID
    /// The difficulty every root starts at; the ASERT schedule of 5.5
    /// derives every other target from it.
    let rootTarget = "ffff"

    /// Labels `p0`…, `c0`… and `g0`… in creation order; a parent always
    /// precedes its children. `p0` is the parent chain's one genesis.
    var labels: [Level: [String]] = [.P: [], .C: [], .G: []]
    var parent: [String: String] = [:]
    var valid: [String: Bool] = [:]
    var facts: [String: OracleBlockFact] = [:]
    var labelOfHash: [String: String] = [:]
    /// `<<u, l>>`: block `u` commits block `l` of the chain one level down
    /// into that chain's directory. Each block has at most one committer.
    var commits: [(u: String, l: String)] = []
    var committer: [String: String] = [:]
    /// The block whose post-state is the block's `parentState` (child
    /// chains) or `prevState` (non-genesis blocks); absent for `emptyHeader`.
    var anchor: [String: String] = [:]
    var prevStateBlock: [String: String] = [:]
    /// The same block, read back from each header's declared prevState.
    var declaredPrevStateBlock: [String: String] = [:]
    var parentState: [String: String] = [:]
    /// The header rule a block breaks, as header admission decided it.
    var headerBad: [String: String] = [:]
    /// A block never delivered (so never admitted).
    var withheld: Set<String> = []
    /// Each block's first grind, by label: `g_<block>`, or for a merged
    /// block the first grind of a block on its proof path.
    var firstGrind: [String: String] = [:]
    var initialQuantity: [String: UInt64] = [:]

    var trees: [Level: ChainTree] = [:]
    /// Every batch each tree took without a throw, in order: what a restart
    /// replays.
    var logs: [Level: [BlockImportBatch]] = [:]
    var held: [Level: [String]] = [.P: [], .C: [], .G: []]
    var executed: Set<String> = []
    var excluded: Set<String> = []
    /// Root exclusions refused for want of another executed root on that
    /// chain: not attempted again until some root there executes.
    var refusedRootExclusions: [Level: Set<String>] = [.P: [], .C: [], .G: []]
    var events: [[String: Any]] = []
    /// Refusals outside the two this generator expects; the test fails on any.
    var unexpectedRefusals: [String] = []
    /// Continuity outcomes decided at validation, by chain and outcome.
    var decisions: [Level: [String: Int]] = [:]
    var continuityOutcomesSeen: [Level: Set<String>] = [:]
    /// Commits whose attributed run is credited above zero at the end, by
    /// the chain credited.
    var attributedCredits: [Level: Int] = [:]
    /// C→G commits whose credit at G equals the C run's grinds plus the
    /// work P attributed into that run, that work above zero.
    var recursiveCredits = 0

    var chains: [Level] { levels == 3 ? [.P, .C, .G] : [.P, .C] }
    func level(_ label: String) -> Level {
        label.hasPrefix("p") ? .P : label.hasPrefix("c") ? .C : .G
    }
    func upper(_ chain: Level) -> Level { chain == .G ? .C : .P }
    func lower(_ chain: Level) -> Level? {
        chain == .P ? .C : chain == .C && levels == 3 ? .G : nil
    }
    func directory(_ chain: Level) -> String { chain == .G ? grandchildDirectory : childDirectory }
    func path(_ chain: Level) -> [String] {
        chain == .P ? [DEFAULT_ROOT_DIRECTORY] : contexts[chain]!.path
    }
    func hash(_ label: String) -> String { oracleCID("hierarchy-\(seed)-\(label)") }
    func grindID(_ grindLabel: String) -> String { oracleCID("hierarchy-\(seed)-\(grindLabel)") }
    func isRoot(_ label: String) -> Bool { parent[label] == nil }
    func carries(_ label: String) -> Bool { commits.contains { $0.u == label } }
    func parentExecuted(_ label: String) -> Bool { parent[label].map(executed.contains) ?? true }
    func chance(_ numerator: Int, in denominator: Int) -> Bool {
        Int.random(in: 0..<denominator, using: &rng) < numerator
    }

    init(seed: UInt64, levels: Int) {
        self.seed = seed
        self.levels = levels
        rng = SplitMix64(seed: seed)
        // Shapes: one parent genesis; one or two geneses on each chain below.
        // Two-level traces draw exactly what they always drew, in order.
        shape(.P)
        shape(.C)
        withhold(.C)
        if levels == 3 {
            shape(.G)
            withhold(.G)
        }

        // Commits first: a committed block's anchor is its carrier's
        // prevState (§5.3 step 3). A genesis's prevState is empty, so it
        // commits only a second genesis below, which is then anchored at
        // empty (invalid, §5.1 rule 4).
        commit(into: .C)
        if levels == 3 {
            commit(into: .G)
            // Header rules (§9.9), carriers more often: a non-genesis block
            // declares another spec, or a prevState other than its parent's
            // post-state (its grandparent's, or empty).
            for chain in chains {
                for label in labels[chain]! where !isRoot(label) {
                    guard chance(1, in: carries(label) ? 3 : 6) else { continue }
                    headerBad[label] = chance(1, in: 2) ? "spec" : "prevState"
                }
            }
        }

        // Facts, chain by chain, parents first: every block a unique
        // post-state, so an anchor names exactly one block.
        for chain in chains {
            for (index, label) in labels[chain]!.enumerated() {
                if chain != .P { chooseAnchor(label) }
                addFact(label, index: index)
            }
        }
        // What header admission itself decides of each non-genesis header.
        if levels == 3 {
            let intended = headerBad
            headerBad = [:]
            for chain in chains {
                for label in labels[chain]! where !isRoot(label) { classifyHeader(label) }
            }
            if headerBad != intended {
                unexpectedRefusals.append("header admission decided \(headerBad), generated \(intended)")
            }
            for label in headerBad.keys { valid[label] = false }
            // Each block's declared prevState, read back from its header, as
            // the same-chain block that produced it.
            for chain in chains {
                var producer: [String: String] = [:]
                for label in labels[chain]! { producer[facts[label]!.postState] = label }
                for label in labels[chain]! {
                    let declared = header(label).prevState.rawCID
                    let block = declared == empty ? nil : producer[declared]
                    if declared != empty, block == nil {
                        unexpectedRefusals.append("prevState of \(label) names no \(chain) block")
                    }
                    if headerBad[label] == nil, block != parent[label] {
                        unexpectedRefusals.append("prevState of \(label) is \(block ?? "empty"), not its parent's")
                    }
                    declaredPrevStateBlock[label] = block
                }
            }
        }

        // Grinds: one per block. A committed block sometimes carries a grind
        // of a block on its proof path — one grind id on two or three chains,
        // credited with a different quantity at each (merged mining): P–C,
        // C–G, P–C–G, or P–G through the C block P commits and that commits
        // the G block.
        for label in chains.flatMap({ labels[$0]! }) {
            if level(label) == .G, let c = committer[label], chance(1, in: 2) {
                if let p = committer[c], firstGrind[c] != "g_\(p)", chance(1, in: 2) {
                    firstGrind[label] = "g_\(p)"
                } else {
                    firstGrind[label] = firstGrind[c]!
                }
            } else if level(label) != .G, let p = committer[label], chance(1, in: 2) {
                firstGrind[label] = "g_\(p)"
            } else {
                firstGrind[label] = "g_\(label)"
            }
            initialQuantity[label] = UInt64.random(in: 1...3, using: &rng)
        }
    }

    func shape(_ chain: Level) {
        let count = Int.random(in: 5...8, using: &rng)
        let roots = chain == .P ? 1 : Int.random(in: 1...2, using: &rng)
        let prefix = chain.rawValue.lowercased()
        for index in 0..<count {
            let label = "\(prefix)\(index)"
            parent[label] = index < roots ? nil : labels[chain]!.randomElement(using: &rng)
            // The parent genesis is valid, so the child has something to anchor on.
            valid[label] = chain == .P && index == 0 ? true : !chance(1, in: 6)
            labels[chain]!.append(label)
        }
    }

    func withhold(_ chain: Level) {
        guard chance(1, in: 2) else { return }
        let parents = Set(parent.values)
        let leaves = labels[chain]!.filter { !isRoot($0) && !parents.contains($0) }
        if let leaf = leaves.randomElement(using: &rng) { withheld.insert(leaf) }
    }

    func commit(into chain: Level) {
        var uncommitted = labels[chain]!
        let first = labels[chain]!.first!
        for u in labels[upper(chain)]! {
            let pool = isRoot(u) ? uncommitted.filter { isRoot($0) && $0 != first } : uncommitted
            guard chance(1, in: isRoot(u) ? 3 : 2), let l = pool.randomElement(using: &rng) else { continue }
            commits.append((u, l))
            committer[l] = u
            uncommitted.removeAll { $0 == l }
        }
    }

    /// A child-chain block's anchor: derived for a committed block;
    /// otherwise random, so all three continuity outcomes occur — forward
    /// (proven), sideways or not yet executed (held), and genesis at empty
    /// or back to empty (invalid).
    func chooseAnchor(_ label: String) {
        let above = labels[upper(level(label))]!
        let chosen: String?
        if let u = committer[label] {
            chosen = prevStateBlock[u]
        } else if isRoot(label) {
            chosen = label != labels[level(label)]!.first! && chance(1, in: 4) ? nil : above.randomElement(using: &rng)
        } else if let old = anchor[parent[label]!] {
            let roll = Int.random(in: 0..<20, using: &rng)
            if roll < 11 {
                chosen = above.filter { ancestry($0).contains(old) }.randomElement(using: &rng)
            } else if roll < 17 {
                chosen = above.randomElement(using: &rng)
            } else {
                chosen = nil
            }
        } else {
            chosen = chance(3, in: 10) ? nil : above.randomElement(using: &rng)
        }
        anchor[label] = chosen
        parentState[label] = chosen.map { facts[$0]!.postState } ?? empty
    }

    func addFact(_ label: String, index: Int) {
        let parentFact = parent[label].flatMap { facts[$0] }
        let prevFrom = headerBad[label] == "prevState" ? parent[label].flatMap { parent[$0] } : parent[label]
        prevStateBlock[label] = prevFrom
        let committed = commits.first { $0.u == label }?.l
        let height = parentFact.map { $0.height + 1 } ?? 0
        let timestamp = Int64(index + 1) * 1_000
        // On the ASERT schedule of the root's spec (§5.5), so header
        // admission's proof-of-work checks pass and its validity rules decide.
        let target = parentFact?.nextTarget ?? rootTarget
        let fact = OracleBlockFact(
            hash: hash(label), parent: parentFact?.hash, height: height,
            postState: oracleCID("hierarchy-\(seed)-post-\(label)"),
            prevState: prevFrom.map { facts[$0]!.postState } ?? empty,
            spec: headerBad[label] == "spec"
                ? (parentFact!.spec == otherSpec ? specCID(spec) : otherSpec)
                : parentFact?.spec ?? specCID(spec),
            target: target,
            nextTarget: height == 0 ? rootTarget : scheduledNextTarget(label, height: height, timestamp: timestamp, target: target),
            timestamp: timestamp,
            childCommitments: committed.map { [directory(level($0)): hash($0)] }
        )
        facts[label] = fact
        labelOfHash[fact.hash] = label
    }

    /// Block 1 of `label`'s ancestry: the ASERT anchor.
    func heightOneAnchor(_ label: String, height: UInt64, timestamp: Int64, target: String) -> DifficultyAnchor {
        if height == 1 {
            return DifficultyAnchor(blockHeight: 1, timestamp: timestamp, target: UInt256.fromHexDigits(target)!)
        }
        let one = ancestry(parent[label]!).first { facts[$0]!.height == 1 }!
        return DifficultyAnchor(
            blockHeight: 1, timestamp: facts[one]!.timestamp, target: UInt256.fromHexDigits(facts[one]!.target)!
        )
    }

    func scheduledNextTarget(_ label: String, height: UInt64, timestamp: Int64, target: String) -> String {
        let anchor = heightOneAnchor(label, height: height, timestamp: timestamp, target: target)
        return spec.calculateAsertTarget(
            anchorTarget: anchor.target, anchorTimestamp: anchor.timestamp, anchorHeight: anchor.blockHeight,
            blockTimestamp: timestamp, blockHeight: height
        ).toHexString()
    }

    /// The block a fact describes, for the decisions that read a header.
    /// Fields no such decision reads are placeholders.
    func header(_ label: String) -> Block {
        let fact = facts[label]!
        let placeholder = oracleCID("hierarchy-placeholder")
        return Block(
            parent: fact.parent.map { VolumeImpl<Block>(rawCID: $0) },
            transactions: HeaderImpl(rawCID: placeholder),
            target: UInt256.fromHexDigits(fact.target)!, nextTarget: UInt256.fromHexDigits(fact.nextTarget)!,
            spec: VolumeImpl(rawCID: fact.spec),
            parentState: LatticeStateHeader(rawCID: parentState[label] ?? empty),
            prevState: LatticeStateHeader(rawCID: fact.prevState),
            postState: LatticeStateHeader(rawCID: fact.postState),
            children: try! HeaderImpl(node: childIndex(label)),
            height: fact.height, timestamp: fact.timestamp, rewardRecipient: nil, nonce: 0
        )
    }

    /// The blocks `label` commits, by directory: the child index its header
    /// binds.
    func childIndex(_ label: String) -> FlatDictionary<BlockHeader> {
        FlatDictionary((facts[label]!.childCommitments ?? [:]).mapValues { BlockHeader(rawCID: $0) })
    }

    /// Header admission's own decision (§9.9) for a non-genesis header
    /// whose work verified and whose parent is held: `Block.headerAdmission`
    /// called with this exporter's own linkage (the parent's fact) and
    /// difficulty anchor (`heightOneAnchor`), decided before any tree holds
    /// the block: the expectation `admitHeader` must then meet. `.excluded`
    /// is the block weighed and excluded at once; it names which rule by the
    /// two predicates it applies.
    func classifyHeader(_ label: String) {
        let block = header(label)
        let parentFact = facts[parent[label]!]!
        let linkage = HeaderLinkageParent(
            height: parentFact.height, timestamp: parentFact.timestamp,
            target: UInt256.fromHexDigits(parentFact.target)!,
            nextTarget: UInt256.fromHexDigits(parentFact.nextTarget)!,
            postStateCID: parentFact.postState, specCID: parentFact.spec
        )
        let admission: HeaderAdmission
        do {
            admission = try block.headerAdmission(
                parent: linkage, spec: spec,
                inheritedAnchor: {
                    self.heightOneAnchor(label, height: block.height, timestamp: block.timestamp,
                                         target: self.facts[label]!.target)
                },
                validationContext: ValidationContext(nowMilliseconds: 1_000_000)
            )
        } catch {
            return unexpectedRefusals.append("header \(label): \(error)")
        }
        switch admission {
        case .linked: break
        case .excluded: headerBad[label] = block.validateSpec(parent: linkage) ? "prevState" : "spec"
        default: unexpectedRefusals.append("header \(label): \(admission)")
        }
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
        for chain in chains {
            for label in labels[chain]! {
                let isHeld = held[chain]!.contains(label)
                if !isHeld, !withheld.contains(label),
                   parent[label].map(held[chain]!.contains) ?? true,
                   chain == .P || trees[upper(chain)] != nil {
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
        for _ in 0..<(levels == 3 ? 120 : 80) {
            guard let action = legalActions.randomElement(using: &rng) else { break }
            await perform(action)
        }
        for chain in chains where chain != .P {
            guard let tree = trees[chain] else { continue }
            for (u, l) in commits where level(l) == chain && held[chain]!.contains(l) {
                if let value = attributed(u, at: l, in: tree), value != "0" { attributedCredits[chain, default: 0] += 1 }
            }
        }
        if levels == 3 { checkRecursion() }
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
            var accepted: Bool
            if trees[chain] == nil {
                // A tree is restored from a log holding a genesis. A child is
                // restored under its parent, which derives every run; the node
                // hosts the chain below, so each tree keeps runs for it.
                do {
                    var tree = chain == .P
                        ? try ChainTree.restoreWithoutContext(replaying: [LiveSubject.batch(batch)], specs: [spec])
                        : try ChainTree.restore(
                            replaying: [LiveSubject.batch(batch)], context: contexts[chain]!,
                            specs: [spec], parent: trees[upper(chain)]!
                        )
                    if let below = lower(chain) { tree.serveRuns(for: directory(below)) }
                    trees[chain] = tree
                    logs[chain] = [LiveSubject.batch(batch)]
                } catch {
                    unexpectedRefusals.append("admit \(label): \(error)")
                }
                accepted = trees[chain] != nil
            } else if !isRoot(label) {
                accepted = admitHeader(label)
            } else {
                accepted = apply(chain, batch)
            }
            if accepted { held[chain]!.append(label) }
            event = [
                "kind": "admit", "ch": chain.rawValue, "block": label,
                "grind": firstGrind[label]!, "qty": quantity, "accepted": accepted,
            ]
            // What the tree itself reports right after the admission; the
            // generated header rule is only the expectation it must meet.
            let headerExcluded = accepted && trees[chain]!.isExcludedRoot(facts[label]!.hash)
            if accepted, headerExcluded != (headerBad[label] != nil) {
                unexpectedRefusals.append("admit \(label): tree excluded \(headerExcluded), header rule \(headerBad[label] ?? "none")")
            }
            if headerExcluded {
                excluded.insert(label)
                event["headerExcluded"] = true
            }
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
                decisions[chain, default: [:]][continuity, default: 0] += 1
                switch continuity {
                case "proven":
                    event = ["kind": "validate", "ch": chain.rawValue, "block": label, "accepted": recordValidation(label)]
                case "invalid":
                    event = recordExclusion(label)
                    event["cause"] = "continuity"
                default:
                    event = ["kind": "validate", "ch": chain.rawValue, "block": label, "accepted": false, "reason": "continuity"]
                }
                event["continuity"] = continuity
            }
        case .exclude(let label):
            event = recordExclusion(label)
            if level(label) != .P { event["cause"] = "transition" }
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

    /// A non-genesis block through the tree's own header admission (§9.9):
    /// its block and first-grind work weighed, and a block breaking a header
    /// rule excluded in the same step. Whatever the tree emitted is logged
    /// for the restart; then the runs it can have moved are re-derived.
    func admitHeader(_ label: String) -> Bool {
        let chain = level(label)
        let admission = trees[chain]!.insertHeader(
            header(label), blockHash: facts[label]!.hash, childIndex: childIndex(label),
            work: VerifiedWorkContribution(id: grindID(firstGrind[label]!), work: UInt256(initialQuantity[label]!)),
            validationContext: ValidationContext(nowMilliseconds: 1_000_000)
        )
        guard let update = admission.update else {
            unexpectedRefusals.append("admit \(label): \(admission)")
            return false
        }
        logs[chain, default: []].append(contentsOf: update.batches)
        attributeRuns([chain: Set(update.weighed)])
        return true
    }

    /// Whether the chain's tree took the batch, as the single-chain
    /// exporter judges it; then the runs it can have moved are re-derived.
    func apply(_ chain: Level, _ batch: OracleBatch, mayRefuse: Bool = false) -> Bool {
        let result = applyFacts(chain, batch, mayRefuse: mayRefuse)
        if !result.threw { attributeRuns([chain: result.weighed]) }
        return result.accepted
    }

    /// One batch on one tree, without attribution.
    ///
    /// `mayRefuse` marks the two refusals expected to throw
    /// `corruptConsensusGraph`: work for a grind located at another block,
    /// and excluding a root with no other executed root. Any other throw is
    /// recorded as unexpected.
    func applyFacts(
        _ chain: Level, _ batch: OracleBatch, mayRefuse: Bool = false
    ) -> (accepted: Bool, weighed: Set<String>, threw: Bool) {
        let result: SubmissionResult?
        do {
            result = try trees[chain]!.apply(LiveSubject.batch(batch))
        } catch ChainStateRestoreError.corruptConsensusGraph where mayRefuse {
            return (false, [], true)
        } catch {
            unexpectedRefusals.append("\(chain.rawValue) \(batch.facts): \(error)")
            return (false, [], true)
        }
        logs[chain, default: []].append(LiveSubject.batch(batch))
        let weighed = Set(result?.weighed ?? [])
        switch batch.facts.first {
        case .validation: return (true, weighed, false)
        case .exclusion: return (result != nil, weighed, false)
        default: return (result.map { $0.addedBlock || $0.addedContribution } ?? false, weighed, false)
        }
    }

    /// As `NodeCore.attributeRuns`: each child level, parents first, is
    /// credited with the runs this step can have moved — the parent level's
    /// weighed blocks and the blocks the parent's own derivation raised,
    /// and this level's weighed blocks. What a level raises flows on down.
    func attributeRuns(_ weighed: [Level: Set<String>]) {
        var raised: [Level: Set<String>] = [:]
        for chain in chains where chain != .P {
            let up = upper(chain)
            let parentBlocks = (weighed[up] ?? []).union(raised[up] ?? [])
            let heldHere = weighed[chain] ?? []
            guard !parentBlocks.isEmpty || !heldHere.isEmpty,
                  let parentTree = trees[up], trees[chain] != nil else { continue }
            let result = trees[chain]!.applyParentRun(
                from: parentTree, directory: directory(chain),
                parentBlocks: parentBlocks, held: heldHere
            )
            raised[chain] = Set(result.raised)
        }
    }

    /// The child block's parent-state continuity (§5.3 step 6), decided by
    /// the connect path's own check against the live tree one level up.
    /// Only `parent == nil` and `parentState` of the block are read by it.
    func continuity(_ label: String) async -> String {
        let chain = level(label)
        let fact = facts[label]!
        let parentFacts = ParentLevelFacts(tree: trees[upper(chain)]!, path: path(upper(chain)))
        let failure = await BlockImport.validateParentFacts(
            BlockImport.parentFactLookup(parentFacts),
            child: header(label), childCID: fact.hash,
            predecessorParentState: parent[label].map { parentState[$0]! },
            context: contexts[chain]!
        )
        guard let failure else { return "proven" }
        // The connect path's own split: a deterministic invalidity is a
        // verdict; a missing parent fact is retried.
        if BlockImport.isDeterministicInvalidity(failure) { return "invalid" }
        if case .crossChainEvidenceRequired(.parentStateContinuity) = failure { return "held" }
        unexpectedRefusals.append("continuity \(label): \(failure)")
        return "unexpected"
    }

    /// The attributed run of committer `u` credited at block `l`.
    func attributed(_ u: String, at l: String, in tree: ChainTree) -> String? {
        attributedWork(u, at: l, in: tree).map { decimal($0.toHexString()) }
    }

    func attributedWork(_ u: String, at l: String, in tree: ChainTree) -> UInt256? {
        AttributedRunIdentity(carrierBlockHash: facts[u]!.hash, directory: directory(level(l))).contributionID
            .flatMap { tree.workContribution(id: $0, at: facts[l]!.hash) }
            .map(\.work)
    }

    /// §9.10 level by level: the run of a C block `c` into G is the
    /// credited work of the C blocks whose nearest committer into G is `c`
    /// — grinds and the runs P attributed at them alike — so G is credited
    /// that less `c`'s own grinds. Counts the credits that carry P-attributed
    /// work, and records any credit that differs from that sum, or that a
    /// whole re-derivation would still raise, as unexpected.
    func checkRecursion() {
        guard let c = trees[.C], let g = trees[.G] else { return }
        for (carrier, l) in commits where level(l) == .G && held[.G]!.contains(l) {
            let run = held[.C]!.filter { c.nearestCarrier(of: facts[$0]!.hash, directory: grandchildDirectory) == facts[carrier]!.hash }
            var grinds = UInt256.zero, fromP = UInt256.zero
            for member in run where member != carrier {
                grinds = grinds + c.grindWork(of: facts[member]!.hash)!.uint256Value!
            }
            for member in run {
                for (p, credited) in commits where credited == member {
                    fromP = fromP + (attributedWork(p, at: member, in: c) ?? .zero)
                }
            }
            let credit = attributedWork(carrier, at: l, in: g) ?? .zero
            if credit != grinds + fromP {
                unexpectedRefusals.append("G credit of \(carrier) at \(l): \(credit), run grinds \(grinds) + P-attributed \(fromP)")
            }
            if fromP > .zero, credit == grinds + fromP { recursiveCredits += 1 }
        }
        // The step-scoped derivation equals a whole one: each level
        // restored from its log under its restored parent, parents first.
        var restored: [Level: ChainTree] = [:]
        for chain in chains {
            do {
                var tree = chain == .P
                    ? try ChainTree.restoreWithoutContext(replaying: logs[chain]!, specs: [spec])
                    : try ChainTree.restore(
                        replaying: logs[chain]!, context: contexts[chain]!,
                        specs: [spec], parent: restored[upper(chain)]!
                    )
                if let below = lower(chain) { tree.serveRuns(for: directory(below)) }
                restored[chain] = tree
            } catch {
                return unexpectedRefusals.append("restore \(chain): \(error)")
            }
        }
        for (u, l) in commits where held[level(l)]!.contains(l) {
            let live = attributedWork(u, at: l, in: trees[level(l)]!)
            let whole = attributedWork(u, at: l, in: restored[level(l)]!)
            if live != whole {
                unexpectedRefusals.append("run of \(u) at \(l): live \(String(describing: live)), restored \(String(describing: whole))")
            }
        }
    }

    func after() async -> [String: Any] {
        func tips(_ chain: Level) -> [String: Any] {
            guard let tree = trees[chain] else {
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
        var sides: [String: Any] = ["P": tips(.P)]
        for chain in chains where chain != .P {
            var side = tips(chain)
            var continuity: [String: String] = [:]
            var attributedRuns: [String: String] = [:]
            if let tree = trees[chain] {
                for label in held[chain]! {
                    let outcome = await self.continuity(label)
                    continuity[label] = outcome
                    continuityOutcomesSeen[chain, default: []].insert(outcome)
                }
                for (u, l) in commits where level(l) == chain && held[chain]!.contains(l) {
                    attributedRuns[u] = attributed(u, at: l, in: tree) ?? "0"
                }
            }
            side["continuity"] = continuity
            // Keyed by committer: the attributed run it credits at its block.
            side["attributed"] = attributedRuns
            sides[chain.rawValue] = side
        }
        return sides
    }

    /// Merged grinds by the chains they are credited on, at their first
    /// blocks: `PCG`, `PC`, `CG`, `PG`.
    var mergedGrinds: [String: Int] {
        var chainsOf: [String: Set<Level>] = [:]
        for label in chains.flatMap({ labels[$0]! }) where !withheld.contains(label) {
            chainsOf[firstGrind[label]!, default: []].insert(level(label))
        }
        var counts: [String: Int] = [:]
        for set in chainsOf.values where set.count > 1 {
            counts[[Level.P, .C, .G].filter(set.contains).map(\.rawValue).joined(), default: 0] += 1
        }
        return counts
    }

    /// Ranks of all block CIDs, every chain, under the tree's own
    /// tie-break, 0 preferred. Only same-chain ranks are ever compared.
    var cidRanks: [String: Int] {
        let all = chains.flatMap { labels[$0]! }
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
                if lower(chain) != nil { block["postState"] = facts[label]!.postState }
                if chain != .P {
                    block["parentState"] = parentState[label]!
                    block["withheld"] = withheld.contains(label)
                }
                if levels == 3 {
                    block["headerBad"] = headerBad[label] ?? NSNull()
                    block["prevStateBlock"] = declaredPrevStateBlock[label] ?? NSNull()
                }
                return block
            }
        }
        var anchors: [String: Any] = [:]
        for chain in chains where chain != .P {
            for label in labels[chain]! { anchors[label] = anchor[label] ?? NSNull() }
        }
        var chainBlocks: [String: Any] = [:]
        for chain in chains { chainBlocks[chain.rawValue] = ["blocks": blocks(chain)] }
        var trace: [String: Any] = [
            "seed": seed,
            "emptyState": empty,
            "chains": chainBlocks,
            "commits": commits.map { [$0.u, $0.l] },
            "anchor": anchors,
            "grinds": chains.flatMap { labels[$0]! }.filter { !withheld.contains($0) }.map { label -> [String: Any] in
                ["label": firstGrind[label]!, "ch": level(label).rawValue, "block": label, "qty": initialQuantity[label]!]
            },
            "events": events,
        ]
        if levels == 3 { trace["levels"] = 3 }
        return try JSONSerialization.data(withJSONObject: trace, options: [.sortedKeys])
    }

    func checkSanity() {
        XCTAssertFalse(events.isEmpty, "seed \(seed)")
        XCTAssertEqual(unexpectedRefusals, [], "seed \(seed) levels \(levels)")
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
            for chain in chains {
                guard let weights = after[chain.rawValue]?["weights"] as? [String: String] else {
                    return XCTFail("seed \(seed): no \(chain) weights")
                }
                for (label, weight) in weights {
                    guard let value = UInt64(weight) else { return XCTFail("seed \(seed) \(label): \(weight)") }
                    XCTAssertGreaterThanOrEqual(value, initialQuantity[label]!, "seed \(seed) \(label)")
                }
            }
            for chain in chains where chain != .P {
                let continuity = after[chain.rawValue]?["continuity"] as? [String: String] ?? [:]
                XCTAssertTrue(continuity.values.allSatisfy { ["proven", "held", "invalid"].contains($0) }, "seed \(seed)")
            }
        }
        // A header-bad block is never validated, nor anything under it.
        for event in events where event["kind"] as? String == "validate" {
            let label = event["block"] as! String
            XCTAssertFalse(ancestry(label).contains { headerBad[$0] != nil }, "seed \(seed): validated \(label)")
        }
    }
}

/// Work as a decimal string. Trace work is a few small grinds, so it fits.
private func decimal(_ hexDigits: String) -> String {
    String(UInt64(hex(hexDigits), radix: 16)!)
}
