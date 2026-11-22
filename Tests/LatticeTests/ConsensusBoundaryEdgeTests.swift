import XCTest
import Foundation
import CID
import Crypto
import Multikey
import UInt256
import cashew
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport

/// Consensus edges at the boundaries of the locked principles: equal-work
/// ties (smaller raw CID bytes win), work weighs / validity selects through
/// deep exclusions, competing child roots under a reorging parent with only
/// the Nexus genesis pinned, the node's clock, the ASERT schedule at its
/// extremes, the block-size limit with a child index, and a host-independent
/// state-root golden.
final class ConsensusBoundaryEdgeTests: XCTestCase {

    // MARK: - Fact-level fixtures

    private func h(_ name: String) -> String { testCID("edge-c:\(name)") }

    private func admission(_ name: String, parent: String?, height: UInt64, work: UInt64) -> BlockImportBatch {
        BlockImportBatch(facts: [
            .block(ChainBlockFact(
                blockHash: h(name), parentBlockHash: parent.map(h), blockHeight: height,
                postStateCID: testCID("edge-c-post:\(name)"),
                prevStateCID: parent.map { testCID("edge-c-post:\($0)") } ?? testCID("edge-c-prev:genesis"),
                specCID: testCID("edge-c-spec"), target: "1", nextTarget: "1",
                timestamp: Int64(1_000 + height)
            )),
            .work(ChainWorkFact(
                blockHash: h(name),
                contribution: VerifiedWorkContribution(id: testCID("edge-c-work:\(name)"), work: UInt256(work))
            )),
        ])
    }

    private func extraWork(_ name: String, grind: String, work: UInt64) -> BlockImportBatch {
        BlockImportBatch(facts: [.work(ChainWorkFact(
            blockHash: h(name),
            contribution: VerifiedWorkContribution(id: testCID("edge-c-grind:\(grind)"), work: UInt256(work))
        ))])
    }

    private func exclusion(_ name: String) -> BlockImportBatch {
        BlockImportBatch(facts: [.exclusion(ChainExclusionFact(blockHash: h(name)))])
    }

    private func rawBytes(_ cid: String) throws -> [UInt8] { Array(try CID(cid).rawBuffer) }

    /// Names ordered by the raw bytes of their CIDs, smallest first — decided
    /// with the CID library alone, not with the consensus helper.
    private func byRawCID(_ names: [String]) throws -> [String] {
        let keyed = try names.map { ($0, try rawBytes(h($0))) }
        return keyed.sorted { $0.1.lexicographicallyPrecedes($1.1) }.map(\.0)
    }

    private func permutations<T>(_ xs: [T]) -> [[T]] {
        guard xs.count > 1 else { return [xs] }
        return xs.indices.flatMap { i -> [[T]] in
            var rest = xs
            let head = rest.remove(at: i)
            return permutations(rest).map { [head] + $0 }
        }
    }

    // MARK: - 5. Three equal-work siblings

    func testThreeEqualWorkSiblingsSelectTheSmallestRawCIDInEveryArrivalOrder() async throws {
        let siblings = ["s1", "s2", "s3"]
        let ordered = try byRawCID(siblings)
        let genesis = admission("g", parent: nil, height: 0, work: 1)
        let facts = Dictionary(uniqueKeysWithValues: siblings.map {
            ($0, admission($0, parent: "g", height: 1, work: 7))
        })
        let orders = permutations(siblings)
        XCTAssertEqual(orders.count, 6)
        for order in orders {
            var live = try ChainTree.restoreWithoutContext(replaying: [genesis])
            for name in order { _ = try live.replay(facts[name]!) }
            let liveTip = live.canonicalTip
            XCTAssertEqual(liveTip, h(ordered[0]), "live, order \(order)")
            let cold = try ChainTree.restoreWithoutContext(
                replaying: [genesis] + order.map { facts[$0]! }
            )
            let coldTip = cold.canonicalTip
            XCTAssertEqual(coldTip, h(ordered[0]), "restored, order \(order)")
            let weight = live.subtreeWeight(forHash: h("g"))
            XCTAssertEqual(weight, WorkSum(UInt256(22)))
        }
    }

    /// Two siblings settle; a third equal-work sibling arrives late. It takes
    /// the tip only if its raw CID bytes are smaller than the incumbent's.
    func testALateEqualWorkSiblingTakesTheTipOnlyWhenItsCIDIsSmaller() async throws {
        // A pool of candidate names, ordered by raw CID bytes.
        let pool = try byRawCID((0..<12).map { "late\($0)" })
        let smallest = pool[0], middle = pool[1], largest = pool[pool.count - 1]
        let genesis = admission("g", parent: nil, height: 0, work: 1)

        // Third sibling smallest: tip switches.
        do {
            let settled = [pool[2], pool[3]]
            var chain = try ChainTree.restoreWithoutContext(replaying: [genesis])
            for name in settled { _ = try chain.replay(admission(name, parent: "g", height: 1, work: 5)) }
            let incumbent = chain.canonicalTip
            XCTAssertEqual(incumbent, h(pool[2]))
            _ = try chain.replay(admission(smallest, parent: "g", height: 1, work: 5))
            let tip = chain.canonicalTip
            XCTAssertEqual(tip, h(smallest), "a smaller-CID equal-work late sibling takes the tip")
            let cold = try ChainTree.restoreWithoutContext(replaying: [genesis] + (settled + [smallest]).map {
                admission($0, parent: "g", height: 1, work: 5)
            })
            let coldTip = cold.canonicalTip
            XCTAssertEqual(coldTip, h(smallest))
        }
        // Third sibling not smallest: incumbent holds.
        do {
            let settled = [middle, pool[2]]
            var chain = try ChainTree.restoreWithoutContext(replaying: [genesis])
            for name in settled { _ = try chain.replay(admission(name, parent: "g", height: 1, work: 5)) }
            _ = try chain.replay(admission(largest, parent: "g", height: 1, work: 5))
            let tip = chain.canonicalTip
            XCTAssertEqual(tip, h(middle), "a larger-CID equal-work late sibling does not displace the incumbent")
            let cold = try ChainTree.restoreWithoutContext(replaying: [genesis] + (settled + [largest]).map {
                admission($0, parent: "g", height: 1, work: 5)
            })
            let coldTip = cold.canonicalTip
            XCTAssertEqual(coldTip, h(middle))
        }
    }

    // MARK: - 7. Deep exclusion with a growing invalid subtree

    /// g → v1 → v2 → v3; under v3 a valid tip w (work 2) and an excluded root
    /// x whose subtree keeps growing (blocks and extra grinds). A rival branch
    /// u under g outweighs the valid-only work of v1 but not its pure work.
    func testDeepExcludedSubtreeKeepsGainingWeightButIsNeverSelected() async throws {
        var log: [BlockImportBatch] = [
            admission("g", parent: nil, height: 0, work: 1),
            admission("v1", parent: "g", height: 1, work: 1),
            admission("v2", parent: "v1", height: 2, work: 1),
            admission("v3", parent: "v2", height: 3, work: 1),
            admission("w", parent: "v3", height: 4, work: 2),
            admission("x", parent: "v3", height: 4, work: 3),
            exclusion("x"),
            admission("u", parent: "g", height: 1, work: 10),
        ]
        var live = try ChainTree.restoreWithoutContext(replaying: [log[0]])
        for batch in log.dropFirst() { _ = try live.replay(batch) }
        // v1 = 1+1+1+2+3 = 8 < u = 10: the rival wins for now.
        var tip = live.canonicalTip
        XCTAssertEqual(tip, h("u"))

        // The excluded subtree grows below x: blocks and extra grinds.
        var expectedV1: UInt64 = 8
        var parent = "x"
        for i in 1...6 {
            let name = "x\(i)"
            let batch = admission(name, parent: parent, height: UInt64(4 + i), work: 2)
            _ = try live.replay(batch)
            log.append(batch)
            let grind = extraWork(name, grind: "extra-\(i)", work: 1)
            _ = try live.replay(grind)
            log.append(grind)
            expectedV1 += 3
            parent = name
            let v1 = live.subtreeWeight(forHash: h("v1"))
            XCTAssertEqual(v1, WorkSum(UInt256(expectedV1)), "ancestor weight rises with invalid work (\(name))")
            let path = live.canonicalHashes
            XCTAssertFalse(path.contains(h("x")), "excluded root never selected")
            XCTAssertFalse(path.contains(h(name)))
        }
        // v1 = 26 > u = 10: the descent goes down v1, then stops at w.
        tip = live.canonicalTip
        XCTAssertEqual(tip, h("w"), "heaviest selectable path ends at the valid tip")
        let gWeight = live.subtreeWeight(forHash: h("g"))
        XCTAssertEqual(gWeight, WorkSum(UInt256(1 + expectedV1 + 10)))

        // Restore/replay the full log, in order and shuffled.
        var rng = SeededRNG(seed: 0xED6E7)
        for trial in 0..<4 {
            let replayed = trial == 0 ? log : log.shuffled(using: &rng)
            let cold = try ChainTree.restoreWithoutContext(replaying: replayed)
            let coldTip = cold.canonicalTip
            XCTAssertEqual(coldTip, h("w"), "cold \(trial)")
            let coldV1 = cold.subtreeWeight(forHash: h("v1"))
            XCTAssertEqual(coldV1, WorkSum(UInt256(expectedV1)), "cold \(trial): added work replays")
            let coldPath = cold.canonicalHashes
            XCTAssertFalse(coldPath.contains(h("x")), "cold \(trial)")
            let roots = cold.excludedRootsForTesting
            XCTAssertEqual(roots, [h("x")], "cold \(trial)")
        }
    }

    // MARK: - 8. Competing child geneses under a reorging parent

    func testCompetingChildGenesesAreUnmovedByAParentReorgAndOnlyTheNexusGenesisIsPinned() async throws {
        let fetcher = StorableFetcher()
        let easy = AdmissionFixture.easy
        let childPath = [DEFAULT_ROOT_DIRECTORY, "Child"]
        let childContext = testChainContext(path: childPath)
        let nexusGenesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            transactions: [AdmissionFixture.unsignedStateChangingGenesisTransaction(
                key: "edge-c-nexus", chainPath: [DEFAULT_ROOT_DIRECTORY]
            )],
            timestamp: 1_000, target: easy, fetcher: fetcher
        )
        var nexus = try await TreeDriver.tree(
            genesis: nexusGenesis, context: testChainContext(genesis: nexusGenesis), fetcher: fetcher
        )

        func childGenesis(nonce: UInt64) async throws -> Block {
            let block = try await BlockBuilder.buildChildGenesis(
                spec: chainLocalSpec(), parentState: nexusGenesis.postState,
                timestamp: 1_500, target: easy, nonce: nonce, fetcher: fetcher
            )
            try await storeBuiltBlock(block, in: fetcher)
            return block
        }
        func evidence(_ child: Block, by carrier: Block) async throws -> VerifiedChildEvidence {
            let proof = try await ChildBlockProof.generate(
                rootHeader: try BlockHeader(node: carrier), childDirectory: "Child", fetcher: fetcher
            )
            return try proof.verifySecuringWork(child: child, chainPath: childPath).get()
        }
        let g1 = try await childGenesis(nonce: 1)
        let g2 = try await childGenesis(nonce: 2)
        XCTAssertEqual(g1.parentState.rawCID, g2.parentState.rawCID, "same parent state")
        let c1 = try await buildAndStoreBlock(
            previous: nexusGenesis, children: ["Child": g1], timestamp: 2_000, target: easy, nonce: 1, fetcher: fetcher
        )
        let c2 = try await buildAndStoreBlock(
            previous: nexusGenesis, children: ["Child": g2], timestamp: 2_100, target: easy, nonce: 2, fetcher: fetcher
        )
        _ = try await TreeDriver.insert(c1, into: &nexus, fetcher: fetcher)
        XCTAssertEqual(nexus.canonicalTip, try BlockHeader(node: c1).rawCID)

        // The child tree holds both roots, weighed by their carriers.
        let e1 = try await evidence(g1, by: c1)
        let e2 = try await evidence(g2, by: c2)
        XCTAssertEqual(e1.contribution?.work, e2.contribution?.work, "equal carriers, equal work")
        var child = try await ChainTree.bootstrap(
            genesis: try BlockHeader(node: g1), evidence: e1, fetcher: fetcher,
            context: childContext, parentFacts: ParentLevelFacts(tree: nexus)
        ).get().tree
        XCTAssertNotNil(child.insertGenesis(
            g2, spec: chainLocalSpec(), childIndex: testChildIndex(g2), evidence: e2
        ).update)
        let g1CID = try BlockHeader(node: g1).rawCID, g2CID = try BlockHeader(node: g2).rawCID
        // Equal work: the tie breaks by the smaller raw CID, decided here
        // with the CID library alone, not with the consensus helper.
        let expected = try rawBytes(g1CID).lexicographicallyPrecedes(try rawBytes(g2CID)) ? g1CID : g2CID
        let tipBefore = child.canonicalTip
        XCTAssertEqual(tipBefore, expected, "equal-work roots: smaller CID")
        let w1Before = child.subtreeWeight(forHash: g1CID)
        let w2Before = child.subtreeWeight(forHash: g2CID)

        // The parent reorgs away from c1 (the block carrying g1).
        _ = try await TreeDriver.insert(c2, into: &nexus, fetcher: fetcher)
        let c2b = try await buildAndStoreBlock(
            previous: c2, timestamp: 3_000, target: easy, nonce: 3, fetcher: fetcher
        )
        _ = try await TreeDriver.insert(c2b, into: &nexus, fetcher: fetcher)
        XCTAssertEqual(nexus.canonicalTip, try BlockHeader(node: c2b).rawCID, "parent reorged")
        XCTAssertFalse(nexus.canonicalHashes.contains(try BlockHeader(node: c1).rawCID))

        // Child fork choice is a function of child-chain work alone.
        XCTAssertEqual(child.canonicalTip, tipBefore, "a parent reorg does not move child fork choice")
        XCTAssertEqual(child.subtreeWeight(forHash: g1CID), w1Before)
        XCTAssertEqual(child.subtreeWeight(forHash: g2CID), w2Before)
        // Both roots still execute against the (still canonical) parent state.
        let afterReorg = ParentLevelFacts(tree: nexus)
        let other = expected == g1CID ? g2CID : g1CID
        if !child.hasExecutedAncestry(blockHash: other) {
            let connected = try await TreeDriver.connect(other, on: &child, fetcher: fetcher, parentFacts: afterReorg)
            XCTAssertNotNil(connected.update)
        }
        XCTAssertTrue(child.hasExecutedAncestry(blockHash: g1CID))
        XCTAssertTrue(child.hasExecutedAncestry(blockHash: g2CID))
        XCTAssertEqual(child.canonicalTip, tipBefore)

        // Only the Nexus genesis is pinned: another Nexus genesis fails restore…
        let rivalNexus = try await buildAndStoreGenesis(
            spec: chainLocalSpec(), timestamp: 1_000, target: easy, nonce: 99, fetcher: fetcher
        )
        do {
            _ = try ChainTree.restore(
                replaying: [try testAdmissionBatch(for: rivalNexus)],
                context: testChainContext(genesis: nexusGenesis)
            )
            XCTFail("a root restore must refuse a genesis other than the pinned one")
        } catch {
            XCTAssertEqual(error as? ChainTreeRestoreError, .unpinnedRootGenesis)
        }
        // …and a child context cannot pin one at all.
        XCTAssertThrowsError(try ChainRuntimeContext(path: childPath, genesisCID: g1CID)) {
            XCTAssertEqual($0 as? ChainRuntimeContextError, .childGenesisPinned)
        }
        XCTAssertTrue(childContext.admitsGenesis(g1CID) && childContext.admitsGenesis(g2CID))
    }

    // MARK: - 9. The node's clock

    private static let nexusLikeSpec = ChainSpec.test(targetBlockTime: 3_600_000, halfLife: 120)

    func testBlockAtNowIsValidAndOneMillisecondLaterIsNotYetValid() async throws {
        let fetcher = StorableFetcher()
        let launch = Int64(Date().timeIntervalSince1970 * 1_000) - 60_000
        let genesis = try await buildAndStoreGenesis(
            spec: Self.nexusLikeSpec, timestamp: launch, target: UInt256.max, fetcher: fetcher
        )
        let genesisValid = try await genesis.validateGenesis(
            fetcher: fetcher, chainPath: [DEFAULT_ROOT_DIRECTORY], validationContext: .current
        ).0
        XCTAssertTrue(genesisValid, "a genesis at the real launch time validates against the real clock")
        let block = try await buildAndStoreBlock(
            previous: genesis, timestamp: launch + 30_000, target: UInt256.max, fetcher: fetcher
        )
        let atNow = try await block.validateNexus(
            fetcher: fetcher, reportTemporalFailure: true,
            validationContext: ValidationContext(nowMilliseconds: block.timestamp)
        ).0
        XCTAssertTrue(atNow, "timestamp == now is accepted")
        do {
            _ = try await block.validateNexus(
                fetcher: fetcher, reportTemporalFailure: true,
                validationContext: ValidationContext(nowMilliseconds: block.timestamp - 1)
            )
            XCTFail("a block one millisecond in the node's future is not yet valid")
        } catch BlockValidationError.notYetValid {}
        let quiet = try await block.validateNexus(
            fetcher: fetcher, validationContext: ValidationContext(nowMilliseconds: block.timestamp - 1)
        ).0
        XCTAssertFalse(quiet, "without temporal reporting it is simply not valid now")
        let real = try await block.validateNexus(fetcher: fetcher, validationContext: .current).0
        XCTAssertTrue(real, "block 1 shortly after a real-clock genesis validates against the real clock")
    }

    // MARK: - 10. ASERT at production-like parameters

    private func assertBuilderAndValidatorAgree(
        _ block: Block, previous: Block, fetcher: StorableFetcher,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let anchor = try await BlockBuilder.resolveDifficultyAnchor(from: previous, fetcher: fetcher)
            ?? DifficultyAnchor(blockHeight: 1, timestamp: block.timestamp, target: block.target)
        XCTAssertTrue(
            block.validateNextTarget(spec: Self.nexusLikeSpec, parent: previous, difficultyAnchor: anchor),
            "validator accepts the builder's target at height \(block.height)", file: file, line: line
        )
    }

    func testDecadesLateBlockEasesToASaturatedNonzeroTarget() async throws {
        let fetcher = StorableFetcher()
        let launch = Int64(Date().timeIntervalSince1970 * 1_000) - 7_200_000
        let start = UInt256(1) << 200
        let genesis = try await buildAndStoreGenesis(
            spec: Self.nexusLikeSpec, timestamp: launch, target: start, fetcher: fetcher
        )
        let block1 = try await buildAndStoreBlock(previous: genesis, timestamp: launch + 3_600_000, fetcher: fetcher)
        try await assertBuilderAndValidatorAgree(block1, previous: genesis, fetcher: fetcher)
        let twentyYears: Int64 = 20 * 365 * 24 * 3_600_000
        let block2 = try await buildAndStoreBlock(
            previous: block1, timestamp: block1.timestamp + twentyYears, fetcher: fetcher
        )
        try await assertBuilderAndValidatorAgree(block2, previous: block1, fetcher: fetcher)
        XCTAssertGreaterThan(block2.nextTarget, block1.nextTarget, "late eases")
        XCTAssertEqual(block2.nextTarget, UInt256.max, "eases until it saturates")
        XCTAssertNotEqual(block2.nextTarget, .zero)
        let valid = try await block2.validateNexus(
            fetcher: fetcher, validationContext: ValidationContext(nowMilliseconds: block2.timestamp)
        ).0
        XCTAssertTrue(valid)
    }

    func testFiveHundredOneMillisecondBlocksHardenNeverToZeroAndNormalTimingHolds() async throws {
        let fetcher = StorableFetcher()
        // The last block lands back on the hourly schedule at height ~507,
        // i.e. ~507 hours after launch: start far enough back that no block
        // lands in the future.
        let launch = Int64(Date().timeIntervalSince1970 * 1_000) - 520 * 3_600_000
        let genesis = try await buildAndStoreGenesis(
            spec: Self.nexusLikeSpec, timestamp: launch, target: UInt256(1) << 200, fetcher: fetcher
        )
        var previous = try await buildAndStoreBlock(previous: genesis, timestamp: launch + 3_600_000, fetcher: fetcher)
        let anchorTarget = previous.target
        let anchorTime = previous.timestamp
        let anchor = DifficultyAnchor(blockHeight: 1, timestamp: anchorTime, target: anchorTarget)
        var lastNext = previous.nextTarget
        for i in 0..<500 {
            // The anchor is supplied (it is block 1's) so the run stays linear;
            // the walk is checked against it below.
            let block = try await BlockBuilder.buildBlock(
                previous: previous, timestamp: previous.timestamp + 1, nonce: UInt64(i),
                difficultyAnchor: anchor, fetcher: fetcher
            )
            XCTAssertTrue(
                block.validateNextTarget(spec: Self.nexusLikeSpec, parent: previous, difficultyAnchor: anchor),
                "validator accepts the builder's target at height \(block.height)"
            )
            XCTAssertLessThanOrEqual(block.nextTarget, lastNext, "fast blocks never ease (height \(block.height))")
            XCTAssertNotEqual(block.nextTarget, .zero)
            XCTAssertEqual(block.target, previous.nextTarget)
            lastNext = block.nextTarget
            previous = block
        }
        // ~500 hours ahead with a 120-hour half-life: > 4 doublings harder.
        XCTAssertLessThan(previous.nextTarget, anchorTarget / UInt256(16))
        XCTAssertGreaterThan(previous.nextTarget, anchorTarget / UInt256(32))
        let hardened = previous.nextTarget

        // Normal spacing: the deficit is unchanged, so the target holds.
        for i in 0..<5 {
            let block = try await BlockBuilder.buildBlock(
                previous: previous, timestamp: previous.timestamp + 3_600_000, nonce: UInt64(1_000 + i),
                difficultyAnchor: anchor, fetcher: fetcher
            )
            XCTAssertTrue(block.validateNextTarget(spec: Self.nexusLikeSpec, parent: previous, difficultyAnchor: anchor))
            XCTAssertEqual(block.nextTarget, hardened, "on-pace blocks neither harden nor ease further")
            previous = block
        }
        // A block that lands back on schedule recovers the anchor target.
        let onSchedule = anchorTime + Int64(previous.height) * 3_600_000
        XCTAssertLessThan(onSchedule, Int64(Date().timeIntervalSince1970 * 1_000), "fixture: no future blocks")
        let recovered = try await BlockBuilder.buildBlock(
            previous: previous, timestamp: onSchedule, nonce: 2_000, difficultyAnchor: anchor, fetcher: fetcher
        )
        XCTAssertTrue(recovered.validateNextTarget(spec: Self.nexusLikeSpec, parent: previous, difficultyAnchor: anchor))
        XCTAssertGreaterThan(recovered.nextTarget, hardened)
        let diff = recovered.nextTarget > anchorTarget
            ? recovered.nextTarget - anchorTarget : anchorTarget - recovered.nextTarget
        XCTAssertLessThan(diff, anchorTarget / UInt256(100), "back on schedule ≈ the anchor target")
    }

    // MARK: - 11. Block size with a child index

    private func sizeSpec(_ maxBlockSize: Int) -> ChainSpec {
        ChainSpec.test(maxBlockSize: maxBlockSize, initialReward: 1, halvingInterval: 1_000, halfLife: 10)
    }

    func testChildIndexBytesCountTowardTheExactBlockSizeLimit() async throws {
        let fetcher = StorableFetcher()
        let childGenesis = try await buildAndStoreGenesis(
            spec: sizeSpec(1_000_000), timestamp: 1, target: UInt256.max, fetcher: fetcher
        )
        func nexus(_ maxBlockSize: Int, children: [String: Block]) async throws -> Block {
            try await buildAndStoreGenesis(
                spec: sizeSpec(maxBlockSize), children: children, timestamp: 2, target: UInt256.max, fetcher: fetcher
            )
        }
        let without = try await nexus(1_000_000, children: [:])
        let probe = try await nexus(1_000_000, children: ["Child": childGenesis, "Other": childGenesis])
        let withoutSize = try await without.logicalContentByteSize(fetcher: fetcher)
        let size = try await probe.logicalContentByteSize(fetcher: fetcher)
        XCTAssertGreaterThan(size, withoutSize, "the children map's bytes are counted")

        let exact = try await nexus(size, children: ["Child": childGenesis, "Other": childGenesis])
        let exactSize = try await exact.logicalContentByteSize(fetcher: fetcher)
        XCTAssertEqual(exactSize, size, "the spec's limit value does not change the counted size")
        let exactFits = try await exact.validateBlockSize(spec: sizeSpec(size), fetcher: fetcher)
        XCTAssertTrue(exactFits)
        let exactValid = try await exact.validateGenesis(
            fetcher: fetcher, chainPath: [DEFAULT_ROOT_DIRECTORY], validationContext: ValidationContext(nowMilliseconds: 10)
        ).0
        XCTAssertTrue(exactValid, "exactly maxBlockSize is valid")

        let over = try await nexus(size - 1, children: ["Child": childGenesis, "Other": childGenesis])
        let overFits = try await over.validateBlockSize(spec: sizeSpec(size - 1), fetcher: fetcher)
        XCTAssertFalse(overFits)
        let overValid = try await over.validateGenesis(
            fetcher: fetcher, chainPath: [DEFAULT_ROOT_DIRECTORY], validationContext: ValidationContext(nowMilliseconds: 10)
        ).0
        XCTAssertFalse(overValid, "limit = size - 1 is invalid")
        // The same block without children fits under that limit, so the
        // children's bytes are what pushed it over.
        XCTAssertLessThan(withoutSize, size - 1)
        let withoutFits = try await without.validateBlockSize(spec: sizeSpec(size - 1), fetcher: fetcher)
        XCTAssertTrue(withoutFits)
    }

    // MARK: - 12. Seeded deterministic sequence, golden state roots

    static let goldenName = "consensus-boundary-state-roots.json"

    struct StateRootGolden: Codable, Equatable {
        struct Entry: Codable, Equatable {
            let height: UInt64
            let transactions: Int
            let postState: String
        }
        let blocks: [Entry]
        let finalPostState: String

        static func diff(expected: StateRootGolden, actual: StateRootGolden) -> [String] {
            var lines: [String] = []
            for (e, a) in zip(expected.blocks, actual.blocks) where e != a {
                lines += GoldenFile.fieldDiff("block \(e.height)", [
                    ("transactions", "\(e.transactions)", "\(a.transactions)"),
                    ("postState", e.postState, a.postState),
                ])
            }
            if expected.blocks.count != actual.blocks.count {
                lines.append("block count: expected \(expected.blocks.count), actual \(actual.blocks.count)")
            }
            lines += GoldenFile.fieldDiff("final", [("postState", expected.finalPostState, actual.finalPostState)])
            return lines
        }
    }

    private func fixedKey(_ byte: UInt8) throws -> (privateKey: String, publicKey: String, address: String) {
        let seed = Data(repeating: byte, count: 32)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let publicKey = Multikey(keyType: .ed25519, keyBytes: key.publicKey.rawRepresentation).hexEncoded
        return (seed.hexString, publicKey, testAddress(publicKey: publicKey))
    }

    /// Builds the seeded sequence, validating every block; returns the
    /// pinned state roots and the tip CID.
    private func seededSequence() async throws -> (StateRootGolden, tip: String) {
        let fetcher = StorableFetcher()
        let spec = ChainSpec.test(premine: 1_000)
        let keys = try (0..<4).map { try fixedKey(0x61 + UInt8($0)) }
        let genesis = try await buildPremineGenesis(
            spec: spec, owner: (keys[0].privateKey, keys[0].publicKey),
            fetcher: fetcher, timestamp: 1_000, target: UInt256.max
        )
        // Lower bounds on spendable balances (rewards ignored, only ever add).
        var balance = [Int64(spec.premineAmount()), 0, 0, 0]
        var nonce = [UInt64](repeating: 0, count: keys.count)
        var rng = GoldenRandom(seed: 0xC0FFEE)
        var previous = genesis
        var entries: [StateRootGolden.Entry] = []
        for height in 1...24 {
            var txs: [Transaction] = []
            var credits = [Int64](repeating: 0, count: keys.count)
            for sender in keys.indices where balance[sender] >= 4 && rng.chance(60) {
                var recipient = rng.nextInt(keys.count - 1)
                if recipient >= sender { recipient += 1 }
                let amount = 1 + Int64(rng.nextInt(Int(balance[sender] / 4)))
                let body = TransactionBody(
                    accountActions: [
                        AccountAction(owner: keys[sender].address, delta: -amount),
                        AccountAction(owner: keys[recipient].address, delta: amount),
                    ],
                    actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
                    signers: [keys[sender].address], nonce: nonce[sender],
                    chainPath: [DEFAULT_ROOT_DIRECTORY]
                )
                txs.append(signedTestTransaction(body, by: (keys[sender].privateKey, keys[sender].publicKey)))
                nonce[sender] += 1
                balance[sender] -= amount
                credits[recipient] += amount
            }
            for i in keys.indices { balance[i] += credits[i] }
            let block = try await buildAndStoreBlock(
                previous: previous, transactions: txs,
                timestamp: 1_000 + Int64(height) * 1_000, target: UInt256.max, nonce: UInt64(height),
                rewardRecipient: keys[rng.nextInt(keys.count)].address, fetcher: fetcher
            )
            let valid = try await block.validateNexus(
                fetcher: fetcher, validationContext: ValidationContext(nowMilliseconds: Int64.max)
            ).0
            XCTAssertTrue(valid, "seeded block \(height) validates")
            entries.append(.init(height: block.height, transactions: txs.count, postState: block.postState.rawCID))
            previous = block
        }
        XCTAssertGreaterThan(entries.map(\.transactions).reduce(0, +), 20, "the sequence carries real transfers")
        return (
            StateRootGolden(blocks: entries, finalPostState: previous.postState.rawCID),
            try BlockHeader(node: previous).rawCID
        )
    }

    /// State roots are pinned; block/tip CIDs are NOT, because they commit
    /// the transaction CIDs, which include Ed25519 signatures — randomized by
    /// CryptoKit on macOS (deterministic on Linux swift-crypto).
    func testSeededTransferSequencePinsHostIndependentStateRoots() async throws {
        let first = try await seededSequence()
        let second = try await seededSequence()
        XCTAssertEqual(first.0, second.0, "state roots do not depend on signature bytes")
        try GoldenFile.assert(first.0, matches: Self.goldenName, diff: StateRootGolden.diff)
    }
}
