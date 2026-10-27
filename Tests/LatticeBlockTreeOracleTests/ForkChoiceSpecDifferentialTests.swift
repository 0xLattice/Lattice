import Foundation
import XCTest
import UInt256
import LatticePrimitives
import LatticePoW
@testable import LatticeBlockTree

/// The live block tree's incremental fork-choice state against a from-scratch
/// recomputation of spec §9.1-9.2, §9.4, §9.9 and §9.10, written here as plain
/// recursion over the accepted facts with exact arithmetic.
///
/// The stream is `OracleRun`'s (`BlockTreeOracleEquivalenceTests`): forks at
/// random depths, genesis forks, repeated and strengthening observations,
/// conflicting grind locations, children before parents, exclusions,
/// validations, work near `UInt256.max`, parent runs into a child chain, and
/// restarts. After every step it compares, for every block either chain
/// planned: `trueCumWork` (`forkChoiceWeight`), the held-subtree total
/// (`subtreeWeight`), `cumulativeWork`, possession, exclusion and execution;
/// the canonical path and tip against a naive GHOST descent; the act-on tip
/// against the naive validated descent; and the revision (§12.5.11): +1 for
/// each mutation the model accepts, unchanged for a duplicate or a refusal.
/// At the end of every seed the accepted fact sets are applied again to empty
/// trees in two other arrival orders, which must reach the identical state.
///
/// Seeds: `ForkChoiceSpecDifferentialTests.seeds`, plus
/// `LATTICE_SPEC_DIFF_SEEDS` more; `LATTICE_SPEC_DIFF_STEPS` steps per seed
/// (default 120). Replay one with `LATTICE_SPEC_DIFF_SEED`.
final class ForkChoiceSpecDifferentialTests: XCTestCase {
    /// 32: a run is credited only to a child block anchored at its
    /// committer's entering state, so fewer runs land, and 16 seeds no longer
    /// reach one past 256 bits.
    static let seeds: [UInt64] = Array(1...32)

    func testIncrementalForkChoiceMatchesSpecRecomputation() {
        let environment = ProcessInfo.processInfo.environment
        let steps = environment["LATTICE_SPEC_DIFF_STEPS"].flatMap(Int.init) ?? 120
        var seeds = Self.seeds
        if let seed = environment["LATTICE_SPEC_DIFF_SEED"].flatMap(UInt64.init) {
            seeds = [seed]
        } else if let more = environment["LATTICE_SPEC_DIFF_SEEDS"].flatMap(UInt64.init), more > 0 {
            let first = (seeds.max() ?? 0) + 1
            seeds += Array(first..<(first + more))
        }
        var coverage: [String: Int] = [:]
        for seed in seeds {
            let run = OracleRun(seed: seed)
            run.hugeWorkOnParent = true
            var differential = SpecDifferential(run: run)
            if let failure = differential.run(steps: steps) {
                XCTFail(failure)
                return
            }
            coverage.merge(differential.coverage, uniquingKeysWith: +)
        }
        print("spec differential coverage (\(seeds.count) seeds × \(steps) steps): "
            + coverage.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        // Each shape the spec singles out must actually occur, or the
        // comparison passes vacuously.
        if environment["LATTICE_SPEC_DIFF_SEED"] == nil {
            for shape in [
                "reorg", "equal-weight fork on the canonical descent", "genesis fork",
                "strengthened", "duplicate", "conflicting location refused",
                "orphan connected", "exclusion", "act-on ≠ canonical tip",
                "sum past 256 bits", "attributed run raised", "attributed run past 256 bits", "restart",
                "attributed run withheld: anchored elsewhere",
            ] {
                XCTAssertGreaterThan(coverage[shape] ?? 0, 0, "never exercised: \(shape)")
            }
        }
    }

    /// The model's own arithmetic and tie-break, against known values.
    func testSpecModelArithmetic() {
        let max = Exact(UInt256.max)
        XCTAssertEqual((max + max).hex, "1" + String(repeating: "f", count: 63) + "e")
        XCTAssertTrue(max < max + Exact(UInt256(UInt64(1))))
        XCTAssertEqual(((max + max) - max).hex, max.hex)
        var measure = SpecMeasure()
        measure.union(["a": Exact(UInt256(UInt64(3)))])
        measure.union(["a": Exact(UInt256(UInt64(5))), "b": Exact(UInt256(UInt64(1)))])
        measure.union(["a": Exact(UInt256(UInt64(4)))])
        XCTAssertEqual(measure.total.hex, "6")
    }
}

// MARK: - Exact arithmetic

/// An exact unsigned integer, little-endian 64-bit limbs with no trailing
/// zero: the model's own, so a bug in `WorkSum` cannot hide in both sides.
struct Exact: Comparable {
    private(set) var limbs: [UInt64]

    static let zero = Exact(limbs: [])

    init(limbs: [UInt64]) {
        self.limbs = limbs
        while self.limbs.last == 0 { self.limbs.removeLast() }
    }

    init(_ value: UInt256) {
        self.init(hexDigits: value.toHexString())
    }

    init(hexDigits: String) {
        var parsed: [UInt64] = []
        var end = hexDigits.endIndex
        while end > hexDigits.startIndex {
            let start = hexDigits.index(end, offsetBy: -16, limitedBy: hexDigits.startIndex) ?? hexDigits.startIndex
            parsed.append(UInt64(hexDigits[start..<end], radix: 16)!)
            end = start
        }
        self.init(limbs: parsed)
    }

    var fitsUInt256: Bool { limbs.count <= 4 }

    /// Minimal lowercase hex, as `hex(_:)` renders the live values.
    var hex: String {
        guard let top = limbs.last else { return "0" }
        return String(top, radix: 16) + limbs.dropLast().reversed().map {
            let digits = String($0, radix: 16)
            return String(repeating: "0", count: 16 - digits.count) + digits
        }.joined()
    }

    static func + (lhs: Exact, rhs: Exact) -> Exact {
        var result: [UInt64] = []
        var carry: UInt64 = 0
        for index in 0..<max(lhs.limbs.count, rhs.limbs.count) {
            let left = index < lhs.limbs.count ? lhs.limbs[index] : 0
            let right = index < rhs.limbs.count ? rhs.limbs[index] : 0
            let (partial, first) = left.addingReportingOverflow(right)
            let (sum, second) = partial.addingReportingOverflow(carry)
            result.append(sum)
            carry = (first ? 1 : 0) + (second ? 1 : 0)
        }
        result.append(carry)
        return Exact(limbs: result)
    }

    /// `lhs - rhs`, for `lhs >= rhs`.
    static func - (lhs: Exact, rhs: Exact) -> Exact {
        precondition(rhs <= lhs)
        var result: [UInt64] = []
        var borrow: UInt64 = 0
        for index in lhs.limbs.indices {
            let right = index < rhs.limbs.count ? rhs.limbs[index] : 0
            let (partial, first) = lhs.limbs[index].subtractingReportingOverflow(right)
            let (difference, second) = partial.subtractingReportingOverflow(borrow)
            result.append(difference)
            borrow = (first ? 1 : 0) + (second ? 1 : 0)
        }
        return Exact(limbs: result)
    }

    static func < (lhs: Exact, rhs: Exact) -> Bool {
        if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
        for index in lhs.limbs.indices.reversed() where lhs.limbs[index] != rhs.limbs[index] {
            return lhs.limbs[index] < rhs.limbs[index]
        }
        return false
    }
}

/// `WorkMeasure` (§9.1): root CID → quantity; union takes the maximum per
/// ID, and the total is the exact sum of the distinct values.
struct SpecMeasure {
    var entries: [String: Exact] = [:]

    mutating func union(_ other: [String: Exact]) {
        for (id, work) in other where entries[id].map({ $0 < work }) ?? true {
            entries[id] = work
        }
    }

    var total: Exact {
        entries.values.reduce(.zero, +)
    }
}

// MARK: - The spec model of one chain

/// One chain's accepted facts, and every derived quantity recomputed from
/// them on demand. Nothing here is cached across mutations.
struct SpecChain {
    struct Block {
        var hash: String
        var parent: String?
        var height: UInt64
        /// The header fields a repeated block fact must match.
        var snapshot: [String]
        var commitments: [String: String]
        var prevState: String
        /// The parent-chain state it anchors to (§9.10).
        var parentState: String
    }

    enum Verdict: Equatable {
        /// Refused; `missing` when only an absent block or a not-yet-executed
        /// other root stands in the way, which restore retries.
        case refused(missing: Bool)
        case unchanged
        case mutated
    }

    var blocks: [String: Block] = [:]
    /// The grinds credited at each block (§9.1: one location per grind).
    var grinds: [String: [String: Exact]] = [:]
    var grindLocation: [String: String] = [:]
    /// The attributed runs credited at each block (§9.10), derived.
    var attributed: [String: [String: Exact]] = [:]
    var excluded: Set<String> = []
    var validated: Set<String> = []

    static func standard(_ cid: String) -> String? {
        CIDIdentity.canonicalString(cid).flatMap { CIDIdentity.isStandard($0) ? $0 : nil }
    }

    var roots: [String] {
        blocks.values.filter { $0.parent == nil }.map(\.hash)
    }

    // MARK: The reducer

    /// Apply one batch: the §9.1 location rules, §9.3's atomic refusal and
    /// idempotent replay, and §9.9's exclusion and validation rules.
    /// `restoring` makes a root exclusion with no other executed root a
    /// retry rather than a refusal, as replay order must not matter.
    mutating func apply(_ batch: OracleBatch, restoring: Bool = false) -> Verdict {
        let facts = batch.facts
        // Execution is never revoked (§9.9): a validation of an excluded
        // block is refused, whatever else the batch carries.
        for case .validation(let hash) in facts {
            if let block = CIDIdentity.canonicalString(hash), excluded.contains(block) {
                return .refused(missing: false)
            }
        }
        if facts.count == 1, case .exclusion(let hash) = facts[0] {
            guard let block = CIDIdentity.canonicalString(hash), let held = blocks[block] else {
                return .refused(missing: true)
            }
            if excluded.contains(block) { return .unchanged }
            if validated.contains(block) { return .refused(missing: false) }
            if held.parent == nil, !roots.contains(where: { $0 != block && validated.contains($0) }) {
                return .refused(missing: restoring)
            }
            excluded.insert(block)
            return .mutated
        }
        if facts.count == 1, case .validation(let hash) = facts[0] {
            guard let block = CIDIdentity.canonicalString(hash), blocks[block] != nil else {
                return .refused(missing: true)
            }
            validated.insert(block)
            return .unchanged
        }

        var works: [(hash: String, grind: String, work: UInt256)] = []
        var blockFacts: [OracleBlockFact] = []
        var validations: [String] = []
        for fact in facts {
            switch fact {
            case .work(let hash, let grind, let work): works.append((hash, grind, work))
            case .block(let block): blockFacts.append(block)
            case .validation(let hash): validations.append(hash)
            case .exclusion: return .refused(missing: false)
            }
        }
        guard works.count == 1, blockFacts.count <= 1, works[0].work > .zero,
              let hash = Self.standard(works[0].hash),
              let grind = Self.standard(works[0].grind),
              validations.count <= 1,
              validations.allSatisfy({ CIDIdentity.canonicalString($0) == hash }) else {
            return .refused(missing: false)
        }
        let work = Exact(works[0].work)

        func credit() -> Verdict {
            if let location = grindLocation[grind], location != hash { return .refused(missing: false) }
            if let held = grinds[hash]?[grind], !(held < work) { return .unchanged }
            grinds[hash, default: [:]][grind] = work
            grindLocation[grind] = hash
            return .mutated
        }

        let verdict: Verdict
        if let fact = blockFacts.first {
            guard let block = Self.block(fact), block.hash == hash else { return .refused(missing: false) }
            if let held = blocks[hash] {
                guard held.parent == block.parent, held.height == block.height,
                      held.snapshot == block.snapshot else { return .refused(missing: false) }
                verdict = credit()
            } else {
                // A new block takes only a new grind (§9.1).
                if grindLocation[grind] != nil { return .refused(missing: false) }
                blocks[hash] = block
                verdict = credit()
            }
        } else {
            guard blocks[hash] != nil else { return .refused(missing: true) }
            verdict = credit()
        }
        if verdict != .refused(missing: false) {
            validated.formUnion(validations.compactMap(CIDIdentity.canonicalString))
        }
        return verdict
    }

    /// A block fact as the graph holds it, or nil when it is not a Lattice
    /// block (§3.1 standard links, positive targets, height 0 iff no parent).
    static func block(_ fact: OracleBlockFact) -> Block? {
        guard let hash = standard(fact.hash),
              let post = standard(fact.postState),
              let prev = standard(fact.prevState),
              let anchor = standard(fact.parentState ?? LatticeState.emptyHeader.rawCID),
              let spec = standard(fact.spec),
              (fact.childCommitments ?? [:]).values.allSatisfy(CIDIdentity.isStandard),
              let target = UInt256.fromHexDigits(fact.target), target > .zero,
              let next = UInt256.fromHexDigits(fact.nextTarget), next > .zero,
              (fact.parent == nil) == (fact.height == 0) else { return nil }
        var parent: String?
        if let named = fact.parent {
            guard let standardParent = standard(named) else { return nil }
            parent = standardParent
        }
        return Block(
            hash: hash, parent: parent, height: fact.height,
            snapshot: [post, prev, anchor, spec, Exact(target).hex, Exact(next).hex, "\(fact.timestamp)"],
            commitments: fact.childCommitments ?? [:],
            prevState: prev,
            parentState: anchor
        )
    }

    /// Restore (§9.3, §9.8): the fixed point of applying every batch, each
    /// retried while only a missing prerequisite blocks it. Nil when restore
    /// must refuse the log.
    static func restore(_ log: [OracleBatch]) -> SpecChain? {
        guard log.contains(where: { batch in
            batch.blockFact.flatMap(block).map { $0.parent == nil } ?? false
                && batch.facts.contains { if case .work = $0 { return true } else { return false } }
        }) else { return nil }
        var chain = SpecChain()
        var pending = log
        while !pending.isEmpty {
            var deferred: [OracleBatch] = []
            for batch in pending {
                switch chain.apply(batch, restoring: true) {
                case .refused(missing: true): deferred.append(batch)
                case .refused(missing: false): return nil
                default: break
                }
            }
            guard deferred.count < pending.count else { return nil }
            pending = deferred
        }
        return chain
    }

    // MARK: Derived quantities (§9.2)

    /// The parent edge a block's height admits. Every block the stream
    /// delivers to this model names its parent at the height above it.
    func parent(of hash: String) -> String? {
        guard let block = blocks[hash], let parent = block.parent, blocks[parent] != nil else { return nil }
        return parent
    }

    var children: [String: [String]] {
        var result: [String: [String]] = [:]
        for block in blocks.values {
            if let parent = parent(of: block.hash) { result[parent, default: []].append(block.hash) }
        }
        return result
    }

    /// Connected: a genesis root, or under a connected held parent.
    func isConnected(_ hash: String) -> Bool {
        var current = hash
        while let block = blocks[current] {
            guard let parentHash = block.parent else { return true }
            guard blocks[parentHash] != nil else { return false }
            current = parentHash
        }
        return false
    }

    /// `own(B)`: the grinds and attributed runs located at B.
    func own(_ hash: String) -> [String: Exact] {
        (grinds[hash] ?? [:]).merging(attributed[hash] ?? [:]) { max($0, $1) }
    }

    /// `effectiveSubtree(B)`, by plain recursion over the held children.
    func subtreeMeasure(_ hash: String, children: [String: [String]]) -> SpecMeasure {
        var measure = SpecMeasure()
        measure.union(own(hash))
        for child in children[hash] ?? [] {
            measure.union(subtreeMeasure(child, children: children).entries)
        }
        return measure
    }

    /// `prefix(B)`, up the held parent edges.
    func prefixMeasure(_ hash: String) -> SpecMeasure {
        var measure = SpecMeasure()
        var current: String? = hash
        while let block = current {
            measure.union(own(block))
            current = parent(of: block)
        }
        return measure
    }

    /// Every held block's `trueCumWork`.
    func trueCumWork() -> [String: Exact] {
        let children = children
        return Dictionary(uniqueKeysWithValues: blocks.keys.map {
            ($0, subtreeMeasure($0, children: children).total)
        })
    }

    /// §9.4: greatest work, then the smaller CID bytes.
    static func heaviest(_ candidates: [String], weights: [String: Exact]) -> String? {
        candidates.min { left, right in
            let l = weights[left]!, r = weights[right]!
            return l != r ? r < l : oracleBytesPrecede(left, right)
        }
    }

    /// The canonical path: from the heaviest root that is not excluded, at
    /// each fork the heaviest child that is not excluded (§9.4, §9.9).
    func canonicalPath(weights: [String: Exact], children: [String: [String]]) -> [String] {
        guard var current = Self.heaviest(roots.filter { !excluded.contains($0) }, weights: weights) else {
            return []
        }
        var path = [current]
        while let next = Self.heaviest(
            (children[current] ?? []).filter { !excluded.contains($0) }, weights: weights
        ) {
            path.append(next)
            current = next
        }
        return path
    }

    /// The act-on tip (§9.9): the same descent through validated blocks only,
    /// from the heaviest validated root; empty while none is validated.
    func actOnTip(weights: [String: Exact], children: [String: [String]]) -> String {
        guard var current = Self.heaviest(roots.filter { validated.contains($0) }, weights: weights) else {
            return ""
        }
        while let next = Self.heaviest(
            (children[current] ?? []).filter { validated.contains($0) }, weights: weights
        ) {
            current = next
        }
        return current
    }

    // MARK: Parent runs (§9.10)

    /// `nearestCarrier(Q, d)` for every connected block Q.
    func carriers(into directory: String) -> [String: String] {
        var result: [String: String] = [:]
        let children = children
        var stack = roots
        while let block = stack.popLast() {
            if blocks[block]!.commitments[directory] != nil {
                result[block] = block
            } else if let parent = parent(of: block), let carrier = result[parent] {
                result[block] = carrier
            }
            stack.append(contentsOf: children[block] ?? [])
        }
        return result
    }

    /// `attributed(C, P, d) = runWork(P, d) − grindWork(P)` for every
    /// carrier P whose committed C `child` holds and that anchors at P's
    /// entering state (`C.parentState == P.prevState`), keyed by C then by
    /// `AttributedRunIdentity(P, d)`: exact, however wide (§9.2).
    /// `withheld` counts the positive runs a mismatched anchor kept back.
    func attributions(
        into directory: String, child: SpecChain
    ) -> (values: [String: [String: Exact]], withheld: Int) {
        var runWork: [String: Exact] = [:]
        for (block, carrier) in carriers(into: directory) {
            runWork[carrier, default: .zero] = runWork[carrier, default: .zero] + SpecMeasure(entries: own(block)).total
        }
        var result: [String: [String: Exact]] = [:]
        var withheld = 0
        for (carrier, run) in runWork {
            guard let committed = blocks[carrier]?.commitments[directory],
                  let held = child.blocks[committed],
                  let id = AttributedRunIdentity(carrierBlockHash: carrier, directory: directory).contributionID
            else { continue }
            let value = run - SpecMeasure(entries: grinds[carrier] ?? [:]).total
            guard value > .zero else { continue }
            guard held.parentState == blocks[carrier]?.prevState else {
                withheld += 1
                continue
            }
            result[committed, default: [:]][id] = value
        }
        return (result, withheld)
    }
}

// MARK: - The differential driver

/// Drives `OracleRun`'s stream into one live world and the spec model, and
/// compares them after every step.
struct SpecDifferential {
    let run: OracleRun
    var model: [OracleSide: SpecChain] = [:]
    var coverage: [String: Int] = [:]
    /// Each chain's canonical path at the last comparison, for coverage.
    var lastPath: [OracleSide: [String]] = [:]

    init(run: OracleRun) {
        self.run = run
    }

    // MARK: Model steps

    /// Re-derive the child's attributed runs from the parent model; how many
    /// (carrier, child) values rose, or nil when one would have to fall.
    mutating func deriveRuns() -> Int? {
        var child = model[.child]!
        let (derived, withheld) = model[.parent]!.attributions(into: childDirectory, child: child)
        if withheld > 0 { coverage["attributed run withheld: anchored elsewhere", default: 0] += 1 }
        var raised = 0
        for (block, values) in child.attributed {
            for (id, old) in values where derived[block]?[id].map({ $0 < old }) ?? true {
                return nil
            }
        }
        for (block, values) in derived {
            for (id, value) in values where child.attributed[block]?[id].map({ $0 < value }) ?? true {
                raised += 1
            }
        }
        child.attributed = derived
        model[.child] = child
        return raised
    }

    /// Rebuild both models from the logs, as restore does; nil when restore
    /// must refuse either.
    mutating func restoreModels(parentLog: [OracleBatch], childLog: [OracleBatch]) -> Bool {
        guard let parent = SpecChain.restore(parentLog), let child = SpecChain.restore(childLog) else {
            return false
        }
        model = [.parent: parent, .child: child]
        return deriveRuns() != nil
    }

    // MARK: Live steps

    static func tree(_ world: OracleWorld<LiveSubject>, _ side: OracleSide) -> ChainTree {
        side == .parent ? world.parent.tree : world.child.tree
    }

    /// The step's live outcome: whether it threw, and the run derivation's
    /// raised count.
    static func apply(
        _ batch: OracleBatch, to side: OracleSide, reserved: Bool, in world: inout OracleWorld<LiveSubject>
    ) -> (threw: Bool, weighed: [String]) {
        let staged = LiveSubject.batch(batch)
        do {
            let result: SubmissionResult?
            if side == .parent {
                if reserved { precondition(world.parent.tree.reserveImportRevision()) }
                result = reserved
                    ? try world.parent.tree.applyReservedStaged(staged) : try world.parent.tree.apply(staged)
            } else {
                if reserved { precondition(world.child.tree.reserveImportRevision()) }
                result = reserved
                    ? try world.child.tree.applyReservedStaged(staged) : try world.child.tree.apply(staged)
            }
            return (false, result?.weighed ?? [])
        } catch {
            return (true, [])
        }
    }

    // MARK: The run

    mutating func run(steps: Int) -> String? {
        let run = self.run
        let parentGenesis = run.makeBlock(.parent, under: nil)
        let childGenesis = run.makeBlock(.child, under: nil)
        run.parentPlan.register(parentGenesis)
        run.childPlan.register(childGenesis)
        for (plan, batch) in [
            (run.parentPlan, run.newBlockBatch(.parent, block: parentGenesis)),
            (run.childPlan, run.newBlockBatch(.child, block: childGenesis)),
        ] {
            plan.sent.append(batch)
            plan.log.append(batch)
            plan.sentBlocks.insert(batch.blockFact!.hash)
        }
        var world = OracleWorld<LiveSubject>(
            parent: try! LiveSubject.restoreRoot(run.parentPlan.log, specs: run.specs).get(),
            child: try! LiveSubject.restoreRoot(run.childPlan.log, specs: run.specs).get()
        )
        // The child through the child path, under its served parent.
        guard run.perform(.restart(parentLog: run.parentPlan.log, childLog: run.childPlan.log), on: &world).restored,
              restoreModels(parentLog: run.parentPlan.log, childLog: run.childPlan.log) else {
            return "seed \(run.seed): the initial restore failed"
        }
        if let failure = compare(world, step: -1, revisions: nil) { return failure }

        for step in 0..<steps {
            let action = run.nextAction()
            run.history.append("\(step): \(run.describe(action))")
            var expected: [OracleSide: UInt64] = [:]
            let before: [OracleSide: UInt64] = [
                .parent: world.parent.tree.currentRevision(), .child: world.child.tree.currentRevision(),
            ]
            var applied: OracleOutcome?
            var restored = false
            switch action {
            case .apply(let side, let batch, let reserved):
                // A block at a height its parent cannot have is dropped by
                // header admission (§9.9) and never reaches this reducer.
                if let block = batch.blockFact, let hash = SpecChain.standard(block.hash),
                   run.plan(side).bad.contains(hash) {
                    continue
                }
                var chain = model[side]!
                let verdict = chain.apply(batch)
                let live = Self.apply(batch, to: side, reserved: reserved, in: &world)
                let refused: Bool
                if case .refused = verdict { refused = true } else { refused = false }
                if live.threw != refused {
                    return report(step: step, "apply: live \(live.threw ? "refused" : "accepted"), model \(verdict)")
                }
                applied = OracleOutcome(rendered: live.threw ? "throw:" : "applied")
                expected[side] = before[side]! + (verdict == .mutated ? 1 : 0)
                expected[side == .parent ? .child : .parent] = before[side == .parent ? .child : .parent]!
                tallyVerdict(verdict, batch: batch, chain: model[side]!)
                if !live.threw {
                    model[side] = chain
                    let afterApply = Self.tree(world, side).currentRevision()
                    if afterApply != expected[side]! {
                        return report(step: step, "revision after apply \(afterApply), expected \(expected[side]!)")
                    }
                    let derived = world.child.tree.applyParentRun(
                        from: world.parent.tree,
                        directory: childDirectory,
                        parentBlocks: side == .parent ? Set(live.weighed) : [],
                        held: side == .child ? Set(live.weighed) : []
                    )
                    guard let raised = deriveRuns() else {
                        return report(step: step, "an attributed run would fall")
                    }
                    if derived.raised.count != raised {
                        return report(step: step, "runs raised \(derived.raised.count), expected \(raised)")
                    }
                    if raised > 0 { coverage["attributed run raised", default: 0] += 1 }
                    expected[.child]! += UInt64(raised)
                }
            case .reevaluate(let side):
                // The projection is always current, so this changes nothing.
                let commit = side == .parent
                    ? world.parent.tree.reevaluateForkChoice() : world.child.tree.reevaluateForkChoice()
                if commit != nil { return report(step: step, "reevaluate moved the projection") }
                expected = before
            case .serve(let directory):
                world.parent.tree.serveRuns(for: directory)
                expected = before
            case .deriveAllRuns:
                let derived = world.child.tree.applyParentRun(from: world.parent.tree, directory: childDirectory)
                guard let raised = deriveRuns() else { return report(step: step, "an attributed run would fall") }
                if derived.raised.count != raised {
                    return report(step: step, "runs raised \(derived.raised.count), expected \(raised)")
                }
                expected = before
                expected[.child]! += UInt64(raised)
            case .restart(let parentLog, let childLog):
                var rebuilt = self
                let modelRestores = rebuilt.restoreModels(parentLog: parentLog, childLog: childLog)
                restored = run.perform(action, on: &world).restored
                if restored != modelRestores {
                    return report(step: step, "restore: live \(restored), model \(modelRestores)")
                }
                if restored {
                    model = rebuilt.model
                    lastPath = [:]
                    coverage["restart", default: 0] += 1
                } else {
                    expected = before
                }
            case .idle:
                expected = before
            }
            run.book(action, applied: applied, restored: restored)
            if let failure = compare(world, step: step, revisions: expected.isEmpty ? nil : expected) {
                return failure
            }
        }
        return checkOrderIndependence(world)
    }

    mutating func tallyVerdict(_ verdict: SpecChain.Verdict, batch: OracleBatch, chain: SpecChain) {
        switch verdict {
        case .refused(let missing):
            if !missing, batch.facts.count <= 2, case .work(let hash, let grind, _)? = batch.facts.last,
               let location = SpecChain.standard(grind).flatMap({ chain.grindLocation[$0] }),
               location != SpecChain.standard(hash) {
                coverage["conflicting location refused", default: 0] += 1
            }
        case .unchanged:
            coverage["duplicate", default: 0] += 1
        case .mutated:
            if batch.facts.count == 1, case .exclusion = batch.facts[0] {
                coverage["exclusion", default: 0] += 1
            } else if case .work(let hash, let grind, _)? = batch.facts.first(where: {
                if case .work = $0 { return true } else { return false }
            }), let held = SpecChain.standard(hash), let id = SpecChain.standard(grind),
                      chain.grinds[held]?[id] != nil {
                coverage["strengthened", default: 0] += 1
            } else if let block = batch.blockFact.flatMap(SpecChain.block) {
                if block.parent == nil { coverage["genesis fork", default: 0] += 1 }
                if chain.blocks.values.contains(where: { $0.parent == block.hash }) {
                    coverage["orphan connected", default: 0] += 1
                }
            }
        }
    }

    // MARK: Comparison

    /// Every derived quantity of both chains, live against the model.
    mutating func compare(
        _ world: OracleWorld<LiveSubject>, step: Int, revisions: [OracleSide: UInt64]?
    ) -> String? {
        for side in [OracleSide.parent, .child] {
            let tree = Self.tree(world, side)
            let chain = model[side]!
            let differences = Self.differences(tree, chain, plan: run.plan(side))
            if !differences.isEmpty {
                return report(step: step, differences.prefix(12).map { "\(side.rawValue) \($0)" }.joined(separator: "\n"))
            }
            if let expected = revisions?[side], tree.currentRevision() != expected {
                return report(step: step, "\(side.rawValue) revision \(tree.currentRevision()), expected \(expected)")
            }
            tallyShapes(side, chain)
        }
        return nil
    }

    static func differences(_ tree: ChainTree, _ chain: SpecChain, plan: ChainPlan) -> [String] {
        var differences: [String] = []
        func check(_ key: String, _ live: String, _ spec: String) {
            if live != spec { differences.append("\(key): live \(live), spec \(spec)") }
        }
        func render(_ work: WorkSum?) -> String { work.map { hex($0.toHexString()) } ?? "nil" }

        let children = chain.children
        let weights = chain.trueCumWork()
        for hash in plan.order {
            guard let held = SpecChain.standard(hash) else { continue }
            let key = "block \(held.suffix(8))"
            check("\(key) held", "\(tree.contains(blockHash: held))", "\(chain.blocks[held] != nil)")
            guard chain.blocks[held] != nil else { continue }
            let connected = chain.isConnected(held)
            check("\(key) trueCumWork", render(tree.forkChoiceWeight(of: held)),
                  connected ? weights[held]!.hex : "nil")
            check("\(key) subtreeWeight", render(tree.subtreeWeight(forHash: held)), weights[held]!.hex)
            check("\(key) cumulativeWork", render(tree.getCumulativeWork(forHash: held)),
                  chain.prefixMeasure(held).total.hex)
            check("\(key) excluded", "\(tree.isExcludedRoot(held))", "\(chain.excluded.contains(held))")
            check("\(key) executed", "\(tree.isExecuted(blockHash: held))", "\(chain.validated.contains(held))")
        }
        let path = chain.canonicalPath(weights: weights, children: children)
        check("canonical tip", tree.canonicalTip, path.last ?? "")
        for (height, hash) in path.enumerated() {
            check("canonical@\(height)", tree.canonicalBlockHash(atHeight: UInt64(height)) ?? "nil", hash)
        }
        check("canonical@\(path.count)", tree.canonicalBlockHash(atHeight: UInt64(path.count)) ?? "nil", "nil")
        check("tip cumulativeWork", render(tree.getTipCumulativeWork()),
              path.last.map { chain.prefixMeasure($0).total.hex } ?? "0")
        check("act-on tip", tree.heaviestExecutedTip(), chain.actOnTip(weights: weights, children: children))
        return differences
    }

    /// What the compared state contained, so a stream that stops reaching a
    /// shape fails the coverage assertion instead of passing vacuously.
    mutating func tallyShapes(_ side: OracleSide, _ chain: SpecChain) {
        let weights = chain.trueCumWork()
        let children = chain.children
        let path = chain.canonicalPath(weights: weights, children: children)
        if let last = lastPath[side], !Set(last).isSubset(of: path) {
            coverage["reorg", default: 0] += 1
        }
        lastPath[side] = path
        if weights.values.contains(where: { !$0.fitsUInt256 }) {
            coverage["sum past 256 bits", default: 0] += 1
        }
        if chain.attributed.values.contains(where: { $0.values.contains { !$0.fitsUInt256 } }) {
            coverage["attributed run past 256 bits", default: 0] += 1
        }
        if path.contains(where: { block in
            let selectable = (children[block] ?? []).filter { !chain.excluded.contains($0) }
            return Set(selectable.map { weights[$0]!.hex }).count < selectable.count
        }) {
            coverage["equal-weight fork on the canonical descent", default: 0] += 1
        }
        let actOn = chain.actOnTip(weights: weights, children: children)
        if !actOn.isEmpty, actOn != path.last { coverage["act-on ≠ canonical tip", default: 0] += 1 }
    }

    // MARK: Order independence

    /// The accepted fact sets, applied to empty trees one batch at a time in
    /// two other arrival orders (each refused batch retried until none can
    /// land), reach the state the run reached, and the model's.
    mutating func checkOrderIndependence(_ world: OracleWorld<LiveSubject>) -> String? {
        let reference = observation(world)
        for order in 0..<2 {
            var rng = SplitMix64(seed: run.seed &* 0x9E37_79B9 &+ UInt64(order))
            let parentLog = run.parentPlan.log.shuffled(using: &rng)
            let childLog = run.childPlan.log.shuffled(using: &rng)
            guard let parentGenesis = parentLog.first(where: { SpecChain.restore([$0]) != nil }),
                  let childGenesis = childLog.first(where: { SpecChain.restore([$0]) != nil }) else {
                return report(step: -1, "order \(order): a log holds no genesis")
            }
            var replayed = OracleWorld<LiveSubject>(
                parent: try! LiveSubject.restoreRoot([parentGenesis], specs: run.specs).get(),
                child: try! LiveSubject.restoreRoot([childGenesis], specs: run.specs).get()
            )
            for directory in run.served {
                replayed.parent.tree.serveRuns(for: directory)
            }
            for (side, log) in [(OracleSide.parent, parentLog), (.child, childLog)] {
                var pending = log
                while !pending.isEmpty {
                    var deferred: [OracleBatch] = []
                    for batch in pending {
                        let live = Self.apply(batch, to: side, reserved: false, in: &replayed)
                        if live.threw {
                            deferred.append(batch)
                        } else {
                            replayed.child.tree.applyParentRun(
                                from: replayed.parent.tree, directory: childDirectory,
                                parentBlocks: side == .parent ? Set(live.weighed) : [],
                                held: side == .child ? Set(live.weighed) : []
                            )
                        }
                    }
                    if deferred.count == pending.count {
                        return report(step: -1, "order \(order): \(side.rawValue) batches never land: \(deferred.count)")
                    }
                    pending = deferred
                }
            }
            let seen = observation(replayed)
            if seen != reference {
                let keys = Set(seen.keys).union(reference.keys).filter { seen[$0] != reference[$0] }.sorted()
                return report(step: -1, "order \(order) reached another state:\n" + keys.prefix(12).map {
                    "  \($0): run \(reference[$0] ?? "<absent>"), reordered \(seen[$0] ?? "<absent>")"
                }.joined(separator: "\n"))
            }
            for side in [OracleSide.parent, .child] {
                let differences = Self.differences(Self.tree(replayed, side), model[side]!, plan: run.plan(side))
                if !differences.isEmpty {
                    return report(step: -1, "order \(order) against the model:\n" + differences.prefix(12).joined(separator: "\n"))
                }
            }
            coverage["order independence checked", default: 0] += 1
        }
        return nil
    }

    /// Every consensus observable `LiveSubject` renders, the revision aside.
    func observation(_ world: OracleWorld<LiveSubject>) -> [String: String] {
        var result: [String: String] = [:]
        for side in [OracleSide.parent, .child] {
            var subject = side == .parent ? world.parent : world.child
            let seen = subject.observe(run.probe(side))
            for (key, value) in seen where key != "revision" {
                // The schedule spec under a disconnected block is provisional
                // (its root is not held) until its component grafts.
                if key.hasSuffix(" scheduleSpec"),
                   seen[String(key.dropLast(" scheduleSpec".count)) + " connected"] != "true" { continue }
                result["\(side.rawValue) \(key)"] = value
            }
        }
        return result
    }

    func report(step: Int, _ detail: String) -> String {
        ([
            "Fork-choice state diverged from the spec recomputation: seed \(run.seed), step \(step).",
            "Reproduce: LATTICE_SPEC_DIFF_SEED=\(run.seed) LATTICE_SPEC_DIFF_STEPS=\(max(step + 1, 1))"
                + " swift test --filter ForkChoiceSpecDifferentialTests",
            "Recent steps:",
        ] + run.history.suffix(8).map { "  \($0)" } + [detail]).joined(separator: "\n")
    }
}
