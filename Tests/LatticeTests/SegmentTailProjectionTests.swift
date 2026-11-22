import XCTest
import UInt256
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport

@MainActor
final class SegmentTailProjectionTests: XCTestCase {
    func testCanonicalUnaryTailAppendAvoidsFullProjectionAndEmitsLeafDelta() async throws {
        let root = segmentTailBlock(name: "append-root", parent: nil, height: 0)
        let alternate = segmentTailBlock(
            name: "append-alternate", parent: root.hash, height: 1
        )
        let canonicalTail = (0..<64).map { index in
            segmentTailBlock(
                name: "append-canonical-\(index)",
                parent: index == 0 ? root.hash : testCID("segment-tail:append-canonical-\(index - 1)"),
                height: UInt64(index + 1)
            )
        }
        let appended = segmentTailBlock(
            name: "append-canonical-64",
            parent: canonicalTail.last!.hash,
            height: 65
        )

        var chain = try ChainTree.restoreWithoutContext(replaying: [segmentTailAdmission(root)])
        _ = try chain.applyStaged(segmentTailAdmission(alternate))
        for block in canonicalTail {
            _ = try chain.applyStaged(segmentTailAdmission(block))
        }

        let initialTip = chain.canonicalTip
        let initialMainChain = chain.canonicalHashes
        XCTAssertEqual(initialTip, canonicalTail.last!.hash)
        XCTAssertEqual(initialMainChain, Set([root.hash] + canonicalTail.map(\.hash)))

        chain.resetFullCanonicalProjectionCount()
        let submission = try chain.applyStaged(segmentTailAdmission(appended))
        let result = try XCTUnwrap(submission)
        let commit = try XCTUnwrap(result.commit)
        let projectionCount = chain.fullCanonicalProjectionCount
        let finalMainChain = chain.canonicalHashes

        XCTAssertEqual(
            projectionCount,
            0,
            "a canonical unary-tail append must update the cached tail, not rebuild the path"
        )
        XCTAssertTrue(result.extendsCanonical)
        XCTAssertEqual(commit.tipHash, appended.hash)
        XCTAssertEqual(commit.canonicalBlocksAdded, [appended.hash: appended.height])
        XCTAssertEqual(commit.canonicalBlocksRemoved, Set<String>())
        XCTAssertEqual(
            finalMainChain,
            Set([root.hash] + canonicalTail.map(\.hash) + [appended.hash])
        )
        await assertSegmentTailReferenceParity(chain)
    }

    func testCanonicalTailAdditionalWorkUsesUnchangedSpineWithoutFullProjection() async throws {
        let root = segmentTailBlock(name: "inherited-root", parent: nil, height: 0)
        let alternate = segmentTailBlock(
            name: "inherited-alternate", parent: root.hash, height: 1
        )
        let canonicalTail = (0..<64).map { index in
            segmentTailBlock(
                name: "inherited-canonical-\(index)",
                parent: index == 0 ? root.hash : testCID("segment-tail:inherited-canonical-\(index - 1)"),
                height: UInt64(index + 1)
            )
        }

        var chain = try ChainTree.restoreWithoutContext(replaying: [segmentTailAdmission(root)])
        _ = try chain.applyStaged(segmentTailAdmission(alternate))
        for block in canonicalTail {
            _ = try chain.applyStaged(segmentTailAdmission(block))
        }

        let tipBefore = chain.canonicalTip
        let mainChainBefore = chain.canonicalHashes
        XCTAssertEqual(tipBefore, canonicalTail.last!.hash)

        chain.resetFullCanonicalProjectionCount()
        let contribution = VerifiedWorkContribution(
            id: testCID("segment-tail:additional-canonical-grind"),
            work: UInt256(7)
        )
        let commit = chain.addWorkContribution(
            contribution,
            to: canonicalTail.last!.hash
        ).commit
        let projectionCount = chain.fullCanonicalProjectionCount
        let tipAfter = chain.canonicalTip
        let mainChainAfter = chain.canonicalHashes

        let nonReorgCommit = try XCTUnwrap(commit)
        XCTAssertFalse(nonReorgCommit.canonicalChanged)
        XCTAssertEqual(nonReorgCommit.tipHash, tipBefore)
        XCTAssertEqual(nonReorgCommit.canonicalBlocksAdded, [:])
        XCTAssertEqual(nonReorgCommit.canonicalBlocksRemoved, Set<String>())
        XCTAssertEqual(projectionCount, 0)
        XCTAssertEqual(tipAfter, tipBefore)
        XCTAssertEqual(mainChainAfter, mainChainBefore)
        await assertSegmentTailReferenceParity(chain)
    }

    func testManyWorkFactsKeepCanonicalTailIncremental() async throws {
        let root = segmentTailBlock(name: "many-inherited-root", parent: nil, height: 0)
        let alternate = segmentTailBlock(
            name: "many-inherited-alternate", parent: root.hash, height: 1
        )
        let canonicalTail = (0..<32).map { index in
            segmentTailBlock(
                name: "many-inherited-canonical-\(index)",
                parent: index == 0
                    ? root.hash
                    : testCID("segment-tail:many-inherited-canonical-\(index - 1)"),
                height: UInt64(index + 1)
            )
        }
        var chain = try ChainTree.restoreWithoutContext(replaying: [segmentTailAdmission(root)])
        _ = try chain.applyStaged(segmentTailAdmission(alternate))
        for block in canonicalTail {
            _ = try chain.applyStaged(segmentTailAdmission(block))
        }

        chain.resetFullCanonicalProjectionCount()
        let initialBlock = chain.hashToBlock[canonicalTail.last!.hash]
        let initial = WorkMeasure(
            try XCTUnwrap(initialBlock)
                .workContributions.values
        )
        let shared = testCID("segment-tail:many-inherited-shared")
        var contributions: [VerifiedWorkContribution] = []
        for index in 0..<512 {
            let contribution = VerifiedWorkContribution(
                id: index.isMultiple(of: 64)
                    ? shared
                    : testCID("segment-tail:many-inherited-\(index)"),
                work: UInt256(index.isMultiple(of: 64) ? UInt64(index + 1) : 1)
            )
            contributions.append(contribution)
            _ = chain.addWorkContribution(
                contribution,
                to: canonicalTail.last!.hash
            )
        }

        var expected = initial
        expected.formUnion(WorkMeasure(contributions))
        let block = chain.hashToBlock[canonicalTail.last!.hash]
        let retained = WorkMeasure(try XCTUnwrap(block).workContributions.values)
        let projectionCount = chain.fullCanonicalProjectionCount

        XCTAssertEqual(retained, expected)
        XCTAssertEqual(
            projectionCount,
            0,
            "incremental work facts must not rebuild the unchanged canonical path"
        )
        await assertSegmentTailReferenceParity(chain)
    }

    func testLateForkWithAttachedNestedOrphanTailEmitsExactReorgDelta() async throws {
        let root = segmentTailBlock(name: "reorg-root", parent: nil, height: 0)
        let prefix = segmentTailBlock(name: "reorg-prefix", parent: root.hash, height: 1)
        let a0 = segmentTailBlock(name: "reorg-a0", parent: prefix.hash, height: 2, work: 1)
        let a1 = segmentTailBlock(name: "reorg-a1", parent: a0.hash, height: 3, work: 1)
        let a2 = segmentTailBlock(name: "reorg-a2", parent: a1.hash, height: 4, work: 4)

        // B0 arrives last. Its already accepted descendants form a tail ending
        // at F, then a nested fork where C is the GHOST-selected child.
        let b0 = segmentTailBlock(name: "reorg-b0", parent: prefix.hash, height: 2, work: 1)
        let b1 = segmentTailBlock(name: "reorg-b1", parent: b0.hash, height: 3, work: 1)
        let fork = segmentTailBlock(name: "reorg-fork", parent: b1.hash, height: 4, work: 1)
        let c0 = segmentTailBlock(name: "reorg-c0", parent: fork.hash, height: 5, work: 1)
        let c1 = segmentTailBlock(name: "reorg-c1", parent: c0.hash, height: 6, work: 2)
        let d0 = segmentTailBlock(name: "reorg-d0", parent: fork.hash, height: 5, work: 1)

        var chain = try ChainTree.restoreWithoutContext(replaying: [segmentTailAdmission(root)])
        for block in [prefix, a0, a1, a2] {
            _ = try chain.applyStaged(segmentTailAdmission(block))
        }
        let initialMainChain = chain.canonicalHashes
        XCTAssertEqual(initialMainChain, Set([root.hash, prefix.hash, a0.hash, a1.hash, a2.hash]))

        // These are deliberately connected below an unavailable B0. They must
        // not affect the selected path until B0 joins the existing prefix.
        for block in [b1, fork, c0, d0, c1] {
            _ = try chain.applyStaged(segmentTailAdmission(block))
        }
        let tipBeforeAttachment = chain.canonicalTip
        XCTAssertEqual(tipBeforeAttachment, a2.hash)

        let submission = try chain.applyStaged(segmentTailAdmission(b0))
        let result = try XCTUnwrap(submission)
        let commit = try XCTUnwrap(result.commit)
        let finalMainChain = chain.canonicalHashes
        let d0IsCanonical = chain.isCanonical(hash: d0.hash)

        XCTAssertEqual(commit.tipHash, c1.hash)
        XCTAssertEqual(
            commit.canonicalBlocksAdded,
            [
                b0.hash: b0.height,
                b1.hash: b1.height,
                fork.hash: fork.height,
                c0.hash: c0.height,
                c1.hash: c1.height,
            ]
        )
        XCTAssertEqual(commit.canonicalBlocksRemoved, Set([a0.hash, a1.hash, a2.hash]))
        XCTAssertEqual(
            finalMainChain,
            Set([root.hash, prefix.hash, b0.hash, b1.hash, fork.hash, c0.hash, c1.hash])
        )
        XCTAssertFalse(d0IsCanonical)
        XCTAssertFalse(commit.canonicalBlocksAdded.keys.contains(d0.hash))
        XCTAssertFalse(commit.canonicalBlocksAdded.keys.contains(root.hash))
        XCTAssertFalse(commit.canonicalBlocksAdded.keys.contains(prefix.hash))
        await assertSegmentTailReferenceParity(chain)
    }

    /// The commit delta is the node's only view of what moved, so a projection
    /// that materializes just the changed suffix must still report exactly the
    /// blocks that joined the main chain — no more.
    func testSuffixProjectionReportsExactlyTheBlocksThatJoined() async throws {
        let root = segmentTailBlock(name: "extend-root", parent: nil, height: 0)
        let a = segmentTailBlock(name: "extend-a", parent: root.hash, height: 1)
        // A losing sibling splits the run, so the canonical path is more than
        // one segment and the delta has a shared prefix to keep.
        let b = segmentTailBlock(name: "extend-b", parent: a.hash, height: 2, work: 4)
        let side = segmentTailBlock(name: "extend-side", parent: a.hash, height: 2, work: 1)
        let c = segmentTailBlock(name: "extend-c", parent: b.hash, height: 3)
        // Delivered before their parent, so connecting `d` extends the canonical
        // path by three blocks through a projection, not the O(1) append.
        let d = segmentTailBlock(name: "extend-d", parent: c.hash, height: 4)
        let e = segmentTailBlock(name: "extend-e", parent: d.hash, height: 5)
        let f = segmentTailBlock(name: "extend-f", parent: e.hash, height: 6)

        var chain = try ChainTree.restoreWithoutContext(replaying: [segmentTailAdmission(root)])
        for block in [a, side, b, c] {
            _ = try chain.applyStaged(segmentTailAdmission(block))
        }
        let tipBefore = chain.canonicalTip
        XCTAssertEqual(tipBefore, c.hash)
        let mainChainBefore = chain.canonicalHashes

        for block in [f, e] {
            _ = try chain.applyStaged(segmentTailAdmission(block))
        }
        let held = chain.canonicalTip
        XCTAssertEqual(held, c.hash, "an unconnected component must not be selected")

        let submission = try chain.applyStaged(segmentTailAdmission(d))
        let result = try XCTUnwrap(submission)
        let commit = try XCTUnwrap(result.commit)
        let mainChainAfter = chain.canonicalHashes

        XCTAssertEqual(commit.tipHash, f.hash)
        XCTAssertEqual(
            commit.canonicalBlocksAdded,
            [d.hash: d.height, e.hash: e.height, f.hash: f.height],
            "only the blocks that joined may be reported as added"
        )
        XCTAssertEqual(commit.canonicalBlocksRemoved, Set<String>())
        XCTAssertEqual(
            mainChainAfter,
            mainChainBefore.union([d.hash, e.hash, f.hash])
        )
        await assertSegmentTailReferenceParity(chain)
    }

}

private struct SegmentTailBlock {
    let hash: String
    let parent: String?
    let height: UInt64
    let work: UInt64
    let name: String
}

private func segmentTailBlock(
    name: String,
    parent: String?,
    height: UInt64,
    work: UInt64 = 1
) -> SegmentTailBlock {
    SegmentTailBlock(
        hash: testCID("segment-tail:\(name)"),
        parent: parent,
        height: height,
        work: work,
        name: name
    )
}

private func segmentTailAdmission(_ block: SegmentTailBlock) -> BlockImportBatch {
    BlockImportBatch(facts: [
        .block(ChainBlockFact(
            blockHash: block.hash,
            parentBlockHash: block.parent,
            blockHeight: block.height,
            postStateCID: testCID("segment-tail:post:\(block.name)"),
            prevStateCID: testCID("segment-tail:prev:\(block.name)"),
            specCID: testCID("segment-tail:spec:\(block.name)"),
            target: "1",
            nextTarget: "1",
            timestamp: Int64(block.height),
            stateDiff: .empty
        )),
        .work(ChainWorkFact(
            blockHash: block.hash,
            contribution: VerifiedWorkContribution(
                id: testCID("segment-tail:work:\(block.name)"),
                work: UInt256(block.work)
            )
        )),
    ])
}

private func assertSegmentTailReferenceParity(
    _ chain: ChainTree,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let blocks = chain.hashToBlock
    guard let reference = ForkChoiceOracle(blocks: blocks, excluded: [])
        .view().canonicalProjection()
    else {
        XCTFail("reference projection missing", file: file, line: line)
        return
    }
    let tip = chain.canonicalTip
    let mainChain = chain.canonicalHashes
    XCTAssertEqual(
        tip,
        reference.tip,
        file: file,
        line: line
    )
    XCTAssertEqual(
        mainChain,
        Set(reference.path),
        file: file,
        line: line
    )
    await assertMainChainIndexMatchesPath(
        chain,
        expectedPath: Set(reference.path),
        "by-height index",
        file: file,
        line: line
    )
}
