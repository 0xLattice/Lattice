import XCTest
@testable import LatticeSimulation
import Foundation
#if canImport(os)
import os
#endif
import ArrayTrie
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import cashew
import UInt256
import WAT

final class StorableFetcher: Fetcher, Storer, VolumeStorer, Sendable {
    private let state = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])
    private let roots = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    func store(rawCid: String, data: Data) {
        state.withLock { $0[rawCid] = data }
    }

    func store(entries: [String: Data]) async {
        state.withLock { $0.merge(entries) { _, new in new } }
    }

    func store(volume: SerializedVolume) async {
        roots.withLock { _ = $0.insert(volume.root) }
        state.withLock { $0.merge(volume.entries) { _, new in new } }
    }

    func volumeRoots() -> Set<String> {
        roots.withLock { $0 }
    }

    func contains(rawCid: String) -> Bool {
        state.withLock { $0[rawCid] != nil }
    }

    var entries: [String: Data] {
        state.withLock { $0 }
    }

    func fetch(rawCid: String) async throws -> Data {
        guard let data = state.withLock({ $0[rawCid] }) else {
            throw cashew.FetcherError.notFound(rawCid)
        }
        return data
    }

    /// Synchronous lookup for non-async callers (e.g. a Network.framework receive
    /// callback that serves CAS bytes off a socket).
    func fetchSync(rawCid: String) throws -> Data {
        guard let data = state.withLock({ $0[rawCid] }) else {
            throw cashew.FetcherError.notFound(rawCid)
        }
        return data
    }
}

/// A fixture block named `name`: a canonical CID whose digest is the name's
/// bytes, so equal-work tie-breaks (CID byte order) follow name order.
func blockCID(_ name: String) -> String {
    LatticeConsensusSimulator.simCID(name)
}

func testCID(_ seed: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: seed)).rawCID
}

struct ThrowingFetcher: Fetcher {
    /// The error every fetch throws; `nil` throws `FetcherError.notFound` for
    /// the requested CID (the "nothing is available" stub).
    let error: (any Error)?

    init(error: (any Error)? = nil) {
        self.error = error
    }

    func fetch(rawCid: String) async throws -> Data {
        throw error ?? cashew.FetcherError.notFound(rawCid)
    }
}

/// Wraps a store and counts how many objects a walk pulls through it: the
/// DEPTH of a walk is a property only a fetch count can see.
actor CountingFetcher: Fetcher, Storer, VolumeStorer {
    let backing: StorableFetcher
    private var fetches = 0

    init(backing: StorableFetcher = StorableFetcher()) {
        self.backing = backing
    }

    func count() -> Int { fetches }
    func resetCount() { fetches = 0 }

    func fetch(rawCid: String) async throws -> Data {
        fetches += 1
        return try await backing.fetch(rawCid: rawCid)
    }

    func store(entries: [String: Data]) async { await backing.store(entries: entries) }
    func store(volume: SerializedVolume) async { await backing.store(volume: volume) }
}

/// Serves a fully populated store except for the CIDs it is told to deny,
/// which fail as `FetcherError.notFound` — the data is genuinely available but
/// momentarily un-fetchable (peer withholding, an in-flight re-request, a
/// source that went away). Re-pointing `denied` simulates the data arriving;
/// `denyAll()` is one-way — the source is gone for good, and `setDenied`
/// cannot bring it back.
actor DenyingFetcher: Fetcher {
    private let backing: StorableFetcher
    private var denied: Set<String>
    private var deniesEverything = false

    init(backing: StorableFetcher, denied: Set<String> = []) {
        self.backing = backing
        self.denied = denied
    }

    func setDenied(_ cids: Set<String>) { denied = cids }
    func denyAll() { deniesEverything = true }

    func fetch(rawCid: String) async throws -> Data {
        if deniesEverything || denied.contains(rawCid) {
            throw cashew.FetcherError.notFound(rawCid)
        }
        return try await backing.fetch(rawCid: rawCid)
    }
}

struct NoopStorer: Storer, VolumeStorer {
    func store(entries: [String: Data]) async throws {}
    func store(volume: SerializedVolume) async throws {}
}

private func stateStructurePaths() -> ArrayTrie<ResolutionStrategy> {
    var paths = ArrayTrie<ResolutionStrategy>()
    for property in LATTICE_STATE_PROPERTIES {
        paths.set([property, ""], value: .list)
    }
    return paths
}

@discardableResult
func storeBuiltBlock(
    _ result: BlockBuildResult,
    in fetcher: any Fetcher & Storer
) async throws -> Block {
    try await storeBuiltBlock(result.block, in: fetcher)
}

@discardableResult
func storeBuiltBlock(
    _ block: Block,
    in fetcher: any Fetcher & Storer
) async throws -> Block {
    let header = try BlockHeader(node: block)
    try await header.store(paths: Block.contentResolutionPaths, storer: fetcher)
    // The child index is one node of the block's boundary, fetched by every
    // reader of the block; it is stored even when it commits nothing.
    var childPaths = ArrayTrie<ResolutionStrategy>()
    childPaths.set([CHILDREN_PROPERTY], value: .targeted)
    for directory in block.children.node?.entries.keys ?? [:].keys {
        childPaths.set([CHILDREN_PROPERTY, directory], value: .targeted)
    }
    try await header.store(paths: childPaths, storer: fetcher)
    if block.height == 0 {
        try await LatticeState.emptyHeader.storeRecursively(storer: fetcher)
    }
    if let postState = block.postState.node {
        let state = try LatticeStateHeader(node: postState)
        let paths = stateStructurePaths()
        let indexedState = try await state.resolve(paths: paths, fetcher: fetcher)
        try await indexedState.store(paths: paths, storer: fetcher)
    }
    return block
}

/// Test local-CAS policy for fixtures that build a chain locally: retain block
/// content plus state-trie structure only when the supplied fetcher is also a
/// storer. Production `BlockBuilder` remains storage-neutral.
func buildAndStoreGenesis(
    spec: ChainSpec,
    transactions: [Transaction] = [],
    children: [String: Block] = [:],
    timestamp: Int64,
    target: UInt256,
    nonce: UInt64 = 0,
    version: UInt16 = Block.currentVersion,
    fetcher: Fetcher
) async throws -> Block {
    let result = try await BlockBuilder.buildGenesisWithTransition(
        spec: spec,
        transactions: transactions,
        children: children,
        timestamp: timestamp,
        target: target,
        nonce: nonce,
        version: version,
        fetcher: fetcher
    )
    guard let storer = fetcher as? (any Fetcher & Storer) else {
        return result.block
    }
    return try await storeBuiltBlock(result, in: storer)
}

/// Test local-CAS policy counterpart to ``buildAndStoreGenesis``.
///
/// `allowFeeRuleViolation` is for fee-rule tests only: when the builder
/// refuses transactions that break the fee rule (C + P > D + W) and there is
/// no recipient, it assembles the block anyway: the builder's header over no
/// transactions, then these transactions and the post-state their actions
/// alone produce. Validation must reject it; builder refusal itself is tested
/// against `BlockBuilder` directly (`CoinbaseTests`). Every other test must
/// build a fee-rule-valid block so it exercises only the defect under test.
func buildAndStoreBlock(
    previous: Block,
    transactions: [Transaction] = [],
    children: [String: Block] = [:],
    parentChainBlock: Block? = nil,
    timestamp: Int64,
    target: UInt256? = nil,
    nextTarget: UInt256? = nil,
    nonce: UInt64 = 0,
    rewardRecipient: String? = nil,
    allowFeeRuleViolation: Bool = false,
    allowStateGrowthViolation: Bool = false,
    fetcher: Fetcher
) async throws -> Block {
    func forgeable(_ error: Error) -> Bool {
        guard rewardRecipient == nil else { return false }
        if case BlockBuilderError.invalidCoinbase(.feeRuleViolated) = error { return allowFeeRuleViolation }
        if case StateErrors.stateGrowthExceeded = error { return allowStateGrowthViolation }
        return false
    }
    func build(_ transactions: [Transaction]) async throws -> BlockBuildResult {
        try await BlockBuilder.buildBlockWithTransition(
            previous: previous,
            transactions: transactions,
            children: children,
            parentChainBlock: parentChainBlock,
            timestamp: timestamp,
            target: target,
            nextTarget: nextTarget,
            nonce: nonce,
            rewardRecipient: rewardRecipient,
            fetcher: fetcher
        )
    }
    let result: BlockBuildResult
    do {
        result = try await build(transactions)
    } catch where forgeable(error) {
        let header = try await build([]).block
        var bodies: [TransactionBody] = []
        for transaction in transactions {
            guard let body = try await transaction.body.resolve(fetcher: fetcher).node else {
                throw BlockBuilderError.invalidTransactionContent
            }
            bodies.append(body)
        }
        let (postState, stateDiff) = try await BlockBuilder.computePostState(
            prevState: previous.postState, transactionBodies: bodies,
            coinbase: nil, fetcher: fetcher
        )
        result = BlockBuildResult(
            block: Block(
                version: header.version, parent: header.parent,
                transactions: try BlockBuilder.buildTransactionsDictionary(transactions),
                target: header.target, nextTarget: header.nextTarget, spec: header.spec,
                parentState: header.parentState, prevState: header.prevState,
                postState: postState, children: header.children,
                height: header.height, timestamp: header.timestamp,
                rewardRecipient: nil, nonce: header.nonce
            ),
            stateDiff: stateDiff,
            materializedPostState: postState.node
        )
    }
    guard let storer = fetcher as? (any Fetcher & Storer) else {
        return result.block
    }
    return try await storeBuiltBlock(result, in: storer)
}

/// Asserts `operation` throws exactly `expected`, so a refusal test passes only
/// on the rule it exercises, never on an unrelated refusal (e.g. the fee rule).
func assertThrows<T: Sendable, E: Error & Equatable>(
    _ expected: E,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    isolation: isolated (any Actor)? = #isolation,
    _ operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        XCTFail("expected \(expected), but it succeeded. \(message)", file: file, line: line)
    } catch let error as E {
        XCTAssertEqual(error, expected, message, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error). \(message)", file: file, line: line)
    }
}

func testAddress(publicKey: String) -> String {
    // known-valid local node; CID computation cannot fail (no Float/Double fields)
    try! HeaderImpl<PublicKey>(node: PublicKey(key: publicKey)).rawCID
}

func signedTestTransaction(
    _ body: TransactionBody,
    by keyPair: (privateKey: String, publicKey: String)
) -> Transaction {
    // known-valid local node; CID computation cannot fail (no Float/Double fields)
    let header = try! HeaderImpl<TransactionBody>(node: body)
    let signature = TransactionSigning.sign(bodyHeader: header, privateKeyHex: keyPair.privateKey)!
    return Transaction(signatures: [keyPair.publicKey: signature], body: header)
}

func buildPremineGenesis(
    spec: ChainSpec,
    owner: (privateKey: String, publicKey: String),
    fetcher: StorableFetcher,
    timestamp: Int64,
    target: UInt256 = UInt256(1000)
) async throws -> Block {
    let ownerAddress = testAddress(publicKey: owner.publicKey)
    let body = TransactionBody(
        accountActions: [AccountAction(owner: ownerAddress, delta: Int64(spec.premineAmount()))],
        actions: [],
        depositActions: [],
        receiptActions: [],
        withdrawalActions: [],
        signers: [],
        nonce: 0,
        chainPath: ["Nexus"]
    )
    let result = try await BlockBuilder.buildGenesisWithTransition(
        spec: spec,
        transactions: [Transaction(
            signatures: [:],
            body: try HeaderImpl<TransactionBody>(node: body)
        )],
        timestamp: timestamp,
        target: target,
        fetcher: fetcher
    )
    return try await storeBuiltBlock(result, in: fetcher)
}

func wasmPolicyFixture(accepts: Bool) throws -> Data {
    let returnValue = accepts ? 1 : 0
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
      (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
        i32.const \(returnValue))
      (func (export "lattice_validate_action") (param $ptr i32) (param $len i32) (result i32)
        i32.const \(returnValue))
    )
    """
    return Data(try wat2wasm(wat))
}

func wasmPolicyFixture(requiringSubstring needle: String) throws -> Data {
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

@discardableResult
func storeWasmPolicy(
    accepts: Bool,
    scope: WasmPolicyRef.Scope,
    fetcher: StorableFetcher,
    entrypoint: String? = nil
) async throws -> WasmPolicyRef {
    let module = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: try wasmPolicyFixture(accepts: accepts)))
    try await module.storeRecursively(storer: fetcher)
    return WasmPolicyRef(moduleCID: module.rawCID, scope: scope, entrypoint: entrypoint)
}

/// A root context pins a genesis CID (§5.1). Tests that never admit a root
/// through `insertGenesis`, `connect` or `restore` with a context take the
/// placeholder; the others pin their genesis (`testChainContext(genesis:)`).
let testPlaceholderGenesisCID = testCID("test-placeholder-root-genesis")

func testChainContext(
    path: [String] = [DEFAULT_ROOT_DIRECTORY],
    genesisCID: String? = nil
) -> ChainRuntimeContext {
    try! ChainRuntimeContext(
        path: path,
        genesisCID: path.count == 1 ? (genesisCID ?? testPlaceholderGenesisCID) : nil
    )
}

/// The root context pinned to `genesis`.
func testChainContext(genesis: Block) -> ChainRuntimeContext {
    testChainContext(genesisCID: try! BlockHeader(node: genesis).rawCID)
}

extension ChainLevel {
    init(testChain chain: ChainState) {
        self.init(chain: chain, context: testChainContext())
    }
}

extension ChainState {
    func submitTestBlock(
        blockHeader: BlockHeader,
        block: Block,
        contribution: VerifiedWorkContribution? = nil
    ) -> SubmissionResult {
        submitBlock(
            blockHeader: blockHeader,
            block: block,
            contribution: contribution ?? VerifiedWorkContribution(
                id: blockHeader.rawCID,
                work: workForTarget(block.target)
            )
        )
    }
}

func testAdmissionStage(_ context: BlockImportStagingContext) async throws {}

func testAdmissionBatch(
    for block: Block,
    contribution: VerifiedWorkContribution? = nil
) throws -> BlockImportBatch {
    let header = try BlockHeader(node: block)
    let work = contribution ?? VerifiedWorkContribution(
        id: header.rawCID,
        work: workForTarget(block.target)
    )
    return BlockImportBatch(facts: [
        .block(ChainBlockFact(
            blockHash: header.rawCID,
            parentBlockHash: block.parent?.rawCID,
            blockHeight: block.height,
            postStateCID: block.postState.rawCID,
            prevStateCID: block.prevState.rawCID,
            specCID: block.spec.rawCID,
            target: block.target.toHexString(),
            nextTarget: block.nextTarget.toHexString(),
            timestamp: block.timestamp,
            stateDiff: .empty
        )),
        .work(ChainWorkFact(blockHash: header.rawCID, contribution: work)),
    ] + executedGenesisFacts(block, blockHash: header.rawCID))
}

/// A genesis batch as bootstrap persists it carries its validation: a root
/// is executed only by a validation fact, never by being restored.
private func executedGenesisFacts(_ block: Block, blockHash: String) -> [ChainFact] {
    block.parent == nil ? [.validation(ChainValidationFact(blockHash: blockHash))] : []
}

func testAdmissionBatch(
    block: Block,
    contribution: VerifiedWorkContribution,
    stateDiff: StateDiff = .empty
) throws -> BlockImportBatch {
    let header = try BlockHeader(node: block)
    return BlockImportBatch(facts: [
        .block(ChainBlockFact(
            blockHash: header.rawCID,
            parentBlockHash: block.parent?.rawCID,
            blockHeight: block.height,
            postStateCID: block.postState.rawCID,
            prevStateCID: block.prevState.rawCID,
            specCID: block.spec.rawCID,
            target: block.target.toHexString(),
            nextTarget: block.nextTarget.toHexString(),
            timestamp: block.timestamp,
            stateDiff: stateDiff
        )),
        .work(ChainWorkFact(blockHash: header.rawCID, contribution: contribution))
    ] + executedGenesisFacts(block, blockHash: header.rawCID))
}

func testWorkBatch(
    blockHash: String,
    contribution: VerifiedWorkContribution
) -> BlockImportBatch {
    BlockImportBatch(facts: [
        .work(ChainWorkFact(blockHash: blockHash, contribution: contribution))
    ])
}

func childValidationPackage(
    proof: ChildBlockProof,
    fetcher _: any Fetcher
) async throws -> ChildValidationPackage {
    ChildValidationPackage(proof: proof)
}

@discardableResult
func storeWasmPolicy(
    requiringSubstring needle: String,
    scope: WasmPolicyRef.Scope,
    fetcher: StorableFetcher,
    entrypoint: String? = nil
) async throws -> WasmPolicyRef {
    let module = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: try wasmPolicyFixture(requiringSubstring: needle)))
    try await module.storeRecursively(storer: fetcher)
    return WasmPolicyRef(moduleCID: module.rawCID, scope: scope, entrypoint: entrypoint)
}

/// Fixed context offsets of the block fields a policy can read.
let wasmPolicyContextHeightOffset = 11
let wasmPolicyContextTimestampOffset = 19

/// A transaction policy accepting iff the big-endian 64-bit context field at
/// `offset` is at least `minimum` (signed compare).
func storeWasmPolicy(
    contextFieldAt offset: Int,
    atLeast minimum: Int64,
    fetcher: StorableFetcher
) async throws -> WasmPolicyRef {
    let wat = """
    (module
      (memory (export "memory") 1)
      (func (export "lattice_alloc") (param $len i32) (result i32) i32.const 1024)
      (func (export "lattice_validate_transaction") (param $ptr i32) (param $len i32) (result i32)
        (local $i i32)
        (local $v i64)
        (loop $read
          local.get $v
          i64.const 8
          i64.shl
          local.get $ptr
          i32.const \(offset)
          i32.add
          local.get $i
          i32.add
          i64.load8_u
          i64.or
          local.set $v
          local.get $i
          i32.const 1
          i32.add
          local.tee $i
          i32.const 8
          i32.lt_u
          br_if $read)
        local.get $v
        i64.const \(minimum)
        i64.ge_s)
    )
    """
    let module = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: Data(try wat2wasm(wat))))
    try await module.storeRecursively(storer: fetcher)
    return WasmPolicyRef(moduleCID: module.rawCID, scope: .transaction)
}

/// The by-height canonical index is derived state that a delta projection can
/// desync without changing the membership set, so parity checks compare it too.
func assertMainChainIndexMatchesPath(
    _ chain: ChainState,
    expectedPath: Set<String>,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let blocks = await chain.hashToBlock
    let index = await chain.canonicalHashByHeight
    var expected: [UInt64: String] = [:]
    for hash in expectedPath {
        guard let height = blocks[hash]?.blockHeight else { continue }
        expected[height] = hash
    }
    XCTAssertEqual(index, expected, message, file: file, line: line)
}

// MARK: - Deterministic PRNG for Reproducible Fuzz and Property Tests

struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}

extension SeededRNG {
    mutating func randomString(length: Int) -> String {
        let chars = "abcdef0123456789"
        return String((0..<length).map { _ in chars.randomElement(using: &self)! })
    }

    mutating func randomHash() -> String {
        randomString(length: 64)
    }

    mutating func randomUInt64(in range: ClosedRange<UInt64>) -> UInt64 {
        UInt64.random(in: range, using: &self)
    }

    mutating func randomBool() -> Bool {
        Bool.random(using: &self)
    }

    /// Same shape as `UUID().uuidString`, drawn from the seed.
    mutating func randomUUIDString() -> String {
        let high = next(), low = next()
        let bytes = (0..<8).map { UInt8(truncatingIfNeeded: high >> ($0 * 8)) }
            + (0..<8).map { UInt8(truncatingIfNeeded: low >> ($0 * 8)) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }
}

/// The seed a property test draws its inputs from. `LATTICE_TEST_SEED`
/// (decimal, or hex with a `0x` prefix) overrides the fixed default, so a
/// default run is deterministic and any failure replays from the seed it
/// prints in `note`.
struct PropertySeed {
    static let environmentKey = "LATTICE_TEST_SEED"
    static let defaultValue: UInt64 = 0x1A77_1CE5_EED0_0001

    let value: UInt64
    /// The command that reruns this one test with this seed.
    let replay: String

    /// Append to every assertion message of a seeded property.
    var note: String {
        "[seed 0x\(String(value, radix: 16)); replay: \(replay)]"
    }

    func generator() -> SeededRNG {
        SeededRNG(seed: value)
    }

    /// Decimal, or hex with a `0x`/`0X` prefix.
    static func parse(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("0x") {
            return UInt64(trimmed.dropFirst(2), radix: 16)
        }
        return UInt64(trimmed)
    }

    static var current: UInt64 {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey] else {
            return defaultValue
        }
        guard let value = parse(raw) else {
            preconditionFailure(
                "\(environmentKey)=\(raw) is neither a decimal nor a 0x-prefixed hex UInt64"
            )
        }
        return value
    }
}

extension XCTestCase {
    /// The seed for the calling test, with a replay hint naming that test.
    func propertySeed(function: String = #function) -> PropertySeed {
        let value = PropertySeed.current
        let test = function.hasSuffix("()") ? String(function.dropLast(2)) : function
        return PropertySeed(
            value: value,
            replay: "\(PropertySeed.environmentKey)=0x\(String(value, radix: 16)) "
                + "swift test --filter LatticeTests.\(type(of: self))/\(test)"
        )
    }
}

/// The parent-chain genesis every test child genesis anchors to: its
/// post-state is real, as a child genesis's `parentState` must be (§5.1).
func testAnchorParentGenesis(fetcher: StorableFetcher) async throws -> Block {
    try await buildAndStoreGenesis(
        spec: chainLocalSpec(),
        transactions: [AdmissionFixture.unsignedStateChangingGenesisTransaction(
            key: "child-genesis-anchor", chainPath: [DEFAULT_ROOT_DIRECTORY]
        )],
        timestamp: 100,
        target: UInt256.max,
        fetcher: fetcher
    )
}

/// A child genesis committing the anchor parent state.
func makeChildGenesis(
    fetcher: StorableFetcher,
    timestamp: Int64 = 1_000,
    nonce: UInt64 = 0,
    spec: ChainSpec = chainLocalSpec(),
    target: UInt256 = UInt256.max,
    transactions: [Transaction] = []
) async throws -> Block {
    let anchor = try await testAnchorParentGenesis(fetcher: fetcher)
    let block = try await BlockBuilder.buildChildGenesis(
        spec: spec, parentState: anchor.postState, transactions: transactions,
        timestamp: timestamp, target: target, nonce: nonce, fetcher: fetcher
    )
    return try await storeBuiltBlock(block, in: fetcher)
}

/// Parent facts attesting exactly `states` as produced by the parent's
/// executed set. They hold no order among those states, so they answer only
/// the links that need none: from the genesis pre-state, or between equal
/// states.
struct ProducedParentStates: ParentChainFacts {
    let states: Set<String>

    func hasContinuity(_ link: ParentStateContinuityLink) -> Bool {
        (link.fromStateCID == LatticeState.emptyHeader.rawCID || link.fromStateCID == link.toStateCID)
            && states.contains(link.toStateCID)
    }
}

/// Parent facts attesting the anchor parent state.
func testParentFacts(fetcher: StorableFetcher) async throws -> ProducedParentStates {
    ProducedParentStates(states: [try await testAnchorParentGenesis(fetcher: fetcher).postState.rawCID])
}

/// A child genesis's `ChildBlockProof`: a carrier on the anchor parent
/// genesis commits `childGenesis` under `directory`, its `prevState` the
/// genesis's `parentState`. The package carries the continuity link.
func carriedGenesisPackage(
    _ childGenesis: Block,
    directory: String = "Child",
    nonce: UInt64 = 0,
    target: UInt256 = UInt256.max,
    fetcher: StorableFetcher
) async throws -> ChildValidationPackage {
    let anchor = try await testAnchorParentGenesis(fetcher: fetcher)
    let carrier = try await buildAndStoreBlock(
        previous: anchor,
        children: [directory: childGenesis],
        timestamp: max(childGenesis.timestamp, anchor.timestamp) + 1,
        target: target,
        nonce: 10_000 + nonce,
        fetcher: fetcher
    )
    let proof = try await ChildBlockProof.generate(
        rootHeader: try BlockHeader(node: carrier),
        childDirectory: directory,
        fetcher: fetcher
    )
    return ChildValidationPackage(
        proof: proof,
        parentStateContinuityLink: ParentStateContinuityLink(
            parentPath: [DEFAULT_ROOT_DIRECTORY],
            fromStateCID: LatticeState.emptyHeader.rawCID,
            toStateCID: childGenesis.parentState.rawCID
        )
    )
}

/// The verified evidence of `carriedGenesisPackage` for `childGenesis`.
func carriedGenesisEvidence(
    _ childGenesis: Block,
    path: [String] = [DEFAULT_ROOT_DIRECTORY, "Child"],
    nonce: UInt64 = 0,
    fetcher: StorableFetcher
) async throws -> VerifiedChildEvidence {
    let package = try await carriedGenesisPackage(
        childGenesis, directory: path.last ?? "Child", nonce: nonce, fetcher: fetcher
    )
    return try await package.proof.verifySecuringWork(child: childGenesis, chainPath: path).get()
}
