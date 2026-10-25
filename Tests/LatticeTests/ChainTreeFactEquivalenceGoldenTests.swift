import Foundation
import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
@testable import LatticeSimulation
import UInt256
import cashew

/// The value API emits the actor path's fact bytes. Over the block topologies
/// of the Lattice simulation corpus (`LatticeConsensusSimulator`), realized as
/// real blocks, every block is admitted twice from the same content: through
/// `ChainLevel` with `.header` then `.execution`, and through a `ChainTree`
/// with `insertHeader` then `connect`/`applyConnect`. Each step's staged
/// batch must be byte-identical — including "no batch" — and the two chains
/// must end in the same selection and executed set. The bytes are pinned in
/// `Goldens/chain-tree-fact-equivalence.json`.
///
/// Headers are delivered headers-first — each after its parent, in the
/// corpus's release order otherwise — since `insertHeader` reads the parent
/// from the tree while `.header` may resolve it as content.
final class ChainTreeFactEquivalenceGoldenTests: XCTestCase {
    static let goldenName = "chain-tree-fact-equivalence.json"

    struct Golden: Codable, Equatable {
        struct Step: Codable, Equatable {
            let name: String
            /// Hex of the staged batch's canonical JSON; nil when none.
            let facts: String?
        }

        let steps: [Step]

        static func diff(expected: Golden, actual: Golden) -> [String] {
            var lines: [String] = []
            if expected.steps.map(\.name) != actual.steps.map(\.name) {
                lines.append("step names: expected \(expected.steps.map(\.name)), actual \(actual.steps.map(\.name))")
            }
            for (left, right) in zip(expected.steps, actual.steps) where left != right {
                lines.append("\(left.name): expected \(left.facts ?? "none"), actual \(right.facts ?? "none")")
            }
            return lines
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func hex(_ batch: BlockImportBatch?) throws -> String? {
        try batch.map { try encoder().encode($0).map { String(format: "%02x", $0) }.joined() }
    }

    /// The one batch an update applied; the corpus never lands a header
    /// excluded (that emits two).
    private static func onlyBatch(_ update: ChainTreeUpdate) -> BlockImportBatch? {
        XCTAssertEqual(update.batches.count, 1, "\(update.blockHash)")
        return update.batches.first
    }

    /// One admission step on both paths.
    private final class Pair {
        let level: ChainLevel
        var tree: ChainTree
        let fetcher: StorableFetcher
        let context: ChainRuntimeContext
        let recorder = AdmissionStageRecorder()
        var steps: [Golden.Step] = []

        init(level: ChainLevel, tree: ChainTree, fetcher: StorableFetcher) {
            self.level = level
            self.tree = tree
            self.fetcher = fetcher
            self.context = level.context
        }

        func stagedSince(_ count: Int) async -> BlockImportBatch? {
            let batches = await recorder.recordedBatches()
            XCTAssertLessThanOrEqual(batches.count, count + 1, "one admission stages at most one batch")
            return batches.count > count ? batches.last : nil
        }

        func record(
            _ name: String,
            old: BlockImportBatch?,
            new: BlockImportBatch?,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let oldHex = try hex(old)
            XCTAssertEqual(oldHex, try hex(new), "\(name): value API facts differ from the actor path", file: file, line: line)
            steps.append(Golden.Step(name: name, facts: oldHex))
        }

        func header(_ name: String, _ block: Block, package: ChildValidationPackage? = nil, evidence: VerifiedChildEvidence? = nil) async throws {
            let before = await recorder.recordedBatches().count
            let recorder = self.recorder
            _ = try await level.admit(
                block, mode: .header, fetcher: fetcher, childPackage: package,
                stage: { await recorder.stage($0) }
            )
            let old = await stagedSince(before)
            let new = try await TreeDriver.insert(block, into: &tree, fetcher: fetcher, evidence: evidence)
            try record("\(name)/header", old: old, new: new.update.flatMap(ChainTreeFactEquivalenceGoldenTests.onlyBatch))
        }

        func execute(_ name: String, _ block: Block, package: ChildValidationPackage? = nil, parentFacts: (any ParentChainFacts)? = nil, grind: String? = nil) async throws {
            let before = await recorder.recordedBatches().count
            let recorder = self.recorder
            _ = try await level.admit(
                block, mode: .execution, fetcher: fetcher, childPackage: package,
                stage: { await recorder.stage($0) }
            )
            let old = await stagedSince(before)
            let new = try await TreeDriver.connect(
                try BlockHeader(node: block).rawCID, on: &tree,
                fetcher: fetcher, parentFacts: parentFacts, grind: grind
            )
            try record("\(name)/execution", old: old, new: new.update.flatMap(ChainTreeFactEquivalenceGoldenTests.onlyBatch))
        }

        func assertSameEnd(_ hashes: [String], file: StaticString = #filePath, line: UInt = #line) async {
            let tip = await level.chain.canonicalTip
            XCTAssertEqual(tree.canonicalTip, tip, "same selection", file: file, line: line)
            for hash in hashes {
                let executed = await level.chain.hasExecutedAncestry(blockHash: hash)
                XCTAssertEqual(tree.hasExecutedAncestry(blockHash: hash), executed, "same executed set at \(hash)", file: file, line: line)
            }
        }
    }

    /// A child proof of `child` through its own carrier, a parent block on
    /// `carrierParent` — so the carrier's pre-state is the child's
    /// `parentState` (`nonce` makes the carrier, and so the grind, distinct).
    private func proof(
        of child: Block,
        carrierParent: Block,
        nonce: UInt64,
        fetcher: StorableFetcher,
        context: ChainRuntimeContext,
        link: ParentStateContinuityLink? = nil
    ) async throws -> (package: ChildValidationPackage, evidence: VerifiedChildEvidence) {
        let carrier = try await buildAndStoreBlock(
            previous: carrierParent, children: ["Child": child],
            timestamp: carrierParent.timestamp + 700, target: AdmissionFixture.easy,
            nonce: 1_000 + nonce, fetcher: fetcher
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier), childDirectory: "Child", fetcher: fetcher
        )
        let evidence = try await proof.verifySecuringWork(child: child, chainPath: context.path).get()
        return (ChildValidationPackage(proof: proof, parentStateContinuityLink: link), evidence)
    }

    /// The continuity link a node derives for `child` from `facts` — present
    /// exactly when the facts answer it — or, for `wrongPath`, a link naming
    /// another parent chain.
    /// The link from `predecessor`'s anchor (the genesis pre-state for a
    /// genesis) to `child`'s, as admission expects it.
    private func continuityLink(
        for child: Block,
        after predecessor: Block? = nil,
        facts: ParentLevelFacts,
        wrongPath: Bool = false
    ) -> ParentStateContinuityLink? {
        let link = ParentStateContinuityLink(
            parentPath: wrongPath ? [DEFAULT_ROOT_DIRECTORY, "Other"] : [DEFAULT_ROOT_DIRECTORY],
            fromStateCID: predecessor?.parentState.rawCID ?? LatticeState.emptyHeader.rawCID,
            toStateCID: child.parentState.rawCID
        )
        return wrongPath || facts.hasContinuity(link) ? link : nil
    }

    /// A child chain under a parent with a main branch, an executed side
    /// branch and a subtree under an excluded root, its genesis carried
    /// under the side branch's state. Covers: genesis bootstrap from its
    /// proof and continuity via the side branch; work from a child proof and
    /// a second proof (evidence / `addWork`); continuity via the side branch,
    /// under the excluded subtree, and from facts for the wrong parent path.
    private func childChainSteps() async throws -> [Golden.Step] {
        let fetcher = StorableFetcher()
        let rootContext = testChainContext()
        let childContext = testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        let easy = AdmissionFixture.easy
        func reward(_ seed: String) -> String { testAddress(publicKey: "equivalence-\(seed)") }

        let parentGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let a = try await buildAndStoreBlock(previous: parentGenesis, timestamp: 2_000, target: easy, nonce: 1, rewardRecipient: reward("a"), fetcher: fetcher)
        let a2 = try await AdmissionFixture.makeChild(of: a, fetcher: fetcher, timestamp: 3_000, nonce: 2)
        let a3 = try await AdmissionFixture.makeChild(of: a2, fetcher: fetcher, timestamp: 4_000, nonce: 3)
        let side = try await buildAndStoreBlock(previous: parentGenesis, timestamp: 2_100, target: easy, nonce: 4, rewardRecipient: reward("side"), fetcher: fetcher)
        let childGenesis = try await BlockBuilder.buildChildGenesis(
            spec: chainLocalSpec(), parentState: side.postState,
            timestamp: 1_000, target: easy, nonce: 1, fetcher: fetcher
        )
        try await storeBuiltBlock(childGenesis, in: fetcher)
        // X declares a real state it does not produce; X1 on it executes, but
        // under a root that is then excluded.
        let rewarded = try await buildAndStoreBlock(previous: parentGenesis, timestamp: 2_200, target: easy, nonce: 6, rewardRecipient: reward("r"), fetcher: fetcher)
        let empty = try await AdmissionFixture.makeChild(of: parentGenesis, fetcher: fetcher, timestamp: 2_300, nonce: 7)
        let x = try await storeBuiltBlock(Block(
            version: empty.version, parent: empty.parent, transactions: empty.transactions,
            target: empty.target, nextTarget: empty.nextTarget, spec: empty.spec,
            parentState: empty.parentState, prevState: empty.prevState,
            postState: rewarded.postState, children: empty.children,
            height: empty.height, timestamp: empty.timestamp,
            rewardRecipient: empty.rewardRecipient, nonce: empty.nonce
        ), in: fetcher)
        let x1 = try await buildAndStoreBlock(previous: x, timestamp: 3_300, target: easy, nonce: 8, rewardRecipient: reward("x1"), fetcher: fetcher)

        var parent = try await TreeDriver.tree(genesis: parentGenesis, context: rootContext, fetcher: fetcher)
        for block in [a, a2, a3, side, x, x1] {
            _ = try await TreeDriver.insert(block, into: &parent, fetcher: fetcher)
        }
        for block in [a, a2, a3, side, x1, x] {
            _ = try await TreeDriver.connect(try BlockHeader(node: block).rawCID, on: &parent, fetcher: fetcher)
        }
        let facts = ParentLevelFacts(tree: parent)
        XCTAssertTrue(parent.isExcludedRoot(try BlockHeader(node: x).rawCID))
        XCTAssertEqual(parent.canonicalTip, try BlockHeader(node: a3).rawCID)

        // Child genesis, carried under the executed side branch's state.
        let carried = try await proof(
            of: childGenesis, carrierParent: side, nonce: 0, fetcher: fetcher, context: childContext,
            link: continuityLink(for: childGenesis, facts: facts)
        )
        XCTAssertNotNil(carried.package.parentStateContinuityLink)
        let recorder = AdmissionStageRecorder()
        let old = try await ChainLevel.bootstrap(
            context: childContext, genesisHeader: try BlockHeader(node: childGenesis),
            fetcher: fetcher, childPackage: carried.package,
            validationContentStorer: fetcher, materializedVolumeStorer: fetcher,
            stage: { await recorder.stage($0) }
        )
        guard case .accepted(let accepted) = old else {
            XCTFail("child bootstrap: \(old)")
            return []
        }
        let new = try await ChainTree.bootstrap(
            genesis: try BlockHeader(node: childGenesis), evidence: carried.evidence, fetcher: fetcher,
            context: childContext, parentFacts: facts
        ).get()
        let oldGenesisBatch = await recorder.recordedBatches().last
        let genesisHex = try Self.hex(oldGenesisBatch)
        XCTAssertEqual(genesisHex, try Self.hex(new.facts), "child genesis bootstrap facts")
        let steps = [Golden.Step(name: "child/genesis/bootstrap", facts: genesisHex)]

        let child = Pair(level: accepted.level, tree: (consume new).tree, fetcher: fetcher)
        func childBlock(parentChainBlock: Block, nonce: UInt64) async throws -> Block {
            let onParent = try await AdmissionFixture.makeChild(
                of: parentChainBlock, fetcher: fetcher, timestamp: parentChainBlock.timestamp + 500, nonce: 100 + nonce
            )
            return try await AdmissionFixture.makeChild(
                of: childGenesis, fetcher: fetcher, timestamp: 2_000 + Int64(nonce), nonce: nonce, parentChainBlock: onParent
            )
        }
        let viaSide = try await childBlock(parentChainBlock: side, nonce: 1)
        let underExcluded = try await childBlock(parentChainBlock: x1, nonce: 2)
        let wrongPath = try await childBlock(parentChainBlock: a, nonce: 3)
        XCTAssertEqual(viaSide.parentState.rawCID, side.postState.rawCID)

        let cases: [(String, Block, Block, Bool)] = [
            ("via-side", viaSide, side, false),
            ("under-excluded", underExcluded, x1, false),
            ("wrong-path", wrongPath, a, true),
        ]
        for (index, (name, block, carrierParent, wrong)) in cases.enumerated() {
            let proved = try await proof(
                of: block, carrierParent: carrierParent, nonce: 10 + UInt64(index), fetcher: fetcher, context: childContext,
                link: continuityLink(for: block, after: childGenesis, facts: facts, wrongPath: wrong)
            )
            try await child.header("child/\(name)", block, package: proved.package, evidence: proved.evidence)
            if index == 0 {
                // A second, distinct grind on the held block: evidence.
                let second = try await proof(of: block, carrierParent: carrierParent, nonce: 20, fetcher: fetcher, context: childContext)
                try await child.header("child/\(name)/second-grind", block, package: second.package, evidence: second.evidence)
            }
            let answering = wrong
                ? ParentLevelFacts(tree: parent, path: [DEFAULT_ROOT_DIRECTORY, "Other"])
                : facts
            try await child.execute(
                "child/\(name)", block, package: proved.package, parentFacts: answering,
                grind: proved.evidence.contribution?.id
            )
        }
        await child.assertSameEnd(try [childGenesis, viaSide, underExcluded, wrongPath].map { try BlockHeader(node: $0).rawCID })
        return steps + child.steps
    }

    /// The simulation corpus's discrete-event topologies: every scenario that
    /// releases blocks, with its release order read from the simulator's own
    /// trace.
    private func corpus() async -> [(scenario: String, blocks: [(String, String)], initial: [String], releases: [String])] {
        let traces = await LatticeConsensusSimulator.runDefaultScenarios()
        func releases(_ scenario: String) -> [String] {
            let trace = traces.first { $0.scenario == scenario }
            return (trace?.events ?? []).compactMap { $0.label.split(separator: " ").last.map(String.init) }
        }
        return [
            (
                "equal-work-tie-stable-base",
                [("M1", "G"), ("F1", "G")],
                ["M1"],
                ["F1"]
            ),
            (
                "seeded-withhold-release",
                [("M1", "G"), ("M2", "M1"), ("F1", "G"), ("F2", "F1"), ("F3", "F2")],
                ["M1", "M2"],
                releases("seeded-withhold-release")
            ),
        ]
    }

    func testInsertHeaderAndConnectEmitTheActorPathFactBytes() async throws {
        var steps: [Golden.Step] = []
        for entry in await corpus() {
            XCTAssertFalse(entry.releases.isEmpty, "\(entry.scenario) releases blocks")
            let fetcher = StorableFetcher()
            let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
            var blocks: [String: Block] = ["G": genesis]
            for (index, (name, parent)) in entry.blocks.enumerated() {
                let previous = try XCTUnwrap(blocks[parent])
                blocks[name] = try await AdmissionFixture.makeChild(
                    of: previous, fetcher: fetcher,
                    timestamp: 1_000 * Int64(previous.height + 2) + Int64(index),
                    nonce: UInt64(index + 1)
                )
            }
            // A proven-invalid sibling of the first main block's child: it
            // weighs, and its execution emits an exclusion on both paths.
            let invalidValid = try await AdmissionFixture.makeChild(
                of: try XCTUnwrap(blocks["M1"]), fetcher: fetcher, timestamp: 5_500, nonce: 99
            )
            blocks["X"] = try await TreeDriver.forgedPostState(of: invalidValid, seed: entry.scenario, fetcher: fetcher)

            let pair = Pair(
                level: AdmissionFixture.makeLevel(genesis: genesis),
                tree: try await TreeDriver.tree(genesis: genesis, context: testChainContext(), fetcher: fetcher),
                fetcher: fetcher
            )
            // Headers-first: each header after its parent.
            var held: Set<String> = ["G"]
            var queue = entry.initial + entry.releases + ["X"]
            let parentOf = Dictionary(uniqueKeysWithValues: entry.blocks + [("X", "M1")])
            while !queue.isEmpty {
                let index = try XCTUnwrap(queue.firstIndex { held.contains(parentOf[$0] ?? "") })
                let name = queue.remove(at: index)
                try await pair.header("\(entry.scenario)/\(name)", try XCTUnwrap(blocks[name]))
                held.insert(name)
            }
            // A re-offered header is a duplicate on both paths: no facts.
            try await pair.header("\(entry.scenario)/M1-again", try XCTUnwrap(blocks["M1"]))
            // Execution in height order, then the root genesis, whose
            // exclusion the root-exclusion rule refuses on both paths.
            let byHeight = blocks.filter { $0.key != "G" }.sorted {
                ($0.value.height, $0.key) < ($1.value.height, $1.key)
            }
            for (name, block) in byHeight {
                try await pair.execute("\(entry.scenario)/\(name)", block)
            }
            try await pair.execute("\(entry.scenario)/G", genesis)
            await pair.assertSameEnd(try blocks.values.map { try BlockHeader(node: $0).rawCID })
            steps += pair.steps
        }

        steps += try await childChainSteps()

        XCTAssertTrue(steps.contains { $0.facts == nil }, "the corpus covers a no-fact step")
        try GoldenFile.assert(
            Golden(steps: steps),
            matches: Self.goldenName,
            diff: Golden.diff
        )
    }
}
