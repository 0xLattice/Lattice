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

final class ChainLocalAdmissionContextTests: XCTestCase {
    func testRuntimeContextRequiresAbsoluteSeparatorFreeNexusPath() throws {
        XCTAssertNoThrow(try ChainRuntimeContext(
            path: [DEFAULT_ROOT_DIRECTORY, "Payments"]
        ))
        for (path, expected) in [
            (["Payments"], ChainRuntimeContextError.rootMustBeNexus),
            (["Other", "Payments"], .rootMustBeNexus),
            ([DEFAULT_ROOT_DIRECTORY, "Pay/ments"], .directoryContainsSeparator)
        ] {
            XCTAssertThrowsError(try ChainRuntimeContext(
                path: path
            )) { error in
                XCTAssertEqual(error as? ChainRuntimeContextError, expected)
            }
        }
    }

    func testRuntimeContextEnforcesProofWireDirectoryAndDepthBounds() throws {
        let maximumDirectory = String(
            repeating: "x",
            count: ChildProofWireLimits.maximumDirectoryBytes
        )
        XCTAssertNoThrow(try ChainRuntimeContext(
            path: [DEFAULT_ROOT_DIRECTORY, maximumDirectory]
        ))
        XCTAssertThrowsError(try ChainRuntimeContext(
            path: [DEFAULT_ROOT_DIRECTORY, maximumDirectory + "x"]
        )) { error in
            XCTAssertEqual(error as? ChainRuntimeContextError, .directoryTooLong)
        }

        XCTAssertNoThrow(try ChainRuntimeContext(
            path: [DEFAULT_ROOT_DIRECTORY] + Array(
                repeating: "Child",
                count: ChildProofWireLimits.maximumDepth
            )
        ))
        XCTAssertThrowsError(try ChainRuntimeContext(
            path: [DEFAULT_ROOT_DIRECTORY] + Array(
                repeating: "Child",
                count: ChildProofWireLimits.maximumDepth + 1
            )
        )) { error in
            XCTAssertEqual(error as? ChainRuntimeContextError, .pathTooDeep)
        }
    }

    func testUnknownErrorClassifiesAsRetryableNotExcluding() {
        // Fail-safe: an unenumerated error type is not a completed deterministic
        // check, so both classifier catch-alls must route it to retryable
        // `.unavailableEvidence`, never to an excluding verdict. Otherwise a new
        // error type on any fetch/IO path becomes a silent consensus split.
        struct UnrecognizedError: Error {}
        let unknown = UnrecognizedError()

        let validation = classifyValidationFailure(unknown)
        XCTAssertEqual(validation, .unavailableEvidence)
        XCTAssertFalse(BlockImport.isDeterministicInvalidity(validation))

        let resolution = classifyResolutionFailure(unknown)
        XCTAssertEqual(resolution, .unavailableEvidence)
        XCTAssertFalse(BlockImport.isDeterministicInvalidity(resolution))
    }

    func testValidationErrorsPartitionIntoAvailabilityAndLocalFailure() {
        // Every `ValidationErrors` case classifies to exactly one side of the
        // availability/verdict partition: an unresolved input is retryable,
        // a serialization failure is this node's own fault and never a
        // consensus verdict, so it is retried too. Neither may drift into
        // `.protocolInvalid`.
        let cases: [ValidationErrors] = [
            .transactionNotResolved,
            .prevStateNotResolved,
            .postStateNotResolved,
            .serializationError,
        ]
        for error in cases {
            let expected: BlockImportError = error == .serializationError
                ? .localVerificationFailure
                : .unavailableEvidence
            let classified = classifyValidationFailure(error)
            XCTAssertEqual(classified, expected, "\(error)")
            XCTAssertFalse(
                BlockImport.isDeterministicInvalidity(classified),
                "\(error) is never a verdict"
            )
        }
    }

    func testDeterministicInvalidityPartitionsAvailabilityFromVerdict() {
        // The data-availability linchpin: only a COMPLETED deterministic check
        // is a verdict that may exclude. Availability, ordering and capacity
        // failures are transient and must never record an exclusion.
        for failure in [
            BlockImportError.protocolInvalid,
            .proofOfWorkInvalid,
        ] {
            XCTAssertTrue(
                BlockImport.isDeterministicInvalidity(failure),
                "\(failure) is a completed invalidity verdict"
            )
        }
        for failure in [
            BlockImportError.unavailableEvidence,
            .providerMalformedEvidence,
            .localVerificationFailure,
            .crossChainEvidenceRequired(.childProof(chainPath: [], childCID: "x")),
            .notYetValid,
            .notAcceptedAtCurrentChain,
        ] {
            XCTAssertFalse(
                BlockImport.isDeterministicInvalidity(failure),
                "\(failure) is transient and never excludes"
            )
        }
    }
}
