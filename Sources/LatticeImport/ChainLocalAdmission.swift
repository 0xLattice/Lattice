import Foundation
import cashew
import LatticePrimitives
import LatticePoW
import LatticeValidation
import LatticeProofs
import LatticeBlockTree
import struct WasmKit.Trap

public enum BlockImportError: Error, Sendable, Equatable {
    case unavailableEvidence
    case providerMalformedEvidence
    case crossChainEvidenceRequired(CrossChainEvidenceRequirement)
    case protocolInvalid
    /// This node failed to encode, hash or decrypt while verifying: a fault
    /// of the node, not a property of the block. Retried, never excluded, or
    /// a node-local fault would fork this node onto a lighter branch.
    case localVerificationFailure
    case notYetValid
    case notAcceptedAtCurrentChain
    case revisionExhausted
    /// A verdict contradicting an execution fact this chain already holds:
    /// an executed block proven invalid, or a proven-invalid block proven
    /// valid. Execution and exclusion are never revoked, so the verdict is a
    /// local fault for the node to surface — never a fact, never a retry
    /// that could succeed.
    case executedVerdictContradiction
    /// The header proves no work the chain accepts: its grind misses its
    /// target, its target is off the schedule, or its bytes do not match their
    /// CID (bytes that match but do not decode are dropped, spec section 9.9).
    /// The one header failure that blames its sender.
    case proofOfWorkInvalid
}

/// Which admission tier `prepare` produces.
///
/// SUPERSEDED: this actor path does not implement spec §9.9 header
/// admission and MUST NOT be used on the flag-day network. Consensus
/// admission is `ChainTree.insertRootHeader`/`insertChildHeader` and
/// `connectJob`/`connect`/`applyConnect`; this path is deleted once the node
/// has moved to them.
///
/// - `.full` (default, unchanged behaviour): execute the state transition and
///   emit a block fact carrying the materialized post-state and its `stateDiff`
///   — a block is weighed and validated in one gate.
/// - `.header` (deferred execution, weight-first-acquisition): weigh the block
///   from its root + verified PoW / securing-work, WITHOUT executing the state
///   transition. The declared post-state is recorded as an unverified claim;
///   validity is a separate, later judgment on the validated tier. Because the
///   consensus graph (`ConsensusBlockInput`) never reads `stateDiff`, a weighed
///   block contributes to fork choice identically to an eager one.
/// - `.execution` (deferred execution, validated tier): execute a block that was
///   already weighed. On success emit the block fact carrying the materialized
///   post-state — the durable "validated" marker that upgrades the weighed
///   claim. On a COMPLETED deterministic invalidity (`postState` mismatch or a
///   committed validity rule) emit an `.exclusion` fact: the subtree keeps
///   its weight, and the fork-choice descent never steps into it. An
///   availability failure is not a verdict: it is a retryable rejection that
///   excludes nothing.
public enum ImportMode: Sendable {
    case full
    case header
    case execution
}


/// What the node must make durable for one admission: the batch.
public struct BlockImportStagingContext: Sendable {
    public let batch: BlockImportBatch

    init(batch: BlockImportBatch) {
        self.batch = batch
    }
}

public struct ChainAcceptance: Sendable {
    public let facts: BlockImportBatch
    public let materializedPostState: LatticeState?
    public let commit: ChainCommit
    public let sameChainPredecessor: SameChainPredecessorRequirement?

    public var stateDiff: StateDiff? {
        for case .block(let fact) in facts.facts { return fact.stateDiff }
        return nil
    }
}

public enum BlockImportResult: Sendable {
    case accepted(ChainAcceptance)
    case duplicate(
        sameChainPredecessor: SameChainPredecessorRequirement? = nil,
        promotedCommit: ChainCommit? = nil
    )
    case rejected(
        BlockImportError,
        sameChainPredecessor: SameChainPredecessorRequirement? = nil
    )

    public var materializedPostState: LatticeState? {
        switch self {
        case .accepted(let acceptance): acceptance.materializedPostState
        case .duplicate, .rejected: nil
        }
    }

    public var sameChainPredecessor: SameChainPredecessorRequirement? {
        switch self {
        case .accepted(let acceptance): acceptance.sameChainPredecessor
        case .rejected(_, let requirement): requirement
        case .duplicate(let requirement, _): requirement
        }
    }

    public var crossChainEvidenceRequirement: CrossChainEvidenceRequirement? {
        guard case .rejected(
            .crossChainEvidenceRequired(let requirement), _
        ) = self else {
            return nil
        }
        return requirement
    }

    public var commit: ChainCommit? {
        switch self {
        case .accepted(let acceptance): acceptance.commit
        case .duplicate(_, let promotedCommit): promotedCommit
        case .rejected: nil
        }
    }

    public var failure: BlockImportError? {
        if case .rejected(let failure, _) = self { return failure }
        return nil
    }

}

public struct ChildChainBootstrapAcceptance: Sendable {
    public let level: ChainLevel
    public let stateDiff: StateDiff
    public let materializedPostState: LatticeState?
    public let commit: ChainCommit
}

public enum ChildChainBootstrapResult: Sendable {
    case accepted(ChildChainBootstrapAcceptance)
    case rejected(BlockImportError)

    public var failure: BlockImportError? {
        guard case .rejected(let failure) = self else { return nil }
        return failure
    }
}

struct PreparedImport: Sendable {
    enum Kind: Sendable {
        /// `validated` records whether the transition was EXECUTED. It is stated
        /// per tier rather than inferred from the materialized state, because a
        /// nil state is not a reliable proxy and this flag gates parent-state
        /// attestation.
        case block(StateDiff, LatticeState?, validated: Bool)
        case evidence
        /// Validated tier: execution of a previously-weighed block completed and
        /// FAILED deterministically. Stage a single `.exclusion` fact; the block
        /// and its work are already possessed, so no new content is stored and
        /// no work fact is re-emitted.
        case exclusion
    }

    let resolvedHeader: BlockHeader
    let block: Block
    let fetcher: any Fetcher
    let contribution: VerifiedWorkContribution
    /// The chain this block is on.
    let chainPath: [String]
    let sameChainPredecessor: SameChainPredecessorRequirement?
    let kind: Kind
    /// A weighed admission possesses the block for fork choice but MUST NOT
    /// resolve or store the block BODY (tier-3: transaction bodies, validation-
    /// path states, WASM policy modules, genesis empty-state). Only the block
    /// BOUNDARY is stored, so the ~74% of below-tip blocks that never become
    /// canonical never fetch their bodies. The body is fetched+stored later, only
    /// if/when the block is validated (`.execution`/`.full` keep storing it).
    /// `var` only so the synthesized memberwise init can default it; never mutated.
    var defersBodyStore: Bool = false
    /// This block's child commitments (§9.10), enumerated where a block fact
    /// is emitted and carried onto it. Nil wherever no block fact is emitted
    /// (evidence, exclusion) and for the bootstrap genesis, which commits
    /// nothing by convention; never mutated.
    var childCommitments: [String: String]? = nil
    /// A weighed genesis's spec, bound by CID: held once its batch applies,
    /// as `insertGenesis` holds it. Never mutated.
    var genesisSpec: ChainSpec? = nil

    var facts: BlockImportBatch {
        BlockImport.admissionFacts(
            blockHash: resolvedHeader.rawCID,
            block: block,
            contribution: contribution,
            kind: kind,
            childCommitments: childCommitments
        )
    }

    /// Store the immutable validation Volumes before the node takes its
    /// durability lease. They remain unretained until the admission batch
    /// becomes visible.
    func cacheValidationContent(
        to validationContentStorer: any VolumeStorer
    ) async throws {
        switch kind {
        case .evidence, .exclusion:
            return
        case .block:
            // A weighed admission stores only the block boundary (root node + tx
            // /children tries) — never the body (tx bodies, validation-path
            // states, WASM modules, genesis empty-state). Every other tier stores
            // the full block unchanged.
            if defersBodyStore {
                try await resolvedHeader.storeBlockBoundary(
                    fetcher: fetcher,
                    storer: validationContentStorer
                )
            } else {
                try await resolvedHeader.storeBlock(
                    fetcher: fetcher,
                    storer: validationContentStorer
                )
            }
        }
    }

    /// Materialized state is a complete Volume and can be evicted until it is
    /// retained with the staged batch. The node must therefore invoke this
    /// immediately before its retention-and-stage boundary.
    func storeMaterializedPostState(
        to materializedVolumeStorer: any VolumeStorer
    ) async throws {
        guard case .block(let stateDiff, let materializedPostState, _) = kind,
              let materializedPostState else {
            return
        }
        try await LatticeStateHeader(node: materializedPostState)
            .storeMaterialized(
                createdBy: stateDiff,
                storer: materializedVolumeStorer
            )
    }

    var stagingContext: BlockImportStagingContext {
        BlockImportStagingContext(batch: facts)
    }
}

fileprivate enum Preparation {
    case ready(PreparedImport)
    case result(BlockImportResult)
    case duplicate(PreparedDuplicateImportState)
}

public enum BlockImportPreflightError: Error, Sendable, Equatable {
    case invalidToken
}

/// A one-use, level-bound result of remote validation and validation-Volume
/// storage.
public actor PreparedBlockImport {
    fileprivate nonisolated let stagingContext: BlockImportStagingContext

    private let levelIdentity: UUID
    private var prepared: PreparedImport?

    fileprivate init(
        levelIdentity: UUID,
        prepared: PreparedImport,
        stagingContext: BlockImportStagingContext
    ) {
        self.levelIdentity = levelIdentity
        self.prepared = prepared
        self.stagingContext = stagingContext
    }

    fileprivate func take(for levelIdentity: UUID) -> PreparedImport? {
        guard self.levelIdentity == levelIdentity else { return nil }
        defer { prepared = nil }
        return prepared
    }
}

fileprivate struct PreparedDuplicateImportState: Sendable {
    let blockHash: String
}

/// A one-use, level-bound duplicate whose immutable validation completed before
/// the node acquired its mutation lease. Resolving it under that lease
/// re-projects fork choice; it never stages consensus facts or reacquires
/// remote content.
public actor PreparedDuplicateImport {
    private let levelIdentity: UUID
    private var state: PreparedDuplicateImportState?

    fileprivate init(
        levelIdentity: UUID,
        state: PreparedDuplicateImportState
    ) {
        self.levelIdentity = levelIdentity
        self.state = state
    }

    fileprivate func take(
        for levelIdentity: UUID
    ) -> PreparedDuplicateImportState? {
        guard self.levelIdentity == levelIdentity else { return nil }
        defer { state = nil }
        return state
    }
}

public enum BlockImportPreflightResult: Sendable {
    case terminal(BlockImportResult)
    case duplicate(PreparedDuplicateImport)
    case ready(PreparedBlockImport)
}

enum BlockImport {
    static func verifyChildProof(
        _ package: ChildValidationPackage,
        child: Block,
        context: ChainRuntimeContext
    ) async -> Result<VerifiedChildEvidence, BlockImportError> {
        await package.proof.verifySecuringWork(
            child: child,
            chainPath: context.path
        ).mapError(mapProofFailure)
    }

    /// The parent-chain facts a child package carries, answered as lookups:
    /// a link the package holds either is the one asked for or is malformed,
    /// and a link it should not hold at all is malformed too.
    static func parentFactLookup(
        _ package: ChildValidationPackage
    ) -> ParentFactLookup {
        { query in
            switch query {
            case .continuity(let expected):
                guard let link = package.parentStateContinuityLink else { return .absent }
                return link == expected ? .present : .malformed
            case .none:
                return package.parentStateContinuityLink == nil ? .absent : .malformed
            }
        }
    }

    /// The parent-chain fact a parent level's executed set answers: a state
    /// its executed set produced on any branch. A level holds no wrong link,
    /// so nothing it answers is malformed.
    static func parentFactLookup(
        _ facts: (any ParentChainFacts)?
    ) -> ParentFactLookup {
        { query in
            switch query {
            case .continuity(let expected):
                guard let facts else { return .absent }
                return await facts.hasContinuity(expected) ? .present : .absent
            case .none:
                return .absent
            }
        }
    }

    /// `predecessorParentState` is the same-chain predecessor's declared
    /// `parentState`, nil for a genesis.
    static func validateParentFacts(
        _ lookup: ParentFactLookup,
        child: Block,
        childCID: String,
        predecessorParentState: String?,
        context: ChainRuntimeContext
    ) async -> BlockImportError? {
        let parentPath = Array(context.path.dropLast())
        // Every block proves that the parent chain carried its anchor forward
        // from its predecessor's (§5.3 step 6): its `parentState` was produced
        // by the parent's executed set, by a block that is or descends from
        // one that produced the predecessor's `parentState`. A genesis has no
        // predecessor and proves its anchor from `emptyHeader`, the parent's
        // own genesis pre-state.
        //
        // Real: the anchor cannot be checked against a CARRIER's `prevState`
        // (`verifySecuringWork`'s terminal binding). A carrier is
        // content-addressed bytes that need not be admitted, connected, valid
        // or canonical (§9.5), so both sides would be attacker-chosen, and a
        // forged `receiptState` could settle a withdrawal that was never paid.
        // Nor may an anchor equal to the predecessor's pass on that equality:
        // a weighed predecessor never proved its own anchor, so a forged
        // state would be laundered one height further along. The parent fact
        // therefore always proves the anchor itself was produced, equal or not.
        //
        // Forward: anchors may not move back or sideways in the parent's
        // history. Otherwise a child block anchored on a parent branch that was
        // then reorganized away (one holding a receipt the canonical parent no
        // longer has) is extended by blocks anchored on the new canonical
        // branch, and its withdrawal stands although the parent chain no longer
        // pays it. Forward-only, honest miners on the canonical parent cannot
        // build on it, so a parent reorganization reorganizes the child too.
        let emptyCID = LatticeState.emptyHeader.rawCID
        let fromStateCID = predecessorParentState ?? emptyCID
        let toStateCID = child.parentState.rawCID
        // A child genesis always proves a real parent state (§5.1 rule 4).
        if child.parent == nil, toStateCID == emptyCID {
            return .protocolInvalid
        }
        if toStateCID == emptyCID {
            // The block commits no parent state, which is the genesis
            // pre-state: allowed only while its predecessor commits none
            // either. Dropping back to it from a real anchor moves backward,
            // and both anchors are in the blocks' own bytes.
            guard fromStateCID == emptyCID else { return .protocolInvalid }
            return await lookup(.none) == .absent ? nil : .providerMalformedEvidence
        }

        let expected = ParentStateContinuityLink(
            parentPath: parentPath,
            fromStateCID: fromStateCID,
            toStateCID: toStateCID
        )
        switch await lookup(.continuity(expected)) {
        case .present:
            return nil
        case .malformed:
            return .providerMalformedEvidence
        case .absent:
            return .crossChainEvidenceRequired(.parentStateContinuity(
                parentPath: parentPath,
                fromStateCID: fromStateCID,
                toStateCID: toStateCID
            ))
        }
    }

    fileprivate static func prepare(
        level: ChainLevel,
        blockHeader: BlockHeader,
        fetcher: any Fetcher,
        childPackage: ChildValidationPackage?,
        validationContext: ValidationContext,
        mode: ImportMode = .full
    ) async -> Preparation {
        let context = level.context
        let resolvedHeader: BlockHeader
        let block: Block
        switch await resolveBlock(blockHeader, fetcher: fetcher) {
        case .success(let resolved):
            resolvedHeader = resolved.header
            block = resolved.block
        case .failure(let failure):
            return .result(rejection(failure))
        }
        let blockHash = resolvedHeader.rawCID
        let knownBlock = await level.chain.contains(blockHash: blockHash)

        let contribution: VerifiedWorkContribution?
        if context.isRoot {
            guard childPackage == nil else {
                return .result(rejection(.protocolInvalid))
            }
            contribution = rootWork(of: block, blockHash: blockHash)
        } else {
            guard let childPackage else {
                return .result(rejection(.crossChainEvidenceRequired(.childProof(
                    chainPath: context.path,
                    childCID: blockHash
                ))))
            }
            switch await verifyChildProof(
                childPackage,
                child: block,
                context: context
            ) {
            case .success(let verified):
                contribution = verified.contribution
            case .failure(let failure):
                return .result(rejection(failure))
            }
        }
        let predecessor = await deriveAncestry(
            blockHash: blockHash,
            block: block,
            level: level
        )

        guard let contribution else {
            return .result(rejection(.proofOfWorkInvalid))
        }

        // §9.10: the weighed and eager sites below enumerate the block's child
        // commitments only where a block fact is emitted — after its work is
        // verified (reading an attacker-sized `children` index costs
        // proof-of-work) and after the duplicate and evidence short-circuits (a
        // re-delivered block costs nothing here). The validate tier orders its
        // own enumeration after its verdict funnel, in `prepareValidatedTier`.
        // Required content, like the rest of the boundary: an unavailable trie
        // must not degrade to "commits nothing", which would route parent work
        // to an older committer and let availability decide a
        // consensus-visible number; every commitments failure below is a
        // rejection, never an empty commitment set.
        //
        // Validated tier: the block was already weighed (its work is verified
        // above and durable). Execute it now and record a validity verdict,
        // bypassing the weighed/known/duplicate short-circuits that assume a
        // first-observation of the header. Isolated so the eager and weighed
        // paths are untouched.
        if case .execution = mode {
            return await prepareValidatedTier(
                resolvedHeader: resolvedHeader,
                block: block,
                blockHash: blockHash,
                fetcher: fetcher,
                contribution: contribution,
                predecessor: predecessor,
                childPackage: childPackage,
                context: context,
                level: level,
                validationContext: validationContext
            )
        }

        if let existing = await level.chain.workContribution(
            id: contribution.id,
            at: blockHash
        ), existing.work >= contribution.work {
            if knownBlock {
                // A predecessor can connect after preflight but before the
                // node takes its mutation lease: the lease rechecks ancestry.
                return .duplicate(PreparedDuplicateImportState(blockHash: blockHash))
            }
            return .result(.duplicate(
                sameChainPredecessor: predecessor
            ))
        }

        if knownBlock {
            // A second, distinct grind on a block already held is new
            // evidence, not a duplicate.
            return .ready(PreparedImport(
                resolvedHeader: resolvedHeader,
                block: block,
                fetcher: fetcher,
                contribution: contribution,
                chainPath: context.path,
                sameChainPredecessor: predecessor,
                kind: .evidence
            ))
        }

        // Weighed tier (deferred execution): the block is possessed and its
        // work is verified (root PoW or child securing proof, above), so it can
        // enter fork choice now. Skip the state transition entirely; emit a
        // block fact whose declared `postStateCID` is recorded as an unverified
        // claim (`StateDiff.empty`, no materialized state). Validity is a later,
        // separate judgment on the validated tier. The consensus graph never
        // reads `stateDiff`, so this contributes to fork choice identically to
        // the eager path.
        //
        // Weighed = possess + structurally verify. Work binds nothing to the
        // parent, so the header-linkage rules the eager path runs inside
        // `validateNexus` (version, parent, spec, prevState == parent.postState,
        // height, timestamp, target schedule) run here too, with the same
        // outcomes: a failed rule is a completed deterministic check, a
        // not-yet-admissible timestamp defers, a missing parent is unavailable
        // evidence. A child genesis is weighed with `insertGenesis`'s
        // semantics (`weighedGenesis`); a root genesis only ever arrives
        // through bootstrap.
        if case .header = mode {
            guard block.parent != nil else {
                return await weighedGenesis(
                    resolvedHeader: resolvedHeader, block: block, blockHash: blockHash,
                    fetcher: fetcher, contribution: contribution, context: context,
                    predecessor: predecessor
                )
            }
            if let failure = await validateHeaderLinkage(
                block: block,
                fetcher: fetcher,
                chain: level.chain,
                validationContext: validationContext
            ) {
                return .result(rejection(failure, sameChainPredecessor: predecessor))
            }
            let commitments: [String: String]
            switch await childCommitments(of: resolvedHeader, fetcher: fetcher) {
            case .success(let enumerated): commitments = enumerated
            case .failure(let failure):
                return .result(rejection(failure, sameChainPredecessor: predecessor))
            }
            return .ready(PreparedImport(
                resolvedHeader: resolvedHeader,
                block: block,
                fetcher: fetcher,
                contribution: contribution,
                chainPath: context.path,
                sameChainPredecessor: predecessor,
                kind: .block(StateDiff.empty, nil, validated: false),
                defersBodyStore: true,
                childCommitments: commitments
            ))
        }

        if block.parent == nil {
            guard !context.isRoot, block.height == 0 else {
                return .result(rejection(.protocolInvalid))
            }
        }

        switch await executeTransition(
            block: block,
            blockHash: blockHash,
            fetcher: fetcher,
            chain: level.chain,
            parentFacts: childPackage.map(parentFactLookup),
            context: context,
            validationContext: validationContext
        ) {
        case .failure(let failure):
            // A child genesis weighs first, as `insertGenesis` does: without
            // a verdict (a missing continuity fact, unavailable content) it is
            // admitted weighed-only, and executed later.
            if block.parent == nil, !isDeterministicInvalidity(failure) {
                return await weighedGenesis(
                    resolvedHeader: resolvedHeader, block: block, blockHash: blockHash,
                    fetcher: fetcher, contribution: contribution, context: context,
                    predecessor: predecessor
                )
            }
            return .result(rejection(failure, sameChainPredecessor: predecessor))
        case .success(let transition):
            let commitments: [String: String]
            switch await childCommitments(of: resolvedHeader, fetcher: fetcher) {
            case .success(let enumerated): commitments = enumerated
            case .failure(let failure):
                return .result(rejection(failure, sameChainPredecessor: predecessor))
            }
            return .ready(PreparedImport(
                resolvedHeader: resolvedHeader,
                block: block,
                fetcher: fetcher,
                contribution: contribution,
                chainPath: context.path,
                sameChainPredecessor: predecessor,
                kind: .block(
                    transition.stateDiff,
                    transition.materializedPostState,
                    validated: true
                ),
                childCommitments: commitments
            ))
        }
    }

    /// A child genesis weighed with `ChainTree.insertGenesis`'s semantics:
    /// its proof's work (already verified), its spec bound by CID, and the
    /// block fact with its commitments, like any block — no execution.
    private static func weighedGenesis(
        resolvedHeader: BlockHeader,
        block: Block,
        blockHash: String,
        fetcher: any Fetcher,
        contribution: VerifiedWorkContribution,
        context: ChainRuntimeContext,
        predecessor: SameChainPredecessorRequirement?
    ) async -> Preparation {
        guard !context.isRoot,
              genesisAdmissible(block, blockHash: blockHash, context: context) else {
            return .result(rejection(.protocolInvalid))
        }
        guard let spec = try? await block.spec.resolve(fetcher: fetcher).node else {
            return .result(rejection(.unavailableEvidence))
        }
        guard ChainTree.binds(spec, to: block.spec.rawCID) else {
            return .result(rejection(.providerMalformedEvidence))
        }
        let commitments: [String: String]
        switch await childCommitments(of: resolvedHeader, fetcher: fetcher) {
        case .success(let enumerated): commitments = enumerated
        case .failure(let failure): return .result(rejection(failure, sameChainPredecessor: predecessor))
        }
        return .ready(PreparedImport(
            resolvedHeader: resolvedHeader,
            block: block,
            fetcher: fetcher,
            contribution: contribution,
            chainPath: context.path,
            sameChainPredecessor: predecessor,
            kind: .block(StateDiff.empty, nil, validated: false),
            defersBodyStore: true,
            childCommitments: commitments,
            genesisSpec: spec
        ))
    }

    /// The structural admission rules every genesis path shares
    /// (`ChainTree.insertGenesis`, the actor path's `weighedGenesis`): a
    /// parentless height-0 block with a well-formed recipient and a positive
    /// `nextTarget`; on the root chain only the configured genesis; on a
    /// child chain a real parent state (§5.1 rule 4). A met target — the
    /// work each path checks — is positive too.
    static func genesisAdmissible(
        _ block: Block,
        blockHash: String,
        context: ChainRuntimeContext
    ) -> Bool {
        block.parent == nil
            && block.height == 0
            && block.nextTarget > .zero
            && block.hasWellFormedRewardRecipient
            && context.admitsGenesis(blockHash)
            && (context.isRoot || block.parentState.rawCID != LatticeState.emptyHeader.rawCID)
    }

    /// Execute a previously-weighed block and produce a validity verdict. A
    /// completed deterministic invalidity becomes an `.exclusion`; every other
    /// failure is a non-verdict retry (availability, ordering) that excludes
    /// nothing. Success upgrades the weighed claim with the materialized state.
    private static func prepareValidatedTier(
        resolvedHeader: BlockHeader,
        block: Block,
        blockHash: String,
        fetcher: any Fetcher,
        contribution: VerifiedWorkContribution,
        predecessor: SameChainPredecessorRequirement?,
        childPackage: ChildValidationPackage?,
        context: ChainRuntimeContext,
        level: ChainLevel,
        validationContext: ValidationContext
    ) async -> Preparation {
        // A root may be excluded only while this chain has ANOTHER executed
        // root to stand on (§9.9). Otherwise the verdict is parked as a
        // non-verdict: never written, so recovery cannot depend on the order
        // it replays in, and the validated tier stops here — visibly — rather
        // than leave a canonical path beneath a proven-invalid genesis.
        // Execution is never revoked: a block this chain executed is never
        // proven invalid. A verdict saying so is a local fault, never a fact.
        let alreadyExecuted = await level.chain.isExecuted(blockHash: blockHash)
        let mayExclude: Bool
        if block.parent == nil {
            mayExclude = await level.chain.hasExecutedRoot(besides: blockHash)
        } else {
            mayExclude = true
        }
        func excluded() -> Preparation {
            guard !alreadyExecuted else {
                return .result(rejection(.executedVerdictContradiction, sameChainPredecessor: predecessor))
            }
            guard mayExclude else {
                return .result(rejection(.notYetValid, sameChainPredecessor: predecessor))
            }
            return .ready(PreparedImport(
                resolvedHeader: resolvedHeader,
                block: block,
                fetcher: fetcher,
                contribution: contribution,
                chainPath: context.path,
                sameChainPredecessor: predecessor,
                kind: .exclusion
            ))
        }
        func rejected(_ failure: BlockImportError) -> Preparation {
            // A completed deterministic check is a verdict; anything else
            // (unavailable, ordering) is retryable and never excludes.
            isDeterministicInvalidity(failure)
                ? excluded()
                : .result(rejection(failure, sameChainPredecessor: predecessor))
        }

        if block.parent == nil, context.isRoot {
            // The root chain's only genesis is its pinned one, executed at
            // bootstrap: re-executing it adds nothing.
            guard context.admitsGenesis(blockHash), alreadyExecuted else {
                return .result(rejection(.protocolInvalid, sameChainPredecessor: predecessor))
            }
            return .result(.duplicate(sameChainPredecessor: predecessor))
        }
        if block.parent == nil, block.height != 0 {
            return excluded()
        }

        switch await executeTransition(
            block: block,
            blockHash: blockHash,
            fetcher: fetcher,
            chain: level.chain,
            parentFacts: childPackage.map(parentFactLookup),
            context: context,
            validationContext: validationContext
        ) {
        case .failure(let failure):
            return rejected(failure)
        case .success(let transition):
            // The reverse direction: a proven-invalid block is never executed.
            if await level.chain.isExcludedRoot(blockHash) {
                return .result(rejection(.executedVerdictContradiction, sameChainPredecessor: predecessor))
            }
            // Commitments (§9.10) only on the one outcome that emits a block
            // fact, and after every verdict above — so a malformed trie is
            // classified by the same funnel as any other deterministic
            // invalidity, and an unavailable one never blocks an exclusion.
            // A possessed block already carries its map; enumerate only for
            // a block not yet held.
            let commitments: [String: String]
            if let recorded = await level.chain.recordedChildCommitments(of: blockHash) {
                commitments = recorded
            } else {
                switch await childCommitments(of: resolvedHeader, fetcher: fetcher) {
                case .success(let enumerated): commitments = enumerated
                case .failure(let failure): return rejected(failure)
                }
            }
            return .ready(PreparedImport(
                resolvedHeader: resolvedHeader,
                block: block,
                fetcher: fetcher,
                contribution: contribution,
                chainPath: context.path,
                sameChainPredecessor: predecessor,
                kind: .block(
                    transition.stateDiff,
                    transition.materializedPostState,
                    validated: true
                ),
                childCommitments: commitments
            ))
        }
    }

    /// The one construction of an admission batch, whichever API admits the
    /// block: a block fact (with its child commitments) and its work, the
    /// validation last when the transition was executed; a work fact alone
    /// for another grind; the exclusion alone for a proven-invalid block.
    static func admissionFacts(
        blockHash: String,
        block: Block,
        contribution: VerifiedWorkContribution,
        kind: PreparedImport.Kind,
        childCommitments: [String: String]?
    ) -> BlockImportBatch {
        // An exclusion is a standalone verdict: exactly one `.exclusion` fact,
        // no block or work fact (both already durable from the weighed tier).
        if case .exclusion = kind {
            return exclusionFacts(blockHash: blockHash)
        }
        var facts: [ChainFact] = []
        switch kind {
        case .block(let stateDiff, _, _):
            facts.append(.block(ChainBlockFact(
                blockHash: blockHash,
                parentBlockHash: block.parent?.rawCID,
                blockHeight: block.height,
                postStateCID: block.postState.rawCID,
                prevStateCID: block.prevState.rawCID,
                specCID: block.spec.rawCID,
                target: block.target.toHexString(),
                nextTarget: block.nextTarget.toHexString(),
                timestamp: block.timestamp,
                stateDiff: stateDiff,
                childCommitments: childCommitments
            )))
        case .evidence, .exclusion:
            break
        }
        facts.append(.work(ChainWorkFact(
            blockHash: blockHash,
            contribution: contribution
        )))
        // Last: execution is the newest judgment in the batch, and keeping the
        // block/work prefix stable leaves existing batch-shape expectations
        // positionally intact.
        if case .block(_, _, true) = kind {
            facts.append(.validation(ChainValidationFact(
                blockHash: blockHash
            )))
        }
        return BlockImportBatch.staged(facts)
    }

    static func exclusionFacts(blockHash: String) -> BlockImportBatch {
        BlockImportBatch.staged([
            .exclusion(ChainExclusionFact(blockHash: blockHash)),
        ])
    }

    /// A root block's own grind: its proof-of-work against its own target,
    /// credited under its own CID. Nil when the hash misses the target.
    static func rootWork(
        of block: Block,
        blockHash: String
    ) -> VerifiedWorkContribution? {
        let rootHash = block.proofOfWorkHash()
        return block.validateProofOfWork(nexusHash: rootHash)
            ? VerifiedWorkContribution(
                id: blockHash,
                work: workForTarget(block.target)
            )
            : nil
    }

    /// A proven-invalid block asks the node for nothing: its predecessor must
    /// not be acquired on its behalf, or a fabricated chain would be parked and
    /// backfilled one junk block at a time. Only a non-verdict (availability,
    /// ordering) keeps the requirement so the node can retry after acquiring.
    static func predecessorRequirement(
        _ requirement: SameChainPredecessorRequirement?,
        after failure: BlockImportError
    ) -> SameChainPredecessorRequirement? {
        isDeterministicInvalidity(failure) ? nil : requirement
    }

    /// The one way a preparation is refused: every rejection carries a
    /// predecessor requirement filtered by the failure
    /// (`predecessorRequirement`), so no site can hand the node a predecessor
    /// to acquire on behalf of a proven-invalid block.
    static func rejection(
        _ failure: BlockImportError,
        sameChainPredecessor: SameChainPredecessorRequirement? = nil
    ) -> BlockImportResult {
        .rejected(
            failure,
            sameChainPredecessor: predecessorRequirement(
                sameChainPredecessor, after: failure
            )
        )
    }


    /// A failure is a validity verdict only when execution completed and the
    /// block is provably invalid. Availability, ordering, capacity and
    /// node-local failures are transient: they must be retried, never recorded
    /// as an exclusion.
    static func isDeterministicInvalidity(_ failure: BlockImportError) -> Bool {
        switch failure {
        case .protocolInvalid, .proofOfWorkInvalid:
            return true
        case .unavailableEvidence, .providerMalformedEvidence,
             .crossChainEvidenceRequired, .localVerificationFailure,
             .notYetValid, .notAcceptedAtCurrentChain, .revisionExhausted,
             .executedVerdictContradiction:
            return false
        }
    }

    /// Every child commitment this block makes, `directory → child CID`, read
    /// from its PoW-bound `children` index (§9.10). Called only after the
    /// block's work is verified and only on paths that emit a block fact, so
    /// the walk is never spent on an unauthenticated header. A failure is
    /// classified like any other boundary resolution: an unavailable node is
    /// retriable, a malformed one is a verdict (§9.9).
    static func childCommitments(
        of blockHeader: BlockHeader,
        fetcher: any Fetcher
    ) async -> Result<[String: String], BlockImportError> {
        do {
            let resolved = try await blockHeader.resolve(
                paths: [[CHILDREN_PROPERTY]: .targeted],
                fetcher: fetcher
            )
            guard let children = resolved.node?.children.node else {
                return .failure(.unavailableEvidence)
            }
            guard children.isWellFormed else {
                return .failure(.protocolInvalid)
            }
            return .success(children.entries.mapValues(\.rawCID))
        } catch {
            return .failure(classifyResolutionFailure(error))
        }
    }

    static func resolveBlock(
        _ blockHeader: BlockHeader,
        fetcher: any Fetcher
    ) async -> Result<(header: BlockHeader, block: Block), BlockImportError> {
        do {
            let resolved = try await blockHeader.resolve(fetcher: fetcher)
            guard let block = resolved.node else {
                return .failure(.unavailableEvidence)
            }
            guard let canonicalCID = try? BlockHeader(node: block).rawCID,
                  canonicalCID == resolved.rawCID else {
                return .failure(.providerMalformedEvidence)
            }
            // A malformed recipient is a property of the CID-bound content,
            // so the block is invalid before it can weigh.
            guard block.hasWellFormedRewardRecipient else {
                return .failure(.protocolInvalid)
            }
            return .success((resolved, block))
        } catch {
            return .failure(classifyResolutionFailure(error))
        }
    }

    struct ExecutedTransition: Sendable {
        let stateDiff: StateDiff
        let materializedPostState: LatticeState?
    }

    /// The one place a block's state transition is executed for admission:
    /// genesis or ordinary dispatch on `parent`, a thrown failure classified
    /// first, a false verdict as `.protocolInvalid`, and — only after the
    /// transition succeeded — the child's parent facts checked against its
    /// package. `chain` is the difficulty-anchor lookup for ordinary blocks
    /// (nil at bootstrap, where only a genesis is ever executed).
    static func executeTransition(
        block: Block,
        blockHash: String,
        fetcher: any Fetcher,
        chain: (any DifficultyAnchorSource)?,
        parentFacts: ParentFactLookup?,
        context: ChainRuntimeContext,
        validationContext: ValidationContext
    ) async -> Result<ExecutedTransition, BlockImportError> {
        let validation: (Bool, StateDiff, LatticeState?)
        do {
            if block.parent == nil {
                validation = try await block.validateGenesisTransition(
                    fetcher: fetcher,
                    chainPath: context.path,
                    reportTemporalFailure: true,
                    validationContext: validationContext
                )
            } else {
                validation = try await block.validateNexus(
                    fetcher: fetcher,
                    chain: chain,
                    chainPath: context.path,
                    reportTemporalFailure: true,
                    validationContext: validationContext
                )
            }
        } catch {
            return .failure(classifyValidationFailure(error))
        }
        guard validation.0 else { return .failure(.protocolInvalid) }
        if !context.isRoot, let parentFacts {
            var predecessorParentState: String?
            if let predecessor = block.parent {
                do {
                    guard let node = try await predecessor.resolve(fetcher: fetcher).node else {
                        return .failure(.unavailableEvidence)
                    }
                    predecessorParentState = node.parentState.rawCID
                } catch {
                    return .failure(classifyResolutionFailure(error))
                }
            }
            if let failure = await validateParentFacts(
                parentFacts,
                child: block,
                childCID: blockHash,
                predecessorParentState: predecessorParentState,
                context: context
            ) {
                return .failure(failure)
            }
        }
        return .success(ExecutedTransition(
            stateDiff: validation.1,
            materializedPostState: validation.2
        ))
    }

    /// A real grind may carry descendant work even when this block is invalid
    /// or disconnected on its own chain. Connectivity is requested separately
    /// only so this process can still try ordinary block admission.
    static func deriveAncestry(
        blockHash: String,
        block: Block,
        level: ChainLevel
    ) async -> SameChainPredecessorRequirement? {
        if await level.chain.hasConnectedAncestry(blockHash: blockHash) {
            return nil
        }
        guard let predecessorCID = block.parent?.rawCID else { return nil }
        let predecessorIsConnected = await level.chain.hasConnectedAncestry(
            blockHash: predecessorCID
        )
        guard !predecessorIsConnected else { return nil }
        return SameChainPredecessorRequirement(
            descendantCID: blockHash,
            predecessorCID: predecessorCID
        )
    }

    /// Structural verification for the weighed tier: the header-linkage rules
    /// `validateBlock` runs (through `validateNexus`) before execution, with
    /// the same failure classification, and nothing else.
    static func validateHeaderLinkage(
        block: Block,
        fetcher: any Fetcher,
        chain: ChainState,
        validationContext: ValidationContext
    ) async -> BlockImportError? {
        do {
            let linked = try await block.validateHeaderLinkage(
                fetcher: fetcher,
                chain: chain,
                reportTemporalFailure: true,
                validationContext: validationContext
            )
            return linked ? nil : .protocolInvalid
        } catch {
            return classifyValidationFailure(error)
        }
    }

    enum GenesisPreparation {
        case failed(BlockImportError)
        case ready(
            (header: BlockHeader, block: Block),
            VerifiedWorkContribution,
            ExecutedTransition
        )
    }

    /// The one genesis admission sequence every actor-path bootstrap runs:
    /// resolve, the genesis position, its work — a root genesis's own grind
    /// against the configured Nexus CID, a child genesis's `ChildBlockProof` —
    /// then execution, a child genesis's continuity included (§5.3).
    static func prepareGenesis(
        context: ChainRuntimeContext,
        genesisHeader: BlockHeader,
        fetcher: any Fetcher,
        childPackage: ChildValidationPackage?,
        validationContext: ValidationContext
    ) async -> GenesisPreparation {
        let resolved: (header: BlockHeader, block: Block)
        switch await resolveBlock(genesisHeader, fetcher: fetcher) {
        case .failure(let failure): return .failed(failure)
        case .success(let value): resolved = value
        }
        let blockHash = resolved.header.rawCID
        guard resolved.block.parent == nil, resolved.block.height == 0,
              context.admitsGenesis(blockHash) else {
            return .failed(.protocolInvalid)
        }
        let contribution: VerifiedWorkContribution?
        if context.isRoot {
            contribution = rootWork(of: resolved.block, blockHash: blockHash)
        } else {
            guard let childPackage else {
                return .failed(.crossChainEvidenceRequired(.childProof(
                    chainPath: context.path, childCID: blockHash
                )))
            }
            switch await verifyChildProof(childPackage, child: resolved.block, context: context) {
            case .success(let verified): contribution = verified.contribution
            case .failure(let failure): return .failed(failure)
            }
        }
        guard let contribution else { return .failed(.proofOfWorkInvalid) }
        switch await executeTransition(
            block: resolved.block,
            blockHash: blockHash,
            fetcher: fetcher,
            chain: nil,
            parentFacts: childPackage.map(parentFactLookup),
            context: context,
            validationContext: validationContext
        ) {
        case .failure(let failure): return .failed(failure)
        case .success(let transition): return .ready(resolved, contribution, transition)
        }
    }

    static func finishBootstrap(
        context: ChainRuntimeContext,
        resolved: (header: BlockHeader, block: Block),
        fetcher: any Fetcher,
        contribution: VerifiedWorkContribution,
        transition: ExecutedTransition,
        validationContentStorer: any VolumeStorer,
        materializedVolumeStorer: any VolumeStorer,
        stage: @Sendable (BlockImportStagingContext) async throws -> Void
    ) async throws -> (
        level: ChainLevel,
        stateDiff: StateDiff,
        materializedPostState: LatticeState?,
        commit: ChainCommit
    ) {
        let commitments = try await childCommitments(of: resolved.header, fetcher: fetcher).get()
        let prepared = PreparedImport(
            resolvedHeader: resolved.header,
            block: resolved.block,
            fetcher: fetcher,
            contribution: contribution,
            chainPath: context.path,
            sameChainPredecessor: nil,
            kind: .block(
                transition.stateDiff,
                transition.materializedPostState,
                validated: true
            ),
            childCommitments: commitments
        )
        try await prepared.cacheValidationContent(to: validationContentStorer)
        let stagingContext = prepared.stagingContext
        try await prepared.storeMaterializedPostState(
            to: materializedVolumeStorer
        )
        try await stage(stagingContext)
        let chain = try await ChainState.restore(replaying: [prepared.facts], context: context)
        return (
            ChainLevel(chain: chain, context: context),
            transition.stateDiff,
            transition.materializedPostState,
            ChainCommit(
                tipHash: resolved.header.rawCID,
                canonicalBlocksAdded: [resolved.header.rawCID: 0]
            )
        )
    }

    static func result(
        for submission: SubmissionResult,
        prepared: PreparedImport,
        sameChainPredecessor: SameChainPredecessorRequirement?
    ) -> BlockImportResult {
        guard let commit = submission.commit else {
            // Unreachable with a non-nil `submission`, and safe by construction:
            // `applyStaged` returns a non-nil `SubmissionResult` only via
            // `submitBlock` (Chain.swift:1226-1231) or `addWorkContribution`
            // (Chain.swift:1830) — both mutate the durable graph and therefore
            // run `projectCanonicalChain()` themselves, always producing a
            // non-nil commit. A no-mutation, stale-heavier outcome instead
            // returns `nil` (Chain.swift:1877/1907), which `commitPreflight`
            // handles by re-projecting at :1048. So no fork-choice re-run is
            // owed here — projection already ran on the mutation path.
            return .duplicate(sameChainPredecessor: sameChainPredecessor)
        }
        let materializedPostState: LatticeState?
        if case .block(_, let state, _) = prepared.kind {
            materializedPostState = state
        } else {
            materializedPostState = nil
        }
        return .accepted(ChainAcceptance(
            facts: prepared.facts,
            materializedPostState: materializedPostState,
            commit: commit,
            sameChainPredecessor: sameChainPredecessor
        ))
    }
}

func classifyResolutionFailure(_ error: Error) -> BlockImportError {
    if error is FetcherError { return .unavailableEvidence }
    if let dataError = error as? DataErrors { return classifyDataError(dataError) }
    if error is CashewDecodingError || error is ResolutionErrors {
        return .protocolInvalid
    }
    // An unenumerated error is not a completed deterministic check, so it must
    // NOT exclude: fail toward retry. A future error type on any fetch/IO path
    // would otherwise become a silent consensus-split vector.
    return .unavailableEvidence
}

private func mapProofFailure(
    _ failure: ChildProofVerificationFailure
) -> BlockImportError {
    switch failure {
    case .crossChainEvidenceRequired(let requirement):
        .crossChainEvidenceRequired(requirement)
    case .malformedEvidence: .providerMalformedEvidence
    case .protocolInvalid: .protocolInvalid
    }
}

func classifyValidationFailure(_ error: Error) -> BlockImportError {
    if error is BlockValidationError { return .notYetValid }
    // The difficulty anchor is not resolvable from the graph: the block parks
    // on its predecessor and is retried when that connects, never excluded.
    if error is AnchorUnavailable { return .unavailableEvidence }
    if let dataError = error as? DataErrors { return classifyDataError(dataError) }
    if error is FetcherError { return .unavailableEvidence }
    if let validationError = error as? ValidationErrors {
        switch validationError {
        case .transactionNotResolved, .prevStateNotResolved, .postStateNotResolved:
            return .unavailableEvidence
        case .serializationError:
            return .localVerificationFailure
        }
    }
    if let transformError = error as? TransformErrors {
        switch transformError {
        case .missingData:
            return .unavailableEvidence
        case .transformFailed, .invalidKey:
            return .protocolInvalid
        }
    }
    if let verdict = wasmPolicyErrorVerdict(error) {
        switch verdict {
        case .unavailable: return .unavailableEvidence
        case .invalid: return .protocolInvalid
        }
    }
    if error is StateErrors || error is ProofErrors
        || error is CashewDecodingError || error is ResolutionErrors {
        return .protocolInvalid
    }
    // Unenumerated error: not a completed deterministic check → retry, exclude
    // nothing. Enumerated deterministic producers above keep excluding.
    return .unavailableEvidence
}

/// What the outcome of a Wasm policy evaluation says about the input it was
/// evaluated on. Anything that is a function of the module and the input on
/// the pinned engine is a completed verdict; only what depends on this node
/// is not. Block import classifies through this one function and transaction
/// preflight classifies through import, so the two paths cannot drift apart:
/// a transaction preflight evicts is one import would exclude, and one import
/// retries stays pooled. The switch is exhaustive with no `default`, so a new
/// `WasmPolicyError` case fails to compile until it is given a verdict here.
/// An error that is not listed is not classified here (`nil`): the caller
/// retries it, so a failure of this node can never become a verdict.
enum WasmPolicyErrorVerdict: Sendable, Equatable {
    /// No verdict: retry, never exclude.
    case unavailable
    /// A completed, deterministic verdict on the input.
    case invalid
}

/// The engine's errors for a module it refuses to decode, validate, translate
/// or link. Each is a function of the module bytes. Most are not public, so
/// they are matched by name; the engine version is pinned exactly.
private let wasmModuleDefectErrorTypes: Set<String> = [
    "WasmParser.WasmParserError",
    "WasmParser.LEBError",
    "WasmParser.StreamError<Swift.UInt8>",
    "WasmKit.ValidationError",
    "WasmKit.TranslationError",
    "WasmKit.ImportError",
]

func wasmPolicyErrorVerdict(_ error: Error) -> WasmPolicyErrorVerdict? {
    // A trap (unreachable, an out-of-bounds access, an integer divide trap, a
    // bad indirect call, call stack exhaustion) is a function of the module
    // and the input on the pinned engine, so every node reaches it: a
    // completed verdict, never an availability gap.
    if error is Trap { return .invalid }
    if wasmModuleDefectErrorTypes.contains(String(reflecting: type(of: error))) {
        return .invalid
    }
    guard let error = error as? WasmPolicyError else { return nil }
    switch error {
    case .missingModule:
        // Missing module bytes: this node cannot reach a verdict, but the
        // policy is not proven invalid. Unavailable, never invalid.
        return .unavailable
    case .contextEncodingFailed:
        // The policy input itself cannot be encoded (a field past the length
        // prefix's range, a negative action index): a property of the input.
        return .invalid
    case .unsupportedABI, .invalidModule, .missingMemory, .missingAllocator,
         .missingEntrypoint, .invalidFunctionSignature,
         .nondeterministicConstruct:
        // A property of the chain's committed policy: its reference or its
        // module bytes. Genesis refuses these, so they are rare after it.
        return .invalid
    case .invalidAllocation, .invalidReturn:
        // What the module's allocator or entrypoint returned for this input.
        return .invalid
    }
}

private func classifyDataError(_ error: DataErrors) -> BlockImportError {
    switch error {
    case .nodeNotAvailable, .keyNotFound:
        return .unavailableEvidence
    case .cidMismatch:
        return .providerMalformedEvidence
    case .missingDeclaredChild:
        return .protocolInvalid
    case .cidCreationFailed:
        // Thrown only when a CID the content names carries no usable
        // multihash (unknown algorithm, empty digest): a property of the
        // CID string, so every node reaches the same verdict.
        return .protocolInvalid
    case .serializationFailed, .encryptionFailed, .decryptionFailed, .invalidIV:
        // This node's own encoder or cipher failed: no verdict on the block.
        return .localVerificationFailure
    }
}

public extension ChainLevel {
#if DEBUG
    /// Test seam for the availability-vs-invalidity partition that gates the
    /// validated tier's exclusion verdict.
    static func isDeterministicInvalidityForTesting(
        _ failure: BlockImportError
    ) -> Bool {
        BlockImport.isDeterministicInvalidity(failure)
    }

    /// Test seam for the fail-safe classifier catch-alls: an unrecognized error
    /// must classify as retryable, never as an excluding verdict.
    static func classifyValidationFailureForTesting(
        _ error: Error
    ) -> BlockImportError {
        classifyValidationFailure(error)
    }

    static func classifyResolutionFailureForTesting(
        _ error: Error
    ) -> BlockImportError {
        classifyResolutionFailure(error)
    }
#endif

    /// Verify one candidate and store its immutable validation Volumes without
    /// mutating the accepted graph. The returned token carries the batch the
    /// node must make durable.
    func preflightBlockImport(
        _ blockHeader: BlockHeader,
        fetcher: any Fetcher,
        childPackage: ChildValidationPackage? = nil,
        validationContext: ValidationContext = .current,
        validationContentStorer: any VolumeStorer,
        mode: ImportMode = .full
    ) async throws -> BlockImportPreflightResult {
        switch await BlockImport.prepare(
            level: self,
            blockHeader: blockHeader,
            fetcher: fetcher,
            childPackage: childPackage,
            validationContext: validationContext,
            mode: mode
        ) {
        case .result(let result):
            return .terminal(result)
        case .duplicate(let duplicate):
            return .duplicate(PreparedDuplicateImport(
                levelIdentity: importIdentity,
                state: duplicate
            ))
        case .ready(let prepared):
            try await prepared.cacheValidationContent(
                to: validationContentStorer
            )
            let stagingContext = prepared.stagingContext
            return .ready(PreparedBlockImport(
                levelIdentity: importIdentity,
                prepared: prepared,
                stagingContext: stagingContext
            ))
        }
    }

    /// Resolve an already-validated duplicate at the node's mutation boundary.
    /// Accepted ancestry only grows, so this rechecks no remote content and
    /// writes no consensus facts.
    func resolveDuplicatePreflight(
        _ preflight: PreparedDuplicateImport
    ) async throws -> BlockImportResult {
        guard let duplicate = await preflight.take(for: importIdentity) else {
            throw BlockImportPreflightError.invalidToken
        }
        let requirement = await chain.sameChainPredecessorRequirement(
            for: duplicate.blockHash
        )
        let promotedCommit = await chain.reevaluateForkChoice()
        return .duplicate(
            sameChainPredecessor: requirement,
            promotedCommit: promotedCommit
        )
    }

    /// Consume a preflight token at the node-owned durability boundary. This
    /// method performs no remote resolution: callers can take their mutation
    /// lease immediately before invoking it.
    func commitPreflight(
        _ preflight: PreparedBlockImport,
        materializedVolumeStorer: any VolumeStorer,
        stage: @Sendable (BlockImportStagingContext) async throws -> Void
    ) async throws -> BlockImportResult {
        guard let prepared = await preflight.take(for: importIdentity) else {
            throw BlockImportPreflightError.invalidToken
        }
        try await prepared.storeMaterializedPostState(
            to: materializedVolumeStorer
        )
        guard await chain.reserveImportRevision() else {
            return BlockImport.rejection(
                .revisionExhausted,
                sameChainPredecessor: prepared.sameChainPredecessor
            )
        }
        // Every refusal the reducer can make of an exclusion is made HERE,
        // under the lease and BEFORE the durable write, so a fact the reducer
        // would refuse is never written: the block must be possessed and not
        // executed (execution is never revoked), and a root exclusion may
        // stand only on another EXECUTED root (§9.9). Preflight checked these
        // outside the lease; the state could have moved since.
        if case .exclusion = prepared.kind {
            let target = prepared.resolvedHeader.rawCID
            if await chain.isExecuted(blockHash: target) {
                await chain.releaseImportRevision()
                return BlockImport.rejection(
                    .executedVerdictContradiction,
                    sameChainPredecessor: prepared.sameChainPredecessor
                )
            }
            let possessed = await chain.contains(blockHash: target)
            let standsOnAnotherRoot: Bool
            if prepared.block.parent == nil {
                standsOnAnotherRoot = await chain.hasExecutedRoot(besides: target)
            } else {
                standsOnAnotherRoot = true
            }
            guard possessed, standsOnAnotherRoot else {
                await chain.releaseImportRevision()
                return BlockImport.rejection(
                    .notYetValid,
                    sameChainPredecessor: prepared.sameChainPredecessor
                )
            }
        }
        // The reverse: a validation for a block excluded since preflight.
        if case .block(_, _, true) = prepared.kind,
           await chain.isExcludedRoot(prepared.resolvedHeader.rawCID) {
            await chain.releaseImportRevision()
            return BlockImport.rejection(
                .executedVerdictContradiction,
                sameChainPredecessor: prepared.sameChainPredecessor
            )
        }
        let stagingContext = preflight.stagingContext
        do {
            try await stage(stagingContext)
        } catch {
            await chain.releaseImportRevision()
            throw error
        }
        let submission = try await chain.applyReservedStaged(prepared.facts)
        if let spec = prepared.genesisSpec {
            await chain.holdSpec(spec, for: prepared.block.spec.rawCID)
        }
        let requirement = await chain.sameChainPredecessorRequirement(
            for: prepared.resolvedHeader.rawCID
        )
        guard let submission else {
            let promotedCommit = await chain.reevaluateForkChoice()
            return .duplicate(
                sameChainPredecessor: requirement,
                promotedCommit: promotedCommit
            )
        }
        return BlockImport.result(
            for: submission,
            prepared: prepared,
            sameChainPredecessor: requirement
        )
    }

    /// The node-owned atomic durability boundary: the staging context carries
    /// the exact batch Lattice verified for this admission.
    func importBlock(
        _ blockHeader: BlockHeader,
        fetcher: any Fetcher,
        childPackage: ChildValidationPackage? = nil,
        validationContext: ValidationContext = .current,
        validationContentStorer: any VolumeStorer,
        materializedVolumeStorer: any VolumeStorer,
        mode: ImportMode = .full,
        stage: @Sendable (BlockImportStagingContext) async throws -> Void
    ) async throws -> BlockImportResult {
        switch try await preflightBlockImport(
            blockHeader,
            fetcher: fetcher,
            childPackage: childPackage,
            validationContext: validationContext,
            validationContentStorer: validationContentStorer,
            mode: mode
        ) {
        case .terminal(let result):
            return result
        case .duplicate(let preflight):
            return try await resolveDuplicatePreflight(preflight)
        case .ready(let preflight):
            return try await commitPreflight(
                preflight,
                materializedVolumeStorer: materializedVolumeStorer,
                stage: stage
            )
        }
    }

    func importBlock(
        _ blockHeader: BlockHeader,
        source: any ContentSource,
        childPackage: ChildValidationPackage? = nil,
        validationContext: ValidationContext = .current,
        validationContentStorer: any VolumeStorer,
        materializedVolumeStorer: any VolumeStorer,
        mode: ImportMode = .full,
        stage: @Sendable (BlockImportStagingContext) async throws -> Void
    ) async throws -> BlockImportResult {
        try await importBlock(
            blockHeader,
            fetcher: CoalescingFetcher(source),
            childPackage: childPackage,
            validationContext: validationContext,
            validationContentStorer: validationContentStorer,
            materializedVolumeStorer: materializedVolumeStorer,
            mode: mode,
            stage: stage
        )
    }

    /// Root bootstrap: the configured Nexus genesis (`context.genesisCID`),
    /// weighed by its own grind and executed, staged as one batch.
    static func bootstrap(
        context: ChainRuntimeContext,
        genesisHeader: BlockHeader,
        fetcher: any Fetcher,
        validationContext: ValidationContext = .current,
        validationContentStorer: any VolumeStorer,
        materializedVolumeStorer: any VolumeStorer,
        stage: @Sendable (BlockImportStagingContext) async throws -> Void
    ) async throws -> (
        level: ChainLevel,
        stateDiff: StateDiff,
        materializedPostState: LatticeState?,
        commit: ChainCommit
    ) {
        guard context.isRoot else { throw BlockImportError.protocolInvalid }
        switch await BlockImport.prepareGenesis(
            context: context,
            genesisHeader: genesisHeader,
            fetcher: fetcher,
            childPackage: nil,
            validationContext: validationContext
        ) {
        case .failed(let failure): throw failure
        case .ready(let resolved, let contribution, let transition):
            return try await BlockImport.finishBootstrap(
                context: context,
                resolved: resolved,
                fetcher: fetcher,
                contribution: contribution,
                transition: transition,
                validationContentStorer: validationContentStorer,
                materializedVolumeStorer: materializedVolumeStorer,
                stage: stage
            )
        }
    }

    /// Child bootstrap: a child genesis weighed by its `ChildBlockProof`
    /// (`childPackage`) and executed like any child block, its continuity
    /// included, staged as one batch. No parent authorization exists.
    static func bootstrap(
        context: ChainRuntimeContext,
        genesisHeader: BlockHeader,
        fetcher: any Fetcher,
        childPackage: ChildValidationPackage,
        validationContext: ValidationContext = .current,
        validationContentStorer: any VolumeStorer,
        materializedVolumeStorer: any VolumeStorer,
        stage: @Sendable (BlockImportStagingContext) async throws -> Void
    ) async throws -> ChildChainBootstrapResult {
        guard !context.isRoot else { throw BlockImportError.protocolInvalid }
        switch await BlockImport.prepareGenesis(
            context: context,
            genesisHeader: genesisHeader,
            fetcher: fetcher,
            childPackage: childPackage,
            validationContext: validationContext
        ) {
        case .failed(let failure):
            return .rejected(failure)
        case .ready(let resolved, let contribution, let transition):
            let accepted = try await BlockImport.finishBootstrap(
                context: context,
                resolved: resolved,
                fetcher: fetcher,
                contribution: contribution,
                transition: transition,
                validationContentStorer: validationContentStorer,
                materializedVolumeStorer: materializedVolumeStorer,
                stage: stage
            )
            return .accepted(ChildChainBootstrapAcceptance(
                level: accepted.level,
                stateDiff: accepted.stateDiff,
                materializedPostState: accepted.materializedPostState,
                commit: accepted.commit
            ))
        }
    }
}
