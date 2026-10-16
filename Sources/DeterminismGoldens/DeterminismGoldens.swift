import Foundation
import Lattice
import WasmParser
import WAT

/// Host-determinism golden vectors (shared source of truth).
///
/// These goldens pin canonical state-root–relevant bytes (the WasmPolicy
/// canonical context encoding), the content ids of the policy modules, and the
/// real `WasmPolicyEvaluator` verdicts. They are asserted byte-for-byte on BOTH
/// macOS (via `HostDeterminismGoldenTests`, an XCTest) and Linux (via the
/// `lattice-determinism-check` executable). Both the test and the executable
/// import THIS file, so the pinned constants and the computation cannot drift.
///
/// Reuses the pinned `executionFeatureSet` profile (Lattice #48) and
/// the existing `canonicalData()` / CAS (`rawCID`) primitives — no new encoders.
public enum DeterminismGoldens {
    // MARK: - Pinned goldens

    public static let goldenContextHex = "4c5750435458000300010101020304050607080000018bcfe568000000018bcfe56418000000fea9677072656d696e65006868616c664c6966650a6c6d6178426c6f636b53697a651a000f42406c7761736d506f6c696369657381a46573636f706566616374696f6e696d6f64756c65434944747472653132372d706f6c6963792d6d6f64756c656a61626956657273696f6e016a656e747279706f696e74776c6174746963655f76616c69646174655f616374696f6e6d696e697469616c5265776172641904006e6d6178537461746547726f7774681a000186a06f68616c76696e67496e74657276616c1927106f746172676574426c6f636b54696d651903e8781f6d61784e756d6265724f665472616e73616374696f6e73506572426c6f636b186400000001000000054e6578757301000000c1a8656e6f6e6365182a67616374696f6e7381a2636b6579767472653132372f706f6c6963792d73656e74696e656c686e657756616c7565781d6c617267652d696e742d39323233333732303336383534373735383037677369676e657273816d7472653132372d7369676e657269636861696e5061746881654e657875736e6163636f756e74416374696f6e73806e6465706f736974416374696f6e73806e72656365697074416374696f6e7380717769746864726177616c416374696f6e73800100000044a2636b6579767472653132372f706f6c6963792d73656e74696e656c686e657756616c7565781d6c617267652d696e742d39323233333732303336383534373735383037010000000000000000"
    public static let goldenAcceptModuleCID = "bafyreif6fnqbpy6xnnigwmx3fpb7vx3sygjlqx65lnu4onqgww4ba3y7zy"
    public static let goldenRejectModuleCID = "bafyreihc4da2uygxqr7y4hvrc5wt3wkprfblhzpiig2vo2vjpjspmndce4"
    public static let goldenFloatModuleCID = "bafyreidpzstizb2rpqoocoumd7kn7jqmdxpxf23fo6q32qpuo3h5ckv7i4"
    public static let goldenBulkMemoryModuleCID = "bafyreigjijol36lvbfxgaomtwex27ycgy6i53bggs3qqrhisji74ipt3fa"
    public static let goldenAtomicModuleCID = "bafyreibgygty4hvauae7yqntmmrq6pvwbvbqxbg27a6i3euiqtjw7l4caq"

    /// The Wasm execution profile that must stay pinned: a host that silently
    /// enabled a non-deterministic feature (threads, memory64, ...) would diverge.
    public static let goldenExecutionFeatureSet: WasmFeatureSet = [.referenceTypes]

    // MARK: - Pinned scenario inputs

    /// Builds the exact `WasmPolicyContext` the goldens are pinned against. Shared
    /// so the XCTest and the executable always exercise identical inputs.
    public static func goldenContext() -> WasmPolicyContext {
        let policy = WasmPolicyRef(moduleCID: "tre127-policy-module", scope: .action)
        let spec = ChainSpec(
            maxNumberOfTransactionsPerBlock: 100,
            maxStateGrowth: 100_000,
            premine: 0,
            targetBlockTime: 1_000,
            initialReward: 1024,
            halvingInterval: 10_000,
            halfLife: 10,
            wasmPolicies: [policy]
        )
        let action = Action(
            key: "tre127/policy-sentinel",
            oldValue: nil,
            newValue: "large-int-9223372036854775807"
        )
        let body = TransactionBody(
            accountActions: [],
            actions: [action],
            depositActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: ["tre127-signer"],
            nonce: 42,
            chainPath: ["Nexus"]
        )
        return WasmPolicyContext(
            scope: .action,
            height: 0x0102_0304_0506_0708,
            timestamp: 1_700_000_000_000,
            parentTimestamp: 1_699_999_999_000,
            chainSpec: spec,
            chainPath: ["Nexus"],
            transaction: body,
            action: action,
            actionIndex: 0
        )
    }

    /// The policy ref used to drive the evaluator (action scope, pinned module CID).
    public static func goldenPolicy() -> WasmPolicyRef {
        WasmPolicyRef(moduleCID: "tre127-policy-module", scope: .action)
    }

    // MARK: - Wasm policy fixtures (substring-sentinel modules)

    /// Deterministic accept module: returns 1 iff the context contains `needle`.
    public static func wasmPolicyFixture(requiringSubstring needle: String) throws -> Data {
        let needleBytes = Array(needle.utf8)
        let escapedNeedle = needleBytes.map { String(format: "\\%02x", $0) }.joined()
        let wat = """
        (module
          (memory (export "memory") 1)
          (data (i32.const 16) "\(escapedNeedle)")
          (global $heap (mut i32) (i32.const 1024))
          (func (export "lattice_alloc") (param $len i32) (result i32)
            (local $ptr i32)
            global.get $heap
            local.set $ptr
            global.get $heap
            local.get $len
            i32.add
            global.set $heap
            local.get $ptr)
          (func $contains (param $ptr i32) (param $len i32) (result i32)
            (local $i i32)
            (local $j i32)
            local.get $len
            i32.const \(needleBytes.count)
            i32.lt_u
            if
              i32.const 0
              return
            end
            (block $not_found
              (loop $outer
                local.get $i
                local.get $len
                i32.const \(needleBytes.count)
                i32.sub
                i32.gt_u
                br_if $not_found
                i32.const 0
                local.set $j
                (block $mismatch
                  (loop $inner
                    local.get $j
                    i32.const \(needleBytes.count)
                    i32.eq
                    if
                      i32.const 1
                      return
                    end
                    local.get $ptr
                    local.get $i
                    i32.add
                    local.get $j
                    i32.add
                    i32.load8_u
                    i32.const 16
                    local.get $j
                    i32.add
                    i32.load8_u
                    i32.ne
                    br_if $mismatch
                    local.get $j
                    i32.const 1
                    i32.add
                    local.set $j
                    br $inner))
                local.get $i
                i32.const 1
                i32.add
                local.set $i
                br $outer))
            i32.const 0)
          (export "lattice_validate_transaction" (func $contains))
          (export "lattice_validate_action" (func $contains))
        )
        """
        return Data(try wat2wasm(wat))
    }

    /// The float-divergence attack module. Computes 0.0/0.0 with
    /// `f64.div`, reinterprets the NaN to i64, and returns a payload bit. The
    /// WASM spec leaves NaN payload/sign bits implementation-defined, so this
    /// verdict could differ across hosts (macOS/arm64 vs Linux/x86_64). The
    /// golden therefore pins the only safe behavior: BOTH hosts must reject
    /// the module outright (`WasmPolicyError.nondeterministicConstruct`)
    /// before it can execute.
    public static func wasmPolicyFloatNaNFixture() throws -> Data {
        let wat = """
        (module
          (memory (export "memory") 1)
          (global $heap (mut i32) (i32.const 1024))
          (func (export "lattice_alloc") (param $len i32) (result i32)
            (local $ptr i32)
            global.get $heap
            local.set $ptr
            global.get $heap
            local.get $len
            i32.add
            global.set $heap
            local.get $ptr)
          (func $nan_payload_bit (param $ptr i32) (param $len i32) (result i32)
            f64.const 0
            f64.const 0
            f64.div
            i64.reinterpret_f64
            i64.const 0x0008000000000000
            i64.and
            i64.const 0
            i64.ne)
          (export "lattice_validate_transaction" (func $nan_payload_bit))
          (export "lattice_validate_action" (func $nan_payload_bit))
        )
        """
        return Data(try wat2wasm(wat))
    }

    /// Bulk-memory stays ALLOWED: a policy that uses `memory.copy`
    /// to copy the first 4 context bytes and compares them against a direct
    /// load. Deterministic (bounds/trap semantics fully specified) and emitted
    /// by default by LLVM/Rust for wasm32, so the allow-list keeps it. The
    /// golden pins both the verdict (true) and that the opcode executes
    /// identically on every host.
    public static func wasmPolicyBulkMemoryFixture() throws -> Data {
        let wat = """
        (module
          (memory (export "memory") 1)
          (global $heap (mut i32) (i32.const 1024))
          (func (export "lattice_alloc") (param $len i32) (result i32)
            (local $ptr i32)
            global.get $heap
            local.set $ptr
            global.get $heap
            local.get $len
            i32.add
            global.set $heap
            local.get $ptr)
          (func $copy_compare (param $ptr i32) (param $len i32) (result i32)
            i32.const 0
            local.get $ptr
            i32.const 4
            memory.copy
            i32.const 0
            i32.load
            local.get $ptr
            i32.load
            i32.eq)
          (export "lattice_validate_transaction" (func $copy_compare))
          (export "lattice_validate_action" (func $copy_compare))
        )
        """
        return Data(try wat2wasm(wat))
    }

    /// Atomics must be REJECTED. WasmKit 0.2.x decodes and executes
    /// atomic opcodes with NO feature gate (the pinned `executionFeatureSet`
    /// does not constrain them), so the opcode allow-list is the only thing
    /// keeping shared-memory semantics out of policies. The golden pins the
    /// only safe behavior: rejection before execution on every host.
    public static func wasmPolicyAtomicFixture() throws -> Data {
        let wat = """
        (module
          (memory (export "memory") 1)
          (global $heap (mut i32) (i32.const 1024))
          (func (export "lattice_alloc") (param $len i32) (result i32)
            (local $ptr i32)
            global.get $heap
            local.set $ptr
            global.get $heap
            local.get $len
            i32.add
            global.set $heap
            local.get $ptr)
          (func $atomic_read (param $ptr i32) (param $len i32) (result i32)
            i32.const 0
            i32.atomic.load)
          (export "lattice_validate_transaction" (func $atomic_read))
          (export "lattice_validate_action" (func $atomic_read))
        )
        """
        return Data(try wat2wasm(wat))
    }

    // MARK: - Check runner

    public struct CheckResult: Sendable {
        public let name: String
        public let passed: Bool
        public let detail: String
    }

    /// Recomputes every pinned golden from live Lattice primitives and compares
    /// against the constants above. Returns one `CheckResult` per check.
    public static func runChecks() throws -> [CheckResult] {
        var results: [CheckResult] = []

        // 0. Execution feature set profile is pinned.
        let featureMatches = WasmPolicyEvaluator.executionFeatureSet == goldenExecutionFeatureSet
            && !WasmPolicyEvaluator.executionFeatureSet.contains(.threads)
            && !WasmPolicyEvaluator.executionFeatureSet.contains(.memory64)
            && !WasmPolicyEvaluator.executionFeatureSet.contains(.tailCall)
        results.append(CheckResult(
            name: "executionFeatureSet pinned ([.referenceTypes], no threads/memory64/tailCall)",
            passed: featureMatches,
            detail: "\(WasmPolicyEvaluator.executionFeatureSet)"
        ))

        // 1. Canonical context bytes — the determinism substrate for state roots.
        let context = goldenContext()
        let contextData = try context.canonicalData()
        let contextHex = contextData.map { String(format: "%02x", $0) }.joined()
        results.append(CheckResult(
            name: "WasmPolicyContext.canonicalData() hex",
            passed: contextHex == goldenContextHex,
            detail: contextHex == goldenContextHex ? "\(contextData.count) bytes match" : "got \(contextHex)"
        ))

        // 2. Policy module content ids — CAS hashing must be host-independent.
        let acceptModule = try wasmPolicyFixture(requiringSubstring: "policy-sentinel")
        let rejectModule = try wasmPolicyFixture(requiringSubstring: "missing-sentinel")
        let acceptCID = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: acceptModule)).rawCID
        let rejectCID = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: rejectModule)).rawCID
        results.append(CheckResult(
            name: "accept module CID (policy-sentinel)",
            passed: acceptCID == goldenAcceptModuleCID,
            detail: acceptCID
        ))
        results.append(CheckResult(
            name: "reject module CID (missing-sentinel)",
            passed: rejectCID == goldenRejectModuleCID,
            detail: rejectCID
        ))

        // 3. Real evaluator verdicts — drive the actual entry point on this host.
        let policy = goldenPolicy()
        let acceptVerdict = try WasmPolicyEvaluator.evaluate(
            policy: policy, contextData: contextData, moduleBytes: acceptModule
        )
        let rejectVerdict = try WasmPolicyEvaluator.evaluate(
            policy: policy, contextData: contextData, moduleBytes: rejectModule
        )
        results.append(CheckResult(
            name: "accept verdict (policy-sentinel must accept)",
            passed: acceptVerdict == true,
            detail: "\(acceptVerdict)"
        ))
        results.append(CheckResult(
            name: "reject verdict (missing-sentinel must reject)",
            passed: rejectVerdict == false,
            detail: "\(rejectVerdict)"
        ))

        // 4. Float opcodes must be rejected before execution. NaN
        // payload bits are implementation-defined, so the only host-independent
        // verdict for a float-using policy is a deterministic parse-time error.
        let floatModule = try wasmPolicyFloatNaNFixture()
        let floatCID = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: floatModule)).rawCID
        results.append(CheckResult(
            name: "float module CID (f64.div NaN payload probe)",
            passed: floatCID == goldenFloatModuleCID,
            detail: floatCID
        ))
        results.append(CheckResult(
            name: "float module rejected at validate (deploy-time)",
            passed: rejectsFloatModule { try WasmPolicyEvaluator.validate(policy: policy, moduleBytes: floatModule) },
            detail: "validate must throw nondeterministicConstruct"
        ))
        results.append(CheckResult(
            name: "float module rejected at evaluate (block-validation-time)",
            passed: rejectsFloatModule { _ = try WasmPolicyEvaluator.evaluate(policy: policy, contextData: contextData, moduleBytes: floatModule) },
            detail: "evaluate must throw nondeterministicConstruct"
        ))

        // 5. Opcode allow-list goldens. Bulk memory stays allowed
        // (and must execute identically everywhere); atomics must be rejected
        // before execution (WasmKit decodes them with no feature gate, so the
        // allow-list is the only enforcement).
        let bulkMemoryModule = try wasmPolicyBulkMemoryFixture()
        let bulkMemoryCID = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: bulkMemoryModule)).rawCID
        results.append(CheckResult(
            name: "bulk-memory module CID (memory.copy probe)",
            passed: bulkMemoryCID == goldenBulkMemoryModuleCID,
            detail: bulkMemoryCID
        ))
        let bulkMemoryVerdict = try WasmPolicyEvaluator.evaluate(
            policy: policy, contextData: contextData, moduleBytes: bulkMemoryModule
        )
        results.append(CheckResult(
            name: "bulk-memory verdict (memory.copy allowed and executes)",
            passed: bulkMemoryVerdict == true,
            detail: "\(bulkMemoryVerdict)"
        ))
        let atomicModule = try wasmPolicyAtomicFixture()
        let atomicCID = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: atomicModule)).rawCID
        results.append(CheckResult(
            name: "atomic module CID (i32.atomic.load probe)",
            passed: atomicCID == goldenAtomicModuleCID,
            detail: atomicCID
        ))
        results.append(CheckResult(
            name: "atomic module rejected at validate (deploy-time)",
            passed: rejectsFloatModule { try WasmPolicyEvaluator.validate(policy: policy, moduleBytes: atomicModule) },
            detail: "validate must throw nondeterministicConstruct"
        ))
        results.append(CheckResult(
            name: "atomic module rejected at evaluate (block-validation-time)",
            passed: rejectsFloatModule { _ = try WasmPolicyEvaluator.evaluate(policy: policy, contextData: contextData, moduleBytes: atomicModule) },
            detail: "evaluate must throw nondeterministicConstruct"
        ))

        return results
    }

    private static func rejectsFloatModule(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            return false
        } catch WasmPolicyError.nondeterministicConstruct {
            return true
        } catch {
            return false
        }
    }
}
