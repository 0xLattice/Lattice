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

/// Serves a store, but while `fault` is set every fetch other than the
/// block's own CID throws it: the block resolves, and its execution hits the
/// fault on its first read.
private actor FaultingFetcher: Fetcher {
    private let backing: StorableFetcher
    private let blockHash: String
    private var fault: (any Error)?

    init(backing: StorableFetcher, blockHash: String, fault: any Error) {
        self.backing = backing
        self.blockHash = blockHash
        self.fault = fault
    }

    func heal() { fault = nil }

    func fetch(rawCid: String) async throws -> Data {
        if let fault, rawCid != blockHash { throw fault }
        return try await backing.fetch(rawCid: rawCid)
    }
}

/// A node-local encoder or cipher fault is no verdict on the block: it is
/// retried and never excluded. A failure the content itself causes stays a
/// verdict.
final class LocalVerificationFailureTests: XCTestCase {
    private static let localFaults: [DataErrors] = [
        .serializationFailed, .encryptionFailed, .decryptionFailed, .invalidIV,
    ]

    func testDataErrorsSplitIntoLocalFaultsAndContentVerdicts() {
        for error in Self.localFaults {
            let classified = classifyValidationFailure(error)
            XCTAssertEqual(classified, .localVerificationFailure, "\(error)")
            XCTAssertFalse(BlockImport.isDeterministicInvalidity(classified), "\(error)")
            XCTAssertEqual(
                classifyResolutionFailure(error),
                .localVerificationFailure,
                "\(error)"
            )
        }
        // A CID the content names with no usable multihash, and a policy
        // input the content makes unencodable, are properties of the content.
        for error in [DataErrors.cidCreationFailed, DataErrors.missingDeclaredChild("x")] {
            let classified = classifyValidationFailure(error)
            XCTAssertEqual(classified, .protocolInvalid, "\(error)")
            XCTAssertTrue(BlockImport.isDeterministicInvalidity(classified), "\(error)")
        }
        let policy = classifyValidationFailure(
            WasmPolicyError.contextEncodingFailed
        )
        XCTAssertEqual(policy, .protocolInvalid)
        XCTAssertTrue(BlockImport.isDeterministicInvalidity(policy))
    }

    private struct Fixture {
        let fetcher: StorableFetcher
        let genesis: Block
        let block: Block
        let blockHash: String
        var tree: ChainTree
    }

    private func fixture() async throws -> Fixture {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let block = try await AdmissionFixture.makeChild(
            of: genesis, fetcher: fetcher, timestamp: 2_000, nonce: 1
        )
        var tree = try await TreeDriver.tree(
            genesis: genesis, context: testChainContext(), fetcher: fetcher
        )
        let inserted = try await TreeDriver.insert(block, into: &tree, fetcher: fetcher)
        XCTAssertNotNil(inserted.update, "\(inserted)")
        return Fixture(
            fetcher: fetcher, genesis: genesis, block: block,
            blockHash: try BlockHeader(node: block).rawCID, tree: tree
        )
    }

    func testConnectRetriesALocalFaultWithoutExcludingAndLaterValidates() async throws {
        for fault in Self.localFaults {
            var fixture = try await fixture()
            let faulting = FaultingFetcher(
                backing: fixture.fetcher, blockHash: fixture.blockHash, fault: fault
            )
            let job = try XCTUnwrap(fixture.tree.connectJob(for: fixture.blockHash, grind: nil))
            let verdict = await ChainTree.connect(job, fetcher: faulting)
            XCTAssertFalse(verdict.provesInvalid, "\(fault)")
            XCTAssertEqual(verdict.retryFailure, .localVerificationFailure, "\(fault)")

            let applied = fixture.tree.applyConnect(verdict)
            XCTAssertNil(applied.update, "\(fault): a retry emits no exclusion fact")
            XCTAssertEqual(applied.failure, .localVerificationFailure, "\(fault)")
            XCTAssertFalse(fixture.tree.hasExecutedAncestry(blockHash: fixture.blockHash))

            // The fault clears; the retry validates the block.
            await faulting.heal()
            let retried = try await TreeDriver.connect(
                fixture.blockHash, on: &fixture.tree, fetcher: faulting
            )
            let update = try XCTUnwrap(retried.update, "\(fault): \(retried)")
            XCTAssertFalse(update.excluded, "\(fault)")
            XCTAssertTrue(fixture.tree.hasExecutedAncestry(blockHash: fixture.blockHash))
        }
    }

    func testConnectStillExcludesAContentCausedFailure() async throws {
        var fixture = try await fixture()
        let faulting = FaultingFetcher(
            backing: fixture.fetcher, blockHash: fixture.blockHash,
            fault: DataErrors.cidCreationFailed
        )
        let connected = try await TreeDriver.connect(
            fixture.blockHash, on: &fixture.tree, fetcher: faulting
        )
        let update = try XCTUnwrap(connected.update, "\(connected)")
        XCTAssertTrue(update.excluded)
        XCTAssertFalse(fixture.tree.hasExecutedAncestry(blockHash: fixture.blockHash))
    }

    /// The same partition through admission as a node drives it: a local
    /// fault is retried whether execution follows the header at once or a
    /// block already weighed, and a content-caused failure of a weighed
    /// block excludes it.
    func testAdmissionRetriesALocalFaultAndStillExcludesContentFailures() async throws {
        for fault in Self.localFaults {
            let fixture = try await fixture()
            var tree = try AdmissionFixture.makeChain(genesis: fixture.genesis)
            let faulting = FaultingFetcher(
                backing: fixture.fetcher, blockHash: fixture.blockHash, fault: fault
            )
            let header = try BlockHeader(node: fixture.block)
            for mode in [TestAdmitMode.full, .execution] {
                let result = try await tree.admit(header, mode: mode, fetcher: faulting)
                XCTAssertEqual(result.failure, .localVerificationFailure, "\(fault) \(mode)")
            }
            XCTAssertFalse(tree.isExcludedRoot(fixture.blockHash), "\(fault)")
            await faulting.heal()
            let healed = try await tree.admit(header, mode: .execution, fetcher: faulting)
            let update = try XCTUnwrap(healed.update, "\(fault): the retry must validate, got \(healed)")
            XCTAssertFalse(update.excluded, "\(fault)")
        }

        // Execution excludes a content-caused failure of a weighed block:
        // applied with an exclusion, not a retryable rejection.
        let fixture = try await fixture()
        var tree = try AdmissionFixture.makeChain(genesis: fixture.genesis)
        let header = try BlockHeader(node: fixture.block)
        let weighed = try await tree.admit(header, mode: .header, fetcher: fixture.fetcher)
        XCTAssertNotNil(weighed.update, "the header must weigh, got \(weighed)")
        let faulting = FaultingFetcher(
            backing: fixture.fetcher, blockHash: fixture.blockHash,
            fault: DataErrors.cidCreationFailed
        )
        let excluded = try await tree.admit(header, mode: .execution, fetcher: faulting)
        let update = try XCTUnwrap(excluded.update, "a content-caused failure must exclude, got \(excluded)")
        XCTAssertTrue(update.excluded)
        XCTAssertTrue(update.batches.flatMap(\.facts).contains {
            if case .exclusion = $0 { return true }
            return false
        })
    }
}
