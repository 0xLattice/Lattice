import XCTest
import UInt256
import cashew
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport

/// Credited work across chain depths.
///
/// A grind is priced by the ROOT-MOST carrier whose target its hash beat,
/// raised if greater by the terminal child's own target. The carriers are the
/// mined root plus every intermediate on the directory path; the terminal child
/// is NOT a carrier.
///
/// Every expectation here is computed by an independent oracle
/// (`expectedCredit`) that restates the rule over plain numbers, never by
/// calling the code under test. A test that asked `verifySecuringWork` what it
/// thought the answer was would agree with any bug it contained.
final class CreditLadderDepthTests: XCTestCase {

    private func ladderSpec() -> ChainSpec {
        ChainSpec.test()
    }

    /// Independent restatement of the rule. `targets` is ROOT-FIRST: index 0 is
    /// the mined root, the last element is the terminal child. Carriers are
    /// everything except the terminal.
    private func expectedCredit(
        targets: [UInt256],
        rootHash: UInt256
    ) -> UInt256 {
        let carriers = targets.dropLast()
        let ancestor = carriers.first { rootHash <= $0 }
            .map { workForTarget($0) } ?? UInt256.zero
        return max(ancestor, workForTarget(targets[targets.count - 1]))
    }

    /// What the OLD rule would have credited, for divergence assertions.
    private func oldMaxCredit(
        targets: [UInt256],
        rootHash: UInt256
    ) -> UInt256 {
        let ancestor = targets.dropLast()
            .filter { rootHash <= $0 }
            .map { workForTarget($0) }
            .max() ?? UInt256.zero
        return max(ancestor, workForTarget(targets[targets.count - 1]))
    }

    /// Build a ladder `root → d0 → d1 → … → terminal` and verify its securing
    /// work. `targets` is root-first and must have at least two entries (a root
    /// and a terminal). Directories are named `L0, L1, …`.
    private func ladder(
        targets: [UInt256],
        miningTarget: UInt256
    ) async throws -> (credit: UInt256, rootHash: UInt256, depth: Int) {
        precondition(targets.count >= 2, "a ladder needs a root and a terminal")
        let fetcher = StorableFetcher()
        let directories = (0..<(targets.count - 1)).map { "L\($0)" }

        // Build bottom-up: the terminal first, then each ancestor committing to
        // the block below it, root last.
        var below = try await buildAndStoreGenesis(
            spec: ladderSpec(),
            timestamp: 1_000,
            target: targets[targets.count - 1],
            nonce: 1,
            fetcher: fetcher
        )
        let terminal = below
        var built: [Block] = []
        for level in stride(from: targets.count - 2, through: 0, by: -1) {
            let block = try await buildAndStoreGenesis(
                spec: ladderSpec(),
                children: [directories[level]: below],
                timestamp: Int64(2_000 + level * 1_000),
                target: targets[level],
                nonce: UInt64(10 + level),
                fetcher: fetcher
            )
            built.append(block)
            below = block
        }
        let rootTemplate = below

        let root = try XCTUnwrap(
            BlockBuilder.mine(
                block: rootTemplate,
                target: miningTarget,
                maxAttempts: 2_000_000
            ),
            "fixture must find a grind under \(miningTarget)"
        )
        try await storeBuiltBlock(root, in: fetcher)

        // Compose the hops root → … → terminal. `built` is bottom-up, so the
        // ancestors above the root run in reverse.
        var proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: root),
            childDirectory: directories[0],
            fetcher: fetcher
        )
        for level in 1..<directories.count {
            // built[0] is the deepest intermediate; the carrier that commits
            // directories[level] is the block one step above it.
            let carrier = built[built.count - 1 - level]
            let hop = try await ChildBlockProof.generate(
                rootHeader: try BlockHeader(node: carrier),
                childDirectory: directories[level],
                fetcher: fetcher
            )
            proof = proof.composing(hop: hop)
        }

        let verification = proof.verifySecuringWork(
            child: terminal,
            chainPath: [DEFAULT_ROOT_DIRECTORY] + directories
        )
        guard case .success(let evidence) = verification,
              let contribution = evidence.contribution else {
            XCTFail("ladder of depth \(directories.count) failed to verify")
            return (.zero, .zero, directories.count)
        }
        return (contribution.work, root.proofOfWorkHash(), directories.count)
    }

    // MARK: - Depth 1: the rules are structurally identical

    /// At depth 1 there is exactly one carrier (the root), so "first met" and
    /// "max of met" cannot differ. Pinned so a future refactor cannot make the
    /// shallowest and commonest case depend on the selection at all.
    func testDepthOneHasASingleCarrierSoTheRulesCannotDiffer() async throws {
        for (root, terminal) in [
            (UInt256.max / UInt256(16), UInt256.max / UInt256(4)),
            (UInt256.max / UInt256(4), UInt256.max / UInt256(16)),
        ] {
            let targets = [root, terminal]
            // Mine to the hardest on the ladder: the TERMINAL target must
            // always be beaten or there is no contribution at all (below).
            let result = try await ladder(
                targets: targets, miningTarget: min(root, terminal)
            )
            XCTAssertEqual(result.depth, 1)
            XCTAssertEqual(
                result.credit,
                expectedCredit(targets: targets, rootHash: result.rootHash)
            )
            XCTAssertEqual(
                result.credit,
                oldMaxCredit(targets: targets, rootHash: result.rootHash),
                "depth 1 must price identically under both rules"
            )
        }
    }

    /// An unbeaten TERMINAL target yields no contribution at all, however much
    /// ancestor work the ladder carries. Discovered by a fixture that mined to
    /// an easy root above a harder terminal and produced nothing — the rule is
    /// real and worth pinning, since every other test here satisfies it by
    /// construction and so cannot observe it.
    func testUnbeatenTerminalTargetYieldsNoContribution() async throws {
        let fetcher = StorableFetcher()
        let terminal = try await buildAndStoreGenesis(
            spec: ladderSpec(),
            timestamp: 1_000,
            target: UInt256.max / UInt256(1024),   // terminal: very hard
            nonce: 1,
            fetcher: fetcher
        )
        let rootTemplate = try await buildAndStoreGenesis(
            spec: ladderSpec(),
            children: ["L0": terminal],
            timestamp: 2_000,
            target: UInt256.max / UInt256(4),      // root: easy
            nonce: 10,
            fetcher: fetcher
        )
        let root = try XCTUnwrap(
            BlockBuilder.mine(
                block: rootTemplate,
                target: UInt256.max / UInt256(4),
                maxAttempts: 2_000_000
            )
        )
        try await storeBuiltBlock(root, in: fetcher)
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: root),
            childDirectory: "L0",
            fetcher: fetcher
        )

        // Fixture guard: the root IS met, so a missing contribution can only be
        // the terminal check and not an unmet ancestor.
        XCTAssertLessThanOrEqual(root.proofOfWorkHash(), UInt256.max / UInt256(4))
        XCTAssertGreaterThan(
            root.proofOfWorkHash(), UInt256.max / UInt256(1024),
            "fixture must MISS the terminal target"
        )

        let verification = proof.verifySecuringWork(
            child: terminal,
            chainPath: [DEFAULT_ROOT_DIRECTORY, "L0"]
        )
        guard case .success(let evidence) = verification else {
            return XCTFail("the proof itself is well formed and must verify")
        }
        XCTAssertNil(
            evidence.contribution,
            """
            A grind that does not beat the terminal child's own target earns \
            that child no work, regardless of ancestor targets it did beat.
            """
        )
    }

    // MARK: - Depth 2

    func testDepthTwoEasingDownwardCreditsTheRoot() async throws {
        let targets = [
            UInt256.max / UInt256(16),   // root, hardest
            UInt256.max / UInt256(8),
            UInt256.max / UInt256(4),    // terminal, easiest
        ]
        let result = try await ladder(targets: targets, miningTarget: targets[0])
        XCTAssertEqual(result.credit, UInt256(16))
        XCTAssertEqual(
            result.credit,
            oldMaxCredit(targets: targets, rootHash: result.rootHash),
            "the ordinary shape must not be repriced"
        )
    }

    func testDepthTwoInvertedCreditsTheRootNotTheHarderIntermediate() async throws {
        let targets = [
            UInt256.max / UInt256(4),    // root, easy
            UInt256.max / UInt256(16),   // intermediate, HARDER
            UInt256.max / UInt256(8),    // terminal
        ]
        let result = try await ladder(targets: targets, miningTarget: targets[1])
        XCTAssertEqual(
            result.credit,
            expectedCredit(targets: targets, rootHash: result.rootHash)
        )
        XCTAssertLessThan(
            result.credit,
            oldMaxCredit(targets: targets, rootHash: result.rootHash),
            "an inverted ladder is exactly where the new rule credits LESS"
        )
    }

    // MARK: - Depth 3 — the shape review found uncovered

    /// Root unmet, so the selection SKIPS it; and the first met carrier is
    /// easier than a deeper met one, so "first met" and "max of met" disagree.
    /// This is the case a second reviewer named as having no coverage.
    func testDepthThreeUnmetRootSkipsToTheFirstMetNotTheHardest() async throws {
        let targets = [
            UInt256.max / UInt256(1024),  // root: far too hard, NOT met
            UInt256.max / UInt256(8),     // first met — easier
            UInt256.max / UInt256(64),    // deeper, HARDER, also met
            UInt256.max / UInt256(4),     // terminal
        ]
        let result = try await ladder(targets: targets, miningTarget: targets[2])
        XCTAssertEqual(result.depth, 3)
        XCTAssertGreaterThan(
            result.rootHash, targets[0],
            "fixture must MISS the root, or the skip branch is untested"
        )
        XCTAssertEqual(
            result.credit,
            expectedCredit(targets: targets, rootHash: result.rootHash)
        )
        XCTAssertEqual(
            result.credit, UInt256(8),
            "credit is the first MET carrier (8), not the harder deeper one (64)"
        )
        XCTAssertLessThan(
            result.credit,
            oldMaxCredit(targets: targets, rootHash: result.rootHash),
            "the old rule would have taken 64 here"
        )
    }

    /// No carrier is met at all: the ancestor term is zero and only the
    /// terminal's own target prices the grind. Guards the `?? .zero` fallback.
    func testNoMetCarrierCreditsOnlyTheTerminalTarget() async throws {
        let targets = [
            UInt256.max / UInt256(1024),
            UInt256.max / UInt256(512),
            UInt256.max / UInt256(4),    // terminal — the only thing met
        ]
        let result = try await ladder(targets: targets, miningTarget: targets[2])
        XCTAssertGreaterThan(result.rootHash, targets[1], "no carrier may be met")
        XCTAssertEqual(
            result.credit,
            expectedCredit(targets: targets, rootHash: result.rootHash)
        )
        XCTAssertEqual(result.credit, UInt256(4))
    }

    /// The terminal raise: a child harder than every ancestor sets its own
    /// price. Without the `max(..., workForTarget(child.target))` term this
    /// would credit the root's easier target.
    func testTerminalHarderThanEveryAncestorRaisesTheCredit() async throws {
        let targets = [
            UInt256.max / UInt256(4),
            UInt256.max / UInt256(8),
            UInt256.max / UInt256(64),   // terminal, hardest of all
        ]
        let result = try await ladder(targets: targets, miningTarget: targets[2])
        XCTAssertEqual(
            result.credit,
            expectedCredit(targets: targets, rootHash: result.rootHash)
        )
        XCTAssertEqual(
            result.credit, UInt256(64),
            "the terminal's own target must raise the credit above the root's 4"
        )
    }

    // MARK: - Matrix

    /// Sweep a matrix of ladder shapes at depths 1-3 and require the
    /// implementation to agree with the oracle on every one. This is the test
    /// that would catch a rule deviation the hand-written cases above miss.
    func testCreditMatchesTheOracleAcrossADepthMatrix() async throws {
        let easy = UInt256.max / UInt256(4)
        let mid = UInt256.max / UInt256(16)
        let hard = UInt256.max / UInt256(64)

        let ladders: [[UInt256]] = [
            [hard, easy],
            [easy, hard],
            [hard, mid, easy],
            [easy, mid, hard],
            [mid, hard, easy],
            [easy, hard, mid],
            [hard, easy, mid, easy],
            [mid, easy, hard, easy],
            [easy, easy, easy, hard],
        ]

        var divergences = 0
        for targets in ladders {
            // Mine to the hardest target on the ladder so several carriers are
            // met and the selection genuinely has to choose.
            let miningTarget = targets.min() ?? easy
            let result = try await ladder(
                targets: targets, miningTarget: miningTarget
            )
            let expected = expectedCredit(
                targets: targets, rootHash: result.rootHash
            )
            XCTAssertEqual(
                result.credit, expected,
                "ladder \(targets.map { workForTarget($0) }) credited \(result.credit), oracle says \(expected)"
            )
            let old = oldMaxCredit(targets: targets, rootHash: result.rootHash)
            XCTAssertLessThanOrEqual(
                result.credit, old,
                "the new rule must never credit MORE than the old one"
            )
            if result.credit != old { divergences += 1 }
        }

        XCTAssertGreaterThan(
            divergences, 0,
            """
            No ladder in the matrix diverged from the old rule, so this matrix \
            would pass unchanged against the old implementation and proves \
            nothing about the change.
            """
        )
    }
}
