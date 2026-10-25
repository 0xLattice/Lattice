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

final class ChainLocalAdmissionChildProofTests: XCTestCase {
    func testChildAdmissionRequiresVerifiedProofAndThenAcceptsIt() async throws {
        let fixture = try await AdmissionFixture.makeChildProofFixture()
        let header = try BlockHeader(node: fixture.candidate)

        let missingProof = try await fixture.childLevel.admit(header, fetcher: fixture.fetcher)
        XCTAssertEqual(
            missingProof.crossChainEvidenceRequirement,
            .childProof(
                chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"],
                childCID: header.rawCID
            )
        )
        XCTAssertNil(missingProof.sameChainPredecessor)

        let admitted = try await fixture.childLevel.admit(
            header,
            fetcher: fixture.fetcher,
            childPackage: fixture.package
        )
        if case .rejected(let failure, _) = admitted {
            return XCTFail("expected child admission, got \(failure)")
        }
        XCTAssertNotNil(admitted.materializedPostState)
        let childChain = await fixture.childLevel.chain
        let containsCandidate = await childChain.contains(blockHash: header.rawCID)
        XCTAssertTrue(containsCandidate)
    }

    func testChildProofRequiresItsRootInTheProof() async throws {
        let fixture = try await AdmissionFixture.makeChildProofFixture()
        let originalProof = fixture.package.proof
        let proofWithoutRoot = ChildBlockProof(
            rootCID: originalProof.rootCID,
            directoryPath: originalProof.directoryPath,
            entries: originalProof.entries.filter { $0.cid != originalProof.rootCID }
        )
        let package = ChildValidationPackage(proof: proofWithoutRoot)

        let result = try await fixture.childLevel.admit(
            fixture.candidate,
            fetcher: fixture.fetcher,
            childPackage: package
        )

        XCTAssertEqual(result.failure, .providerMalformedEvidence)
    }

    func testChildProofAcceptsAnyRootThatCommitsToTheChild() async throws {
        let fixture = try await AdmissionFixture.makeChildProofFixture()
        let alternateCarrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": fixture.candidate],
            timestamp: 4_000,
            target: AdmissionFixture.easy,
            nonce: 9,
            fetcher: fixture.fetcher
        )
        let alternateProof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: alternateCarrier),
            childDirectory: "Child",
            fetcher: fixture.fetcher
        )
        let package = ChildValidationPackage(proof: alternateProof)

        let result = try await fixture.childLevel.admit(
            fixture.candidate,
            fetcher: fixture.fetcher,
            childPackage: package
        )

        XCTAssertNil(result.failure)
    }

    func testChildProofRejectsConflictingPathEntries() async throws {
        let fixture = try await AdmissionFixture.makeChildProofFixture()
        let proof = fixture.package.proof
        let first = try XCTUnwrap(proof.entries.first)
        let conflictingProof = ChildBlockProof(
            rootCID: proof.rootCID,
            directoryPath: proof.directoryPath,
            entries: proof.entries + [(first.cid, first.data + Data([0]))]
        )
        let package = ChildValidationPackage(proof: conflictingProof)

        let result = try await fixture.childLevel.admit(
            fixture.candidate,
            fetcher: fixture.fetcher,
            childPackage: package
        )

        XCTAssertEqual(result.failure, .providerMalformedEvidence)
    }

    func testChildProofRejectsDuplicatePathEntries() async throws {
        let fixture = try await AdmissionFixture.makeChildProofFixture()
        let proof = fixture.package.proof
        let first = try XCTUnwrap(proof.entries.first)
        let duplicateProof = ChildBlockProof(
            rootCID: proof.rootCID,
            directoryPath: proof.directoryPath,
            entries: proof.entries + [first]
        )
        let package = ChildValidationPackage(proof: duplicateProof)

        let result = try await fixture.childLevel.admit(
            fixture.candidate,
            fetcher: fixture.fetcher,
            childPackage: package
        )

        XCTAssertEqual(result.failure, .providerMalformedEvidence)
    }

    func testChildProofRejectsUnrelatedPathEntries() async throws {
        let fixture = try await AdmissionFixture.makeChildProofFixture()
        let proof = fixture.package.proof
        let paddedProof = ChildBlockProof(
            rootCID: proof.rootCID,
            directoryPath: proof.directoryPath,
            entries: proof.entries + [("unused", Data([0]))]
        )

        let result = try await fixture.childLevel.admit(
            fixture.candidate,
            fetcher: fixture.fetcher,
            childPackage: ChildValidationPackage(proof: paddedProof)
        )

        XCTAssertEqual(result.failure, .providerMalformedEvidence)
    }

    func testChildWorkProofDoesNotRequireParentCarrierFact() async throws {
        let fetcher = StorableFetcher()
        let parentGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let childGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let candidate = try await AdmissionFixture.makeChild(
            of: childGenesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 2,
            parentChainBlock: parentGenesis
        )
        let parentCarrier = try await buildAndStoreBlock(
            previous: parentGenesis,
            children: ["Child": candidate],
            timestamp: 3_000,
            target: AdmissionFixture.easy,
            nonce: 3,
            fetcher: fetcher
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: parentCarrier),
            childDirectory: "Child",
            fetcher: fetcher
        )
        let childLevel = ChainLevel(
            chain: ChainState.fromGenesis(block: childGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        )
        let paddedProof = ChildBlockProof(
            rootCID: proof.rootCID,
            directoryPath: proof.directoryPath,
            entries: proof.entries + [("unused", Data([0]))]
        )
        let malformedBeforeAcquisition = try await childLevel.admit(
            candidate,
            fetcher: fetcher,
            childPackage: ChildValidationPackage(proof: paddedProof)
        )
        XCTAssertEqual(
            malformedBeforeAcquisition.failure,
            .providerMalformedEvidence
        )

        let surplusBeforeAcquisition = try await childLevel.admit(
            candidate,
            fetcher: fetcher,
            childPackage: ChildValidationPackage(
                proof: proof,
                parentStateContinuityLink: ParentStateContinuityLink(
                    parentPath: [DEFAULT_ROOT_DIRECTORY],
                    fromStateCID: LatticeState.emptyHeader.rawCID,
                    toStateCID: testCID("surplus-parent-state")
                )
            )
        )
        XCTAssertEqual(surplusBeforeAcquisition.failure, .providerMalformedEvidence)

        let missing = try await childLevel.admit(
            candidate,
            fetcher: fetcher,
            childPackage: ChildValidationPackage(proof: proof)
        )
        guard case .accepted = missing else {
            return XCTFail("proof-derived work should admit without a carrier fact")
        }
        XCTAssertNil(missing.sameChainPredecessor)
    }

    func testSecondChildRootPinsItsMaterializedVolumes() async throws {
        let fetcher = StorableFetcher()
        let durable = RecordingAdmissionStorer()
        let firstRoot = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            nonce: 1
        )
        let transaction = AdmissionFixture.unsignedStateChangingGenesisTransaction(
            key: "materialized",
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"]
        )
        let secondRoot = try await makeChildGenesis(
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 2,
            transactions: [transaction]
        )
        let childLevel = ChainLevel(
            chain: ChainState.fromGenesis(block: firstRoot),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        )
        let secondHeader = try BlockHeader(node: secondRoot)
        let package = try await carriedGenesisPackage(secondRoot, nonce: 3, fetcher: fetcher)

        let result = try await childLevel.admit(
            secondHeader,
            fetcher: fetcher,
            storer: durable,
            childPackage: package
        )

        let diff: StateDiff
        switch result {
        case .accepted(let acceptance):
            diff = try XCTUnwrap(acceptance.stateDiff)
        case .duplicate:
            return XCTFail("second root must not be a duplicate")
        case .rejected(let failure, _):
            return XCTFail("expected second child root admission, got \(failure)")
        }
        XCTAssertNotNil(result.materializedPostState)
        XCTAssertFalse(diff.created.isEmpty)
        let roots = await durable.volumeRoots()
        XCTAssertTrue(roots.contains(secondRoot.postState.rawCID))
        for (cid, createdCount) in diff.created
        where createdCount > diff.replaced[cid, default: 0] {
            XCTAssertTrue(roots.contains(cid), "materialized Volume \(cid) was not pinned")
        }
        let childChain = await childLevel.chain
        let containsSecondRoot = await childChain.contains(blockHash: secondHeader.rawCID)
        XCTAssertTrue(containsSecondRoot)
    }

    /// A child genesis is deployed by being carried: a real parent block
    /// commits it in its child index, and its proof alone weighs it. No
    /// parent record authorizes it.
    func testACarriedChildGenesisBootstrapsFromItsProofAlone() async throws {
        let fetcher = StorableFetcher()
        let parentGenesis = try await testAnchorParentGenesis(fetcher: fetcher)
        let parentLevel = AdmissionFixture.makeLevel(genesis: parentGenesis)
        let childGenesis = try await BlockBuilder.buildChildGenesis(
            spec: chainLocalSpec(),
            parentState: parentGenesis.postState,
            transactions: [AdmissionFixture.unsignedStateChangingGenesisTransaction(
                key: "child-genesis",
                chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"]
            )],
            timestamp: 1_500,
            target: AdmissionFixture.easy,
            fetcher: fetcher
        )
        try await storeBuiltBlock(childGenesis, in: fetcher)
        let childHeader = try BlockHeader(node: childGenesis)

        let carrier = try await buildAndStoreBlock(
            previous: parentGenesis,
            children: ["Child": childGenesis],
            timestamp: 2_000,
            target: AdmissionFixture.easy,
            nonce: 2,
            fetcher: fetcher
        )
        let admission = try await parentLevel.admit(try BlockHeader(node: carrier), fetcher: fetcher)
        if case .rejected(let failure, _) = admission {
            return XCTFail("the carrier should admit on the parent: \(failure)")
        }
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier),
            childDirectory: "Child",
            fetcher: fetcher
        )
        let parentState = childGenesis.parentState.rawCID
        let link = parentState == LatticeState.emptyHeader.rawCID ? nil : ParentStateContinuityLink(
            parentPath: [DEFAULT_ROOT_DIRECTORY],
            fromStateCID: LatticeState.emptyHeader.rawCID,
            toStateCID: parentState
        )
        let childBootstrapResult = try await ChainLevel.bootstrap(
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"]),
            genesisHeader: childHeader,
            fetcher: fetcher,
            childPackage: ChildValidationPackage(proof: proof, parentStateContinuityLink: link),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: testAdmissionStage
        )
        guard case .accepted(let childBootstrap) = childBootstrapResult else {
            return XCTFail("a carried genesis must bootstrap the child: \(childBootstrapResult)")
        }
        let childTip = await childBootstrap.level.chain.canonicalTip
        XCTAssertEqual(childTip, childHeader.rawCID)
    }

    func testMultiHopProofRequiresTheExactFullPath() async throws {
        let fetcher = StorableFetcher()
        let parentTemplate = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 500)
        let leafGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let candidate = try await AdmissionFixture.makeChild(
            of: leafGenesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 2,
            parentChainBlock: parentTemplate
        )
        let middleCarrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Leaf": candidate],
            timestamp: 3_000,
            target: AdmissionFixture.easy,
            nonce: 3,
            fetcher: fetcher
        )
        let rootCarrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Middle": middleCarrier],
            timestamp: 4_000,
            target: AdmissionFixture.easy,
            nonce: 4,
            fetcher: fetcher
        )
        let rootHop = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: rootCarrier),
            childDirectory: "Middle",
            fetcher: fetcher
        )
        let leafHop = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: middleCarrier),
            childDirectory: "Leaf",
            fetcher: fetcher
        )
        let proof = rootHop.composing(hop: leafHop)
        let package = try await childValidationPackage(
            proof: proof,
            fetcher: fetcher
        )
        let candidateHeader = try BlockHeader(node: candidate)
        let wrongPath = ChainLevel(
            chain: ChainState.fromGenesis(block: leafGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Middle", "Other"])
        )

        let rejected = try await wrongPath.admit(
            candidateHeader,
            fetcher: fetcher,
            childPackage: package
        )
        XCTAssertEqual(rejected.failure, .providerMalformedEvidence)

        let exactPath = ChainLevel(
            chain: ChainState.fromGenesis(block: leafGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Middle", "Leaf"])
        )
        let proofOnly = try await exactPath.admit(
            candidateHeader,
            fetcher: fetcher,
            childPackage: ChildValidationPackage(proof: proof)
        )
        guard case .accepted = proofOnly else {
            return XCTFail("the exact proof path should need no carrier fact")
        }

        let surplusEvidence = ChildValidationPackage(
            proof: proof,
            parentStateContinuityLink: ParentStateContinuityLink(
                parentPath: [DEFAULT_ROOT_DIRECTORY, "Middle"],
                fromStateCID: LatticeState.emptyHeader.rawCID,
                toStateCID: testCID("surplus-parent-state")
            )
        )
        let duplicateWithSurplusEvidence = try await exactPath.admit(
            candidateHeader,
            fetcher: fetcher,
            childPackage: surplusEvidence
        )
        guard case .duplicate = duplicateWithSurplusEvidence else {
            return XCTFail("known blocks must not re-request parent facts")
        }

        let accepted = try await exactPath.admit(
            candidateHeader,
            fetcher: fetcher,
            childPackage: package
        )
        if case .rejected(let failure, _) = accepted {
            return XCTFail("the complete path should verify: \(failure)")
        }
        let containsCandidate = await exactPath.chain.contains(blockHash: candidateHeader.rawCID)
        XCTAssertTrue(containsCandidate)
    }

    func testProofBindsEvidenceToTheSuppliedChild() async throws {
        let fixture = try await AdmissionFixture.makeChildProofFixture()
        let candidate = fixture.candidate
        let proof = fixture.package.proof
        let valid = await proof.verifySecuringWork(
            child: candidate,
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"]
        )
        guard case .success(let evidence) = valid else {
            return XCTFail("fixture proof must verify")
        }
        XCTAssertEqual(
            evidence.childCID,
            try BlockHeader(node: candidate).rawCID
        )
        XCTAssertEqual(evidence.grindID, proof.rootCID)

        let alternateRoot = await proof.verifySecuringWork(
            child: candidate,
            chainPath: ["Other", "Child"]
        )
        guard case .failure(let alternateRootFailure) = alternateRoot else {
            return XCTFail("proof verification must reject a non-Nexus root")
        }
        XCTAssertEqual(alternateRootFailure, .malformedEvidence)

        let impostor = Block(
            version: candidate.version,
            parent: candidate.parent,
            transactions: candidate.transactions,
            target: candidate.target,
            nextTarget: candidate.nextTarget,
            spec: candidate.spec,
            parentState: candidate.parentState,
            prevState: candidate.prevState,
            postState: candidate.postState,
            children: candidate.children,
            height: candidate.height,
            timestamp: candidate.timestamp,
            rewardRecipient: candidate.rewardRecipient,
            nonce: candidate.nonce + 1
        )
        let mismatched = await proof.verifySecuringWork(
            child: impostor,
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"]
        )
        guard case .failure(let failure) = mismatched else {
            return XCTFail("proof evidence must not transfer to another child")
        }
        XCTAssertEqual(failure, .malformedEvidence)
    }

    func testChildProofRejectsBrokenVerticalStateContinuity() async throws {
        let fetcher = StorableFetcher()
        let parentTemplate = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 500)
        let childGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000, nonce: 1)
        let candidate = try await AdmissionFixture.makeChild(
            of: childGenesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 2,
            parentChainBlock: parentTemplate
        )
        let wrongParentState = VolumeImpl<LatticeState>(
            rawCID: testCID("wrong-parent-state")
        )
        let tampered = candidate.set(properties: [PARENT_STATE_PROPERTY: wrongParentState])
        guard let mined = BlockBuilder.mine(block: tampered, target: AdmissionFixture.easy, maxAttempts: 10) else {
            return XCTFail("easy target should mine")
        }
        try await storeBuiltBlock(mined, in: fetcher)
        let carrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": mined],
            timestamp: 3_000,
            target: AdmissionFixture.easy,
            nonce: 3,
            fetcher: fetcher
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier),
            childDirectory: "Child",
            fetcher: fetcher
        )
        let package = try await childValidationPackage(proof: proof, fetcher: fetcher)
        let level = ChainLevel(
            chain: ChainState.fromGenesis(block: childGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        )

        let result = try await level.admit(mined, fetcher: fetcher, childPackage: package)

        XCTAssertEqual(result.failure, .protocolInvalid)
    }
}
