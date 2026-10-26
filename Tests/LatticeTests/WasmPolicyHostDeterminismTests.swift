import XCTest
import Crypto
@testable import LatticePrimitives
@testable import LatticeValidation
@testable import LatticeImport
@_spi(Fuzzing) import WasmKit
import WAT

/// §7.4: a policy verdict is a function of the module and the context alone.
/// These tests look for a host input that could leak into it: the process
/// (hash seed), the thread (native stack size), concurrency, instance state
/// carried between evaluations, host imports, and integer edge semantics the
/// engine must implement exactly as WebAssembly specifies. Floats/SIMD are
/// rejected at validation (WasmPolicyFloatRejectionTests,
/// WasmPolicyOpcodeAllowListTests); memory.grow is pinned in WasmPolicyTests.
/// Non-termination is out of scope: there is no execution bound.
final class WasmPolicyHostDeterminismTests: XCTestCase {
    private static let policy = WasmPolicyRef(moduleCID: "host-determinism", scope: .transaction)
    private var policy: WasmPolicyRef { Self.policy }

    private static let allocator = """
      (global $heap (mut i32) (i32.const 1024))
      (func (export "lattice_alloc") (param $len i32) (result i32)
        global.get $heap
        global.get $heap
        local.get $len
        i32.add
        global.set $heap)
    """

    private func module(entry body: String, extra: String = "", imports: String = "") throws -> Data {
        Data(try wat2wasm("""
        (module
          \(imports)
          (memory (export "memory") 1)
          \(Self.allocator)
          \(extra)
          (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
            \(body))
        )
        """))
    }

    private func evaluate(_ module: Data, context: Data = Data()) throws -> Bool {
        try Self.evaluate(module, context: context)
    }

    private static func evaluate(_ module: Data, context: Data = Data()) throws -> Bool {
        try WasmPolicyEvaluator.evaluate(policy: policy, contextData: context, moduleBytes: module)
    }

    // MARK: - integer edge semantics

    /// Each expression must equal the value WebAssembly specifies. A host
    /// operator that differs (Swift `%` traps on `Int.min % -1`; `<<` does not
    /// mask the shift count) would crash the node or change the verdict.
    func testIntegerEdgeCasesComputeTheSpecifiedValue() throws {
        let cases: [(String, String)] = [
            ("(i32.rem_s (i32.const 0x80000000) (i32.const -1))", "(i32.const 0)"),
            ("(i32.div_s (i32.const -7) (i32.const 2))", "(i32.const -3)"),
            ("(i32.rem_s (i32.const -7) (i32.const 2))", "(i32.const -1)"),
            ("(i32.div_u (i32.const -1) (i32.const 2))", "(i32.const 0x7fffffff)"),
            ("(i32.mul (i32.const 0x7fffffff) (i32.const 2))", "(i32.const -2)"),
            ("(i32.add (i32.const 0x7fffffff) (i32.const 1))", "(i32.const 0x80000000)"),
            ("(i32.shl (i32.const 1) (i32.const 33))", "(i32.const 2)"),
            ("(i32.shr_u (i32.const -1) (i32.const 32))", "(i32.const -1)"),
            ("(i32.shr_s (i32.const 0x80000000) (i32.const 63))", "(i32.const -1)"),
            ("(i32.rotl (i32.const 1) (i32.const 33))", "(i32.const 2)"),
            ("(i32.rotr (i32.const 1) (i32.const 33))", "(i32.const 0x80000000)"),
            ("(i32.clz (i32.const 0))", "(i32.const 32)"),
            ("(i32.ctz (i32.const 0))", "(i32.const 32)"),
            ("(i32.popcnt (i32.const -1))", "(i32.const 32)"),
            ("(i32.extend8_s (i32.const 0x80))", "(i32.const -128)"),
            ("(i32.extend16_s (i32.const 0x8000))", "(i32.const -32768)"),
            ("(i32.wrap_i64 (i64.const 0x100000001))", "(i32.const 1)"),
        ]
        let cases64: [(String, String)] = [
            ("(i64.rem_s (i64.const 0x8000000000000000) (i64.const -1))", "(i64.const 0)"),
            ("(i64.div_s (i64.const -7) (i64.const 2))", "(i64.const -3)"),
            ("(i64.shl (i64.const 1) (i64.const 65))", "(i64.const 2)"),
            ("(i64.shr_s (i64.const 0x8000000000000000) (i64.const 127))", "(i64.const -1)"),
            ("(i64.rotr (i64.const 1) (i64.const 65))", "(i64.const 0x8000000000000000)"),
            ("(i64.clz (i64.const 0))", "(i64.const 64)"),
            ("(i64.ctz (i64.const 0))", "(i64.const 64)"),
            ("(i64.extend_i32_u (i32.const -1))", "(i64.const 0xffffffff)"),
            ("(i64.extend_i32_s (i32.const -1))", "(i64.const -1)"),
            ("(i64.extend32_s (i64.const 0x80000000))", "(i64.const -2147483648)"),
            ("(i64.mul (i64.const 0x7fffffffffffffff) (i64.const 2))", "(i64.const -2)"),
        ]
        for (expression, expected) in cases {
            XCTAssertTrue(try evaluate(try module(entry: "(i32.eq \(expression) \(expected))")), expression)
        }
        for (expression, expected) in cases64 {
            XCTAssertTrue(try evaluate(try module(entry: "(i64.eq \(expression) \(expected))")), expression)
        }
    }

    /// Integer traps and out-of-range effective addresses are traps (a
    /// completed invalid verdict), never a host crash and never a wrapped
    /// address: the effective address is the 33-bit sum, not a 32-bit one.
    func testIntegerAndAddressTrapsAreVerdicts() throws {
        let traps = [
            "(i64.div_s (i64.const 0x8000000000000000) (i64.const -1)) drop i32.const 1",
            "(i64.rem_u (i64.const 1) (i64.const 0)) drop i32.const 1",
            "(i32.rem_s (i32.const 1) (i32.const 0))",
            "(i32.load offset=0xffffffff (i32.const 1))",
            "(i32.load offset=4 (i32.const -4))",
            "(i64.load (i32.const 65529)) drop i32.const 1",
            "(memory.fill (i32.const 65535) (i32.const 1) (i32.const 2)) i32.const 1",
            "(memory.copy (i32.const 0) (i32.const 65535) (i32.const 2)) i32.const 1",
        ]
        for body in traps {
            XCTAssertThrowsError(try evaluate(try module(entry: body)), body) { error in
                XCTAssertTrue(error is Trap, "\(body): \(error)")
                XCTAssertEqual(wasmPolicyErrorVerdict(error), .invalid, body)
            }
        }
    }

    // MARK: - instance state never carries over

    /// Every evaluation instantiates afresh: a policy that accepts only while
    /// its mutable global, its memory, and its start function's side effect
    /// are untouched accepts on every evaluation, sequential or concurrent.
    func testEvaluationsNeverObserveEarlierEvaluations() async throws {
        let stateful = try module(entry: """
            (if (result i32) (i32.and
                  (i32.eqz (global.get $count))
                  (i32.and (i32.eqz (i32.load (i32.const 0)))
                           (i32.eq (global.get $started) (i32.const 1))))
              (then
                (global.set $count (i32.add (global.get $count) (i32.const 1)))
                (i32.store (i32.const 0) (i32.const 1))
                (global.set $started (i32.const 2))
                (i32.const 1))
              (else (i32.const 0)))
            """, extra: """
            (global $count (mut i32) (i32.const 0))
            (global $started (mut i32) (i32.const 0))
            (func $start (global.set $started (i32.const 1)))
            (start $start)
            """)
        for _ in 0..<8 {
            XCTAssertTrue(try evaluate(stateful))
        }
        let verdicts = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 {
                group.addTask { (try? Self.evaluate(stateful)) ?? false }
            }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        XCTAssertEqual(verdicts, Array(repeating: true, count: 32))
    }

    // MARK: - no host inputs

    /// The host supplies no imports: no clock, no randomness, no environment,
    /// no shared memory. A module that asks for any of them does not link,
    /// and that is a property of the module (an invalid verdict).
    func testHostImportsAreNeverSatisfied() throws {
        let imports = [
            "(import \"wasi_snapshot_preview1\" \"clock_time_get\" (func (param i32 i64 i32) (result i32)))",
            "(import \"wasi_snapshot_preview1\" \"random_get\" (func (param i32 i32) (result i32)))",
            "(import \"env\" \"now\" (global i64))",
            "(import \"env\" \"table\" (table 1 funcref))",
        ]
        for item in imports {
            let bytes = try module(entry: "i32.const 1", imports: item)
            XCTAssertThrowsError(try WasmPolicyEvaluator.validate(policy: policy, moduleBytes: bytes), item) { error in
                XCTAssertEqual(wasmPolicyErrorVerdict(error), .invalid, "\(item): \(error)")
            }
            XCTAssertThrowsError(try evaluate(bytes), item)
        }
        let importedMemory = Data(try wat2wasm("""
        (module
          (import "env" "memory" (memory 1))
          (export "memory" (memory 0))
          \(Self.allocator)
          (func (export "lattice_validate_transaction") (param i32 i32) (result i32) i32.const 1))
        """))
        XCTAssertThrowsError(try WasmPolicyEvaluator.validate(policy: policy, moduleBytes: importedMemory)) { error in
            XCTAssertEqual(wasmPolicyErrorVerdict(error), .invalid, "\(error)")
        }
    }

    /// Shared (threads) memory is outside the pinned feature set and must not
    /// decode: the limits flag 0x03 is a decode error, not a silently private
    /// memory.
    func testSharedMemoryIsRejected() throws {
        let shared = Data([
            0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
            0x05, 0x04, 0x01, // memory section, one memory
            0x03, 0x01, 0x01, // shared, min 1, max 1
        ])
        XCTAssertThrowsError(try WasmPolicyEvaluator.validate(policy: policy, moduleBytes: shared)) { error in
            XCTAssertEqual(wasmPolicyErrorVerdict(error), .invalid, "\(error)")
        }
    }

    // MARK: - call stack depth

    /// Recurses `n` times, `n` read from the first four context bytes.
    private func recursionModule(locals: Int) throws -> Data {
        let declared = locals == 0 ? "" : "(local " + String(repeating: "i64 ", count: locals) + ")"
        return try module(entry: "(call $down (i32.load (local.get $ptr)))", extra: """
            (func $down (param $n i32) (result i32)
              \(declared)
              (if (result i32) (i32.eqz (local.get $n))
                (then (i32.const 1))
                (else (call $down (i32.sub (local.get $n) (i32.const 1))))))
            """)
    }

    private static func depthContext(_ depth: Int) -> Data {
        withUnsafeBytes(of: UInt32(depth).littleEndian) { Data($0) }
    }

    /// true = accepted, false = trapped (call stack exhausted).
    private static func reaches(_ module: Data, depth: Int) throws -> Bool {
        do {
            return try evaluate(module, context: depthContext(depth))
        } catch let trap as Trap {
            XCTAssertEqual(wasmPolicyErrorVerdict(trap), .invalid)
            return false
        }
    }

    /// The deepest recursion that still returns.
    private func maximumDepth(_ module: Data) throws -> Int {
        var low = 0, high = 1 << 22
        XCTAssertTrue(try Self.reaches(module, depth: low))
        XCTAssertFalse(try Self.reaches(module, depth: high))
        while high - low > 1 {
            let mid = (low + high) / 2
            if try Self.reaches(module, depth: mid) { low = mid } else { high = mid }
        }
        return low
    }

    private func onThread<T>(stackSize: Int, _ body: @escaping @Sendable () throws -> T) throws -> T {
        var result: Result<T, Error>!
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result = Result { try body() }
            done.signal()
        }
        thread.stackSize = stackSize
        thread.start()
        done.wait()
        return try result.get()
    }

    /// The trap depth is fixed by `callStackBytes` and the engine's frame
    /// layout, and the engine keeps wasm frames on its own VM stack: the host
    /// thread's native stack (128 KiB, 16 MiB, a Task) must not move it. The
    /// pinned depths change only with the engine (a consensus change, §7.4).
    func testCallStackDepthIsIndependentOfTheHostThread() async throws {
        let golden: [(locals: Int, depth: Int)] = [(0, Self.goldenDepthNoLocals), (64, Self.goldenDepthWideFrame)]
        for (locals, expected) in golden {
            let bytes = try recursionModule(locals: locals)
            let depth = try maximumDepth(bytes)
            XCTAssertEqual(depth, expected, "locals \(locals)")
            for stackSize in [128 << 10, 16 << 20] {
                let edge = try onThread(stackSize: stackSize) {
                    (try Self.reaches(bytes, depth: depth), try Self.reaches(bytes, depth: depth + 1))
                }
                XCTAssertTrue(edge.0, "stack \(stackSize) locals \(locals)")
                XCTAssertFalse(edge.1, "stack \(stackSize) locals \(locals)")
            }
            let inner = try await Self.reachesFromTask(bytes, depth: depth)
            let outer = try await Self.reachesFromTask(bytes, depth: depth + 1)
            XCTAssertTrue(inner, "task locals \(locals)")
            XCTAssertFalse(outer, "task locals \(locals)")
        }
    }

    private static func reachesFromTask(_ module: Data, depth: Int) async throws -> Bool {
        try await Task.detached { try reaches(module, depth: depth) }.value
    }

    /// The engine picks its interpreter threading model per platform
    /// (`defaultForCurrentPlatform`), and evaluation translates lazily while
    /// genesis translates eagerly. Neither may move the trap depth.
    func testCallStackDepthIsIndependentOfThreadingModelAndCompilationMode() throws {
        let bytes = Array(try recursionModule(locals: 8))
        let module = try parseWasm(bytes: bytes, features: WasmPolicyEvaluator.executionFeatureSet)
        func reaches(_ depth: Int, _ threading: EngineConfiguration.ThreadingModel,
                     _ mode: EngineConfiguration.CompilationMode) throws -> Bool {
            let engine = Engine(configuration: EngineConfiguration(
                threadingModel: threading, compilationMode: mode,
                stackSize: WasmPolicyEvaluator.callStackBytes,
                features: WasmPolicyEvaluator.executionFeatureSet))
            let instance = try module.instantiate(store: Store(engine: engine))
            let memory = instance.exports[memory: "memory"]!
            memory.withUnsafeMutableBufferPointer(offset: 0, count: 4) { buffer in
                withUnsafeBytes(of: UInt32(depth).littleEndian) { buffer.copyMemory(from: $0) }
            }
            do {
                let result = try instance.exports[function: "lattice_validate_transaction"]!([.i32(0), .i32(4)])
                return result.first?.i32 == 1
            } catch is Trap {
                return false
            }
        }
        var depths: [Int] = []
        for threading in [EngineConfiguration.ThreadingModel.direct, .token] {
            for mode in [EngineConfiguration.CompilationMode.lazy, .eager] {
                var low = 0, high = 1 << 22
                while high - low > 1 {
                    let mid = (low + high) / 2
                    if try reaches(mid, threading, mode) { low = mid } else { high = mid }
                }
                depths.append(low)
            }
        }
        XCTAssertEqual(Set(depths).count, 1, "\(depths)")
        XCTAssertEqual(depths.first, try maximumDepth(Data(bytes)))
    }

    static let goldenDepthNoLocals = 8189
    static let goldenDepthWideFrame = 909

    /// Validation and translation of a deeply nested body must not recurse on
    /// the native stack: a node whose validating thread has a small stack
    /// would crash at genesis where another admits the chain.
    func testDeepBlockNestingValidatesOnASmallHostStack() throws {
        let depth = 20_000
        let body = String(repeating: "block\n", count: depth)
            + String(repeating: "end\n", count: depth) + "i32.const 1"
        let bytes = try module(entry: body)
        let verdict = try onThread(stackSize: 128 << 10) {
            try WasmPolicyEvaluator.validate(policy: Self.policy, moduleBytes: bytes)
            return try Self.evaluate(bytes)
        }
        XCTAssertTrue(verdict)
    }

    // MARK: - context bytes across processes

    /// A context exercising every field, including non-ASCII path components
    /// and optional values, so the encoder's handling of each is covered.
    static func richContext() -> WasmPolicyContext {
        let policies = [
            WasmPolicyRef(moduleCID: "b-module", scope: .action, entrypoint: "z"),
            WasmPolicyRef(moduleCID: "a-module", sourceCID: "src", scope: .transaction),
        ]
        let actions = [
            Action(key: "zeta", oldValue: nil, newValue: "1"),
            Action(key: "alpha", oldValue: "x", newValue: nil),
            Action(key: "ключ/鍵", oldValue: "é", newValue: "e\u{301}"),
        ]
        let body = TransactionBody(
            accountActions: [], actions: actions, depositActions: [],
            receiptActions: [], withdrawalActions: [], signers: ["s2", "s1"], nonce: 42,
            chainPath: ["Nexus", "child-ü"]
        )
        return WasmPolicyContext(
            scope: .action, height: UInt64.max, timestamp: -1,
            chainSpec: ChainSpec.test(halfLife: 7, wasmPolicies: policies),
            chainPath: ["Nexus", "child-ü"],
            transaction: body, action: actions[2], actionIndex: 2
        )
    }

    /// What a process computes: the context bytes' length and digest.
    static func processDigest() throws -> String {
        let context = try richContext().canonicalData()
        let digest = SHA256.hash(data: context).map { String(format: "%02x", $0) }.joined()
        return "\(context.count) \(digest)"
    }

    private static let digestEnvironmentKey = "LATTICE_WASM_DETERMINISM_DIGEST_OUT"

    /// Child-process half of the cross-process test; a no-op otherwise.
    func testEmitProcessDigestForParent() throws {
        guard let path = ProcessInfo.processInfo.environment[Self.digestEnvironmentKey] else { return }
        try Self.processDigest().write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Swift seeds hashing per process, so any Dictionary or Set iterated
    /// while encoding would order differently in another process. Encode the
    /// same context here, twice, and in two child processes (one with a
    /// random seed, one with deterministic hashing) and require equal bytes.
    func testContextBytesAreIdenticalAcrossProcesses() throws {
        let local = try Self.processDigest()
        XCTAssertEqual(local, try Self.processDigest())
        for deterministicHashing in [false, true] {
            guard let child = try runChild(deterministicHashing: deterministicHashing) else {
                throw XCTSkip("cannot locate the test runner to spawn a child process")
            }
            XCTAssertEqual(child, local, "deterministic hashing \(deterministicHashing)")
        }
    }

    private func runChild(deterministicHashing: Bool) throws -> String? {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("wasm-determinism-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: out) }
        let process = Process()
        let testName = "LatticeTests.WasmPolicyHostDeterminismTests/testEmitProcessDigestForParent"
        #if os(macOS)
        let bundle = Bundle(for: Self.self).bundlePath
        guard bundle.hasSuffix(".xctest"),
              let runner = ProcessInfo.processInfo.arguments.first,
              FileManager.default.isExecutableFile(atPath: runner) else { return nil }
        process.executableURL = URL(fileURLWithPath: runner)
        process.arguments = ["-XCTest", testName, bundle]
        #else
        guard let runner = ProcessInfo.processInfo.arguments.first,
              FileManager.default.isExecutableFile(atPath: runner) else { return nil }
        process.executableURL = URL(fileURLWithPath: runner)
        process.arguments = [testName]
        #endif
        var environment = ProcessInfo.processInfo.environment
        environment[Self.digestEnvironmentKey] = out
        if deterministicHashing {
            environment["SWIFT_DETERMINISTIC_HASHING"] = "1"
        } else {
            environment.removeValue(forKey: "SWIFT_DETERMINISTIC_HASHING")
        }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try String(contentsOfFile: out, encoding: .utf8)
    }
}
