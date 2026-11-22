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

/// A child block weighs only by a `ChildBlockProof` that verifies for
/// exactly it on exactly this chain's path. A proof whose bytes do not prove
/// the child is a proof-of-work failure (`ChainTree.headerFailure`); one
/// that proves it against a carrier it does not enter from is structural.
final class ChainLocalAdmissionChildProofTests: XCTestCase {
    func testChildAdmissionRequiresVerifiedProofAndThenAcceptsIt() async throws {
        var fixture = try await AdmissionFixture.makeChildProofFixture()
        let header = try BlockHeader(node: fixture.candidate)

        let missingProof = try await fixture.childChain.admit(header, fetcher: fixture.fetcher)
        XCTAssertEqual(
            missingProof.failure,
            .crossChainEvidenceRequired(.childProof(
                chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"],
                childCID: header.rawCID
            ))
        )
        XCTAssertFalse(fixture.childChain.contains(blockHash: header.rawCID))

        let admitted = try await fixture.childChain.admit(
            header,
            fetcher: fixture.fetcher,
            child: fixture.package
        )
        if let failure = admitted.failure {
            return XCTFail("expected child admission, got \(failure)")
        }
        XCTAssertEqual(admitted.update?.excluded, false)
        XCTAssertNotNil(admitted.update?.materializedPostState)
        XCTAssertTrue(fixture.childChain.contains(blockHash: header.rawCID))
        XCTAssertTrue(fixture.childChain.isExecuted(blockHash: header.rawCID))
    }

    func testChildProofRequiresItsRootInTheProof() async throws {
        var fixture = try await AdmissionFixture.makeChildProofFixture()
        let originalProof = fixture.package.proof
        let proofWithoutRoot = ChildBlockProof(
            rootCID: originalProof.rootCID,
            directoryPath: originalProof.directoryPath,
            entries: originalProof.entries.filter { $0.cid != originalProof.rootCID }
        )
        let package = TestChildPackage(proof: proofWithoutRoot)

        let result = try await fixture.childChain.admit(
            fixture.candidate,
            fetcher: fixture.fetcher,
            child: package
        )

        XCTAssertEqual(result.failure, .proofOfWorkInvalid)
    }

    func testChildProofAcceptsAnyRootThatCommitsToTheChild() async throws {
        var fixture = try await AdmissionFixture.makeChildProofFixture()
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
        let package = TestChildPackage(proof: alternateProof)

        let result = try await fixture.childChain.admit(
            fixture.candidate,
            fetcher: fixture.fetcher,
            child: package
        )

        XCTAssertNil(result.failure)
    }

    func testChildProofRejectsConflictingPathEntries() async throws {
        var fixture = try await AdmissionFixture.makeChildProofFixture()
        let proof = fixture.package.proof
        let first = try XCTUnwrap(proof.entries.first)
        let conflictingProof = ChildBlockProof(
            rootCID: proof.rootCID,
            directoryPath: proof.directoryPath,
            entries: proof.entries + [(first.cid, first.data + Data([0]))]
        )
        let package = TestChildPackage(proof: conflictingProof)

        let result = try await fixture.childChain.admit(
            fixture.candidate,
            fetcher: fixture.fetcher,
            child: package
        )

        XCTAssertEqual(result.failure, .proofOfWorkInvalid)
    }

    func testChildProofRejectsDuplicatePathEntries() async throws {
        var fixture = try await AdmissionFixture.makeChildProofFixture()
        let proof = fixture.package.proof
        let first = try XCTUnwrap(proof.entries.first)
        let duplicateProof = ChildBlockProof(
            rootCID: proof.rootCID,
            directoryPath: proof.directoryPath,
            entries: proof.entries + [first]
        )
        let package = TestChildPackage(proof: duplicateProof)

        let result = try await fixture.childChain.admit(
            fixture.candidate,
            fetcher: fixture.fetcher,
            child: package
        )

        XCTAssertEqual(result.failure, .proofOfWorkInvalid)
    }

    func testChildProofRejectsUnrelatedPathEntries() async throws {
        var fixture = try await AdmissionFixture.makeChildProofFixture()
        let proof = fixture.package.proof
        let paddedProof = ChildBlockProof(
            rootCID: proof.rootCID,
            directoryPath: proof.directoryPath,
            entries: proof.entries + [("unused", Data([0]))]
        )

        let result = try await fixture.childChain.admit(
            fixture.candidate,
            fetcher: fixture.fetcher,
            child: TestChildPackage(proof: paddedProof)
        )

        XCTAssertEqual(result.failure, .proofOfWorkInvalid)
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
        var childChain = try ChainTree.fromGenesis(
            block: childGenesis,
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"]),
            spec: chainLocalSpec()
        )
        let paddedProof = ChildBlockProof(
            rootCID: proof.rootCID,
            directoryPath: proof.directoryPath,
            entries: proof.entries + [("unused", Data([0]))]
        )
        let malformedBeforeAcquisition = try await childChain.admit(
            candidate,
            fetcher: fetcher,
            child: TestChildPackage(proof: paddedProof)
        )
        XCTAssertEqual(
            malformedBeforeAcquisition.failure,
            .proofOfWorkInvalid
        )

        let missing = try await childChain.admit(
            candidate,
            fetcher: fetcher,
            child: TestChildPackage(proof: proof)
        )
        guard let update = missing.update, !update.excluded else {
            return XCTFail("proof-derived work should admit without a carrier fact, got \(missing)")
        }
        XCTAssertTrue(childChain.isExecuted(blockHash: try BlockHeader(node: candidate).rawCID))
    }

    /// A second child root weighs by its carrier proof and executes like any
    /// child block, producing its materialized post-state.
    func testSecondChildRootExecutesToItsMaterializedPostState() async throws {
        let fetcher = StorableFetcher()
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
        var childChain = try ChainTree.fromGenesis(
            block: firstRoot,
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"]),
            spec: chainLocalSpec()
        )
        let secondHeader = try BlockHeader(node: secondRoot)
        let package = try await carriedGenesisPackage(secondRoot, nonce: 3, fetcher: fetcher)
        let evidence = try package.proof.verifySecuringWork(
            child: secondRoot, chainPath: [DEFAULT_ROOT_DIRECTORY, "Child"]
        ).get()

        let weighed = childChain.insertGenesis(
            secondRoot, spec: chainLocalSpec(), childIndex: testChildIndex(secondRoot), evidence: evidence
        )
        XCTAssertNotNil(weighed.update, "second child root weighs: \(weighed)")
        let job = try XCTUnwrap(childChain.connectJob(for: secondHeader.rawCID))
        let result = childChain.applyConnect(
            await ChainTree.connect(job, fetcher: fetcher, parentFacts: package.parentFacts)
        )

        guard let update = result.update else {
            return XCTFail("expected second child root execution, got \(result)")
        }
        XCTAssertFalse(update.excluded)
        let diff = try XCTUnwrap(update.batches.flatMap(\.facts).lazy.compactMap { fact -> StateDiff? in
            if case .block(let block) = fact { return block.stateDiff }
            return nil
        }.first)
        let materialized = try XCTUnwrap(update.materializedPostState)
        XCTAssertEqual(try LatticeStateHeader(node: materialized).rawCID, secondRoot.postState.rawCID)
        XCTAssertFalse(diff.created.isEmpty)
        XCTAssertTrue(childChain.contains(blockHash: secondHeader.rawCID))
        XCTAssertTrue(childChain.isExecuted(blockHash: secondHeader.rawCID))
    }

    /// A child genesis is deployed by being carried: a real parent block
    /// commits it in its child index, and its proof alone weighs it. No
    /// parent record authorizes it.
    func testACarriedChildGenesisBootstrapsFromItsProofAlone() async throws {
        let fetcher = StorableFetcher()
        let parentGenesis = try await testAnchorParentGenesis(fetcher: fetcher)
        var parentChain = try AdmissionFixture.makeChain(genesis: parentGenesis)
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
        let admission = try await parentChain.admit(try BlockHeader(node: carrier), fetcher: fetcher)
        if let failure = admission.failure {
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
        let childPath = [DEFAULT_ROOT_DIRECTORY, "Child"]
        let childBootstrapResult = await ChainTree.bootstrap(
            genesis: childHeader,
            evidence: try proof.verifySecuringWork(child: childGenesis, chainPath: childPath).get(),
            fetcher: fetcher,
            context: testChainContext(path: childPath),
            parentFacts: TestChildPackage(proof: proof, parentStateContinuityLink: link).parentFacts
        )
        guard case .success(let childBootstrap) = childBootstrapResult else {
            return XCTFail("a carried genesis must bootstrap the child: \(childBootstrapResult)")
        }
        XCTAssertEqual(childBootstrap.tree.canonicalTip, childHeader.rawCID)
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
        let package = TestChildPackage(proof: proof)
        let candidateHeader = try BlockHeader(node: candidate)
        var wrongPath = try ChainTree.fromGenesis(
            block: leafGenesis,
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Middle", "Other"]),
            spec: chainLocalSpec()
        )

        let rejected = try await wrongPath.admit(
            candidateHeader,
            fetcher: fetcher,
            child: package
        )
        XCTAssertEqual(rejected.failure, .proofOfWorkInvalid)

        var exactPath = try ChainTree.fromGenesis(
            block: leafGenesis,
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Middle", "Leaf"]),
            spec: chainLocalSpec()
        )
        let proofOnly = try await exactPath.admit(
            candidateHeader,
            fetcher: fetcher,
            child: TestChildPackage(proof: proof)
        )
        guard let update = proofOnly.update, !update.excluded else {
            return XCTFail("the exact proof path should need no carrier fact, got \(proofOnly)")
        }

        let surplusEvidence = TestChildPackage(
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
            child: surplusEvidence
        )
        guard case .duplicate = duplicateWithSurplusEvidence else {
            return XCTFail("known blocks must not re-request parent facts")
        }

        let accepted = try await exactPath.admit(
            candidateHeader,
            fetcher: fetcher,
            child: package
        )
        if let failure = accepted.failure {
            return XCTFail("the complete path should verify: \(failure)")
        }
        XCTAssertTrue(exactPath.contains(blockHash: candidateHeader.rawCID))
    }

    func testProofBindsEvidenceToTheSuppliedChild() async throws {
        let fixture = try await AdmissionFixture.makeChildProofFixture()
        let candidate = fixture.candidate
        let proof = fixture.package.proof
        let valid = proof.verifySecuringWork(
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

        let alternateRoot = proof.verifySecuringWork(
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
        let mismatched = proof.verifySecuringWork(
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
        let package = TestChildPackage(proof: proof)
        var level = try ChainTree.fromGenesis(
            block: childGenesis,
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"]),
            spec: chainLocalSpec()
        )

        let result = try await level.admit(mined, fetcher: fetcher, child: package)

        XCTAssertEqual(result.failure, .protocolInvalid)
    }
}
