import Foundation
import XCTest
import UInt256
import LatticePrimitives
import LatticePoW

/// The live block tree against the frozen 50.0.1 reference
/// (`LatticeBlockTreeReference`): seeded random fact streams over a parent
/// chain and a child chain it commits into, applied to both, with every
/// observable compared after every step.
///
/// Scale it locally with `LATTICE_ORACLE_SEEDS` (seed count, default 32) and
/// `LATTICE_ORACLE_STEPS` (steps per seed, default 100); replay one failing
/// seed with `LATTICE_ORACLE_SEED`.
final class BlockTreeOracleEquivalenceTests: XCTestCase {
    /// The stream's identity shapes are what it means them to be: each
    /// non-standard shape is a canonical spelling distinct from its
    /// digest-sharing siblings, and the upper-case spelling names the same key.
    func testStreamIdentityShapes() {
        let cid = oracleCID("oracle-shape")
        let digest = oracleDigest(cid)
        let shapes = [cid] + [UInt8(0x55), 0x70, nil].map { oracleCID(digest: digest, codec: $0) }
        XCTAssertEqual(Set(shapes).count, shapes.count)
        for shape in shapes {
            XCTAssertEqual(CIDIdentity.canonicalString(shape), shape)
        }
        XCTAssertNotEqual(upperCaseSpelling(cid), cid)
        XCTAssertEqual(CIDIdentity.canonicalString(upperCaseSpelling(cid)), cid)
        XCTAssertNil(CIDIdentity.canonicalString("not-a-cid"))
    }

    func testLiveBlockTreeMatchesFrozenReference() {
        let environment = ProcessInfo.processInfo.environment
        let steps = environment["LATTICE_ORACLE_STEPS"].flatMap(Int.init) ?? 100
        let seeds: [UInt64]
        if let seed = environment["LATTICE_ORACLE_SEED"].flatMap(UInt64.init) {
            seeds = [seed]
        } else {
            let count = environment["LATTICE_ORACLE_SEEDS"].flatMap(UInt64.init) ?? 32
            seeds = Array(1...max(count, 1))
        }
        var coverage: [String: Int] = [:]
        for seed in seeds {
            let run = OracleRun(seed: seed)
            if let failure = run.run(steps: steps) {
                XCTFail(failure)
            }
            coverage.merge(run.coverage, uniquingKeysWith: +)
        }
        // What the streams exercised, so a generator change that stops
        // reaching a path shows up in the log.
        print("oracle coverage (\(seeds.count) seeds × \(steps) steps): "
            + coverage.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        // The act-on queries compare equal trivially when the act-on tip is
        // always the best tip or no avoidance ever moves it; a stream that
        // stops reaching either fails here rather than passing vacuously.
        if environment["LATTICE_ORACLE_SEED"] == nil {
            XCTAssertGreaterThan(coverage["act-on ≠ best tip"] ?? 0, 0)
            XCTAssertGreaterThan(coverage["avoiding changed the answer"] ?? 0, 0)
        }
    }
}

// MARK: - The two worlds

/// One subject's parent chain and the child chain it commits into.
struct OracleWorld<Subject: OracleSubject> {
    var parent: Subject
    var child: Subject
}

enum OracleSide: String {
    case parent, child
}

enum OracleAction {
    case apply(OracleSide, OracleBatch, reserved: Bool)
    case reevaluate(OracleSide)
    case serve(String)
    case deriveAllRuns
    /// Restore both chains from these logs (a prefix of what was applied,
    /// possibly shuffled).
    case restart(parentLog: [OracleBatch], childLog: [OracleBatch])
    case idle
}

let childDirectory = "kid"
let otherDirectory = "other"

// MARK: - The stream

/// What the stream has planned and sent for one chain. Generation reads only
/// this and the RNG — never a tree — so both worlds see the same stream.
final class ChainPlan {
    var planned: [String: OracleBlockFact] = [:]
    var order: [String] = []
    var bad: Set<String> = []
    var sentBlocks: Set<String> = []
    var validationsSent: Set<String> = []
    var withheld: [OracleBatch] = []
    var sent: [OracleBatch] = []
    /// Batches applied without throwing: what a restart replays.
    var log: [OracleBatch] = []
    var grinds: [(id: String, hash: String)] = []
    var grindWork: [String: UInt256] = [:]

    func register(_ block: OracleBlockFact, bad isBad: Bool = false) {
        if planned[block.hash] == nil { order.append(block.hash) }
        planned[block.hash] = block
        if isBad { bad.insert(block.hash) }
    }
}

final class OracleRun {
    let seed: UInt64
    var rng: SplitMix64
    var counter = 0
    let parentPlan = ChainPlan()
    let childPlan = ChainPlan()
    var served: [String] = [childDirectory]
    let states: [String]
    let specs: [ChainSpec]
    let specCIDs: [String]
    let childContext = try! ChainRuntimeContext(path: [DEFAULT_ROOT_DIRECTORY, childDirectory])
    let foreignHash: String
    var history: [String] = []
    var mintedCIDs: Set<String> = []
    /// Decides which steps get the full observation, apart from the stream's
    /// RNG so the schedule never changes what is generated.
    var observationRNG: SplitMix64
    /// Counts of what the live outcomes showed.
    var coverage: [String: Int] = [:]
    /// Near-max work on the parent chain too. Off for the frozen-reference
    /// oracle (see `nextAction`); the spec differential turns it on.
    var hugeWorkOnParent = false

    init(seed: UInt64) {
        self.seed = seed
        rng = SplitMix64(seed: seed)
        observationRNG = SplitMix64(seed: seed ^ 0x0B5E_4FA7_10A5_0B5E)
        states = (0..<6).map { oracleCID("oracle-state-\($0)") }
        specs = [oracleSpec(targetBlockTime: 1_000), oracleSpec(targetBlockTime: 2_000)]
        specCIDs = specs.map(specCID)
        foreignHash = oracleCID("oracle-\(seed)-foreign")
    }

    func plan(_ side: OracleSide) -> ChainPlan {
        side == .parent ? parentPlan : childPlan
    }

    // MARK: Random helpers

    func int(_ bound: Int) -> Int { Int(rng.next() % UInt64(bound)) }
    func chance(_ percent: Int) -> Bool { int(100) < percent }
    func element<T>(_ values: [T]) -> T? { values.isEmpty ? nil : values[int(values.count)] }

    /// A new identity: a dag-cbor sha2-256 CIDv1, the only shape the tree
    /// holds (spec §3.1).
    func freshCID(_ tag: String) -> String {
        counter += 1
        let minted = oracleCID("oracle-\(seed)-\(tag)-\(counter)")
        mintedCIDs.insert(minted)
        return minted
    }

    /// `cid` under a shape that is not the standard CID: the same digest
    /// under another codec or as a CIDv0, or no CID at all.
    func nonStandard(_ cid: String) -> String {
        switch int(4) {
        case 0: oracleCID(digest: oracleDigest(cid), codec: 0x55)  // raw
        case 1: oracleCID(digest: oracleDigest(cid), codec: 0x70)  // dag-pb
        case 2: oracleCID(digest: oracleDigest(cid), codec: nil)  // CIDv0
        default: "not-a-cid-\(counter)"
        }
    }

    /// Sometimes a non-canonical spelling of the same CID: the tree must key
    /// it as the canonical one.
    func spell(_ cid: String) -> String {
        chance(5) ? upperCaseSpelling(cid) : cid
    }

    func spelled(_ batch: OracleBatch) -> OracleBatch {
        OracleBatch(facts: batch.facts.map { fact in
            switch fact {
            case .block(var block):
                block.hash = spell(block.hash)
                block.parent = block.parent.map(spell)
                block.postState = spell(block.postState)
                block.prevState = spell(block.prevState)
                block.parentState = block.parentState.map(spell)
                return .block(block)
            case .work(let hash, let grind, let work):
                return .work(blockHash: spell(hash), grindID: spell(grind), work: work)
            case .exclusion(let hash): return .exclusion(spell(hash))
            case .validation(let hash): return .validation(spell(hash))
            }
        })
    }

    /// Mostly tiny, so equal-work siblings and equal subtrees are common.
    func work() -> UInt256 {
        switch int(10) {
        case 0..<5: UInt256(UInt64(1 + int(4)))
        case 5..<8: UInt256(UInt64(1 + int(1_000)))
        default: UInt256(rng.next() | 1)
        }
    }

    /// Near the top of the range: a few of these on one path push every sum
    /// past 256 bits.
    func hugeWork() -> UInt256 {
        UInt256.max - UInt256(UInt64(int(1_000)))
    }

    func target() -> String {
        String(rng.next() % 0xFFFF_FFFF + 1, radix: 16)
    }

    // MARK: Blocks

    func makeBlock(_ side: OracleSide, under parent: OracleBlockFact?, height: UInt64? = nil) -> OracleBlockFact {
        let spec: String
        if let parent {
            // Mostly the parent's spec; sometimes a mismatch (the block an
            // execution would exclude).
            spec = chance(90) ? parent.spec : specCIDs[int(specCIDs.count)]
        } else {
            spec = specCIDs[int(specCIDs.count)]
        }
        // Mostly the parent's post-state; sometimes a state mismatch.
        let prevState = parent.flatMap { chance(85) ? $0.postState : nil } ?? states[int(states.count)]
        var commitments: [String: String]?
        var parentState: String?
        if side == .parent {
            if chance(25) {
                // Mostly a child block anchored at this block's entering state,
                // which takes its run; sometimes any, which may not (§9.10).
                let anchoredHere = childPlan.order.filter { childPlan.planned[$0]?.parentState == prevState }
                let committed = chance(85) ? element(anchoredHere) : nil
                commitments = [childDirectory: committed ?? element(childPlan.order) ?? foreignHash]
            }
            if chance(5) {
                commitments = (commitments ?? [:]).merging([otherDirectory: freshCID("other-child")]) { a, _ in a }
            }
        } else if parent != nil {
            // Anchored at some parent block's entering state, or any state.
            parentState = chance(80)
                ? element(parentPlan.order).flatMap { parentPlan.planned[$0]?.prevState }
                : states[int(states.count)]
        }
        let timestamp = (parent?.timestamp ?? 1_000_000) + Int64(int(2_000)) - 100
        return OracleBlockFact(
            hash: freshCID("\(side.rawValue)-block"),
            parent: parent?.hash,
            height: height ?? parent.map { $0.height + 1 } ?? 0,
            postState: states[int(states.count)],
            prevState: prevState,
            spec: spec,
            target: target(),
            nextTarget: target(),
            timestamp: timestamp,
            childCommitments: commitments,
            parentState: parentState
        )
    }

    func pickParent(_ plan: ChainPlan) -> OracleBlockFact? {
        let candidates = plan.order.filter { !plan.bad.contains($0) }
        let pool = chance(55) ? Array(candidates.suffix(6)) : candidates
        return element(pool).flatMap { plan.planned[$0] }
    }

    /// A new block with its first grind, and sometimes its validation.
    func newBlockBatch(
        _ side: OracleSide, block: OracleBlockFact, huge: Bool = false, amount fixed: UInt256? = nil
    ) -> OracleBatch {
        let plan = plan(side)
        let grind = freshCID("\(side.rawValue)-grind")
        let amount = fixed ?? (huge ? hugeWork() : work())
        plan.grinds.append((grind, block.hash))
        plan.grindWork[grind] = amount
        var facts: [OracleFact] = [.block(block), .work(blockHash: block.hash, grindID: grind, work: amount)]
        if chance(10) {
            facts.append(.validation(block.hash))
            plan.validationsSent.insert(block.hash)
        }
        return OracleBatch(facts: facts)
    }

    func send(_ side: OracleSide, _ unspelled: OracleBatch) -> OracleAction {
        let plan = plan(side)
        let batch = spelled(unspelled)
        plan.sent.append(batch)
        for case .block(let block) in batch.facts {
            plan.sentBlocks.insert(block.hash)
        }
        return .apply(side, batch, reserved: chance(5))
    }

    /// A block naming a non-standard link: refused at the tree's entry, so
    /// never booked. Applied unreserved: the reference adapter refuses it
    /// for the 50.0.1 tree, which has no such rule.
    func malformed(_ side: OracleSide, _ block: OracleBlockFact, amount: UInt256) -> OracleAction {
        .apply(side, OracleBatch(facts: [
            .block(block), .work(blockHash: block.hash, grindID: freshCID("grind"), work: amount),
        ]), reserved: false)
    }

    func deliverWithheld(_ side: OracleSide) -> OracleAction? {
        let plan = plan(side)
        guard !plan.withheld.isEmpty else { return nil }
        return send(side, plan.withheld.remove(at: int(plan.withheld.count)))
    }

    // MARK: The next step

    func nextAction() -> OracleAction {
        let side: OracleSide = chance(60) ? .parent : .child
        let plan = plan(side)
        let roll = int(100)
        switch roll {
        case 0..<12:
            // An equal-work sibling of a leaf: the tie-break, not the work,
            // picks between them.
            let parents = Set(plan.planned.values.compactMap(\.parent))
            let candidates = plan.order.filter {
                !plan.bad.contains($0) && !parents.contains($0) && plan.planned[$0]?.parent != nil
            }
            guard let siblingHash = element(Array(candidates.suffix(8))),
                  let sibling = plan.planned[siblingHash],
                  let parent = sibling.parent.flatMap({ plan.planned[$0] }),
                  let grind = plan.grinds.first(where: { $0.hash == siblingHash }),
                  let amount = plan.grindWork[grind.id] else { return .idle }
            var block = makeBlock(side, under: parent)
            if chance(35) {
                // A block naming its parent under another shape of the same
                // digest: not a Lattice block, refused at the tree's entry.
                block.parent = nonStandard(parent.hash)
                return malformed(side, block, amount: amount)
            } else if chance(60) {
                // A sibling whose CID text sorts against the other's the
                // opposite way to its bytes (about one pair in twenty-five):
                // only a byte-order tie-break picks the reference's block.
                for attempt in 0..<200 {
                    let candidate = oracleCID("oracle-\(seed)-inverted-\(counter)-\(attempt)")
                    if !mintedCIDs.contains(candidate),
                       (candidate < siblingHash) != oracleBytesPrecede(candidate, siblingHash) {
                        mintedCIDs.insert(candidate)
                        block.hash = candidate
                        break
                    }
                }
            }
            plan.register(block)
            return send(side, newBlockBatch(side, block: block, amount: amount))
        case 12..<30, 30..<38:
            // Extend a fork; from 30, withhold the new block and deliver an
            // earlier withheld one instead (children before parents).
            guard let parent = pickParent(plan) else { return .idle }
            let block = makeBlock(side, under: parent)
            plan.register(block)
            let batch = newBlockBatch(side, block: block)
            if roll >= 30 {
                plan.withheld.append(batch)
                return deliverWithheld(side) ?? .idle
            }
            return send(side, batch)
        case 38..<48:
            return deliverWithheld(side) ?? .idle
        case 48..<58:
            // Strengthen an existing grind: mostly upward, sometimes not.
            guard let grind = element(plan.grinds) else { return .idle }
            let old = plan.grindWork[grind.id] ?? .zero
            var amount: UInt256
            if chance(70) {
                let delta = work()
                amount = old > UInt256.max - delta ? UInt256.max : old + delta
            } else {
                amount = old > UInt256(UInt64(1)) && chance(50) ? old - UInt256(UInt64(1)) : old
            }
            if amount == .zero { amount = UInt256(UInt64(1)) }
            plan.grindWork[grind.id] = max(old, amount)
            var facts: [OracleFact] = [.work(blockHash: grind.hash, grindID: grind.id, work: amount)]
            if chance(15), let block = plan.planned[grind.hash] {
                facts.insert(.block(block), at: 0)
            }
            return send(side, OracleBatch(facts: facts))
        case 58..<64:
            // A second grind on a block, held or not.
            guard let hash = element(plan.order) else { return .idle }
            let grind = freshCID("\(side.rawValue)-grind")
            let amount = work()
            plan.grinds.append((grind, hash))
            plan.grindWork[grind] = amount
            return send(side, OracleBatch(facts: [.work(blockHash: hash, grindID: grind, work: amount)]))
        case 64..<66:
            // One grind at a second location: refused.
            guard let grind = element(plan.grinds), let hash = element(plan.order),
                  hash != grind.hash else { return .idle }
            if chance(50), let parent = pickParent(plan) {
                let block = makeBlock(side, under: parent)
                plan.register(block)
                return send(side, OracleBatch(facts: [
                    .block(block), .work(blockHash: block.hash, grindID: grind.id, work: work()),
                ]))
            }
            return send(side, OracleBatch(facts: [.work(blockHash: hash, grindID: grind.id, work: work())]))
        case 66..<72:
            guard let batch = element(plan.sent) else { return .idle }
            return send(side, batch)
        case 72..<82:
            let next = plan.order.first { plan.sentBlocks.contains($0) && !plan.validationsSent.contains($0) }
            guard let hash = chance(50) ? next ?? element(plan.order) : element(plan.order) else {
                return .idle
            }
            plan.validationsSent.insert(hash)
            return send(side, OracleBatch(facts: [.validation(hash)]))
        case 82..<87:
            let candidates = plan.order.filter { plan.sentBlocks.contains($0) }
            let unvalidated = candidates.filter { !plan.validationsSent.contains($0) }
            guard let hash = element(chance(80) && !unvalidated.isEmpty ? unvalidated : candidates) else {
                return .idle
            }
            return send(side, OracleBatch(facts: [.exclusion(hash)]))
        case 87..<90:
            // A child whose parent has not arrived, at a height its parent can
            // never connect.
            let absent = plan.order.filter { !plan.sentBlocks.contains($0) && !plan.bad.contains($0) }
            guard let parentHash = element(absent), let parent = plan.planned[parentHash] else {
                return .idle
            }
            let block = makeBlock(side, under: parent, height: parent.height + 2)
            plan.register(block, bad: true)
            return send(side, newBlockBatch(side, block: block))
        case 90..<92:
            let root = makeBlock(side, under: nil)
            plan.register(root)
            return send(side, newBlockBatch(side, block: root))
        case 92..<95:
            guard let parent = pickParent(plan) else { return .idle }
            let block = makeBlock(side, under: parent)
            plan.register(block)
            // Near-max work on the child only: two such parent grinds in one
            // run make an attributed run past 256 bits, which 50.0.1 skipped
            // and §9.2 credits exactly, so the oracles would rightly differ.
            return send(side, newBlockBatch(side, block: block, huge: side == .child || hugeWorkOnParent))
        case 95:
            // Malformed: zero work, a parented height-0 block, a block named
            // by something that is not a CID, or a block naming a state,
            // spec or child that is not the standard CID.
            guard let parent = pickParent(plan) else { return .idle }
            if chance(40) {
                var block = makeBlock(side, under: parent)
                switch int(4) {
                case 0: block.postState = nonStandard(block.postState)
                case 1: block.prevState = nonStandard(block.prevState)
                case 2: block.spec = nonStandard(block.spec)
                default:
                    block.childCommitments = [childDirectory: nonStandard(element(childPlan.order) ?? foreignHash)]
                }
                return malformed(side, block, amount: work())
            }
            if chance(33) {
                var block = makeBlock(side, under: parent)
                block.hash = "not-a-cid-\(counter)"
                return .apply(side, OracleBatch(facts: [
                    .block(block), .work(blockHash: block.hash, grindID: freshCID("grind"), work: work()),
                ]), reserved: false)
            }
            if chance(50) {
                let block = makeBlock(side, under: parent)
                return send(side, OracleBatch(facts: [
                    .block(block), .work(blockHash: block.hash, grindID: freshCID("zero"), work: .zero),
                ]))
            }
            let block = makeBlock(side, under: parent, height: 0)
            return send(side, OracleBatch(facts: [
                .block(block), .work(blockHash: block.hash, grindID: freshCID("grind"), work: work()),
            ]))
        case 96:
            return chance(50) ? .reevaluate(side) : .deriveAllRuns
        case 97:
            if !served.contains(otherDirectory) {
                return .serve(otherDirectory)
            }
            return .deriveAllRuns
        default:
            // Restart: replay all of each log, or a prefix (the tail lost),
            // in order or shuffled.
            func replayed(_ log: [OracleBatch]) -> [OracleBatch] {
                var kept = chance(30) ? Array(log.prefix(1 + int(log.count))) : log
                if chance(50) {
                    kept.shuffle(using: &rng)
                }
                return kept
            }
            return .restart(parentLog: replayed(parentPlan.log), childLog: replayed(childPlan.log))
        }
    }

    // MARK: Performing a step on one world

    /// Rendered outcomes, and the outcome of an `.apply` for bookkeeping.
    func perform<Subject: OracleSubject>(
        _ action: OracleAction,
        on world: inout OracleWorld<Subject>
    ) -> (lines: [String], applied: OracleOutcome?, restored: Bool) {
        switch action {
        case .idle:
            return ([], nil, false)
        case .apply(let side, let batch, let reserved):
            let outcome: OracleOutcome
            if side == .parent {
                outcome = world.parent.apply(batch, reserved: reserved)
            } else {
                outcome = world.child.apply(batch, reserved: reserved)
            }
            var lines = ["apply \(outcome.rendered)"]
            if !outcome.threw {
                let derived = world.child.applyParentRun(
                    from: world.parent,
                    directory: childDirectory,
                    parentBlocks: side == .parent ? Set(outcome.weighed) : [],
                    held: side == .child ? Set(outcome.weighed) : []
                )
                lines.append("runs \(derived.rendered)")
            }
            return (lines, outcome, false)
        case .reevaluate(let side):
            let outcome = side == .parent ? world.parent.reevaluate() : world.child.reevaluate()
            return (["reevaluate \(outcome.rendered)"], nil, false)
        case .serve(let directory):
            world.parent.serveRuns(directory)
            return ([], nil, false)
        case .deriveAllRuns:
            let derived = world.child.applyParentRun(
                from: world.parent, directory: childDirectory, parentBlocks: nil, held: []
            )
            return (["runs \(derived.rendered)"], nil, false)
        case .restart(let parentLog, let childLog):
            switch Subject.restoreRoot(parentLog, specs: specs) {
            case .failure(let failure):
                return (["restore parent failed: \(failure.text)"], nil, false)
            case .success(var parent):
                for directory in served {
                    parent.serveRuns(directory)
                }
                switch Subject.restoreChild(childLog, context: childContext, specs: specs, parent: parent) {
                case .failure(let failure):
                    return (["restore child failed: \(failure.text)"], nil, false)
                case .success(let child):
                    world = OracleWorld(parent: parent, child: child)
                    return (["restored"], nil, true)
                }
            }
        }
    }

    func probe(_ side: OracleSide) -> OracleProbe {
        let plan = plan(side)
        return OracleProbe(
            hashes: plan.order + [foreignHash, "not-a-cid"],
            grinds: plan.grinds,
            states: states + [LatticeState.emptyHeader.rawCID, "not-a-cid"],
            directories: [childDirectory, otherDirectory],
            served: served,
            maxHeight: (plan.planned.values.map(\.height).max() ?? 0) + 1
        )
    }

    func observe<Subject: OracleSubject>(_ world: inout OracleWorld<Subject>) -> [OracleSide: [String: String]] {
        [.parent: world.parent.observe(probe(.parent)), .child: world.child.observe(probe(.child))]
    }

    func observeTip<Subject: OracleSubject>(_ world: inout OracleWorld<Subject>) -> [OracleSide: [String: String]] {
        [.parent: world.parent.observeTip(), .child: world.child.observeTip()]
    }

    func describe(_ action: OracleAction) -> String {
        func fact(_ fact: OracleFact) -> String {
            switch fact {
            case .block(let block):
                "block(\(block.hash.suffix(8)) ← \(block.parent.map { String($0.suffix(8)) } ?? "nil") h\(block.height))"
            case .work(let hash, let grind, let work):
                "work(\(hash.suffix(8)) \(grind.suffix(8))=\(work.toHexString().drop { $0 == "0" }))"
            case .exclusion(let hash): "exclusion(\(hash.suffix(8)))"
            case .validation(let hash): "validation(\(hash.suffix(8)))"
            }
        }
        switch action {
        case .idle: return "idle"
        case .apply(let side, let batch, let reserved):
            return "\(side.rawValue)\(reserved ? " reserved" : "") [\(batch.facts.map(fact).joined(separator: ", "))]"
        case .reevaluate(let side): return "reevaluate \(side.rawValue)"
        case .serve(let directory): return "serve \(directory)"
        case .deriveAllRuns: return "derive all runs"
        case .restart(let parentLog, let childLog):
            return "restart parent=\(parentLog.count) child=\(childLog.count)"
        }
    }

    // MARK: The run

    /// Nil when the two trees agreed at every step; otherwise the first
    /// disagreement, with the seed that reproduces it.
    func run(steps: Int) -> String? {
        let parentGenesis = makeBlock(.parent, under: nil)
        let childGenesis = makeBlock(.child, under: nil)
        parentPlan.register(parentGenesis)
        childPlan.register(childGenesis)
        let parentGenesisBatch = newBlockBatch(.parent, block: parentGenesis)
        let childGenesisBatch = newBlockBatch(.child, block: childGenesis)
        for (plan, batch) in [(parentPlan, parentGenesisBatch), (childPlan, childGenesisBatch)] {
            plan.sent.append(batch)
            plan.log.append(batch)
            plan.sentBlocks.insert(batch.blockFact!.hash)
        }
        var live = OracleWorld<LiveSubject>(
            parent: try! LiveSubject.restoreRoot([parentGenesisBatch], specs: specs).get(),
            child: try! LiveSubject.restoreRoot([childGenesisBatch], specs: specs).get()
        )
        var reference = OracleWorld<ReferenceSubject>(
            parent: try! ReferenceSubject.restoreRoot([parentGenesisBatch], specs: specs).get(),
            child: try! ReferenceSubject.restoreRoot([childGenesisBatch], specs: specs).get()
        )
        // The child through the child path, under its served parent.
        let start = OracleAction.restart(parentLog: parentPlan.log, childLog: childPlan.log)
        _ = perform(start, on: &live)
        _ = perform(start, on: &reference)

        for step in 0..<steps {
            let action = nextAction()
            history.append("\(step): \(describe(action))")
            let liveResult = perform(action, on: &live)
            let referenceResult = perform(action, on: &reference)
            if liveResult.lines != referenceResult.lines {
                return report(step: step, differences: [(
                    "outcome", liveResult.lines.joined(separator: "\n"),
                    referenceResult.lines.joined(separator: "\n")
                )])
            }
            book(action, applied: liveResult.applied, restored: liveResult.restored)
            tally(liveResult.lines)

            // Full observation reads caches into being, so it runs on about
            // one step in four (and the last); the rest compare the tip and
            // revision alone, letting a stale cache ride several mutations.
            let full = observationRNG.next() % 4 == 0 || step == steps - 1
            if full { coverage["fully observed steps", default: 0] += 1 }
            let liveSeen = full ? observe(&live) : observeTip(&live)
            let referenceSeen = full ? observe(&reference) : observeTip(&reference)
            for side in [OracleSide.parent, .child] {
                var live = liveSeen[side] ?? [:], reference = referenceSeen[side] ?? [:]
                // `cumulativeWork` is not compared for a block whose parent is
                // held but never recorded it as a child (it arrived first, at a
                // height the parent cannot have, so it can never connect):
                // 50.0.1 gave it a cache-timing-dependent value — zero, or
                // whatever it held when last read as a root. The live walk
                // answers it deterministically. An orphan whose parent is not
                // held is compared like any block.
                for key in live.keys where key.hasSuffix(" cumulativeWork") {
                    let hash = String(key.dropFirst("block ".count).dropLast(" cumulativeWork".count))
                    if Self.isUnlinked(hash, in: live) {
                        live[key] = nil
                        reference[key] = nil
                    }
                }
                if full {
                    let tips = live["heaviestExecutedTip"]?.split(separator: ",", omittingEmptySubsequences: false) ?? []
                    let actOn = tips.first.map(String.init) ?? ""
                    if actOn != live["tip"] {
                        coverage["act-on ≠ best tip", default: 0] += 1
                    }
                    if live.contains(where: { $0.key.hasSuffix(" heaviestExecutedTip avoiding") && $0.value != actOn }) {
                        coverage["avoiding changed the answer", default: 0] += 1
                    }
                }
                if (live["tipCumulativeWork"]?.count ?? 0) > 64 {
                    coverage["steps with a \(side.rawValue) sum past 256 bits", default: 0] += 1
                }
                guard live != reference else { continue }
                let keys = Set(live.keys).union(reference.keys)
                    .filter { live[$0] != reference[$0] }
                    .sorted()
                return report(step: step, differences: keys.map {
                    ("\(side.rawValue) \($0)", live[$0] ?? "<absent>", reference[$0] ?? "<absent>")
                })
            }
        }
        return nil
    }

    /// Whether `hash` names a parent that is held but does not list it as a
    /// child, read from the observed graph keys.
    static func isUnlinked(_ hash: String, in seen: [String: String]) -> Bool {
        guard let graph = seen["block \(hash) graph"],
              let start = graph.range(of: "parent=") else { return false }
        let parent = String(graph[start.upperBound...].prefix { $0 != " " })
        guard seen["block \(parent) contains"] == "true",
              let parentGraph = seen["block \(parent) graph"],
              let children = parentGraph.range(of: "children=") else { return false }
        return !parentGraph[children.upperBound...].split(separator: ",").contains { $0 == hash }
    }

    func tally(_ lines: [String]) {
        for line in lines {
            if line.hasPrefix("apply throw:") {
                coverage["throw " + line.dropFirst("apply throw:".count), default: 0] += 1
            } else if line.hasPrefix("apply ") {
                coverage["applied", default: 0] += 1
            }
            if line.range(of: "removed=[^ ]", options: .regularExpression) != nil {
                coverage["reorg", default: 0] += 1
            }
            if line.range(of: "^runs raised=[^ ]", options: .regularExpression) != nil {
                coverage["attributed run raised", default: 0] += 1
            }
            if line == "restored" { coverage["restart", default: 0] += 1 }
            if line.hasPrefix("restore "), line != "restored" { coverage["restart refused", default: 0] += 1 }
        }
    }

    /// Track what the live world accepted, for later restarts.
    func book(_ action: OracleAction, applied: OracleOutcome?, restored: Bool) {
        switch action {
        case .apply(let side, let batch, _):
            if let applied, !applied.threw {
                plan(side).log.append(batch)
            }
        case .serve(let directory):
            served.append(directory)
        case .restart(let parentLog, let childLog):
            guard restored else { return }
            for (plan, kept) in [(parentPlan, parentLog), (childPlan, childLog)] {
                // What the restart lost can arrive again.
                var remaining = kept
                for batch in plan.log {
                    if let index = remaining.firstIndex(of: batch) {
                        remaining.remove(at: index)
                    } else {
                        plan.withheld.append(batch)
                    }
                }
                plan.log = kept
            }
        default:
            break
        }
    }

    func report(step: Int, differences: [(String, String, String)]) -> String {
        var lines = [
            "Block tree diverged from the frozen 50.0.1 reference: seed \(seed), step \(step).",
            "Reproduce: LATTICE_ORACLE_SEED=\(seed) LATTICE_ORACLE_STEPS=\(step + 1) swift test --filter BlockTreeOracleEquivalenceTests",
            "Recent steps:",
        ]
        lines += history.suffix(8).map { "  \($0)" }
        lines.append("\(differences.count) difference(s):")
        for (key, live, reference) in differences.prefix(12) {
            lines.append("  \(key)\n    live:      \(live)\n    reference: \(reference)")
        }
        return lines.joined(separator: "\n")
    }
}

extension OracleBatch {
    var blockFact: OracleBlockFact? {
        for case .block(let block) in facts { return block }
        return nil
    }
}
