import XCTest
import UInt256
@testable import LatticeBlockTree

/// The act-on tip at the genesis fork (spec §9.4, §9.9): several genesis
/// roots are a fork like any other, so the descent starts at the heaviest
/// executed root that is not excluded — not only at the canonical root.
final class ActOnTipGenesisForkTests: XCTestCase {
    private let spec = oracleSpec(targetBlockTime: 1_000)
    private var facts: [String: OracleBlockFact] = [:]
    private var tree: ChainTree!

    private func hash(_ label: String) -> String { facts[label]!.hash }

    /// Admit `label` under `parent` (nil for a root) with `work` from its own grind.
    private func admit(_ label: String, under parent: String? = nil, work: UInt64) throws {
        let parentFact = parent.map { facts[$0]! }
        let rootState = oracleCID("genesis-fork-state-0")
        let fact = OracleBlockFact(
            hash: oracleCID("genesis-fork-\(label)"), parent: parentFact?.hash,
            height: parentFact.map { $0.height + 1 } ?? 0,
            postState: parentFact == nil ? rootState : oracleCID("genesis-fork-post-\(label)"),
            prevState: parentFact?.postState ?? rootState, spec: specCID(spec),
            target: "ffff", nextTarget: "ffff",
            timestamp: (parentFact?.timestamp ?? 0) + 1_000, childCommitments: nil
        )
        facts[label] = fact
        let batch = OracleBatch(facts: [
            .block(fact),
            .work(blockHash: fact.hash, grindID: oracleCID("genesis-fork-g-\(label)"), work: UInt256(work)),
        ])
        if tree == nil {
            tree = try LiveSubject.restoreRoot([batch], specs: [spec]).get().tree
        } else {
            let result = try tree.apply(LiveSubject.batch(batch))
            XCTAssertEqual(result.map { $0.addedBlock && $0.addedContribution }, true, "admit \(label)")
        }
    }

    private func validate(_ label: String) throws {
        _ = try tree.apply(LiveSubject.batch(OracleBatch(facts: [.validation(hash(label))])))
        XCTAssertTrue(tree.isExecuted(blockHash: hash(label)), "validate \(label)")
    }

    private func exclude(_ label: String) throws {
        _ = try tree.apply(LiveSubject.batch(OracleBatch(facts: [.exclusion(hash(label))])))
        XCTAssertTrue(tree.isExcludedRoot(hash(label)), "exclude \(label)")
    }

    /// A heavier root whose body is withheld weighs (it is canonical) but
    /// does not stall the act-on tip, which descends from the executed root.
    func testHeavierUnexecutedRootDoesNotStallActOnTip() throws {
        try admit("light", work: 1)
        try validate("light")
        try admit("a", under: "light", work: 1)
        try validate("a")
        try admit("heavy", work: 5)

        XCTAssertEqual(Set(tree.genesisRoots), [hash("light"), hash("heavy")])
        XCTAssertEqual(tree.canonicalTip, hash("heavy"))
        XCTAssertEqual(tree.heaviestExecutedTip(), hash("a"))

        // Once the heavier root executes, the act-on tip moves to it.
        try validate("heavy")
        XCTAssertEqual(tree.heaviestExecutedTip(), hash("heavy"))
    }

    /// No executed root: no act-on tip.
    func testNoExecutedRootHasNoActOnTip() throws {
        try admit("r1", work: 1)
        try admit("r2", work: 2)
        XCTAssertEqual(tree.heaviestExecutedTip(), "")
    }

    /// An excluded root is never the start, however heavy.
    func testExcludedRootIsNotTheStart() throws {
        try admit("light", work: 1)
        try validate("light")
        try admit("bad", work: 5)
        try exclude("bad")
        XCTAssertEqual(tree.heaviestExecutedTip(), hash("light"))
    }

    /// Avoiding the act-on root steps to the heaviest other executed root,
    /// as avoiding any other block steps to its parent's next child; with no
    /// other executed root the act-on tip stands.
    func testAvoidingARootStepsAtTheGenesisFork() throws {
        try admit("r1", work: 3)
        try validate("r1")
        try admit("r2", work: 1)
        try validate("r2")
        try admit("b", under: "r2", work: 1)
        try validate("b")
        try admit("r3", work: 9)

        XCTAssertEqual(tree.heaviestExecutedTip(), hash("r1"))
        XCTAssertEqual(tree.heaviestExecutedTip(avoiding: [hash("r1")]), hash("b"))
        XCTAssertEqual(tree.heaviestExecutedTip(avoiding: [hash("r1"), hash("r2")]), hash("r1"))
    }

    /// Avoiding the act-on root while it is not the canonical one: the
    /// descent moves to the next executed root.
    func testAvoidingANonCanonicalActOnRoot() throws {
        try admit("r1", work: 3)
        try validate("r1")
        try admit("r2", work: 1)
        try validate("r2")
        try admit("heavy", work: 9)

        XCTAssertEqual(tree.canonicalTip, hash("heavy"))
        XCTAssertEqual(tree.heaviestExecutedTip(), hash("r1"))
        XCTAssertEqual(tree.heaviestExecutedTip(avoiding: [hash("r1")]), hash("r2"))
    }

    /// Executed roots of equal weight: fork choice's CID tie-break decides.
    func testRootTieBreaksByCID() throws {
        try admit("t1", work: 2)
        try validate("t1")
        try admit("t2", work: 2)
        try validate("t2")
        try admit("heavy", work: 9)

        let preferred = forkChoicePrefersBlock(hash("t1"), over: hash("t2")) ? hash("t1") : hash("t2")
        XCTAssertEqual(tree.heaviestExecutedTip(), preferred)
    }
}
