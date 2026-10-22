import Foundation
import cashew
@_spi(Fuzzing)
import WasmKit
import WasmParser
import LatticePrimitives

public struct WasmPolicyContext: Codable, Sendable {
    public static let canonicalEncodingVersion: UInt16 = 2

    public let abiVersion: UInt16
    public let scope: WasmPolicyRef.Scope
    /// Height of the block the transaction is validated in.
    public let height: UInt64
    /// Timestamp (ms) of that block. Miner-chosen: consensus only requires it to
    /// exceed the parent's, so prefer `height` for rules a miner must not skew.
    public let timestamp: Int64
    public let chainSpec: ChainSpec
    public let chainPath: [String]
    public let transaction: TransactionBody?
    public let action: Action?
    public let actionIndex: Int?

    public init(
        scope: WasmPolicyRef.Scope,
        height: UInt64,
        timestamp: Int64,
        chainSpec: ChainSpec,
        chainPath: [String],
        transaction: TransactionBody?,
        action: Action?,
        actionIndex: Int?
    ) {
        self.abiVersion = WasmPolicyRef.currentABIVersion
        self.scope = scope
        self.height = height
        self.timestamp = timestamp
        self.chainSpec = chainSpec
        self.chainPath = chainPath
        self.transaction = transaction
        self.action = action
        self.actionIndex = actionIndex
    }

    public func canonicalData() throws -> Data {
        var encoder = WasmPolicyContextCanonicalEncoder()
        try encoder.appendContext(self)
        return encoder.data
    }
}

public enum WasmPolicyError: Error, Sendable {
    case unsupportedABI(UInt16)
    case missingModule(String)
    case invalidModule
    case missingMemory
    case missingAllocator
    case missingEntrypoint(String)
    case invalidFunctionSignature(String)
    case invalidAllocation
    case invalidReturn
    case contextEncodingFailed
    case nondeterministicConstruct(String)
}

private struct WasmPolicyContextCanonicalEncoder {
    private static let magic = Array("LWPCTX".utf8)

    private(set) var data = Data()

    mutating func appendContext(_ context: WasmPolicyContext) throws {
        data.append(contentsOf: Self.magic)
        appendUInt16(WasmPolicyContext.canonicalEncodingVersion)
        appendUInt16(context.abiVersion)
        appendUInt8(context.scope.canonicalTag)
        appendUInt64(context.height)
        appendUInt64(UInt64(bitPattern: context.timestamp))
        try appendNode(context.chainSpec)
        try appendStringArray(context.chainPath)
        try appendOptionalNode(context.transaction)
        try appendOptionalAction(context.action)
        if let actionIndex = context.actionIndex {
            guard actionIndex >= 0 else { throw WasmPolicyError.contextEncodingFailed }
            appendUInt8(1)
            appendUInt64(UInt64(actionIndex))
        } else {
            appendUInt8(0)
        }
    }

    private mutating func appendOptionalNode<T: Node>(_ node: T?) throws {
        guard let node else {
            appendUInt8(0)
            return
        }
        appendUInt8(1)
        try appendNode(node)
    }

    private mutating func appendOptionalAction(_ action: Action?) throws {
        guard let action else {
            appendUInt8(0)
            return
        }
        appendUInt8(1)
        let actionData = try DagCBOR.encode(action)
        try appendLengthPrefixed(actionData)
    }

    private mutating func appendNode<T: Node>(_ node: T) throws {
        guard let nodeData = node.toData() else { throw WasmPolicyError.contextEncodingFailed }
        try appendLengthPrefixed(nodeData)
    }

    private mutating func appendStringArray(_ values: [String]) throws {
        guard values.count <= Int(UInt32.max) else { throw WasmPolicyError.contextEncodingFailed }
        appendUInt32(UInt32(values.count))
        for value in values {
            try appendLengthPrefixed(Data(value.utf8))
        }
    }

    private mutating func appendLengthPrefixed(_ bytes: Data) throws {
        guard bytes.count <= Int(UInt32.max) else { throw WasmPolicyError.contextEncodingFailed }
        appendUInt32(UInt32(bytes.count))
        data.append(bytes)
    }

    private mutating func appendUInt8(_ value: UInt8) {
        data.append(value)
    }

    private mutating func appendUInt16(_ value: UInt16) {
        var be = value.bigEndian
        data.append(Data(bytes: &be, count: MemoryLayout<UInt16>.size))
    }

    private mutating func appendUInt32(_ value: UInt32) {
        var be = value.bigEndian
        data.append(Data(bytes: &be, count: MemoryLayout<UInt32>.size))
    }

    private mutating func appendUInt64(_ value: UInt64) {
        var be = value.bigEndian
        data.append(Data(bytes: &be, count: MemoryLayout<UInt64>.size))
    }
}

private extension WasmPolicyRef.Scope {
    var canonicalTag: UInt8 {
        switch self {
        case .transaction: return 0
        case .action: return 1
        }
    }
}

public enum WasmPolicyEvaluator {
    // A chain's WasmPolicy is its own committed, opt-in validity rule, not
    // permissionless metered code — so neither the protocol nor the node imposes
    // a module-size, memory, or table limit. The only bounds are WebAssembly's
    // own (32-bit linear memory, the module's declared maxima), so a verdict is
    // a pure function of (module, context): the same on every node.
    public static let executionFeatureSet: WasmFeatureSet = [.referenceTypes]

    /// The policy call stack, in bytes. A policy that recurses past it traps,
    /// and a trap is part of the verdict, so the depth is fixed here rather
    /// than left to the engine's default: it must be the same on every node.
    /// The call depth that reaches it also depends on the engine's frame
    /// layout, so an engine upgrade is a consensus change.
    public static let callStackBytes = 1 << 19

    public static func evaluate(
        policy: WasmPolicyRef,
        context: WasmPolicyContext,
        fetcher: Fetcher
    ) async throws -> Bool {
        guard policy.abiVersion == WasmPolicyRef.currentABIVersion else {
            throw WasmPolicyError.unsupportedABI(policy.abiVersion)
        }
        let moduleHeader = WasmPolicyModuleHeader(rawCID: policy.moduleCID)
        guard let moduleNode = try await moduleHeader.resolve(fetcher: fetcher).node else {
            throw WasmPolicyError.missingModule(policy.moduleCID)
        }
        return try evaluate(
            policy: policy,
            contextData: context.canonicalData(),
            moduleBytes: moduleNode.bytes)
    }

    public static func evaluate(
        policy: WasmPolicyRef,
        contextData: Data,
        moduleBytes: Data
    ) throws -> Bool {
        let (memory, alloc, entrypoint) = try instantiate(
            policy: policy, moduleBytes: moduleBytes)

        let contextBytes = Array(contextData)
        // Only the WASM32 address-space bound applies; the module's actual memory
        // capacity is checked against `memorySize` below.
        guard contextBytes.count <= Int(Int32.max) else {
            throw WasmPolicyError.invalidAllocation
        }
        let contextLength = Int32(contextBytes.count)
        let ptrValue = try alloc([Value(signed: contextLength)])
        guard let ptr = ptrValue.first?.i32 else {
            throw WasmPolicyError.invalidReturn
        }
        let signedPtr = Int32(bitPattern: ptr)
        let memorySize = memory.data.count
        guard signedPtr >= 0 else {
            throw WasmPolicyError.invalidAllocation
        }
        let ptrOffset = Int(signedPtr)
        guard ptrOffset <= memorySize,
              contextBytes.count <= memorySize - ptrOffset else {
            throw WasmPolicyError.invalidAllocation
        }
        if !contextBytes.isEmpty {
            memory.withUnsafeMutableBufferPointer(offset: UInt(ptrOffset), count: contextBytes.count) { buffer in
                contextBytes.withUnsafeBytes { source in
                    buffer.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: source.count)
                }
            }
        }
        let result = try entrypoint([
            Value(signed: Int32(bitPattern: ptr)),
            Value(signed: contextLength),
        ])
        guard let raw = result.first?.i32 else {
            throw WasmPolicyError.invalidReturn
        }
        return raw == 1
    }

    /// Validates the whole module: every function body, called or not. The
    /// engine otherwise validates a body only when it first runs, which would
    /// leave a defect in the chain's committed module to surface on the first
    /// transaction that reaches it. Translation is per function and does not
    /// depend on the compilation mode, so a module that passes here cannot
    /// fail validation when an evaluation later translates a body lazily.
    public static func validate(
        policy: WasmPolicyRef,
        moduleBytes: Data
    ) throws {
        _ = try instantiate(
            policy: policy, moduleBytes: moduleBytes, compilationMode: .eager)
    }

    /// Process-wide cache of parsed/compiled modules, keyed by module content id.
    static let moduleCache = WasmModuleCache.shared

    private static func instantiate(
        policy: WasmPolicyRef,
        moduleBytes: Data,
        compilationMode: EngineConfiguration.CompilationMode = .lazy
    ) throws -> (
        memory: WasmKit.Memory,
        alloc: Function,
        entrypoint: Function
    ) {
        guard policy.abiVersion == WasmPolicyRef.currentABIVersion else {
            throw WasmPolicyError.unsupportedABI(policy.abiVersion)
        }
        // Cache key is the module's content id (CID of the immutable bytes).
        // Reusing the parsed `Module` across evaluations is safe: `instantiate`
        // below is non-mutating and allocates a fresh per-evaluation Store/Instance.
        let moduleCID = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: moduleBytes)).rawCID
        let module = try moduleCache.module(forKey: moduleCID) {
            let bytes = Array(moduleBytes)
            //: float/vector constructs are nondeterministic across hosts
            // (NaN payloads) and must never reach execution.
            try WasmPolicyDeterminismScan.scan(moduleBytes: bytes, features: Self.executionFeatureSet)
            return try parseWasm(bytes: bytes, features: Self.executionFeatureSet)
        }
        let engine = Engine(configuration: EngineConfiguration(
            compilationMode: compilationMode,
            stackSize: Self.callStackBytes, features: Self.executionFeatureSet
        ))
        let store = Store(engine: engine)
        let instance = try module.instantiate(store: store)
        guard let memory = instance.exports[memory: "memory"] else {
            throw WasmPolicyError.missingMemory
        }
        guard let alloc = instance.exports[function: "lattice_alloc"] else {
            throw WasmPolicyError.missingAllocator
        }
        guard let entrypoint = instance.exports[function: policy.entrypoint] else {
            throw WasmPolicyError.missingEntrypoint(policy.entrypoint)
        }
        let allocType = FunctionType(parameters: [.i32], results: [.i32])
        guard alloc.type == allocType else {
            throw WasmPolicyError.invalidFunctionSignature("lattice_alloc")
        }
        let entrypointType = FunctionType(parameters: [.i32, .i32], results: [.i32])
        guard entrypoint.type == entrypointType else {
            throw WasmPolicyError.invalidFunctionSignature(policy.entrypoint)
        }
        return (memory, alloc, entrypoint)
    }
}
