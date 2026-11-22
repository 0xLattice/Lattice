import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import UInt256

//: the single public work-from-target primitive.
final class WorkForDifficultyTests: XCTestCase {

    func testZeroDifficultyYieldsZeroWork() {
        XCTAssertEqual(workForTarget(.zero), .zero,
                       "zero target must return zero work, not trap on divide-by-zero")
    }

    func testInclusiveThresholdWorkForSmallTargets() {
        // Validity is hash <= target, so target+1 hashes qualify and work is
        // 2^256/(target+1) = (max - target)/(target + 1) + 1.
        // target 1 → {0,1} → 2^256/2 = 2^255.
        XCTAssertEqual(workForTarget(UInt256(1)),
                       (UInt256.max - UInt256(1)) / UInt256(2) + UInt256(1))
        // target 2 → {0,1,2} → 2^256/3 (NOT the exclusive max/2).
        XCTAssertEqual(workForTarget(UInt256(2)),
                       (UInt256.max - UInt256(2)) / UInt256(3) + UInt256(1))
        XCTAssertNotEqual(workForTarget(UInt256(2)), UInt256.max / 2)
    }

    func testMaxTargetYieldsUnitWork() {
        // Every hash valid → one expected try → unit work; must not divide by
        // (target + 1) which overflows to zero at target == max.
        XCTAssertEqual(workForTarget(UInt256.max), UInt256(1))
    }

    func testInclusiveAndExclusiveAgreeForLargeTargets() {
        // For realistic huge targets the +1 is negligible: the two forms differ
        // by at most a couple of units, so the fix does not perturb real chains.
        let big = UInt256.max / UInt256(1_000_000)
        let inclusive = workForTarget(big)
        let exclusive = UInt256.max / big
        let diff = inclusive > exclusive ? inclusive - exclusive : exclusive - inclusive
        XCTAssertLessThanOrEqual(diff, UInt256(2))
    }
}
