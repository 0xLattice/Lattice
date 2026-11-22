import Foundation
import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import UInt256
import cashew
import WAT

/// What one admission emits: the facts a node makes durable, the duplicate
/// that emits none, and the canonical change it reports.
final class AdmissionFactEmissionTests: XCTestCase {
    func testAdmissionEmitsBlockWithInitialWorkThenOnlyNewGrind() async throws {
        var fixture = try await AdmissionFixture.makeChildProofFixture()
        let alternateCarrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": fixture.candidate],
            timestamp: 4_000,
            target: AdmissionFixture.easy,
            nonce: 4,
            fetcher: fixture.fetcher
        )
        let alternateProof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: alternateCarrier),
            childDirectory: "Child",
            fetcher: fixture.fetcher
        )
        let header = try BlockHeader(node: fixture.candidate)

        let initial = try await fixture.childChain.admit(
            header,
            fetcher: fixture.fetcher,
            child: fixture.package
        )
        let later = try await fixture.childChain.admit(
            header,
            mode: .header,
            fetcher: fixture.fetcher,
            child: TestChildPackage(proof: alternateProof)
        )

        let initialUpdate = try XCTUnwrap(initial.update, "the first grind must apply, got \(initial)")
        let laterUpdate = try XCTUnwrap(later.update, "a distinct grind must apply, got \(later)")
        guard initialUpdate.batches.count == 1,
              laterUpdate.batches.count == 1 else {
            return XCTFail("expected one batch each: \(initialUpdate.batches) \(laterUpdate.batches)")
        }
        let first = initialUpdate.batches[0]
        let second = laterUpdate.batches[0]
        guard // block + work + validation from execution; the later grind
              // emits work alone.
              first.facts.count == 3,
              case .block(let blockFact) = first.facts[0],
              case .work(let initialWork) = first.facts[1],
              case .validation = first.facts[2],
              second.facts.count == 1,
              case .work(let laterWork) = second.facts[0] else {
            return XCTFail("expected one block/work/validation batch and one work-only batch")
        }
        XCTAssertEqual(blockFact.blockHash, header.rawCID)
        XCTAssertEqual(initialWork.blockHash, header.rawCID)
        XCTAssertEqual(initialWork.contribution.id, fixture.package.proof.rootCID)
        XCTAssertEqual(
            first.facts[1].id,
            .work(
                blockHash: header.rawCID,
                grindID: fixture.package.proof.rootCID,
                work: initialWork.contribution.work.toHexString()
            )
        )
        XCTAssertEqual(laterWork.blockHash, header.rawCID)
        XCTAssertEqual(laterWork.contribution.id, alternateProof.rootCID)
        XCTAssertEqual(
            second.facts[0].id,
            .work(
                blockHash: header.rawCID,
                grindID: alternateProof.rootCID,
                work: laterWork.contribution.work.toHexString()
            )
        )
    }

    func testReplayIsDuplicateAndEmitsNothing() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let candidate = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        var tree = try AdmissionFixture.makeChain(genesis: genesis)
        let header = try BlockHeader(node: candidate)

        let admitted = try await tree.admit(header, fetcher: fetcher)
        XCTAssertNotNil(admitted.update, "\(admitted)")

        let replay = try await tree.admit(header, fetcher: fetcher)

        guard case .duplicate = replay else {
            return XCTFail("known consensus facts must remain duplicate, got \(replay)")
        }
    }

    func testOrphanIsHeldUntilItsSameChainPredecessorConnects() async throws {
        // A header over a parent the tree does not hold emits nothing and is
        // held; once the predecessor is admitted, the same header applies.
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let missingParent = try await AdmissionFixture.makeChild(
            of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1
        )
        let orphan = try await buildAndStoreBlock(
            previous: missingParent,
            timestamp: 3_000,
            target: AdmissionFixture.easy,
            nonce: 2,
            fetcher: fetcher
        )
        let orphanHeader = try BlockHeader(node: orphan)
        var tree = try AdmissionFixture.makeChain(genesis: genesis)

        let held = try await tree.admit(orphanHeader, fetcher: fetcher)

        XCTAssertEqual(held.failure, .unavailableEvidence)
        XCTAssertFalse(tree.contains(blockHash: orphanHeader.rawCID))

        let parent = try await tree.admit(missingParent, fetcher: fetcher)
        XCTAssertNotNil(parent.update, "\(parent)")
        let connected = try await tree.admit(orphanHeader, fetcher: fetcher)
        XCTAssertNotNil(connected.update, "\(connected)")
        XCTAssertEqual(tree.canonicalTip, orphanHeader.rawCID)
    }

    func testDuplicateReadmissionPromotesSideBlockThatBecomesHeaviest() async throws {
        // A cold-syncing host can hold a block in the graph a moment before
        // the fork-choice landscape that makes it canonical is complete. When
        // the completing evidence lands, the block is re-admitted; because it
        // carries no stronger work it is classified a duplicate. The duplicate
        // seam must still re-run the existing fork choice, or the
        // now-heaviest side block is never promoted.
        //
        // Pure sequential admission self-heals (a connecting mutation re-projects),
        // so the stranded landscape is reconstructed directly: a real, heavier
        // fork present in the durable graph while the canonical projection still
        // points at a lighter fork.
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let incumbent = try await AdmissionFixture.makeChild(
            of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1
        )
        let heavier1 = try await AdmissionFixture.makeChild(
            of: genesis, fetcher: fetcher, timestamp: 2_500, nonce: 2
        )
        let heavier2 = try await AdmissionFixture.makeChild(
            of: heavier1, fetcher: fetcher, timestamp: 3_500, nonce: 3
        )
        let genesisCID = try BlockHeader(node: genesis).rawCID
        let incumbentCID = try BlockHeader(node: incumbent).rawCID
        let heavier1CID = try BlockHeader(node: heavier1).rawCID
        let heavier2CID = try BlockHeader(node: heavier2).rawCID

        // Admit every block through the normal path so the graph records their
        // real, self-consistent work facts. This tree self-heals to the heavier
        // fork; it is only a source of authentic block metadata.
        var source = try AdmissionFixture.makeChain(genesis: genesis)
        for block in [incumbent, heavier1, heavier2] {
            let admitted = try await source.admit(block, fetcher: fetcher)
            XCTAssertNotNil(admitted.update, "\(admitted)")
        }
        let hashes = [genesisCID, incumbentCID, heavier1CID, heavier2CID]
        var metas: [String: BlockMeta] = [:]
        for hash in hashes {
            metas[hash] = try XCTUnwrap(source.getConsensusBlock(hash: hash))
        }

        // Reconstruct the stranded landscape: the heavier fork is fully present
        // and executed in the durable graph, but the canonical projection still
        // points at the lighter incumbent tip.
        var stranded = try ChainTree(
            canonicalTip: incumbentCID,
            canonicalHashes: [genesisCID, incumbentCID],
            indexToBlockHash: [:],
            hashToBlock: metas,
            validatedBlocks: Set(hashes)
        )
        XCTAssertEqual(
            stranded.canonicalTip, incumbentCID,
            "the stranded projection must start on the lighter fork"
        )

        // Re-admit the heaviest tip's header with its own grind. It is
        // already held with equal work, so it is a duplicate. The seam re-runs
        // fork choice and surfaces the promotion.
        let replay = stranded.insertHeader(
            heavier2,
            blockHash: heavier2CID,
            childIndex: testChildIndex(heavier2),
            work: try XCTUnwrap(ChainTree.rootWork(of: heavier2)),
            validationContext: .current
        )
        guard case .duplicate(let promoted) = replay else {
            return XCTFail("the known heavier tip must re-admit as a duplicate, got \(replay)")
        }
        let commit = try XCTUnwrap(
            promoted,
            "the duplicate seam must surface the fork-choice promotion"
        )
        XCTAssertTrue(commit.canonicalChanged)
        XCTAssertEqual(commit.tipHash, heavier2CID)
        XCTAssertEqual(stranded.canonicalTip, heavier2CID)
    }

    func testAdmissionReturnsExactChainLocalReorganization() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let main1 = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1)
        let main2 = try await AdmissionFixture.makeChild(of: main1, fetcher: fetcher, timestamp: 3_000, nonce: 2)
        let fork1 = try await AdmissionFixture.makeChild(of: genesis, fetcher: fetcher, timestamp: 2_500, nonce: 3)
        let fork2 = try await AdmissionFixture.makeChild(of: fork1, fetcher: fetcher, timestamp: 3_500, nonce: 4)
        let fork3 = try await AdmissionFixture.makeChild(of: fork2, fetcher: fetcher, timestamp: 4_500, nonce: 5)
        var tree = try AdmissionFixture.makeChain(genesis: genesis)
        // The net canonical change one block's admission reported: its
        // header's, then its execution's.
        func admitted(_ block: Block) async throws -> ChainCommit? {
            let header = try await tree.admit(block, mode: .header, fetcher: fetcher)
            let execution = try await tree.admit(block, mode: .execution, fetcher: fetcher)
            XCTAssertNotNil(header.update, "\(header)")
            XCTAssertNotNil(execution.update, "\(execution)")
            return ChainCommit.composing(header.update?.commit, then: execution.update?.commit)
        }

        for block in [main1, main2] {
            _ = try await admitted(block)
        }
        _ = try await admitted(fork1)
        let fork2Commit = try await admitted(fork2)
        let fork3Commit = try await admitted(fork3)

        let main1Hash = try BlockHeader(node: main1).rawCID
        let fork1Hash = try BlockHeader(node: fork1).rawCID
        let forkWinsTie = forkChoicePrefersBlock(
            fork1Hash,
            over: main1Hash
        )
        let commit = try XCTUnwrap(
            forkWinsTie ? fork2Commit : fork3Commit
        )
        let winningPrefix = forkWinsTie ? [fork1, fork2] : [fork1, fork2, fork3]
        let forkHashes = try Set(winningPrefix.map { try BlockHeader(node: $0).rawCID })
        let mainHashes = try Set([main1, main2].map { try BlockHeader(node: $0).rawCID })
        XCTAssertEqual(
            commit.tipHash,
            try BlockHeader(node: forkWinsTie ? fork2 : fork3).rawCID
        )
        XCTAssertTrue(commit.canonicalChanged)
        XCTAssertEqual(Set(commit.canonicalBlocksAdded.keys), forkHashes)
        XCTAssertEqual(commit.canonicalBlocksRemoved, mainHashes)
        XCTAssertEqual(tree.canonicalTip, try BlockHeader(node: fork3).rawCID)
    }
}
