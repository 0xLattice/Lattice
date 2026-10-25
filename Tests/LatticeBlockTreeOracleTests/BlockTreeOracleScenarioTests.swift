import XCTest
import UInt256
import LatticePrimitives
import LatticePoW

/// Scripted fact streams for the shapes a change to how blocks are held must
/// not move, each applied to the live tree and the frozen 50.0.1 reference
/// with every observable compared after every step. The random stream
/// (`BlockTreeOracleEquivalenceTests`) reaches these too, but by chance; here
/// each is reached on purpose.
final class BlockTreeOracleScenarioTests: XCTestCase {
    func testEqualWeightSiblings() {
        var script = Script("equal")
        let genesis = script.genesis()
        // Many equal-weight pairs, so both CID byte orders occur.
        for pair in 0..<6 {
            let a = script.block("a\(pair)", under: genesis)
            let b = script.block("b\(pair)", under: genesis)
            script.add(a, work: 5)
            script.add(b, work: 5)
        }
        script.check(self)
    }

    func testStrengthenedGrindOnALosingSiblingFlipsTheWinner() {
        var script = Script("flip")
        let genesis = script.genesis()
        let winner = script.block("winner", under: genesis)
        let loser = script.block("loser", under: genesis)
        script.add(winner, work: 9)
        let grind = script.add(loser, work: 3)
        let winnerChild = script.block("winner-child", under: winner)

        script.add(winnerChild, work: 1)
        script.strengthen(grind, at: loser, to: 20)
        script.strengthen(grind, at: loser, to: 19)  // weaker: refused
        script.check(self, tip: loser)
    }

    func testOneGrindAtASecondBlockIsRefused() {
        var script = Script("relocate")
        let genesis = script.genesis()
        let first = script.block("first", under: genesis)
        let second = script.block("second", under: genesis)
        let grind = script.add(first, work: 4)
        script.add(second, work: 2)
        // As work on a held block, and as a new block's first grind.
        script.strengthen(grind, at: second, to: 50)
        let third = script.block("third", under: genesis)

        script.add(third, grind: grind, work: 50)
        script.check(self, tip: first)
    }

    /// A header naming its parent under another codec (or as a CIDv0) names a
    /// different block, even with the parent's digest: it never connects.
    func testParentNamedUnderAnotherShapeNeverConnects() {
        for codec: UInt8? in [0x55, 0x70, nil] {
            var script = Script("twin-parent-\(codec.map(String.init) ?? "v0")")
            let genesis = script.genesis()
            let held = script.block("held", under: genesis)
            let twin = oracleCID(digest: oracleDigest(held.hash), codec: codec)
            let orphan = script.block("orphan", under: held, naming: twin)
            let below = script.block("below", under: orphan)
            script.add(held, work: 2)
            script.add(orphan, work: 50)
            script.add(below, work: 50)
            script.check(self, tip: held)
        }
    }

    /// Post- and prev-states under another codec, or as a CIDv0, are other
    /// states: continuity and the executed set never confuse them with the
    /// canonical state of the same digest.
    func testStatesUnderAnotherShapeAreOtherStates() {
        var script = Script("twin-state")
        let genesis = script.genesis()
        let rawTwin = oracleCID(digest: oracleDigest(genesis.postState), codec: 0x55)
        let v0Twin = oracleCID(digest: oracleDigest(genesis.postState), codec: nil)
        let a = script.block("a", under: genesis, post: rawTwin)
        let b = script.block("b", under: a, post: v0Twin)
        let c = script.block("c", under: b)
        script.add(a, work: 1)
        script.add(b, work: 1)
        script.add(c, work: 1)
        script.validate(genesis)
        script.validate(a)
        script.validate(b)
        script.restart(shuffled: true)
        script.check(self, tip: c)
    }

    /// A block hash and a grind ID are computed locally, so the live tree
    /// refuses a fact naming either in another shape (the reference, which
    /// keys by text, has no such rule: this is the one place they differ).
    func testANonCanonicalBlockHashOrGrindIsRefusedAtEntry() throws {
        var script = Script("refused")
        let genesis = script.genesis()
        guard let genesisBatch = script.genesisBatch else { return XCTFail("no genesis") }
        var live = try LiveSubject.restoreRoot([genesisBatch], specs: [script.spec]).get()
        var block = script.block("block", under: genesis)
        let canonicalHash = block.hash
        let grind = oracleCID("scenario-refused-grind")
        for codec: UInt8? in [0x55, 0x70, nil] {
            block.hash = oracleCID(digest: oracleDigest(canonicalHash), codec: codec)
            let outcome = live.apply(OracleBatch(facts: [
                .block(block), .work(blockHash: block.hash, grindID: grind, work: 5),
            ]), reserved: false)
            XCTAssertTrue(outcome.threw, "block hash \(block.hash): \(outcome.rendered)")
        }
        block.hash = canonicalHash
        let twinGrind = oracleCID(digest: oracleDigest(grind), codec: 0x55)
        let outcome = live.apply(OracleBatch(facts: [
            .block(block), .work(blockHash: block.hash, grindID: twinGrind, work: 5),
        ]), reserved: false)
        XCTAssertTrue(outcome.threw, "grind \(twinGrind): \(outcome.rendered)")
        XCTAssertEqual(live.observeTip()["tip"], genesis.hash)
    }

    func testOrphanComponentsGraftedLater() {
        var script = Script("graft")
        let genesis = script.genesis()
        let top = script.block("top", under: genesis)
        let middle = script.block("middle", under: top)
        let left = script.block("left", under: middle)
        let right = script.block("right", under: middle)
        let deep = script.block("deep", under: right)
        // Children first, then the block that connects them all.
        script.add(deep, work: 6)
        script.add(left, work: 2)
        script.add(right, work: 2)
        script.add(middle, work: 1)
        let rival = script.block("rival", under: genesis)

        script.add(rival, work: 8)
        script.validate(genesis)
        script.add(top, work: 1)
        script.check(self, tip: deep)
    }

    func testExcludedRootWithAnEqualWeightSibling() {
        var script = Script("exclude")
        let genesis = script.genesis()
        let a = script.block("a", under: genesis)
        let b = script.block("b", under: genesis)
        script.add(a, work: 7)
        script.add(b, work: 7)
        script.validate(genesis)
        let winner = script.tieWinner(a, b)
        script.exclude(winner)
        let after = script.block("after", under: winner)
        script.add(after, work: 1)
        script.check(self, tip: winner == a ? b : a)
    }

    func testMultipleGenesisRoots() {
        var script = Script("roots")
        let first = script.genesis()
        let second = script.root("second")
        let third = script.root("third")
        script.add(second, work: 30)
        script.add(third, work: 30)
        let onFirst = script.block("on-first", under: first)

        script.add(onFirst, work: 40)
        script.validate(first)
        script.exclude(second)  // another root is executed: allowed
        script.validate(third)
        script.exclude(third)  // executed: refused
        script.check(self, tip: onFirst)
    }

    /// `UInt256.max`-scale contributions on many blocks: every sum leaves
    /// 256 bits, on forks and on the canonical path.
    func testSumsPast256Bits() {
        var script = Script("huge")
        let genesis = script.genesis(work: .max)
        var tips = [genesis]
        for step in 0..<24 {
            let parent = tips[step % tips.count]
            let block = script.block("h\(step)", under: parent)
            script.add(block, work: UInt256.max - UInt256(UInt64(step)))
            script.add(block, work: .max)
            tips.append(block)
        }
        script.check(self)
    }

    func testSeveralAnchoredBlocksShareAPostState() {
        var script = Script("shared")
        let genesis = script.genesis()
        let shared = script.state(1)
        var producers: [OracleBlockFact] = []
        for index in 0..<4 {
            let block = script.block("p\(index)", under: genesis, post: shared)
            script.add(block, work: UInt256(UInt64(index + 1)))
            producers.append(block)
        }
        let next = script.block("next", under: producers[1], post: script.state(2))
        script.add(next, work: 1)
        let onward = script.block("onward", under: next, post: shared)
        script.add(onward, work: 1)
        script.validate(genesis)
        for block in producers.dropLast() { script.validate(block) }
        script.validate(next)
        script.check(self)
    }

    /// Restart from the same log in order and shuffled, at several points.
    func testRestoreFromShuffledAndOrderedLogs() {
        var script = Script("restore")
        let genesis = script.genesis()
        var parent = genesis
        for step in 0..<12 {
            let block = script.block("r\(step)", under: parent)
            let sibling = script.block("r\(step)-sibling", under: parent)
            let grind = script.add(block, work: UInt256(UInt64(step % 3 + 2)))
            script.add(sibling, work: UInt256(UInt64(step % 4 + 1)))
            if step % 3 == 0 { script.strengthen(grind, at: block, to: 9) }
            if step % 4 == 1 { script.validate(block) }
            script.restart(shuffled: step % 2 == 0)
            parent = block
        }
        script.check(self)
    }
}

// MARK: - The script

/// One chain's scripted stream, with what it has issued for the probe.
private struct Script {
    enum Step {
        case apply(OracleBatch)
        case restart(shuffled: Bool)
    }

    let name: String
    let spec = oracleSpec(targetBlockTime: 1_000)
    var steps: [Step] = []
    var genesisBatch: OracleBatch?
    var blocks: [OracleBlockFact] = []
    var grinds: [(id: String, hash: String)] = []
    var states: [String] = []

    init(_ name: String) {
        self.name = name
    }

    func state(_ index: Int) -> String {
        oracleCID("scenario-\(name)-state-\(index)")
    }

    mutating func root(_ label: String) -> OracleBlockFact {
        let block = OracleBlockFact(
            hash: oracleCID("scenario-\(name)-\(label)"), parent: nil, height: 0,
            postState: state(0), prevState: state(0), spec: specCID(spec),
            target: "ffff", nextTarget: "ffff", timestamp: 1_000, childCommitments: nil
        )
        blocks.append(block)
        return block
    }

    mutating func genesis(work: UInt256 = UInt256(1)) -> OracleBlockFact {
        let block = root("genesis")
        let grind = oracleCID("scenario-\(name)-grind-genesis")
        grinds.append((grind, block.hash))
        genesisBatch = OracleBatch(facts: [.block(block), .work(blockHash: block.hash, grindID: grind, work: work)])
        return block
    }

    /// A block under `parent`, its header naming the parent as `naming` when
    /// given (the parent's hash otherwise).
    mutating func block(
        _ label: String, under parent: OracleBlockFact, post: String? = nil, naming: String? = nil
    ) -> OracleBlockFact {
        let block = OracleBlockFact(
            hash: oracleCID("scenario-\(name)-\(label)"), parent: naming ?? parent.hash, height: parent.height + 1,
            postState: post ?? oracleCID("scenario-\(name)-post-\(label)"), prevState: parent.postState,
            spec: parent.spec, target: "ffff", nextTarget: "ffff",
            timestamp: parent.timestamp + 1_000, childCommitments: nil
        )
        blocks.append(block)
        return block
    }

    /// The block with its first grind, or another grind on a held block.
    @discardableResult
    mutating func add(_ block: OracleBlockFact, grind: String? = nil, work: UInt256) -> String {
        let id = grind ?? oracleCID("scenario-\(name)-grind-\(grinds.count)")
        grinds.append((id, block.hash))
        let first = !steps.contains {
            guard case .apply(let batch) = $0 else { return false }
            return batch.facts.contains(.block(block))
        }
        let workFact = OracleFact.work(blockHash: block.hash, grindID: id, work: work)
        steps.append(.apply(OracleBatch(facts: first ? [.block(block), workFact] : [workFact])))
        return id
    }

    mutating func strengthen(_ grind: String, at block: OracleBlockFact, to work: UInt256) {
        grinds.append((grind, block.hash))
        steps.append(.apply(OracleBatch(facts: [.work(blockHash: block.hash, grindID: grind, work: work)])))
    }

    mutating func validate(_ block: OracleBlockFact) {
        steps.append(.apply(OracleBatch(facts: [.validation(block.hash)])))
    }

    mutating func exclude(_ block: OracleBlockFact) {
        steps.append(.apply(OracleBatch(facts: [.exclusion(block.hash)])))
    }

    mutating func restart(shuffled: Bool) {
        steps.append(.restart(shuffled: shuffled))
    }

    /// The one of two equal-weight siblings the tie-break selects.
    func tieWinner(_ a: OracleBlockFact, _ b: OracleBlockFact) -> OracleBlockFact {
        oracleBytesPrecede(a.hash, b.hash) ? a : b
    }

    var probe: OracleProbe {
        OracleProbe(
            hashes: blocks.map(\.hash) + ["not-a-cid"],
            grinds: grinds,
            states: Array(Set(blocks.flatMap { [$0.postState, $0.prevState] })).sorted()
                + [LatticeState.emptyHeader.rawCID],
            directories: [],
            served: [],
            maxHeight: (blocks.map(\.height).max() ?? 0) + 1
        )
    }

    /// Run the script on both trees, comparing every observable after every
    /// step.
    func check(
        _ test: XCTestCase, tip: OracleBlockFact? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let genesisBatch else { return XCTFail("no genesis", file: file, line: line) }
        let specs = [spec]
        var live = try! LiveSubject.restoreRoot([genesisBatch], specs: specs).get()
        var reference = try! ReferenceSubject.restoreRoot([genesisBatch], specs: specs).get()
        var log = [genesisBatch]
        var rng = SplitMix64(seed: UInt64(name.utf8.count))
        func compare(_ step: Int) -> Bool {
            let seen = live.observe(probe), expected = reference.observe(probe)
            let keys = Set(seen.keys).union(expected.keys).filter { seen[$0] != expected[$0] }.sorted()
            guard keys.isEmpty else {
                XCTFail("\(name) step \(step): " + keys.prefix(6).map {
                    "\($0)\n  live:      \(seen[$0] ?? "<absent>")\n  reference: \(expected[$0] ?? "<absent>")"
                }.joined(separator: "\n"), file: file, line: line)
                return false
            }
            return true
        }
        guard compare(-1) else { return }
        for (index, step) in steps.enumerated() {
            switch step {
            case .apply(let batch):
                let outcome = live.apply(batch, reserved: false)
                let expected = reference.apply(batch, reserved: false)
                guard outcome == expected else {
                    return XCTFail("\(name) step \(index): \(outcome.rendered) vs \(expected.rendered)", file: file, line: line)
                }
                if !outcome.threw { log.append(batch) }
            case .restart(let shuffled):
                var replayed = log
                if shuffled { replayed.shuffle(using: &rng) }
                live = try! LiveSubject.restoreRoot(replayed, specs: specs).get()
                reference = try! ReferenceSubject.restoreRoot(replayed, specs: specs).get()
            }
            guard compare(index) else { return }
        }
        if let tip {
            XCTAssertEqual(live.observeTip()["tip"], tip.hash, "\(name): final tip", file: file, line: line)
        }
    }
}
