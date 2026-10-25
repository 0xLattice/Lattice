import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import UInt256
import cashew

/// A child block's parent anchor may only move forward along the parent's
/// history (§5.3 step 6): from its predecessor's anchor to a state the parent's
/// executed set produced at or below a block that produced it.
final class ParentAnchorMonotonicityTests: XCTestCase {
    private func batch(
        _ block: String, parent: String?, height: UInt64, from: String, to: String, nonce: Int64,
        executed: Bool = true
    ) -> BlockImportBatch {
        var facts: [ChainFact] = [
            .block(ChainBlockFact(
                blockHash: block, parentBlockHash: parent, blockHeight: height,
                postStateCID: to, prevStateCID: from, specCID: testCID("anchor-spec"),
                target: UInt256.max.toHexString(), nextTarget: UInt256.max.toHexString(),
                timestamp: nonce, stateDiff: .empty
            )),
            .work(ChainWorkFact(
                blockHash: block,
                contribution: VerifiedWorkContribution(id: testCID("anchor-grind-\(nonce)"), work: 1)
            )),
        ]
        if executed { facts.append(.validation(ChainValidationFact(blockHash: block))) }
        return BlockImportBatch(facts: facts)
    }

    private let a = testCID("state-a"), b = testCID("state-b"), c = testCID("state-c")
    private let d = testCID("state-d"), e = testCID("state-e"), f = testCID("state-f")
    private let g = testCID("state-g")
    private var empty: String { LatticeState.emptyHeader.rawCID }

    /// root (a→b) splits into left (b→c) → leftTip (c→e) and right (b→d) →
    /// rightTip (d→f); `e` is also produced on the right by rightTwin (d→e);
    /// weighed (f→g) is never executed.
    private func parentTree() throws -> ChainTree {
        let root = testCID("p-root"), left = testCID("p-left"), right = testCID("p-right")
        let rightTip = testCID("p-right-tip")
        return try ChainTree.restoreWithoutContext(replaying: [
            batch(root, parent: nil, height: 0, from: a, to: b, nonce: 1),
            batch(left, parent: root, height: 1, from: b, to: c, nonce: 2),
            batch(right, parent: root, height: 1, from: b, to: d, nonce: 3),
            batch(testCID("p-left-tip"), parent: left, height: 2, from: c, to: e, nonce: 4),
            batch(rightTip, parent: right, height: 2, from: d, to: f, nonce: 5),
            batch(testCID("p-right-twin"), parent: right, height: 2, from: d, to: e, nonce: 6),
            batch(testCID("p-weighed"), parent: rightTip, height: 3, from: f, to: g, nonce: 7, executed: false),
        ])
    }

    func testTheExecutedSetAdvancesOnlyForward() throws {
        let tree = try parentTree()
        XCTAssertTrue(tree.executedSetAdvanced(from: b, to: c), "forward one block")
        XCTAssertTrue(tree.executedSetAdvanced(from: b, to: f), "forward two blocks")
        XCTAssertTrue(tree.executedSetAdvanced(from: c, to: e), "forward on the left")
        XCTAssertTrue(tree.executedSetAdvanced(from: d, to: e), "a state produced on both branches counts on either")
        XCTAssertFalse(tree.executedSetAdvanced(from: c, to: d), "sideways")
        XCTAssertFalse(tree.executedSetAdvanced(from: c, to: f), "sideways, deeper")
        XCTAssertFalse(tree.executedSetAdvanced(from: f, to: b), "backward")
        XCTAssertTrue(tree.executedSetAdvanced(from: c, to: c), "an equal state the chain produced")
        XCTAssertTrue(tree.executedSetAdvanced(from: empty, to: d), "from the genesis pre-state")
        XCTAssertFalse(tree.executedSetAdvanced(from: g, to: g), "equality is no evidence for a state never executed")
        XCTAssertFalse(tree.executedSetAdvanced(from: f, to: g), "nor is a weighed block")
    }

    func testAdvancingDoesNotWalkTheDistance() throws {
        let depth = 2_000
        var batches: [BlockImportBatch] = []
        var previous: String?
        for height in 0..<depth {
            let block = testCID("deep-\(height)")
            batches.append(batch(
                block, parent: previous, height: UInt64(height),
                from: testCID("deep-state-\(height)"), to: testCID("deep-state-\(height + 1)"), nonce: Int64(height)
            ))
            previous = block
        }
        let tree = try ChainTree.restoreWithoutContext(replaying: batches)
        let before = tree.stateContinuityBlockVisitCount
        XCTAssertTrue(tree.executedSetAdvanced(from: testCID("deep-state-1"), to: testCID("deep-state-\(depth)")))
        XCTAssertFalse(tree.executedSetAdvanced(from: testCID("deep-state-\(depth)"), to: testCID("deep-state-1")))
        XCTAssertEqual(tree.stateContinuityBlockVisitCount, before, "an ancestry test, not a search")
    }

    // MARK: - Admission

    private func child(anchor: String, genesis: Bool = false, template: Block) -> Block {
        Block(
            version: template.version,
            parent: genesis ? nil : VolumeImpl<Block>(rawCID: testCID("child-predecessor")),
            transactions: template.transactions, target: template.target, nextTarget: template.nextTarget,
            spec: template.spec, parentState: LatticeStateHeader(rawCID: anchor),
            prevState: template.prevState, postState: template.postState, children: template.children,
            height: genesis ? 0 : 1, timestamp: template.timestamp, rewardRecipient: nil, nonce: 0
        )
    }

    func testAdmissionRefusesAnAnchorThatDoesNotMoveForward() async throws {
        let template = try await AdmissionFixture.makeGenesis(fetcher: StorableFetcher(), timestamp: 1_000)
        let facts: (any ParentChainFacts)? = ParentLevelFacts(tree: try parentTree(), path: [DEFAULT_ROOT_DIRECTORY])
        let lookup = BlockImport.parentFactLookup(facts)
        let context = testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        func verdict(_ predecessorAnchor: String?, _ anchor: String) -> BlockImportError? {
            let block = child(anchor: anchor, genesis: predecessorAnchor == nil, template: template)
            return BlockImport.validateParentFacts(
                lookup, child: block, childCID: testCID("child"),
                predecessorParentState: predecessorAnchor, context: context
            )
        }

        XCTAssertNil(verdict(nil, c), "a genesis anchors from the parent's genesis pre-state")
        XCTAssertNil(verdict(b, c), "forward")
        XCTAssertNil(verdict(c, c), "unchanged")
        // The attack: a withdrawal anchored on `c`, whose branch the parent
        // then abandoned for `d`, cannot be extended from the new branch.
        XCTAssertEqual(verdict(c, d), .crossChainEvidenceRequired(.parentStateContinuity(
            parentPath: [DEFAULT_ROOT_DIRECTORY], fromStateCID: c, toStateCID: d
        )))
        XCTAssertNotNil(verdict(f, b), "backward")
        XCTAssertNotNil(verdict(g, g), "an unexecuted anchor is not carried along by equality")
        // Committing no parent state is the genesis pre-state: dropping back
        // to it from a real anchor is backward, in the blocks' own bytes.
        XCTAssertEqual(verdict(c, empty), .protocolInvalid)
        XCTAssertNil(verdict(empty, empty), "no anchor yet, none now")
        XCTAssertEqual(verdict(nil, empty), .protocolInvalid, "a genesis must anchor")
    }

    // MARK: - The tour ancestry test

    func testTourAncestryMatchesTheBlockTree() {
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        var index = NamedEulerIndex.empty
        var parent: [String: String] = [:]
        var blocks: [String] = []
        for root in 0..<2 {
            let hash = "root-\(root)"
            XCTAssertTrue(index.insertRoot(hash))
            blocks.append(hash)
        }
        for i in 0..<300 {
            let hash = "block-\(i)"
            let under = blocks[next(blocks.count)]
            XCTAssertNotNil(index.insertLeaf(hash, under: under))
            parent[hash] = under
            blocks.append(hash)
        }
        func isAncestorOrSelf(_ ancestor: String, _ descendant: String) -> Bool {
            var cursor: String? = descendant
            while let block = cursor {
                if block == ancestor { return true }
                cursor = parent[block]
            }
            return false
        }
        for ancestor in blocks {
            for descendant in blocks {
                XCTAssertEqual(
                    index.encloses(ancestor, descendant), isAncestorOrSelf(ancestor, descendant),
                    "\(ancestor) encloses \(descendant)"
                )
            }
        }
        XCTAssertNil(index.encloses("root-0", "unrouted"))
    }
}
