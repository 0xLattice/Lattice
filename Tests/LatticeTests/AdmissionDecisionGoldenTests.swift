import Foundation
import XCTest
import Crypto
import Multikey
import UInt256
import cashew
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport

// MARK: - The observable

/// Everything one `ChainTree` admission operation observably produced, with
/// every content id rendered by fixture name so the file reads as a decision
/// table. The `fixtures` map pins the names to their hashes.
struct AdmissionDecisionGolden: Codable, Equatable {
    struct Fact: Codable, Equatable {
        let kind: String
        let block: String
        let grind: String?
        let work: String?
    }

    struct Step: Codable, Equatable {
        let scenario: String
        let step: Int
        /// `header` (`insertRootHeader`/`insertChildHeader`), `genesis`
        /// (`insertGenesis`) or `connect` (`connectJob` → `connect` →
        /// `applyConnect`).
        let operation: String
        let candidate: String
        /// `applied`, `duplicate` or `rejected`.
        let result: String
        /// A stable classification of the failure (`kind.subkind`), produced by
        /// an exhaustive switch — never a runtime description of the enum.
        let failure: String?
        /// Chain path named by the failure, when it names one.
        let failurePath: [String]?
        /// Content ids named by the failure, rendered by fixture name.
        let failureCIDs: [String]?
        let excluded: Bool
        let materializedPostState: Bool
        let commitTip: String?
        let commitRevision: UInt64?
        let commitAdded: [String]
        let commitRemoved: [String]
        /// The applied batches, in order.
        let batches: [[Fact]]
        let possessedAfter: Bool
        let executedAfter: Bool
        let excludedAfter: Bool
    }

    let fixtures: [String: String]
    let steps: [Step]

    static func diff(expected: AdmissionDecisionGolden, actual: AdmissionDecisionGolden) -> [String] {
        var lines: [String] = []
        for name in Set(expected.fixtures.keys).union(actual.fixtures.keys).sorted()
        where expected.fixtures[name] != actual.fixtures[name] {
            lines.append("fixture \(name): expected \(expected.fixtures[name] ?? "absent"), actual \(actual.fixtures[name] ?? "absent")")
        }
        func key(_ step: Step) -> String { "\(step.scenario)/\(step.step)" }
        let actualSteps = Dictionary(uniqueKeysWithValues: actual.steps.map { (key($0), $0) })
        for step in expected.steps {
            guard let other = actualSteps[key(step)] else {
                lines.append("\(key(step)): missing from actual")
                continue
            }
            lines += GoldenFile.fieldDiff(key(step), [
                ("operation", step.operation, other.operation),
                ("candidate", step.candidate, other.candidate),
                ("result", step.result, other.result),
                ("failure", step.failure ?? "nil", other.failure ?? "nil"),
                ("failurePath", "\(step.failurePath ?? [])", "\(other.failurePath ?? [])"),
                ("failureCIDs", "\(step.failureCIDs ?? [])", "\(other.failureCIDs ?? [])"),
                ("excluded", "\(step.excluded)", "\(other.excluded)"),
                ("materializedPostState", "\(step.materializedPostState)", "\(other.materializedPostState)"),
                ("commitTip", step.commitTip ?? "nil", other.commitTip ?? "nil"),
                ("commitRevision", step.commitRevision.map(String.init) ?? "nil", other.commitRevision.map(String.init) ?? "nil"),
                ("commitAdded", "\(step.commitAdded)", "\(other.commitAdded)"),
                ("commitRemoved", "\(step.commitRemoved)", "\(other.commitRemoved)"),
                ("batches", "\(step.batches)", "\(other.batches)"),
                ("possessedAfter", "\(step.possessedAfter)", "\(other.possessedAfter)"),
                ("executedAfter", "\(step.executedAfter)", "\(other.executedAfter)"),
                ("excludedAfter", "\(step.excludedAfter)", "\(other.excludedAfter)"),
            ])
        }
        for key in Set(actualSteps.keys).subtracting(expected.steps.map(key)).sorted() {
            lines.append("\(key): unexpected in actual")
        }
        return lines
    }
}

// MARK: - Fixtures

private enum AdmissionFixtureError: Error, CustomStringConvertible {
    /// The pinned signature no longer verifies over the fixed transfer body.
    case stalePinnedSignature(fresh: String)
    /// The target-miss fixture's carrier happened to beat the hard target.
    case carrierHitsTheHardTarget

    var description: String {
        switch self {
        case .stalePinnedSignature(let fresh):
            "the transfer body changed; pin the fresh signature "
                + "in AdmissionFixtures.transferSignature: \(fresh)"
        case .carrierHitsTheHardTarget:
            "missCarrier must miss the child's target of 1; change its nonce"
        }
    }
}

/// Blocks built once through `BlockBuilder` with fixed timestamps, nonces, a
/// fixed signing key and a PINNED signature, so every content id is stable
/// across runs and hosts. The signature is pinned rather than recomputed
/// because CryptoKit's Ed25519 signing is randomized (verification is not):
/// a fresh signature per run would move `valid`'s CID and flip the
/// `valid`/`side` CID tie-break.
private struct AdmissionFixtures {
    static let spec = ChainSpec.test(premine: 1_000)
    static let easy = UInt256.max
    static let childDirectory = "Child"

    /// Any 32 bytes are a valid Ed25519 seed, so no host RNG is involved.
    static let signerSeed = Data(repeating: 0x41, count: 32)
    static let recipientSeed = Data(repeating: 0x42, count: 32)
    /// Signature of `signerSeed`'s key over the fixed transfer body. `build()`
    /// fails with the replacement value if the body ever changes.
    static let transferSignature = "7f27f0e98caa285fc72b9bc6f3f3bda52b7746e15155b4471860b29d65cc453a53aa11c6d05586b4649ed1564a36b583e270347f54a7408761fdeb92290dfa0b"

    let fetcher = StorableFetcher()
    /// Block boundaries and the spec only — what a node holds after weighing —
    /// so a validate-tier execution finds no body to run.
    let bodyless = StorableFetcher()
    private(set) var names: [String: String] = [:]
    private(set) var blocks: [String: Block] = [:]
    private(set) var packages: [String: ChildValidationPackage] = [:]

    static func fixedKey(_ seed: Data) throws -> (privateKey: String, publicKey: String, address: String) {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let publicKey = Multikey(keyType: .ed25519, keyBytes: key.publicKey.rawRepresentation).hexEncoded
        return (seed.hexString, publicKey, testAddress(publicKey: publicKey))
    }

    private mutating func register(_ name: String, _ block: Block) throws -> Block {
        names[try BlockHeader(node: block).rawCID] = name
        blocks[name] = block
        return block
    }

    private mutating func variant(
        _ name: String,
        of valid: Block,
        height: UInt64? = nil,
        nextTarget: UInt256? = nil,
        prevState: LatticeStateHeader? = nil,
        postState: LatticeStateHeader? = nil,
        timestamp: Int64? = nil,
        spec: VolumeImpl<ChainSpec>? = nil
    ) async throws -> Block {
        try register(name, try await storeBuiltBlock(Block(
            version: valid.version,
            parent: valid.parent,
            transactions: valid.transactions,
            target: valid.target,
            nextTarget: nextTarget ?? valid.nextTarget,
            spec: spec ?? valid.spec,
            parentState: valid.parentState,
            prevState: prevState ?? valid.prevState,
            postState: postState ?? valid.postState,
            children: valid.children,
            height: height ?? valid.height,
            timestamp: timestamp ?? valid.timestamp,
            rewardRecipient: valid.rewardRecipient,
            nonce: valid.nonce
        ), in: fetcher))
    }

    static func build() async throws -> AdmissionFixtures {
        var fixtures = AdmissionFixtures()
        let signer = try fixedKey(signerSeed)
        let recipient = try fixedKey(recipientSeed)
        let genesis = try fixtures.register("genesis", try await buildPremineGenesis(
            spec: spec, owner: (signer.privateKey, signer.publicKey),
            fetcher: fixtures.fetcher, timestamp: 1_000, target: easy
        ))
        // A real state change: a transfer, and block 1's reward paid to the
        // same recipient through the coinbase.
        let body = try HeaderImpl<TransactionBody>(node: TransactionBody(
            accountActions: [
                AccountAction(owner: signer.address, delta: -10),
                AccountAction(owner: recipient.address, delta: 10),
            ],
            actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
            signers: [signer.address], nonce: 0,
            chainPath: [DEFAULT_ROOT_DIRECTORY]
        ))
        guard TransactionSigning.verify(
            bodyHeader: body, signature: transferSignature, publicKeyHex: signer.publicKey
        ) else {
            throw AdmissionFixtureError.stalePinnedSignature(
                fresh: TransactionSigning.sign(bodyHeader: body, privateKeyHex: signer.privateKey) ?? "<signing failed>"
            )
        }
        let transfer = Transaction(signatures: [signer.publicKey: transferSignature], body: body)
        let valid = try fixtures.register("valid", try await buildAndStoreBlock(
            previous: genesis, transactions: [transfer],
            timestamp: 2_000, target: easy, nonce: 1,
            rewardRecipient: recipient.address, fetcher: fixtures.fetcher
        ))
        _ = try fixtures.register("side", try await buildAndStoreBlock(
            previous: genesis, timestamp: 2_500, target: easy, nonce: 8, fetcher: fixtures.fetcher
        ))
        _ = try fixtures.register("grandchild", try await buildAndStoreBlock(
            previous: valid, timestamp: 3_000, target: easy, nonce: 3, fetcher: fixtures.fetcher
        ))
        _ = try await fixtures.variant("badPrevState", of: valid, prevState: valid.postState)
        _ = try await fixtures.variant("wrongNextTarget", of: valid, nextTarget: valid.nextTarget - UInt256(1))
        _ = try await fixtures.variant("wrongHeight", of: valid, height: valid.height + 1)
        _ = try await fixtures.variant("forgedPostState", of: valid, postState: genesis.postState)
        _ = try await fixtures.variant("staleTimestamp", of: valid, timestamp: genesis.timestamp)
        _ = try await fixtures.variant(
            "otherSpec", of: valid, spec: try VolumeImpl<ChainSpec>(node: ChainSpec.test(premine: 7))
        )

        // A second root for the root chain, which admits only its configured
        // genesis.
        _ = try fixtures.register("rivalGenesis", try await buildAndStoreGenesis(
            spec: spec, timestamp: 1_000, target: easy, nonce: 11, fetcher: fixtures.fetcher
        ))

        let hardGenesis = try fixtures.register("hardGenesis", try await buildAndStoreGenesis(
            spec: spec, timestamp: 1_000, target: easy / UInt256(2), nonce: 9, fetcher: fixtures.fetcher
        ))
        _ = try fixtures.register("tooEasy", try await buildAndStoreBlock(
            previous: hardGenesis, timestamp: 2_000, target: easy, nonce: 1, fetcher: fixtures.fetcher
        ))

        // A child chain block co-mined into a carrier on the parent chain.
        // Child genesis blocks commit the parent genesis's post-state (§5.1).
        let childGenesis = try fixtures.register("childGenesis", try await storeBuiltBlock(
            try await BlockBuilder.buildChildGenesis(
                spec: spec, parentState: genesis.postState,
                timestamp: 1_000, target: easy, nonce: 1, fetcher: fixtures.fetcher
            ), in: fixtures.fetcher
        ))
        let childCandidate = try fixtures.register("childCandidate", try await buildAndStoreBlock(
            previous: childGenesis, parentChainBlock: genesis,
            timestamp: 2_000, target: easy, nonce: 1, fetcher: fixtures.fetcher
        ))
        let carrier = try fixtures.register("carrier", try await buildAndStoreGenesis(
            spec: spec, children: [childDirectory: childCandidate],
            timestamp: 3_000, target: easy, nonce: 2, fetcher: fixtures.fetcher
        ))
        let proof = try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: carrier),
            childDirectory: childDirectory,
            fetcher: fixtures.fetcher
        )
        fixtures.packages["childCandidate"] = ChildValidationPackage(proof: proof)

        // Roots of the child chain, each weighed by a carrier's proof: the
        // genesis, a rival genesis, and one block under the rival.
        let rivalChildGenesis = try fixtures.register("rivalChildGenesis", try await storeBuiltBlock(
            try await BlockBuilder.buildChildGenesis(
                spec: spec, parentState: genesis.postState,
                timestamp: 1_000, target: easy, nonce: 2, fetcher: fixtures.fetcher
            ), in: fixtures.fetcher
        ))
        let rivalChildBlock = try fixtures.register("rivalChildBlock", try await buildAndStoreBlock(
            previous: rivalChildGenesis, parentChainBlock: genesis,
            timestamp: 2_000, target: easy, nonce: 2, fetcher: fixtures.fetcher
        ))
        for (index, (name, block)) in [
            ("childGenesis", childGenesis),
            ("rivalChildGenesis", rivalChildGenesis),
            ("rivalChildBlock", rivalChildBlock),
        ].enumerated() {
            // A carrier's `prevState` is its child's `parentState`: a block on
            // the parent genesis for a child genesis, a genesis-shaped carrier
            // for a block committing the empty parent state.
            let rootCarrier = try fixtures.register("\(name)Carrier", block.parent == nil
                ? try await buildAndStoreBlock(
                    previous: genesis, children: [childDirectory: block],
                    timestamp: 3_000, target: easy, nonce: 20 + UInt64(index), fetcher: fixtures.fetcher
                )
                : try await buildAndStoreGenesis(
                    spec: spec, children: [childDirectory: block],
                    timestamp: 3_000, target: easy, nonce: 20 + UInt64(index), fetcher: fixtures.fetcher
                ))
            fixtures.packages[name] = ChildValidationPackage(proof: try await ChildBlockProof.generate(
                rootHeader: try BlockHeader(node: rootCarrier),
                childDirectory: childDirectory,
                fetcher: fixtures.fetcher
            ))
        }

        // A child block whose own target the carrier's hash MISSES: the proof
        // still relays work for descendants, but at this level the block is a
        // carrier, never admitted.
        let hardTarget = UInt256(1)
        let hardChildGenesis = try fixtures.register("hardChildGenesis", try await buildAndStoreGenesis(
            spec: spec, timestamp: 1_000, target: hardTarget, nonce: 1, fetcher: fixtures.fetcher
        ))
        let missedChild = try fixtures.register("missedChild", try await buildAndStoreBlock(
            previous: hardChildGenesis, parentChainBlock: genesis,
            timestamp: 2_000, target: hardTarget, nextTarget: easy, nonce: 2, fetcher: fixtures.fetcher
        ))
        let missCarrier = try fixtures.register("missCarrier", try await buildAndStoreGenesis(
            spec: spec, children: [childDirectory: missedChild],
            timestamp: 3_000, target: easy, nonce: 3, fetcher: fixtures.fetcher
        ))
        guard missCarrier.proofOfWorkHash() > hardTarget else {
            throw AdmissionFixtureError.carrierHitsTheHardTarget
        }
        fixtures.packages["missedChild"] = ChildValidationPackage(proof: try await ChildBlockProof.generate(
            rootHeader: try BlockHeader(node: missCarrier),
            childDirectory: childDirectory,
            fetcher: fixtures.fetcher
        ))

        try await BlockHeader(node: valid).storeBlockBoundary(fetcher: fixtures.fetcher, storer: fixtures.bodyless)
        try await BlockHeader(node: genesis).storeBlockBoundary(fetcher: fixtures.fetcher, storer: fixtures.bodyless)
        fixtures.bodyless.store(
            rawCid: genesis.spec.rawCID,
            data: try await fixtures.fetcher.fetch(rawCid: genesis.spec.rawCID)
        )
        return fixtures
    }

    func name(_ hash: String) -> String { names[hash] ?? hash }

    func hash(named name: String) throws -> String {
        try BlockHeader(node: try XCTUnwrap(blocks[name], "no fixture named \(name)")).rawCID
    }

    func tree(genesis: String, path: [String] = [DEFAULT_ROOT_DIRECTORY]) throws -> ChainTree {
        try ChainTree.fromGenesis(
            block: try XCTUnwrap(blocks[genesis], "no fixture named \(genesis)"),
            context: testChainContext(path: path),
            spec: Self.spec
        )
    }

    /// The verified evidence of `name`'s carrier proof on `path`.
    func evidence(_ name: String, path: [String]) async throws -> VerifiedChildEvidence {
        let package = try XCTUnwrap(packages[name], "no package for \(name)")
        let block = try XCTUnwrap(blocks[name], "no fixture named \(name)")
        return try await package.proof.verifySecuringWork(child: block, chainPath: path).get()
    }

    /// A child tree on `path` made by `ChainTree.bootstrap` — the one genesis
    /// path — from `genesis` and its carrier's proof.
    func bootstrappedTree(genesis: String, path: [String]) async throws -> ChainTree {
        let block = try XCTUnwrap(blocks[genesis], "no fixture named \(genesis)")
        return try await ChainTree.bootstrap(
            genesis: try BlockHeader(node: block),
            evidence: try await evidence(genesis, path: path),
            fetcher: fetcher,
            context: testChainContext(path: path),
            parentFacts: try parentFacts()
        ).get().tree
    }

    /// Parent facts attesting the parent genesis's post-state — the state
    /// every child genesis fixture commits.
    func parentFacts() throws -> ProducedParentStates {
        ProducedParentStates(states: [try XCTUnwrap(blocks["genesis"]).postState.rawCID])
    }

    /// The stable classification the golden records for a failure.
    func classify(_ failure: BlockImportError) -> (kind: String, path: [String]?, cids: [String]?) {
        switch failure {
        case .unavailableEvidence: return ("unavailableEvidence", nil, nil)
        case .providerMalformedEvidence: return ("providerMalformedEvidence", nil, nil)
        case .protocolInvalid: return ("protocolInvalid", nil, nil)
        case .localVerificationFailure: return ("localVerificationFailure", nil, nil)
        case .notYetValid: return ("notYetAdmissible", nil, nil)
        case .notAcceptedAtCurrentChain: return ("notAcceptedAtCurrentChain", nil, nil)
        case .revisionExhausted: return ("revisionExhausted", nil, nil)
        case .executedVerdictContradiction: return ("executedVerdictContradiction", nil, nil)
        case .proofOfWorkInvalid: return ("proofOfWorkInvalid", nil, nil)
        case .crossChainEvidenceRequired(let requirement):
            switch requirement {
            case .childProof(let chainPath, let childCID):
                return ("crossChainEvidenceRequired.childProof", chainPath, [name(childCID)])
            case .parentStateContinuity(let parentPath, let fromStateCID, let toStateCID):
                return (
                    "crossChainEvidenceRequired.parentStateContinuity",
                    parentPath,
                    [name(fromStateCID), name(toStateCID)]
                )
            }
        }
    }
}

// MARK: - Scenarios

private struct AdmissionScenario {
    enum Operation: String {
        case header
        case genesis
        case connect
    }

    struct Step {
        let operation: Operation
        let candidate: String
        /// Insert a child header with the verified evidence of its package.
        var package: Bool = false
        /// Execute against the boundary-only fetcher.
        var bodyless: Bool = false
    }

    let name: String
    let genesis: String
    var path: [String] = [DEFAULT_ROOT_DIRECTORY]
    /// Seed a child tree through `ChainTree.bootstrap` (its genesis weighed
    /// by its carrier's proof) rather than the test-only `fromGenesis`.
    var bootstrapped: Bool = false
    let steps: [Step]

    static func header(_ candidate: String, package: Bool = false) -> Step {
        Step(operation: .header, candidate: candidate, package: package)
    }

    static func connect(_ candidate: String, bodyless: Bool = false) -> Step {
        Step(operation: .connect, candidate: candidate, bodyless: bodyless)
    }

    /// `insertGenesis`; with `package`, the candidate's carrier proof.
    static func genesis(_ candidate: String, package: Bool = false) -> Step {
        Step(operation: .genesis, candidate: candidate, package: package)
    }

    static let childPath = [DEFAULT_ROOT_DIRECTORY, AdmissionFixtures.childDirectory]

    static let all: [AdmissionScenario] = [
        AdmissionScenario(name: "valid", genesis: "genesis", steps: [header("valid"), connect("valid")]),
        AdmissionScenario(name: "duplicate", genesis: "genesis", steps: [header("valid"), header("valid")]),
        AdmissionScenario(name: "sideBlock", genesis: "genesis", steps: [header("valid"), header("side")]),
        AdmissionScenario(name: "unavailableParent", genesis: "genesis", steps: [header("grandchild")]),
        AdmissionScenario(name: "badPrevState", genesis: "genesis", steps: [header("badPrevState"), connect("badPrevState")]),
        AdmissionScenario(name: "staleTimestamp", genesis: "genesis", steps: [header("staleTimestamp")]),
        AdmissionScenario(name: "otherSpec", genesis: "genesis", steps: [header("otherSpec")]),
        AdmissionScenario(name: "wrongNextTarget", genesis: "genesis", steps: [header("wrongNextTarget")]),
        AdmissionScenario(name: "wrongHeight", genesis: "genesis", steps: [header("wrongHeight")]),
        AdmissionScenario(name: "forgedPostState", genesis: "genesis", steps: [header("forgedPostState"), connect("forgedPostState")]),
        AdmissionScenario(name: "targetEasierThanSchedule", genesis: "hardGenesis", steps: [header("tooEasy")]),
        AdmissionScenario(name: "rivalGenesis", genesis: "genesis", steps: [header("hardGenesis")]),
        AdmissionScenario(name: "carriedChild", genesis: "childGenesis", path: childPath, steps: [header("childCandidate", package: true)]),
        AdmissionScenario(name: "carriedChildWithoutProof", genesis: "childGenesis", path: childPath, steps: [header("childCandidate")]),
        AdmissionScenario(name: "targetMissCarrier", genesis: "hardChildGenesis", path: childPath, steps: [header("missedChild", package: true)]),
        AdmissionScenario(
            name: "weighedThenValidateWithoutBody", genesis: "genesis",
            steps: [header("valid"), connect("valid", bodyless: true)]
        ),
        AdmissionScenario(name: "weighedThenExtend", genesis: "genesis", steps: [header("valid"), header("grandchild")]),
        // Genesis roots (§9.9 genesis admission, §9.4 across roots).
        AdmissionScenario(name: "rootRivalGenesis", genesis: "genesis", steps: [genesis("rivalGenesis")]),
        AdmissionScenario(
            name: "childRivalWithoutProof", genesis: "childGenesis", path: childPath, bootstrapped: true,
            steps: [genesis("rivalChildGenesis")]
        ),
        AdmissionScenario(
            name: "childRivalRoot", genesis: "childGenesis", path: childPath, bootstrapped: true,
            steps: [genesis("rivalChildGenesis", package: true), connect("rivalChildGenesis"),
                    genesis("rivalChildGenesis", package: true)]
        ),
        AdmissionScenario(
            name: "rivalHeavierWins", genesis: "childGenesis", path: childPath, bootstrapped: true,
            steps: [genesis("rivalChildGenesis", package: true), header("rivalChildBlock", package: true),
                    connect("rivalChildGenesis")]
        ),
        AdmissionScenario(
            name: "rivalEqualWorkTie", genesis: "childGenesis", path: childPath, bootstrapped: true,
            steps: [header("childCandidate", package: true), genesis("rivalChildGenesis", package: true),
                    header("rivalChildBlock", package: true)]
        ),
    ]
}

// MARK: - Tests

/// Pins the admission decision table of the `ChainTree` API: for every
/// fixture block, the result case, failure, exclusion, materialization,
/// emitted commit, and the exact applied batches.
final class AdmissionDecisionGoldenTests: XCTestCase {
    static let goldenName = "admission-decisions.json"

    private func fact(_ fact: ChainFact, _ fixtures: AdmissionFixtures) -> AdmissionDecisionGolden.Fact {
        switch fact {
        case .block(let value):
            AdmissionDecisionGolden.Fact(kind: "block", block: fixtures.name(value.blockHash), grind: nil, work: nil)
        case .work(let value):
            AdmissionDecisionGolden.Fact(
                kind: "work",
                block: fixtures.name(value.blockHash),
                grind: fixtures.name(value.contribution.id),
                work: value.contribution.work.toHexString()
            )
        case .exclusion(let value):
            AdmissionDecisionGolden.Fact(kind: "exclusion", block: fixtures.name(value.blockHash), grind: nil, work: nil)
        case .validation(let value):
            AdmissionDecisionGolden.Fact(kind: "validation", block: fixtures.name(value.blockHash), grind: nil, work: nil)
        case .fold(let value):
            AdmissionDecisionGolden.Fact(kind: "fold", block: fixtures.name(value.blockHash), grind: nil, work: value.work.toHexString())
        }
    }

    private func perform(
        _ step: AdmissionScenario.Step,
        on tree: inout ChainTree,
        path: [String],
        fixtures: AdmissionFixtures
    ) async throws -> ChainTreeAdmission {
        let block = try XCTUnwrap(fixtures.blocks[step.candidate])
        switch step.operation {
        case .header:
            let resolved = try await block.children.resolve(fetcher: fixtures.fetcher).node
            let childIndex = try XCTUnwrap(resolved)
            guard step.package else {
                return tree.insertRootHeader(block, childIndex: childIndex)
            }
            let package = try XCTUnwrap(fixtures.packages[step.candidate])
            let evidence = try await package.proof.verifySecuringWork(child: block, chainPath: path).get()
            return tree.insertChildHeader(block, childIndex: childIndex, evidence: evidence)
        case .genesis:
            guard step.package else {
                return tree.insertGenesis(block, spec: AdmissionFixtures.spec, childIndex: testChildIndex(block))
            }
            return tree.insertGenesis(block, spec: AdmissionFixtures.spec, childIndex: testChildIndex(block),
                evidence: try await fixtures.evidence(step.candidate, path: path)
            )
        case .connect:
            let job = try XCTUnwrap(tree.connectJob(for: try BlockHeader(node: block).rawCID))
            let verdict = await ChainTree.connect(
                job, fetcher: step.bodyless ? fixtures.bodyless : fixtures.fetcher,
                parentFacts: path.count > 1 ? try fixtures.parentFacts() : nil
            )
            return tree.applyConnect(verdict)
        }
    }

    private func run(
        _ scenario: AdmissionScenario,
        fixtures: AdmissionFixtures
    ) async throws -> [AdmissionDecisionGolden.Step] {
        var tree = scenario.bootstrapped
            ? try await fixtures.bootstrappedTree(genesis: scenario.genesis, path: scenario.path)
            : try fixtures.tree(genesis: scenario.genesis, path: scenario.path)
        var steps: [AdmissionDecisionGolden.Step] = []
        for (index, step) in scenario.steps.enumerated() {
            let hash = try fixtures.hash(named: step.candidate)
            let result = try await perform(step, on: &tree, path: scenario.path, fixtures: fixtures)
            let resultName: String
            let commit: ChainCommit?
            switch result {
            case .applied(let update):
                resultName = "applied"
                commit = update.commit
            case .duplicate(let promoted):
                resultName = "duplicate"
                commit = promoted
            case .rejected:
                resultName = "rejected"
                commit = nil
            }
            let failure = result.failure.map(fixtures.classify)
            steps.append(AdmissionDecisionGolden.Step(
                scenario: scenario.name,
                step: index,
                operation: step.operation.rawValue,
                candidate: step.candidate,
                result: resultName,
                failure: failure?.kind,
                failurePath: failure?.path,
                failureCIDs: failure?.cids,
                excluded: result.update?.excluded ?? false,
                materializedPostState: result.update?.materializedPostState != nil,
                commitTip: commit.map { fixtures.name($0.tipHash) },
                commitRevision: commit?.revision,
                commitAdded: commit.map { $0.canonicalBlocksAdded.keys.map(fixtures.name).sorted() } ?? [],
                commitRemoved: commit.map { $0.canonicalBlocksRemoved.map(fixtures.name).sorted() } ?? [],
                batches: (result.update?.batches ?? []).map { $0.facts.map { fact($0, fixtures) } },
                possessedAfter: tree.contains(blockHash: hash),
                executedAfter: tree.hasExecutedAncestry(blockHash: hash),
                excludedAfter: tree.isExcludedRoot(hash)
            ))
        }
        return steps
    }

    func testAdmissionDecisionsMatchGolden() async throws {
        let fixtures = try await AdmissionFixtures.build()
        var steps: [AdmissionDecisionGolden.Step] = []
        for scenario in AdmissionScenario.all {
            steps += try await run(scenario, fixtures: fixtures)
        }
        let golden = AdmissionDecisionGolden(
            fixtures: Dictionary(uniqueKeysWithValues: fixtures.names.map { ($0.value, $0.key) }),
            steps: steps
        )
        try GoldenFile.assert(golden, matches: Self.goldenName, diff: AdmissionDecisionGolden.diff)
    }
}
