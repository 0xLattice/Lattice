import XCTest
import LatticePrimitives
@testable import LatticeValidation
@testable import LatticeImport
import cashew
import WAT

/// The availability-vs-invalidity partition of validation errors: which ones
/// are a verdict (an exclusion), which are retried.
final class ValidationErrorPartitionTests: XCTestCase {
    func testWasmPolicyErrorClassificationMatchesImport() {
        // What import excludes is exactly what `validationErrorProvesInvalid`
        // calls a verdict, so a mempool evicts what import would exclude and
        // keeps what it would retry (#63). Every policy error is a function
        // of the module and the input, so a verdict, except a module this
        // node cannot obtain: retry, never exclude.
        let cases: [WasmPolicyError] = [
            .unsupportedABI(WasmPolicyRef.currentABIVersion + 1),
            .missingModule("m"),
            .invalidModule,
            .missingMemory,
            .missingAllocator,
            .missingEntrypoint("e"),
            .invalidFunctionSignature("f"),
            .invalidAllocation,
            .invalidReturn,
            .contextEncodingFailed,
            .nondeterministicConstruct("c"),
        ]
        for error in cases {
            let imported = classifyValidationFailure(error)
            let provesInvalid = validationErrorProvesInvalid(error)
            let isVerdict: Bool
            if case .missingModule = error { isVerdict = false } else { isVerdict = true }
            XCTAssertEqual(
                imported,
                isVerdict ? .protocolInvalid : .unavailableEvidence,
                "import: \(error)"
            )
            XCTAssertEqual(provesInvalid, isVerdict, "partition: \(error)")
        }
    }

    func testAProviderFaultOrAnUnknownErrorIsRetriedNotEvicted() {
        // Bytes that do not hash to the id asked for are a provider's fault,
        // and an error nothing enumerates is not known to be the
        // transaction's: neither is a verdict on it.
        struct Unenumerated: Error {}
        XCTAssertFalse(validationErrorProvesInvalid(DataErrors.cidMismatch))
        XCTAssertFalse(validationErrorProvesInvalid(Unenumerated()))
    }

    func testEveryEngineModuleDefectErrorIsAVerdict() throws {
        // The engine's module-defect errors are matched by type name, so each
        // name is pinned here against the error the engine really throws.
        func module(_ body: String, imports: String = "") throws -> Data {
            Data(try wat2wasm("""
            (module
              \(imports)
              (memory (export "memory") 1)
              (func (export "lattice_alloc") (param i32) (result i32) i32.const 1024)
              (func (export "lattice_validate_transaction") (param i32 i32) (result i32)
                \(body))
            )
            """))
        }
        var truncated = try module("i32.const 1")
        truncated.removeLast(3)
        var overlong = Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01])
        overlong.append(contentsOf: [UInt8](repeating: 0x80, count: 6))
        let defects: [(String, Data)] = [
            ("WasmKit.TranslationError", try module("i64.const 1")),
            ("WasmKit.ValidationError", try module("i32.add")),
            ("WasmKit.ImportError", try module("i32.const 1", imports: "(import \"env\" \"f\" (func))")),
            ("WasmParser.WasmParserError", Data([0, 1, 2, 3])),
            ("WasmParser.StreamError<Swift.UInt8>", truncated),
            ("WasmParser.LEBError", overlong),
        ]
        let policy = WasmPolicyRef(moduleCID: "inline", scope: .transaction)
        for (typeName, bytes) in defects {
            XCTAssertThrowsError(try WasmPolicyEvaluator.evaluate(
                policy: policy, contextData: Data(), moduleBytes: bytes
            )) { error in
                XCTAssertEqual(String(reflecting: type(of: error)), typeName)
                XCTAssertEqual(
                    classifyValidationFailure(error), .protocolInvalid, typeName
                )
                XCTAssertTrue(validationErrorProvesInvalid(error), typeName)
            }
        }
    }
}
