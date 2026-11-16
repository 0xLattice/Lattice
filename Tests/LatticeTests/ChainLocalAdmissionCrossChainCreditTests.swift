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

final class ChainLocalAdmissionCrossChainCreditTests: XCTestCase {
    private func verifiedMultiHopContribution(
        outerTarget: UInt256,
        middleTarget: UInt256,
        leafTarget: UInt256,
        miningTarget: UInt256
    ) async throws -> (
        fetcher: StorableFetcher,
        leafGenesis: Block,
        candidate: Block,
        package: ChildValidationPackage,
        downstreamCID: String,
        contribution: VerifiedWorkContribution,
        rootHash: UInt256,
        rootCID: String
    ) {
        let fetcher = StorableFetcher()
        let parentTemplate = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 500)
        let leafGenesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            timestamp: 1_000,
            target: leafTarget,
            nonce: 1,
            fetcher: fetcher
        )
        let downstream = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            timestamp: 1_500,
            target: leafTarget,
            nonce: 5,
            fetcher: fetcher
        )
        let leaf = try await buildAndStoreBlock(
            previous: leafGenesis,
            children: ["Downstream": downstream],
            parentChainBlock: parentTemplate,
            timestamp: 2_000,
            target: leafTarget,
            nextTarget: leafTarget,
            nonce: 2,
            fetcher: fetcher
        )
        let middle = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Leaf": leaf],
            timestamp: 3_000,
            target: middleTarget,
            nonce: 3,
            fetcher: fetcher
        )
        let rootTemplate = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Middle": middle],
            timestamp: 4_000,
            target: outerTarget,
            nonce: 4,
            fetcher: fetcher
        )
        let root = try XCTUnwrap(
            BlockBuilder.mine(
                block: rootTemplate,
                target: miningTarget,
                maxAttempts: 1_000_000
            ),
            "the fixture must find a root grind under its hardest accepted target"
        )
        try await storeBuiltBlock(root, in: fetcher)

        let rootHop = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: root),
            childDirectory: "Middle",
            fetcher: fetcher
        )
        let leafHop = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: middle),
            childDirectory: "Leaf",
            fetcher: fetcher
        )
        let proof = rootHop.composing(hop: leafHop)
        let package = try await childValidationPackage(
            proof: proof,
            fetcher: fetcher
        )
        let verification = proof.verifySecuringWork(
            child: leaf,
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Middle", "Leaf"]
        )
        guard case .success(let evidence) = verification else {
            throw ChainLocalTestError.unexpectedFailure
        }
        return (
            fetcher: fetcher,
            leafGenesis: leafGenesis,
            candidate: leaf,
            package: package,
            downstreamCID: try BlockHeader(node: downstream).rawCID,
            contribution: try XCTUnwrap(evidence.contribution),
            rootHash: root.proofOfWorkHash(),
            rootCID: proof.rootCID
        )
    }

    func testTargetHitInvalidTransitionIsRejectedWithoutPredecessor() async throws {
        let fetcher = StorableFetcher()
        let genesis = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            transactions: [AdmissionFixture.unsignedStateChangingGenesisTransaction(
                key: "carrier-parent",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )]
        )
        let valid = try await AdmissionFixture.makeChild(
            of: genesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 1
        )
        XCTAssertNotEqual(valid.postState.rawCID, LatticeState.emptyHeader.rawCID)
        let invalid = Block(
            version: valid.version,
            parent: valid.parent,
            transactions: valid.transactions,
            target: valid.target,
            nextTarget: valid.nextTarget,
            spec: valid.spec,
            parentState: valid.parentState,
            prevState: valid.prevState,
            postState: LatticeState.emptyHeader,
            children: valid.children,
            height: valid.height,
            timestamp: valid.timestamp,
            rewardRecipient: valid.rewardRecipient,
            nonce: valid.nonce
        )
        try await storeBuiltBlock(invalid, in: fetcher)
        let header = try BlockHeader(node: invalid)
        let recorder = AdmissionStageRecorder()

        let result = try await AdmissionFixture.makeLevel(genesis: genesis)
            .admit(header, fetcher: fetcher, stage: { batch in await recorder.stage(batch) })

        guard case .rejected(let failure, _) = result else {
            return XCTFail("local invalidity must remain visible")
        }
        XCTAssertEqual(failure, .protocolInvalid)
        let stageCount = await recorder.count(for: header.rawCID)
        XCTAssertEqual(stageCount, 0)

        let otherGenesis = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher,
            timestamp: 500,
            nonce: 99
        )
        let disconnected = try await AdmissionFixture.makeLevel(genesis: otherGenesis)
            .admit(header, fetcher: fetcher)
        XCTAssertEqual(disconnected.failure, .protocolInvalid)
        // A predecessor requirement does not survive a proven invalidity — a verdict asks the node to acquire nothing
        // (see testProvenInvalidBlockRequestsNoPredecessor).
        XCTAssertNil(disconnected.sameChainPredecessor)
    }

    func testActiveChildRelaysAuthenticatedAlternateGenesisTargetMiss() async throws {
        let fetcher = StorableFetcher()
        let nexusGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let alternate = try await BlockBuilder.buildChildGenesis(
            spec: chainLocalSpec(),
            parentState: nexusGenesis.postState,
            timestamp: 1_500,
            target: UInt256(1),
            fetcher: fetcher
        )
        try await storeBuiltBlock(alternate, in: fetcher)
        let alternateHeader = try BlockHeader(node: alternate)
        let root = try await buildAndStoreBlock(
            previous: nexusGenesis,
            children: ["Child": alternate],
            timestamp: 2_000,
            target: AdmissionFixture.easy,
            nonce: 2,
            fetcher: fetcher
        )
        XCTAssertGreaterThan(root.proofOfWorkHash(), alternate.target)

        let nexusLevel = AdmissionFixture.makeLevel(genesis: nexusGenesis)
        let rootHeader = try BlockHeader(node: root)
        _ = try await nexusLevel.admit(rootHeader, fetcher: fetcher)
        let proof = try await ChildBlockProof.generate(
            rootHeader: rootHeader,
            childDirectory: "Child",
            fetcher: fetcher
        )
        let activeGenesis = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            nonce: 9,
        )
        let activeLevel = ChainLevel(
            chain: ChainState.fromGenesis(block: activeGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        )
        let result = try await activeLevel.admit(
            alternateHeader,
            fetcher: fetcher,
            childPackage: ChildValidationPackage(proof: proof)
        )

        XCTAssertEqual(result.failure, .proofOfWorkInvalid)
        let stored = await activeLevel.chain.contains(blockHash: alternateHeader.rawCID)
        XCTAssertFalse(stored)
    }

    func testChildAcceptsWhenAncestorCarrierMissesItsOwnTarget() async throws {
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
        let carrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": candidate],
            timestamp: 3_000,
            target: .zero,
            nonce: 3,
            fetcher: fetcher
        )
        let level = ChainLevel(
            chain: ChainState.fromGenesis(block: childGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier),
            childDirectory: "Child",
            fetcher: fetcher
        )
        let package = try await childValidationPackage(proof: proof, fetcher: fetcher)
        let candidateHeader = try BlockHeader(node: candidate)

        let result = try await level.admit(
            candidateHeader,
            fetcher: fetcher,
            childPackage: package
        )

        if case .rejected(let failure, _) = result {
            return XCTFail("an ancestor target miss must not invalidate its child: \(failure)")
        }
        let containsCandidate = await level.chain.contains(blockHash: candidateHeader.rawCID)
        XCTAssertTrue(containsCandidate)
    }

    func testCurrentChainTargetMissIsAProofOfWorkFailureWithoutMutation() async throws {
        let fetcher = StorableFetcher()
        let hardTarget = UInt256(1)
        let parentTemplate = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 500)
        let childGenesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            timestamp: 1_000,
            target: hardTarget,
            nonce: 1,
            fetcher: fetcher
        )
        let candidate = try await buildAndStoreBlock(
            previous: childGenesis,
            parentChainBlock: parentTemplate,
            timestamp: 2_000,
            target: hardTarget,
            nextTarget: AdmissionFixture.easy,
            nonce: 2,
            fetcher: fetcher
        )
        let carrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": candidate],
            timestamp: 3_000,
            target: AdmissionFixture.easy,
            nonce: 3,
            fetcher: fetcher
        )
        XCTAssertGreaterThan(carrier.proofOfWorkHash(), hardTarget)
        XCTAssertFalse(candidate.validateNextTarget(
            spec: chainLocalSpec(),
            parent: childGenesis,
            difficultyAnchor: DifficultyAnchor(
                blockHeight: 1,
                timestamp: candidate.timestamp, target: candidate.target
            )
        ))
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
        let recorder = AdmissionStageRecorder()
        let durable = RecordingAdmissionStorer()
        let candidateHeader = try BlockHeader(node: candidate)

        let result = try await level.admit(
            candidateHeader,
            fetcher: fetcher,
            storer: durable,
            childPackage: package,
            stage: { record in await recorder.stage(record) }
        )

        XCTAssertEqual(result.failure, .proofOfWorkInvalid)
        let stageCount = await recorder.count(for: candidateHeader.rawCID)
        let containsCarrier = await level.chain.contains(blockHash: candidateHeader.rawCID)
        XCTAssertEqual(stageCount, 0)
        XCTAssertFalse(containsCarrier)
        let storeCalls = await durable.storeCallCount()
        XCTAssertEqual(storeCalls, 0)
    }

    func testDisconnectedTargetMissRelaysWithoutAcquiringPredecessor() async throws {
        let fetcher = StorableFetcher()
        let parentTemplate = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 500)
        let childGenesis = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let missingPredecessor = try await buildAndStoreBlock(
            previous: childGenesis,
            parentChainBlock: parentTemplate,
            timestamp: 1_001,
            target: AdmissionFixture.easy,
            nonce: 1,
            fetcher: fetcher
        )
        // An explicitly hard target, because this test needs a block the root's
        // proof of work MISSES. Inheriting the scheduled target no longer
        // produces one: the predecessor is height 1, so it anchors the schedule
        // at its own `easy` target rather than retargeting away from it, and
        // nothing can miss a maximum target. Committing harder than the schedule
        // is permitted — `target <= parent.nextTarget` — and it is the miss, not
        // its provenance, that this test is about.
        let candidate = try await buildAndStoreBlock(
            previous: missingPredecessor,
            parentChainBlock: parentTemplate,
            timestamp: 1_002,
            target: UInt256(1),
            nonce: 2,
            fetcher: fetcher
        )
        let root = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": candidate],
            timestamp: 4_000,
            target: AdmissionFixture.easy,
            nonce: 3,
            fetcher: fetcher
        )
        XCTAssertGreaterThan(root.proofOfWorkHash(), candidate.target)
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: root),
            childDirectory: "Child",
            fetcher: fetcher
        )
        let level = ChainLevel(
            chain: ChainState.fromGenesis(block: childGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        )
        let candidateHeader = try BlockHeader(node: candidate)
        let candidatePackage = try await childValidationPackage(
            proof: proof,
            fetcher: fetcher
        )
        let result = try await level.admit(
            candidateHeader,
            fetcher: fetcher,
            childPackage: candidatePackage
        )

        XCTAssertEqual(result.failure, .proofOfWorkInvalid)
        XCTAssertNil(result.sameChainPredecessor)
    }

    func testUnbootstrappedIntermediateGenesisRelaysTargetMissToGrandchild() async throws {
        let fetcher = StorableFetcher()
        let parentTemplate = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 500)
        let leafGenesis = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            nonce: 1
        )
        let leaf = try await AdmissionFixture.makeChild(
            of: leafGenesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 2,
            parentChainBlock: parentTemplate
        )
        let middle = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Leaf": leaf],
            timestamp: 3_000,
            target: UInt256(1),
            nonce: 3,
            fetcher: fetcher
        )
        let root = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Middle": middle],
            timestamp: 4_000,
            target: AdmissionFixture.easy,
            nonce: 4,
            fetcher: fetcher
        )
        XCTAssertGreaterThan(root.proofOfWorkHash(), middle.target)

        let rootHop = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: root),
            childDirectory: "Middle",
            fetcher: fetcher
        )
        // The middle genesis is never bootstrapped: its chain need not exist
        // for the share to relay through it.

        let leafHop = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: middle),
            childDirectory: "Leaf",
            fetcher: fetcher
        )
        let leafProof = rootHop.composing(hop: leafHop)
        let leafLevel = ChainLevel(
            chain: ChainState.fromGenesis(block: leafGenesis),
            context: testChainContext(
                path: [DEFAULT_ROOT_DIRECTORY, "Middle", "Leaf"]
            )
        )
        let admitted = try await leafLevel.admit(
            leaf,
            fetcher: fetcher,
            childPackage: ChildValidationPackage(proof: leafProof)
        )

        if case .rejected(let failure, _) = admitted {
            return XCTFail("grandchild must accept through target-miss parent: \(failure)")
        }
        let containsLeaf = await leafLevel.chain.contains(
            blockHash: try BlockHeader(node: leaf).rawCID
        )
        XCTAssertTrue(containsLeaf)
    }

    func testTargetHitInvalidIntermediateStillRelaysGrandchild() async throws {
        let fetcher = StorableFetcher()
        let leafGenesis = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            nonce: 1
        )
        let middleTemplate = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher,
            timestamp: 1_500,
            nonce: 2
        )
        let leaf = try await AdmissionFixture.makeChild(
            of: leafGenesis,
            fetcher: fetcher,
            timestamp: 2_000,
            nonce: 3,
            parentChainBlock: middleTemplate
        )
        let validMiddle = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            transactions: [AdmissionFixture.unsignedStateChangingGenesisTransaction(
                key: "invalid-middle",
                chainPath: [DEFAULT_ROOT_DIRECTORY, "Middle"]
            )],
            children: ["Leaf": leaf],
            timestamp: 3_000,
            target: AdmissionFixture.easy,
            nonce: 4,
            fetcher: fetcher
        )
        XCTAssertNotEqual(
            validMiddle.postState.rawCID,
            LatticeState.emptyHeader.rawCID
        )
        let invalidMiddle = Block(
            version: validMiddle.version,
            parent: validMiddle.parent,
            transactions: validMiddle.transactions,
            target: validMiddle.target,
            nextTarget: validMiddle.nextTarget,
            spec: validMiddle.spec,
            parentState: validMiddle.parentState,
            prevState: validMiddle.prevState,
            postState: LatticeState.emptyHeader,
            children: validMiddle.children,
            height: validMiddle.height,
            timestamp: validMiddle.timestamp,
            rewardRecipient: validMiddle.rewardRecipient,
            nonce: validMiddle.nonce
        )
        try await storeBuiltBlock(invalidMiddle, in: fetcher)
        let root = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Middle": invalidMiddle],
            timestamp: 4_000,
            target: AdmissionFixture.easy,
            nonce: 5,
            fetcher: fetcher
        )
        let middleHeader = try BlockHeader(node: invalidMiddle)
        let rootHop = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: root),
            childDirectory: "Middle",
            fetcher: fetcher
        )
        let recorder = AdmissionStageRecorder()
        let middleResult = try await ChainLevel.bootstrap(
            context: testChainContext(
                path: [DEFAULT_ROOT_DIRECTORY, "Middle"]
            ),
            genesisHeader: middleHeader,
            fetcher: fetcher,
            childPackage: ChildValidationPackage(proof: rootHop),
            validationContentStorer: fetcher,
            materializedVolumeStorer: fetcher,
            stage: { batch in await recorder.stage(batch) }
        )
        guard case .rejected(let failure) = middleResult else {
            return XCTFail("the invalid intermediate must report local rejection")
        }
        XCTAssertEqual(failure, .protocolInvalid)
        let stagedMiddle = await recorder.count(for: middleHeader.rawCID)
        XCTAssertEqual(stagedMiddle, 0)

        let leafHop = try await ChildBlockProof.generate(
            rootHeader: middleHeader,
            childDirectory: "Leaf",
            fetcher: fetcher
        )
        let leafLevel = ChainLevel(
            chain: ChainState.fromGenesis(block: leafGenesis),
            context: testChainContext(
                path: [DEFAULT_ROOT_DIRECTORY, "Middle", "Leaf"]
            )
        )
        let admitted = try await leafLevel.admit(
            leaf,
            fetcher: fetcher,
            childPackage: ChildValidationPackage(
                proof: rootHop.composing(hop: leafHop)
            )
        )

        XCTAssertNil(admitted.failure)
        let containsLeaf = await leafLevel.chain.contains(
            blockHash: try BlockHeader(node: leaf).rawCID
        )
        XCTAssertTrue(containsLeaf)
    }

    func testMissingParentContinuityFactStillRelaysGrandchildWork() async throws {
        let fetcher = StorableFetcher()
        let parentGenesis = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher,
            timestamp: 500,
            transactions: [AdmissionFixture.unsignedStateChangingGenesisTransaction(
                key: "parent-state",
                chainPath: [DEFAULT_ROOT_DIRECTORY]
            )]
        )
        XCTAssertNotEqual(
            parentGenesis.prevState.rawCID,
            parentGenesis.postState.rawCID
        )
        let middleGenesis = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            nonce: 2
        )
        let middlePredecessor = try await AdmissionFixture.makeChild(
            of: middleGenesis,
            fetcher: fetcher,
            timestamp: 1_100,
            nonce: 3,
            parentChainBlock: parentGenesis
        )
        let leafGenesis = try await AdmissionFixture.makeGenesis(
            fetcher: fetcher,
            timestamp: 1_000,
            nonce: 4
        )
        let middleTemplate = try await AdmissionFixture.makeChild(
            of: middlePredecessor,
            fetcher: fetcher,
            timestamp: 1_200,
            nonce: 5
        )
        let leaf = try await AdmissionFixture.makeChild(
            of: leafGenesis,
            fetcher: fetcher,
            timestamp: 1_300,
            nonce: 6,
            parentChainBlock: middleTemplate
        )
        let validMiddle = try await buildAndStoreBlock(
            previous: middlePredecessor,
            children: ["Leaf": leaf],
            timestamp: 1_200,
            nonce: 5,
            fetcher: fetcher
        )
        let invalidMiddle = Block(
            version: validMiddle.version,
            parent: validMiddle.parent,
            transactions: validMiddle.transactions,
            target: validMiddle.target,
            nextTarget: validMiddle.nextTarget,
            spec: validMiddle.spec,
            parentState: parentGenesis.postState,
            prevState: validMiddle.prevState,
            postState: validMiddle.postState,
            children: validMiddle.children,
            height: validMiddle.height,
            timestamp: validMiddle.timestamp,
            rewardRecipient: validMiddle.rewardRecipient,
            nonce: validMiddle.nonce
        )
        try await storeBuiltBlock(invalidMiddle, in: fetcher)
        let middleLevel = ChainLevel(
            chain: ChainState.fromGenesis(block: middleGenesis),
            context: testChainContext(
                path: [DEFAULT_ROOT_DIRECTORY, "Middle"]
            )
        )
        let predecessorRoot = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Middle": middlePredecessor],
            timestamp: 2_000,
            target: AdmissionFixture.easy,
            nonce: 7,
            fetcher: fetcher
        )
        let predecessorProof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: predecessorRoot),
            childDirectory: "Middle",
            fetcher: fetcher
        )
        let predecessorResult = try await middleLevel
            .admit(
                middlePredecessor,
                fetcher: fetcher,
                childPackage: ChildValidationPackage(
                    proof: predecessorProof
                )
            )
        guard case .accepted = predecessorResult else {
            return XCTFail("middle predecessor must connect")
        }
        let validLocal = try await validMiddle.validateNexus(
            fetcher: fetcher,
            chain: middleLevel.chain,
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Middle"],
            reportTemporalFailure: true
        )
        XCTAssertTrue(validLocal.0)

        let rootTemplate = try await buildAndStoreBlock(
            previous: parentGenesis,
            children: ["Middle": invalidMiddle],
            timestamp: 2_100,
            target: AdmissionFixture.easy,
            nonce: 8,
            fetcher: fetcher
        )
        let root = try XCTUnwrap(BlockBuilder.mine(
            block: rootTemplate,
            target: invalidMiddle.target,
            maxAttempts: 1_000_000
        ))
        try await storeBuiltBlock(root, in: fetcher)
        let rootHop = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: root),
            childDirectory: "Middle",
            fetcher: fetcher
        )
        guard case .success = rootHop.verifySecuringWork(
            child: invalidMiddle,
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Middle"]
        ) else {
            return XCTFail("structural work proof must verify")
        }
        let localValidation = try await invalidMiddle.validateNexus(
            fetcher: fetcher,
            chain: middleLevel.chain,
            chainPath: [DEFAULT_ROOT_DIRECTORY, "Middle"],
            reportTemporalFailure: true
        )
        XCTAssertTrue(localValidation.0)
        let middleHeader = try BlockHeader(node: invalidMiddle)
        let middleResult = try await middleLevel.admit(
            middleHeader,
            fetcher: fetcher,
            childPackage: ChildValidationPackage(proof: rootHop)
        )
        guard case .some(
            .crossChainEvidenceRequired(.parentStateContinuity)
        ) = middleResult.failure else {
            return XCTFail(
                "missing parent-state gate must not admit: "
                    + String(describing: middleResult.failure)
            )
        }

        let leafHop = try await ChildBlockProof.generate(
            rootHeader: middleHeader,
            childDirectory: "Leaf",
            fetcher: fetcher
        )
        let leafLevel = ChainLevel(
            chain: ChainState.fromGenesis(block: leafGenesis),
            context: testChainContext(
                path: [DEFAULT_ROOT_DIRECTORY, "Middle", "Leaf"]
            )
        )
        let leafResult = try await leafLevel.admit(
            leaf,
            fetcher: fetcher,
            childPackage: ChildValidationPackage(
                proof: rootHop.composing(hop: leafHop)
            )
        )
        XCTAssertNil(leafResult.failure)
    }

    func testBrokenCarrierContinuityStillRelaysRealWork() async throws {
        let fetcher = StorableFetcher()
        let hardTarget = UInt256(1)
        let genesis = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            timestamp: 1_000,
            target: hardTarget,
            fetcher: fetcher
        )
        let valid = try await buildAndStoreBlock(
            previous: genesis,
            timestamp: 2_000,
            target: hardTarget,
            nextTarget: hardTarget,
            nonce: 1,
            fetcher: fetcher
        )
        let malformedCarrier = Block(
            version: valid.version,
            parent: valid.parent,
            transactions: valid.transactions,
            target: valid.target,
            nextTarget: valid.nextTarget,
            spec: valid.spec,
            parentState: valid.parentState,
            prevState: valid.prevState,
            postState: valid.postState,
            children: valid.children,
            height: valid.height + 1,
            timestamp: valid.timestamp,
            rewardRecipient: valid.rewardRecipient,
            nonce: valid.nonce
        )
        try await storeBuiltBlock(malformedCarrier, in: fetcher)
        XCTAssertGreaterThan(malformedCarrier.proofOfWorkHash(), hardTarget)

        let result = try await AdmissionFixture.makeLevel(genesis: genesis).admit(
            malformedCarrier,
            fetcher: fetcher
        )

        XCTAssertEqual(result.failure, .proofOfWorkInvalid)
    }

    func testInvalidTerminalGenesisIsRejectedBeforeParentEvidenceRequest() async throws {
        let fetcher = StorableFetcher()
        let validChild = try await AdmissionFixture.makeGenesis(fetcher: fetcher, timestamp: 1_000)
        let invalidChild = Block(
            version: validChild.version,
            parent: nil,
            transactions: validChild.transactions,
            target: validChild.target,
            nextTarget: validChild.nextTarget,
            spec: validChild.spec,
            parentState: validChild.parentState,
            prevState: validChild.prevState,
            postState: validChild.postState,
            children: validChild.children,
            height: 1,
            timestamp: validChild.timestamp,
            rewardRecipient: validChild.rewardRecipient,
            nonce: validChild.nonce
        )
        try await storeBuiltBlock(invalidChild, in: fetcher)
        let carrier = try await buildAndStoreGenesis(
            spec: chainLocalSpec(),
            children: ["Child": invalidChild],
            timestamp: 2_000,
            target: AdmissionFixture.easy,
            fetcher: fetcher
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier),
            childDirectory: "Child",
            fetcher: fetcher
        )

        let level = ChainLevel(
            chain: ChainState.fromGenesis(block: validChild),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Child"])
        )
        let result = try await level.admit(
            invalidChild,
            fetcher: fetcher,
            childPackage: ChildValidationPackage(proof: proof)
        )
        XCTAssertEqual(result.failure, .protocolInvalid)
    }

    func testCreditComesFromTheRootMostMetTargetWhenTargetsEaseDownward() async throws {
        let outerTarget = UInt256.max / UInt256(16)
        let middleTarget = UInt256.max / UInt256(8)
        let leafTarget = UInt256.max / UInt256(4)

        let verified = try await verifiedMultiHopContribution(
            outerTarget: outerTarget,
            middleTarget: middleTarget,
            leafTarget: leafTarget,
            miningTarget: outerTarget
        )

        XCTAssertLessThanOrEqual(verified.rootHash, outerTarget)
        XCTAssertEqual(verified.contribution.id, verified.rootCID)
        XCTAssertEqual(verified.contribution.work, UInt256(16))
    }

    func testCreditedWorkSurvivesAdmissionAndReplay() async throws {
        let fixture = try await verifiedMultiHopContribution(
            outerTarget: UInt256.max / UInt256(16),
            middleTarget: UInt256.max / UInt256(8),
            leafTarget: UInt256.max / UInt256(4),
            miningTarget: UInt256.max / UInt256(16)
        )
        let expectedWork = UInt256(16)
        let level = ChainLevel(
            chain: ChainState.fromGenesis(block: fixture.leafGenesis),
            context: testChainContext(path: [DEFAULT_ROOT_DIRECTORY, "Middle", "Leaf"])
        )
        let genesisBatch = try testAdmissionBatch(for: fixture.leafGenesis)
        let recorder = AdmissionStageRecorder()
        let candidateHeader = try BlockHeader(node: fixture.candidate)

        let admitted = try await level.admit(
            candidateHeader,
            fetcher: fixture.fetcher,
            childPackage: fixture.package,
            stage: { batch in await recorder.stage(batch) }
        )
        guard case .accepted = admitted else {
            return XCTFail("the real multi-hop proof should admit")
        }
        XCTAssertEqual(fixture.contribution.work, expectedWork)
        let liveRecord = await level.chain.workContribution(id: fixture.rootCID)
        XCTAssertEqual(try XCTUnwrap(liveRecord).contribution, fixture.contribution)

        let batches = await recorder.recordedBatches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(
            batches.flatMap(\.facts).compactMap { fact -> VerifiedWorkContribution? in
                guard case .work(let work) = fact else { return nil }
                return work.contribution
            },
            [fixture.contribution]
        )
        let snapshotData = try JSONEncoder().encode(genesisBatch)
        let batchData = try JSONEncoder().encode(batches)
        let decodedGenesis = try JSONDecoder().decode(BlockImportBatch.self, from: snapshotData)
        let decodedBatches = try JSONDecoder().decode([BlockImportBatch].self, from: batchData)
        let restored = try await ChainState.restoreWithoutContext(replaying: [decodedGenesis] + decodedBatches)
        let restoredRecord = await restored.workContribution(id: fixture.rootCID)
        XCTAssertEqual(try XCTUnwrap(restoredRecord).contribution, fixture.contribution)
    }

    /// A grind is priced by the ROOT-MOST carrier whose target it beat, not by
    /// the hardest one. Here the hierarchy is inverted — the middle chain is
    /// harder (max/16) than the root above it (max/4) — so the two rules
    /// disagree, and this pins which one governs.
    ///
    /// The old rule took a max over every met target and credited the middle
    /// chain's 16. That let a DEEPER chain set the price of a grind, which is
    /// backwards: depth is further from the work that secures the hierarchy,
    /// not closer to it.
    func testMultiHopProofCreditsRootMostMetTargetNotTheHardest() async throws {
        let outerTarget = UInt256.max / UInt256(4)
        let middleTarget = UInt256.max / UInt256(16)
        let leafTarget = UInt256.max / UInt256(8)

        let verified = try await verifiedMultiHopContribution(
            outerTarget: outerTarget,
            middleTarget: middleTarget,
            leafTarget: leafTarget,
            miningTarget: middleTarget
        )

        // Fixture guard: the hash must actually beat the harder middle target,
        // or the two rules would agree here and this would test nothing.
        XCTAssertLessThanOrEqual(
            verified.rootHash, middleTarget,
            "fixture must beat the middle target for the rules to diverge"
        )
        XCTAssertEqual(verified.contribution.id, verified.rootCID)
        // Root-most met target is the outer chain's max/4 => 4. The leaf's own
        // max/8 => 8 then wins the final max, so the credit is 8 — NOT the
        // middle chain's 16.
        XCTAssertEqual(
            verified.contribution.work, UInt256(8),
            """
            Credit must come from the root-most met target (4), raised only by \
            the child's own target (8) — never from a deeper chain's harder \
            target (16).
            """
        )
    }

    /// The ORDINARY merged-mining case, and the branch the other tests miss: a
    /// grind that beats the child's target but NOT the root's own target.
    ///
    /// `carriers.first(where:)` does two things — take index 0, and SKIP
    /// carriers whose target was not met. Every other test here mines hard
    /// enough that the root is met, so they only ever pin the first behaviour.
    /// Without this test, dropping the predicate entirely
    /// (`carriers.first.map { workForTarget($0.block.target) }`) passes the
    /// whole suite while crediting an UNMET target — work the hash never did.
    func testUnmetRootIsSkippedRatherThanCredited() async throws {
        let outerTarget = UInt256.max / UInt256(1024)  // root: far too hard
        let middleTarget = UInt256.max / UInt256(16)
        let leafTarget = UInt256.max / UInt256(4)

        let verified = try await verifiedMultiHopContribution(
            outerTarget: outerTarget,
            middleTarget: middleTarget,
            leafTarget: leafTarget,
            miningTarget: middleTarget
        )

        // Fixture guard: the root's target must genuinely NOT be met, or this
        // exercises the take-index-0 path and proves nothing new.
        XCTAssertGreaterThan(
            verified.rootHash, outerTarget,
            "fixture must MISS the root target, or the skip branch is not reached"
        )
        XCTAssertLessThanOrEqual(
            verified.rootHash, middleTarget,
            "fixture must meet the middle target, or nothing is credited"
        )
        XCTAssertEqual(
            verified.contribution.work, UInt256(16),
            """
            Credit must come from the root-most target actually MET (16), never \
            from an unmet harder one (1024). Crediting an unmet target invents \
            work the hash did not do.
            """
        )
    }

    func testTerminalTargetRaisesCreditWhenItExceedsTheMetAncestor() async throws {
        let outerTarget = UInt256.max / UInt256(4)
        let middleTarget = UInt256.max / UInt256(8)
        let leafTarget = UInt256.max / UInt256(16)

        let verified = try await verifiedMultiHopContribution(
            outerTarget: outerTarget,
            middleTarget: middleTarget,
            leafTarget: leafTarget,
            miningTarget: leafTarget
        )

        XCTAssertLessThanOrEqual(verified.rootHash, leafTarget)
        XCTAssertEqual(verified.contribution.id, verified.rootCID)
        XCTAssertEqual(verified.contribution.work, UInt256(16))
    }

    func testMultiHopCarrierTargetMissDoesNotEraseStrongerAcceptedWork() async throws {
        let outerTarget = UInt256.max / UInt256(16)
        let leafTarget = UInt256.max / UInt256(4)

        let verified = try await verifiedMultiHopContribution(
            outerTarget: outerTarget,
            middleTarget: .zero,
            leafTarget: leafTarget,
            miningTarget: outerTarget
        )

        XCTAssertLessThanOrEqual(verified.rootHash, outerTarget)
        XCTAssertGreaterThan(verified.rootHash, .zero)
        XCTAssertEqual(verified.contribution.id, verified.rootCID)
        XCTAssertEqual(verified.contribution.work, UInt256(16))
    }
}
