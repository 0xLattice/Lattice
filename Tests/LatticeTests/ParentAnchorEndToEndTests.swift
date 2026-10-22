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
import Foundation

// End to end with real blocks: a parent ChainTree executes a forked Nexus, a
// child ChainTree weighs real child blocks from real carrier proofs and
// connects them against `ParentLevelFacts` of that parent. What is under test
// is §5.3 step 6 as of "a child's parent anchor only moves forward": the
// continuity link runs from the predecessor's parentState to the block's.

private func signTx(
    body: TransactionBody,
    keypair: (privateKey: String, publicKey: String)
) -> Transaction {
    let bodyHeader = try! HeaderImpl<TransactionBody>(node: body)
    let sig = TransactionSigning.sign(bodyHeader: bodyHeader, privateKeyHex: keypair.privateKey)!
    return Transaction(signatures: [keypair.publicKey: sig], body: bodyHeader)
}

private func addr(_ publicKey: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: publicKey)).rawCID
}

private func cid(_ block: Block) throws -> String {
    try BlockHeader(node: block).rawCID
}

/// Serves `backing`, except that each CID in `allowance` may be fetched only
/// that many more times; after that it is not found. Counts every fetch.
private actor GatedFetcher: Fetcher {
    let backing: StorableFetcher
    private var allowance: [String: Int]
    private var fetched: [String: Int] = [:]

    init(backing: StorableFetcher, allowance: [String: Int] = [:]) {
        self.backing = backing
        self.allowance = allowance
    }

    func fetch(rawCid: String) async throws -> Data {
        fetched[rawCid, default: 0] += 1
        if let left = allowance[rawCid] {
            guard left > 0 else { throw cashew.FetcherError.notFound(rawCid) }
            allowance[rawCid] = left - 1
        }
        return try await backing.fetch(rawCid: rawCid)
    }

    func count(_ rawCid: String) -> Int { fetched[rawCid] ?? 0 }
}

/// A Nexus, its executed parent `ChainTree`, the swap parties, and builders
/// for parent blocks, child blocks anchored at a parent block's state, and
/// their carrier proofs.
private final class World {
    let fetcher = StorableFetcher()
    let t = Int64(Date().timeIntervalSince1970 * 1000)
    let demander = CryptoUtils.generateKeyPair()
    let withdrawer = CryptoUtils.generateKeyPair()
    let depositNonce: UInt128 = 4242
    let amount: UInt64 = 200
    let rootPath = [DEFAULT_ROOT_DIRECTORY]
    let childPath = [DEFAULT_ROOT_DIRECTORY, "Child"]
    let g: Block
    var parent: ChainTree
    private var nonces: UInt64 = 0

    var demanderAddr: String { addr(demander.publicKey) }
    var withdrawerAddr: String { addr(withdrawer.publicKey) }
    var childContext: ChainRuntimeContext { testChainContext(path: childPath) }
    /// The parent's facts as they stand now (a value: re-read after the
    /// parent changes).
    var facts: ParentLevelFacts { ParentLevelFacts(tree: parent) }
    var depositKey: String {
        DepositKey(nonce: depositNonce, demander: demanderAddr, amountDemanded: amount).description
    }

    init() async throws {
        g = try await buildAndStoreGenesis(
            spec: ChainSpec.test(),
            transactions: [AdmissionFixture.unsignedStateChangingGenesisTransaction(
                key: "e2e-parent-state", chainPath: [DEFAULT_ROOT_DIRECTORY]
            )],
            timestamp: t - 100_000, target: .max, fetcher: fetcher
        )
        parent = try await TreeDriver.tree(genesis: g, context: testChainContext(genesis: g), fetcher: fetcher)
    }

    func nextNonce() -> UInt64 {
        nonces += 1
        return nonces
    }

    // MARK: Parent

    /// A parent block with its own coinbase, so every parent state is distinct.
    func parentBlock(on previous: Block, at offset: Int64, transactions: [Transaction] = [], reward: String? = nil) async throws -> Block {
        let nonce = nextNonce()
        return try await buildAndStoreBlock(
            previous: previous, transactions: transactions, timestamp: t + offset, target: .max,
            nonce: nonce, rewardRecipient: reward ?? testAddress(publicKey: "e2e-parent-\(nonce)"),
            fetcher: fetcher
        )
    }

    func weighParent(_ block: Block) async throws {
        let admission = try await TreeDriver.insert(block, into: &parent, fetcher: fetcher)
        XCTAssertNotNil(admission.update, "parent header: \(admission)")
    }

    func executeParent(_ block: Block) async throws {
        let admission = try await TreeDriver.connect(try cid(block), on: &parent, fetcher: fetcher)
        XCTAssertNotNil(admission.update, "parent execution: \(admission)")
        XCTAssertTrue(parent.isExecuted(blockHash: try cid(block)))
    }

    var receiptTx: Transaction {
        signTx(body: TransactionBody(
            accountActions: [], actions: [], depositActions: [],
            receiptActions: [ReceiptAction(
                withdrawer: withdrawerAddr, nonce: depositNonce, demander: demanderAddr,
                amountDemanded: amount, directory: "Child"
            )],
            withdrawalActions: [], signers: [withdrawerAddr], nonce: 0, chainPath: rootPath
        ), keypair: withdrawer)
    }

    // MARK: Child

    var depositTx: Transaction {
        signTx(body: TransactionBody(
            accountActions: [AccountAction(owner: demanderAddr, delta: -Int64(amount))],
            actions: [], depositActions: [DepositAction(
                nonce: depositNonce, demander: demanderAddr, amountDemanded: amount, amountDeposited: amount
            )],
            receiptActions: [], withdrawalActions: [],
            signers: [demanderAddr], nonce: 0, chainPath: childPath
        ), keypair: demander)
    }

    var withdrawalTx: Transaction {
        signTx(body: TransactionBody(
            accountActions: [AccountAction(owner: withdrawerAddr, delta: Int64(amount))],
            actions: [], depositActions: [], receiptActions: [],
            withdrawalActions: [WithdrawalAction(
                withdrawer: withdrawerAddr, nonce: depositNonce, demander: demanderAddr,
                amountDemanded: amount, amountWithdrawn: amount
            )],
            signers: [withdrawerAddr], nonce: 0, chainPath: childPath
        ), keypair: withdrawer)
    }

    func childGenesis(anchoredAt anchor: Block, at offset: Int64) async throws -> Block {
        let genesis = try await BlockBuilder.buildChildGenesis(
            spec: ChainSpec.test(), parentState: anchor.postState,
            timestamp: t + offset, target: .max, nonce: nextNonce(), fetcher: fetcher
        )
        return try await storeBuiltBlock(genesis, in: fetcher)
    }

    /// A child block on `previous`. With `anchoredAt`, its parentState is that
    /// parent block's post-state; otherwise it inherits its predecessor's.
    func childBlock(
        previous: Block, anchoredAt anchor: Block? = nil, transactions: [Transaction] = [],
        at offset: Int64, reward: String? = nil
    ) async throws -> Block {
        var parentChainBlock: Block?
        if let anchor {
            // Any block on `anchor` enters at its post-state; it is never
            // offered to the parent.
            parentChainBlock = try await buildAndStoreBlock(
                previous: anchor, timestamp: anchor.timestamp + 1, target: .max,
                nonce: nextNonce(), fetcher: fetcher
            )
        }
        let block = try await buildAndStoreBlock(
            previous: previous, transactions: transactions, parentChainBlock: parentChainBlock,
            timestamp: t + offset, target: .max, nonce: nextNonce(), rewardRecipient: reward,
            fetcher: fetcher
        )
        if let anchor {
            XCTAssertEqual(block.parentState.rawCID, anchor.postState.rawCID, "fixture: anchor")
        }
        return block
    }

    /// The work of a real carrier — a parent block on `carrierParent`
    /// committing `child` — verified against `child`.
    func evidence(for child: Block, carrierParent: Block) async throws -> VerifiedChildEvidence {
        let carrier = try await buildAndStoreBlock(
            previous: carrierParent, children: ["Child": child],
            timestamp: carrierParent.timestamp + 700, target: .max,
            nonce: 10_000 + nextNonce(), fetcher: fetcher
        )
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier), childDirectory: "Child", fetcher: fetcher
        )
        return try await proof.verifySecuringWork(child: child, chainPath: childPath).get()
    }

    func bootstrapChild(_ genesis: Block, carrierParent: Block) async throws -> ChainTree {
        let evidence = try await evidence(for: genesis, carrierParent: carrierParent)
        return try await ChainTree.bootstrap(
            genesis: try BlockHeader(node: genesis), evidence: evidence, fetcher: fetcher,
            context: childContext, parentFacts: facts
        ).get().tree
    }

    /// Weigh `block` on `tree` from a real carrier on `carrierParent`.
    func weigh(_ block: Block, carrierParent: Block, on tree: inout ChainTree, file: StaticString = #filePath, line: UInt = #line) async throws {
        let evidence = try await evidence(for: block, carrierParent: carrierParent)
        let admission = try await TreeDriver.insert(block, into: &tree, fetcher: fetcher, evidence: evidence)
        XCTAssertNotNil(admission.update, "child header: \(admission)", file: file, line: line)
        XCTAssertFalse(admission.update?.excluded ?? true, "child header lands unexcluded", file: file, line: line)
    }

    func connect(_ block: Block, on tree: inout ChainTree, fetcher: (any Fetcher)? = nil, facts: (any ParentChainFacts)? = nil) async throws -> ChainTreeAdmission {
        try await TreeDriver.connect(
            try cid(block), on: &tree, fetcher: fetcher ?? self.fetcher, parentFacts: facts ?? self.facts
        )
    }

    func continuity(from: Block, to: Block) -> BlockImportError {
        continuity(from: from.postState.rawCID, to: to.postState.rawCID)
    }

    func continuity(from: String, to: String) -> BlockImportError {
        .crossChainEvidenceRequired(.parentStateContinuity(parentPath: rootPath, fromStateCID: from, toStateCID: to))
    }
}

final class ParentAnchorEndToEndTests: XCTestCase {

    // MARK: - Assertions

    /// A refusal on local data: no fact, no exclusion, not executed, and the
    /// block's work still weighs in its own and its predecessor's subtree.
    private func assertRefusedStillWeighed(
        _ admission: ChainTreeAdmission, _ expected: BlockImportError, block: Block, tree: ChainTree,
        _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let hash = try cid(block)
        XCTAssertNil(admission.update, "\(message): no fact", file: file, line: line)
        XCTAssertEqual(admission.failure, expected, message, file: file, line: line)
        XCTAssertFalse(BlockImport.isDeterministicInvalidity(expected), "\(message): not a verdict", file: file, line: line)
        XCTAssertFalse(tree.isExcludedRoot(hash), "\(message): never excluded", file: file, line: line)
        XCTAssertFalse(tree.isExecuted(blockHash: hash), "\(message): not executed", file: file, line: line)
        let own = tree.forkChoice.weight(of: hash)
        XCTAssertNotNil(own, "\(message): still routed", file: file, line: line)
        XCTAssertGreaterThan(own ?? .zero, .zero, "\(message): its work weighs", file: file, line: line)
        if let predecessor = block.parent?.rawCID, let own {
            let above = tree.forkChoice.weight(of: predecessor) ?? .zero
            XCTAssertGreaterThan(above, own, "\(message): and counts in its predecessor's subtree", file: file, line: line)
        }
    }

    private func assertConnected(
        _ admission: ChainTreeAdmission, block: Block, tree: ChainTree, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertNotNil(admission.update, "\(message): \(admission)", file: file, line: line)
        XCTAssertFalse(admission.update?.excluded ?? true, message, file: file, line: line)
        XCTAssertTrue(tree.isExecuted(blockHash: try cid(block)), message, file: file, line: line)
    }

    /// The tip a node acts on (§9.9): from the selectable root, the heaviest
    /// validated child at each fork (by whole-subtree work), until none is.
    private func validatedTip(_ tree: ChainTree) -> String? {
        func selectable(_ hashes: [String]) -> [String] {
            hashes.filter { tree.isExecuted(blockHash: $0) && !tree.isExcludedRoot($0) }
        }
        let roots = Array(tree.indexToBlockHash[0] ?? []).filter { tree.graph.parent(of: $0) == nil }
        guard var current = tree.forkChoice.preferred(among: selectable(roots)) else { return nil }
        while let next = tree.forkChoice.preferred(among: selectable(tree.graph.children(of: current))) {
            current = next
        }
        return current
    }

    // MARK: - 1. The attack

    /// The parent forks after A into S (a receipt paying the demander, then
    /// S2) and the heavier canonical C1-C2-C3. A child withdrawal W, anchored
    /// at S, settles the deposit. A child block anchored on the canonical
    /// parent cannot extend W (evidence required, never an exclusion); a
    /// block anchored on S's own continuation can. An honest sibling branch
    /// anchored on the canonical parent connects, and once it outweighs W's
    /// subtree the child reorganizes to it: the deposit is unspent again and
    /// the withdrawer is not credited.
    func testCanonicalChildWorkCannotExtendAStaleReceiptWithdrawalAndReorgsItAway() async throws {
        let w = try await World()
        let a = try await w.parentBlock(on: w.g, at: -95_000)
        let s = try await w.parentBlock(on: a, at: -90_000, transactions: [w.receiptTx], reward: w.withdrawerAddr)
        let s2 = try await w.parentBlock(on: s, at: -85_000)
        let c1 = try await w.parentBlock(on: a, at: -90_000)
        let c2 = try await w.parentBlock(on: c1, at: -85_000)
        let c3 = try await w.parentBlock(on: c2, at: -80_000)
        for block in [a, s, s2, c1, c2, c3] {
            try await w.weighParent(block)
            try await w.executeParent(block)
        }
        XCTAssertEqual(w.parent.canonicalTip, try cid(c3), "fixture: C is the canonical parent")
        XCTAssertFalse(w.parent.isCanonical(hash: try cid(s)), "fixture: S is abandoned")
        XCTAssertEqual(Set([w.g, a, s, s2, c1, c2, c3].map(\.postState.rawCID)).count, 7, "fixture: distinct parent states")

        // Child: genesis and deposit anchored at the parent genesis.
        let genesis = try await w.childGenesis(anchoredAt: w.g, at: -94_000)
        var child = try await w.bootstrapChild(genesis, carrierParent: w.g)
        let deposit = try await w.childBlock(
            previous: genesis, transactions: [w.depositTx], at: -80_000, reward: w.demanderAddr
        )
        try await w.weigh(deposit, carrierParent: w.g, on: &child)
        try assertConnected(try await w.connect(deposit, on: &child), block: deposit, tree: child, "deposit")

        // W: anchored forward, from G's state to S's (the receipt).
        let withdrawal = try await w.childBlock(
            previous: deposit, anchoredAt: s, transactions: [w.withdrawalTx], at: -70_000, reward: w.withdrawerAddr
        )
        try await w.weigh(withdrawal, carrierParent: s, on: &child)
        try assertConnected(try await w.connect(withdrawal, on: &child), block: withdrawal, tree: child, "the withdrawal on S")
        let spent: UInt64? = try withdrawal.postState.node?.depositState.node?.get(key: w.depositKey)
        XCTAssertEqual(spent, SPENT_DEPOSIT_MARKER, "fixture: W spends the deposit")
        let paid: UInt64? = try withdrawal.postState.node?.accountState.node?.get(key: w.withdrawerAddr)
        XCTAssertGreaterThanOrEqual(paid ?? 0, w.amount, "fixture: W credits the withdrawer")

        // An honest miner on the canonical parent anchors at C3: sideways from S.
        let onWFromC = try await w.childBlock(previous: withdrawal, anchoredAt: c3, at: -60_000)
        try await w.weigh(onWFromC, carrierParent: c3, on: &child)
        try assertRefusedStillWeighed(
            try await w.connect(onWFromC, on: &child), w.continuity(from: s, to: c3),
            block: onWFromC, tree: child, "a canonical-parent block on W"
        )
        // Only work anchored on the abandoned branch extends W.
        let onWFromS2 = try await w.childBlock(previous: withdrawal, anchoredAt: s2, at: -59_000)
        try await w.weigh(onWFromS2, carrierParent: s2, on: &child)
        try assertConnected(try await w.connect(onWFromS2, on: &child), block: onWFromS2, tree: child, "a stale-parent block on W")
        XCTAssertEqual(validatedTip(child), try cid(onWFromS2), "W's branch is acted on while it is heavier")

        // The honest sibling branch: on the deposit, anchored at C3.
        let wSubtree = try XCTUnwrap(child.forkChoice.weight(of: try cid(withdrawal)))
        var honest: [Block] = []
        var previous = deposit
        var honestWeight = WorkSum.zero
        while honestWeight <= wSubtree, honest.count < 10 {
            let block = try await w.childBlock(
                previous: previous, anchoredAt: honest.isEmpty ? c3 : nil,
                at: -65_000 + Int64(honest.count) * 1_000
            )
            try await w.weigh(block, carrierParent: c3, on: &child)
            try assertConnected(try await w.connect(block, on: &child), block: block, tree: child, "honest block \(honest.count)")
            honest.append(block)
            previous = block
            honestWeight = try XCTUnwrap(child.forkChoice.weight(of: try cid(honest[0])))
            if honestWeight < wSubtree {
                XCTAssertEqual(validatedTip(child), try cid(onWFromS2), "a lighter honest branch does not take over")
            }
        }
        XCTAssertEqual(honest.count, 4, "W's subtree weighs three blocks, the refused one included")
        let tip = try cid(previous)
        XCTAssertEqual(child.canonicalTip, tip, "fork choice moves to the honest branch")
        XCTAssertEqual(validatedTip(child), tip, "and so does the tip acted on")
        XCTAssertFalse(child.isCanonical(hash: try cid(withdrawal)), "W is reorganized away")
        XCTAssertTrue(child.isCanonical(hash: try cid(deposit)))

        let state = try XCTUnwrap(previous.postState.node, "the honest tip's executed state")
        let deposited: UInt64? = try state.depositState.node?.get(key: w.depositKey)
        XCTAssertEqual(deposited, w.amount, "the deposit is unspent at the new tip")
        let credited: UInt64? = try state.accountState.node?.get(key: w.withdrawerAddr)
        XCTAssertNil(credited, "the withdrawer is not credited at the new tip")

        // The refused block is still refused, still weighed, never excluded.
        try assertRefusedStillWeighed(
            try await w.connect(onWFromC, on: &child), w.continuity(from: s, to: c3),
            block: onWFromC, tree: child, "a canonical-parent block on W, after the reorg"
        )
    }

    // MARK: - 2. Laundering

    /// A weighed predecessor anchored at a state the parent never executed —
    /// a real parent block the parent never received, and a bare forged CID —
    /// and a successor with the same parentState: equality carries nothing,
    /// so the successor needs evidence for the anchor itself. Once the parent
    /// executes the real block both connect; the forged one never does.
    func testAnEqualAnchorDoesNotLaunderAnUnexecutedParentState() async throws {
        let w = try await World()
        let a = try await w.parentBlock(on: w.g, at: -95_000)
        try await w.weighParent(a)
        try await w.executeParent(a)
        let ghost = try await w.parentBlock(on: a, at: -90_000)
        XCTAssertFalse(w.parent.executedSetProduced(stateCID: ghost.postState.rawCID), "fixture: never executed")

        let genesis = try await w.childGenesis(anchoredAt: a, at: -94_000)
        var child = try await w.bootstrapChild(genesis, carrierParent: a)

        let predecessor = try await w.childBlock(previous: genesis, anchoredAt: ghost, at: -80_000)
        let successor = try await w.childBlock(previous: predecessor, at: -79_000)
        XCTAssertEqual(successor.parentState.rawCID, predecessor.parentState.rawCID, "fixture: equal anchors")
        try await w.weigh(predecessor, carrierParent: ghost, on: &child)
        try await w.weigh(successor, carrierParent: ghost, on: &child)
        // Connect the successor first: its predecessor is weighed, never checked.
        try assertRefusedStillWeighed(
            try await w.connect(successor, on: &child),
            w.continuity(from: ghost.postState.rawCID, to: ghost.postState.rawCID),
            block: successor, tree: child, "a successor matching an unexecuted anchor"
        )
        try assertRefusedStillWeighed(
            try await w.connect(predecessor, on: &child), w.continuity(from: a, to: ghost),
            block: predecessor, tree: child, "the predecessor itself"
        )

        // A bare forged state CID, on a block weighed from test evidence.
        let forged = testCID("e2e-forged-parent-state")
        let template = try await w.childBlock(previous: genesis, at: -78_000)
        let forgedPredecessor = try await storeBuiltBlock(Block(
            version: template.version, parent: template.parent, transactions: template.transactions,
            target: template.target, nextTarget: template.nextTarget, spec: template.spec,
            parentState: LatticeStateHeader(rawCID: forged), prevState: template.prevState,
            postState: template.postState, children: template.children, height: template.height,
            timestamp: template.timestamp, rewardRecipient: template.rewardRecipient, nonce: template.nonce
        ), in: w.fetcher)
        let forgedSuccessor = try await w.childBlock(previous: forgedPredecessor, at: -77_000)
        XCTAssertEqual(forgedSuccessor.parentState.rawCID, forged, "fixture: inherits the forged anchor")
        for (index, block) in [forgedPredecessor, forgedSuccessor].enumerated() {
            let admission = try await TreeDriver.insert(
                block, into: &child, fetcher: w.fetcher,
                work: VerifiedWorkContribution(id: testCID("e2e-forged-grind-\(index)"), work: 1)
            )
            XCTAssertNotNil(admission.update, "forged header \(index): \(admission)")
        }
        try assertRefusedStillWeighed(
            try await w.connect(forgedSuccessor, on: &child), w.continuity(from: forged, to: forged),
            block: forgedSuccessor, tree: child, "a successor matching a forged anchor"
        )

        // The real anchor is retried, not condemned: the parent executes it.
        try await w.weighParent(ghost)
        try await w.executeParent(ghost)
        try assertConnected(try await w.connect(predecessor, on: &child), block: predecessor, tree: child, "predecessor, once executed upstream")
        try assertConnected(try await w.connect(successor, on: &child), block: successor, tree: child, "successor, once executed upstream")
        try assertRefusedStillWeighed(
            try await w.connect(forgedSuccessor, on: &child), w.continuity(from: forged, to: forged),
            block: forgedSuccessor, tree: child, "the forged anchor stays unproven"
        )
    }

    // MARK: - 3. Predecessor body unavailable

    /// The predecessor's block bytes are missing — entirely, or only by the
    /// time the anchor is read after validation resolved them: the connect is
    /// an availability failure (retry), never `.protocolInvalid`, and it
    /// connects once the bytes are back.
    func testAMissingPredecessorBodyIsRetriedNeverInvalid() async throws {
        let w = try await World()
        let a = try await w.parentBlock(on: w.g, at: -95_000)
        let b = try await w.parentBlock(on: a, at: -90_000)
        for block in [a, b] {
            try await w.weighParent(block)
            try await w.executeParent(block)
        }
        let genesis = try await w.childGenesis(anchoredAt: w.g, at: -94_000)
        var child = try await w.bootstrapChild(genesis, carrierParent: w.g)
        let first = try await w.childBlock(previous: genesis, anchoredAt: a, at: -80_000)
        try await w.weigh(first, carrierParent: a, on: &child)
        try assertConnected(try await w.connect(first, on: &child), block: first, tree: child, "first")
        let second = try await w.childBlock(previous: first, anchoredAt: b, at: -79_000)
        try await w.weigh(second, carrierParent: b, on: &child)
        let predecessor = try cid(first)

        // Entirely absent.
        let absent = GatedFetcher(backing: w.fetcher, allowance: [predecessor: 0])
        try assertRefusedStillWeighed(
            try await w.connect(second, on: &child, fetcher: absent), .unavailableEvidence,
            block: second, tree: child, "predecessor bytes absent"
        )

        // Present for validation, gone when the anchor is read: count the
        // predecessor fetches of a full connect on a copy, then allow one fewer.
        var probe = child
        let counter = GatedFetcher(backing: w.fetcher)
        try assertConnected(try await w.connect(second, on: &probe, fetcher: counter), block: second, tree: probe, "probe")
        let fetches = await counter.count(predecessor)
        XCTAssertGreaterThanOrEqual(fetches, 2, "validation and the anchor read each resolve the predecessor")
        let evicted = GatedFetcher(backing: w.fetcher, allowance: [predecessor: fetches - 1])
        try assertRefusedStillWeighed(
            try await w.connect(second, on: &child, fetcher: evicted), .unavailableEvidence,
            block: second, tree: child, "predecessor bytes gone by the anchor read"
        )
        let evictedFetches = await evicted.count(predecessor)
        XCTAssertEqual(evictedFetches, fetches, "the refused fetch is the anchor read")

        try assertConnected(try await w.connect(second, on: &child), block: second, tree: child, "bytes back")
    }

    // MARK: - 4. Retry when facts arrive

    /// A child withdrawal anchored on a parent branch the parent has not yet
    /// executed — first unknown to it, then only weighed — is refused with
    /// evidence required, stays weighed, and connects once the parent
    /// executes that branch.
    func testARefusedAnchorConnectsOnceTheParentExecutesItsBranch() async throws {
        let w = try await World()
        let a = try await w.parentBlock(on: w.g, at: -95_000)
        try await w.weighParent(a)
        try await w.executeParent(a)
        let s = try await w.parentBlock(on: a, at: -90_000, transactions: [w.receiptTx], reward: w.withdrawerAddr)

        let genesis = try await w.childGenesis(anchoredAt: w.g, at: -94_000)
        var child = try await w.bootstrapChild(genesis, carrierParent: w.g)
        let deposit = try await w.childBlock(
            previous: genesis, transactions: [w.depositTx], at: -80_000, reward: w.demanderAddr
        )
        try await w.weigh(deposit, carrierParent: w.g, on: &child)
        try assertConnected(try await w.connect(deposit, on: &child), block: deposit, tree: child, "deposit")
        let withdrawal = try await w.childBlock(
            previous: deposit, anchoredAt: s, transactions: [w.withdrawalTx], at: -70_000, reward: w.withdrawerAddr
        )
        try await w.weigh(withdrawal, carrierParent: s, on: &child)

        try assertRefusedStillWeighed(
            try await w.connect(withdrawal, on: &child), w.continuity(from: w.g, to: s),
            block: withdrawal, tree: child, "the parent has not seen S"
        )
        try await w.weighParent(s)
        try assertRefusedStillWeighed(
            try await w.connect(withdrawal, on: &child), w.continuity(from: w.g, to: s),
            block: withdrawal, tree: child, "the parent has only weighed S"
        )
        try await w.executeParent(s)
        try assertConnected(try await w.connect(withdrawal, on: &child), block: withdrawal, tree: child, "the parent executed S")
        XCTAssertEqual(validatedTip(child), try cid(withdrawal))
    }
}
