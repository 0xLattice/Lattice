import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import Foundation
import cashew

private struct LegacyDirectChildEdge: Hashable, Scalar {
    let parentCarrierCID: String
    let directory: String
    let childCID: String
    let proofBytes: Data
}

final class ChildBlockProofCoreTests: XCTestCase {
    private func proof(
        root: String = "bafyroot",
        path: [String] = ["Nexus", "ChildA"],
        entries: [(String, Data)] = [("bafyroot", Data([1, 2, 3])), ("bafychild", Data([4, 5]))]
    ) -> ChildBlockProof {
        ChildBlockProof(rootCID: root, directoryPath: path, entries: entries)
    }

    private func composedFixture() async throws -> (
        root: Block,
        leaf: Block,
        middle: Block,
        composed: ChildBlockProof,
        terminalHop: ChildBlockProof
    ) {
        let storage = StorableFetcher()
        let spec = ChainSpec.test(halfLife: 10)
        let leaf = try await buildAndStoreGenesis(
            spec: spec,
            timestamp: 1_000,
            target: .max,
            fetcher: storage
        )
        let middle = try await buildAndStoreGenesis(
            spec: spec,
            children: ["Leaf": leaf],
            timestamp: 2_000,
            target: .max,
            fetcher: storage
        )
        let root = try await buildAndStoreGenesis(
            spec: spec,
            children: ["Middle": middle],
            timestamp: 3_000,
            target: .max,
            fetcher: storage
        )
        let firstHop = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: root),
            childDirectory: "Middle",
            fetcher: storage
        )
        let terminalHop = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: middle),
            childDirectory: "Leaf",
            fetcher: storage
        )
        return (root, leaf, middle, firstHop.composing(hop: terminalHop), terminalHop)
    }

    func test_serialize_roundTrips() throws {
        let p = proof()
        guard let back = ChildBlockProof.deserialize(try p.serialize()) else {
            return XCTFail("deserialize failed")
        }
        XCTAssertEqual(back.rootCID, p.rootCID)
        XCTAssertEqual(back.directoryPath, p.directoryPath)
        XCTAssertEqual(back.entries.map(\.cid), p.entries.map(\.cid))
        XCTAssertEqual(back.entries.map(\.data), p.entries.map(\.data))
    }

    func test_deserialize_rejectsTruncated() throws {
        let bytes = try proof().serialize()
        XCTAssertNil(ChildBlockProof.deserialize(bytes.prefix(bytes.count - 1)),
                     "a truncated proof must not decode")
        XCTAssertNil(ChildBlockProof.deserialize(Data()), "empty input must not decode")
        XCTAssertNil(
            ChildBlockProof.deserialize(bytes + Data([0])),
            "trailing bytes must not produce a second encoding of the same proof"
        )
    }

    func test_serializeRejectsOversizedFields() {
        let oversized = String(repeating: "x", count: Int(UInt16.max) + 1)
        XCTAssertThrowsError(
            try proof(root: oversized).serialize()
        ) { error in
            XCTAssertEqual(error as? ChildProofSerializationError, .valueTooLarge)
        }
    }

    func test_serializeEnforcesExactDirectoryAndDepthBounds() throws {
        let maximumDirectory = String(
            repeating: "x",
            count: ChildProofWireLimits.maximumDirectoryBytes
        )
        XCTAssertNoThrow(try proof(path: [maximumDirectory]).serialize())
        XCTAssertThrowsError(try proof(path: [maximumDirectory + "x"]).serialize()) {
            XCTAssertEqual($0 as? ChildProofSerializationError, .valueTooLarge)
        }

        XCTAssertNoThrow(try proof(path: Array(
            repeating: "x",
            count: ChildProofWireLimits.maximumDepth
        )).serialize())
        XCTAssertThrowsError(try proof(path: Array(
            repeating: "x",
            count: ChildProofWireLimits.maximumDepth + 1
        )).serialize()) {
            XCTAssertEqual($0 as? ChildProofSerializationError, .valueTooLarge)
        }
    }

    func test_deserializeRejectsNonCanonicalEntryOrder() throws {
        var nonCanonical = try proof(root: "r", path: [], entries: [
            ("a", Data([1])),
            ("b", Data([2]))
        ]).serialize()
        nonCanonical.swapAt(9, 17)

        XCTAssertNil(ChildBlockProof.deserialize(nonCanonical))
    }

    func test_composing_concatenatesDirectoryPath() {
        let hop1 = proof(root: "bafyA", path: ["Nexus", "A"], entries: [("bafyA", Data([1]))])
        let hop2 = proof(root: "bafyB", path: ["A", "B"], entries: [("bafyB", Data([2]))])
        let composed = hop1.composing(hop: hop2)
        XCTAssertEqual(composed.directoryPath.first, "Nexus")
        XCTAssertEqual(composed.directoryPath.last, "B")
    }

    func test_composingDeduplicatesIdenticalEntries() {
        let shared = ("shared", Data([1]))
        let upstream = proof(entries: [shared])
        let hop = proof(root: "shared", path: ["Child"], entries: [shared])

        let composed = upstream.composing(hop: hop)

        XCTAssertEqual(composed.entries.count, 1)
    }

    func test_directHopExtractsCanonicalTerminalHopAndBindsChild() async throws {
        let fixture = try await composedFixture()
        let extracted = await fixture.composed.directHop()
        let direct = try XCTUnwrap(extracted)

        XCTAssertEqual(
            try direct.proof.serialize(),
            try fixture.terminalHop.serialize()
        )
        XCTAssertEqual(direct.childCID, try BlockHeader(node: fixture.leaf).rawCID)
        XCTAssertEqual(direct.parentStateCID, fixture.middle.prevState.rawCID)
        XCTAssertTrue(direct.binds(child: fixture.leaf))
        XCTAssertFalse(direct.binds(child: fixture.middle))

        let reextractedResult = await fixture.terminalHop.directHop()
        let reextracted = try XCTUnwrap(reextractedResult)
        XCTAssertEqual(
            try reextracted.proof.serialize(),
            try fixture.terminalHop.serialize()
        )
    }

    func test_directChildEdgeCanonicalizesTerminalHopAndBindsChild() async throws {
        let fixture = try await composedFixture()
        let derived = await DirectChildEdge.derive(from: fixture.composed)
        let edge = try XCTUnwrap(derived)

        XCTAssertEqual(edge.parentCarrierCID, fixture.terminalHop.rootCID)
        XCTAssertEqual(edge.directory, try XCTUnwrap(fixture.terminalHop.directoryPath.last))
        XCTAssertEqual(edge.childCID, try BlockHeader(node: fixture.leaf).rawCID)
        XCTAssertEqual(edge.proofBytes, try fixture.terminalHop.serialize())
        XCTAssertNotNil(edge.edgeCID)
        XCTAssertEqual(
            edge.edgeCID,
            try HeaderImpl<LegacyDirectChildEdge>(node: .init(
                parentCarrierCID: edge.parentCarrierCID,
                directory: edge.directory,
                childCID: edge.childCID,
                proofBytes: edge.proofBytes
            )).rawCID
        )
        let bindsLeaf = await edge.validates(child: fixture.leaf)
        let bindsMiddle = await edge.validates(child: fixture.middle)
        XCTAssertTrue(bindsLeaf)
        XCTAssertFalse(bindsMiddle)

        let malformed = DirectChildEdge(
            parentCarrierCID: edge.parentCarrierCID,
            directory: edge.directory,
            childCID: edge.childCID,
            proofBytes: edge.proofBytes + Data([0])
        )
        let validatedMalformed = await malformed.validated()
        XCTAssertNil(validatedMalformed)
    }

    func test_directHopRejectsDuplicateEntries() async throws {
        let fixture = try await composedFixture()
        let duplicate = ChildBlockProof(
            rootCID: fixture.composed.rootCID,
            directoryPath: fixture.composed.directoryPath,
            entries: fixture.composed.entries + [try XCTUnwrap(fixture.composed.entries.first)]
        )

        let extracted = await duplicate.directHop()
        XCTAssertNil(extracted)
    }

    func test_directHopRejectsMalformedOrUnresolvableProofs() async throws {
        let fixture = try await composedFixture()
        let emptyPath = ChildBlockProof(
            rootCID: fixture.composed.rootCID,
            directoryPath: [],
            entries: fixture.composed.entries
        )
        let malformedEntry = ChildBlockProof(
            rootCID: fixture.composed.rootCID,
            directoryPath: fixture.composed.directoryPath,
            entries: fixture.composed.entries + [("not-a-cid", Data([1]))]
        )
        let missingRoot = ChildBlockProof(
            rootCID: testCID("missing-root"),
            directoryPath: fixture.composed.directoryPath,
            entries: fixture.composed.entries
        )

        let emptyPathResult = await emptyPath.directHop()
        let malformedEntryResult = await malformedEntry.directHop()
        let missingRootResult = await missingRoot.directHop()
        XCTAssertNil(emptyPathResult)
        XCTAssertNil(malformedEntryResult)
        XCTAssertNil(missingRootResult)
    }

    func test_targetedResolutionRejectsTamperedIntermediateBytes() async throws {
        let fixture = try await composedFixture()
        guard let index = fixture.composed.entries.firstIndex(where: {
            $0.cid != fixture.composed.rootCID
        }) else {
            return XCTFail("fixture requires an intermediate CAS entry")
        }
        var entries = fixture.composed.entries
        entries[index].data.append(0)
        let tampered = ChildBlockProof(
            rootCID: fixture.composed.rootCID,
            directoryPath: fixture.composed.directoryPath,
            entries: entries
        )

        let result = tampered.verifySecuringWork(
            child: fixture.leaf,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
                + fixture.composed.directoryPath
        )

        guard case .failure(let failure) = result else {
            return XCTFail("targeted resolution accepted bytes under the wrong CID")
        }
        XCTAssertEqual(failure, .malformedEvidence)
    }

    func test_schedulingTargetsDerivesOnlyContentBoundPathTargets() async throws {
        let fixture = try await composedFixture()
        let result = await fixture.composed.schedulingTargets(
            root: fixture.root,
            terminal: fixture.leaf
        )
        let targets = try XCTUnwrap(result)

        XCTAssertEqual(targets.searchTarget, fixture.leaf.target)
        XCTAssertEqual(
            targets.deploymentTarget,
            min(min(fixture.root.target, fixture.middle.target), fixture.leaf.target)
        )

        let wrongRoot = await fixture.composed.schedulingTargets(
            root: fixture.middle,
            terminal: fixture.leaf
        )
        let wrongTerminal = await fixture.composed.schedulingTargets(
            root: fixture.root,
            terminal: fixture.middle
        )
        XCTAssertNil(wrongRoot)
        XCTAssertNil(wrongTerminal)

        let padded = ChildBlockProof(
            rootCID: fixture.composed.rootCID,
            directoryPath: fixture.composed.directoryPath,
            entries: fixture.composed.entries + [(testCID("unused"), Data([1]))]
        )
        let paddedResult = await padded.schedulingTargets(
            root: fixture.root,
            terminal: fixture.leaf
        )
        XCTAssertNil(paddedResult)

        let emptyPath = ChildBlockProof(
            rootCID: fixture.composed.rootCID,
            directoryPath: [],
            entries: fixture.composed.entries
        )
        let emptyPathResult = await emptyPath.schedulingTargets(
            root: fixture.root,
            terminal: fixture.leaf
        )
        XCTAssertNil(emptyPathResult)
    }
}
