import Foundation
import XCTest

/// Every golden-backed test class and the file it reads. A deleted or renamed
/// golden would otherwise surface only as that one test's "missing golden"
/// failure; this lists the set in one place and refuses stray files, so the
/// directory cannot accumulate expectations nothing reads.
@MainActor
final class GoldenInventoryTests: XCTestCase {
    static let inventory: [(testClass: String, golden: String)] = [
        ("ForkChoiceReplayGoldenTests", ForkChoiceReplayGoldenTests.goldenName),
        ("ForkChoiceReplayGoldenTests", ForkChoiceReplayGoldenTests.traceGoldenName),
        ("AdmissionDecisionGoldenTests", AdmissionDecisionGoldenTests.goldenName),
        ("AdmissionBatchEncodingGoldenTests", AdmissionBatchEncodingGoldenTests.goldenName),
        ("WorkTableGoldenTests", WorkTableGoldenTests.goldenName),
        ("ChainTreeFactEquivalenceGoldenTests", ChainTreeFactEquivalenceGoldenTests.goldenName),
        ("ConsensusBoundaryEdgeTests", ConsensusBoundaryEdgeTests.goldenName),
        ("TransactionEncodingDifferentialTests", TransactionEncodingDifferentialTests.corpusName),
    ]

    func testEveryGoldenFileExistsAndIsJSON() async throws {
        for entry in Self.inventory {
            let url = GoldenFile.url(entry.golden)
            let data = try XCTUnwrap(
                FileManager.default.contents(atPath: url.path),
                "\(entry.testClass) reads \(entry.golden), which is missing"
            )
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: data),
                "\(entry.golden) is not valid JSON"
            )
        }
    }

    func testGoldensDirectoryHoldsOnlyInventoriedFiles() async throws {
        let present = try FileManager.default.contentsOfDirectory(atPath: GoldenFile.directory.path)
            .filter { !$0.hasPrefix(".") }
        XCTAssertEqual(
            Set(present), Set(Self.inventory.map(\.golden)),
            "add new goldens to the inventory; remove files nothing reads"
        )
    }
}
