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

enum BlockImport {
    enum FactKind: Sendable {
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

    /// The one construction of an admission batch, whichever API admits the
    /// block: a block fact (with its child commitments) and its work, the
    /// validation last when the transition was executed; a work fact alone
    /// for another grind; the exclusion alone for a proven-invalid block.
    static func admissionFacts(
        blockHash: String,
        block: Block,
        contribution: VerifiedWorkContribution,
        kind: FactKind,
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
                // Absent for the empty header, so root-chain facts keep
                // their encoding.
                parentStateCID: block.parentState.rawCID == LatticeState.emptyHeader.rawCID
                    ? nil : block.parentState.rawCID,
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
/// is not. Block import classifies through this one function, transaction
/// preflight through import, and a node's template filter calls it directly
/// (it is public for that), so the paths cannot drift apart:
/// a transaction preflight evicts is one import would exclude, and one import
/// retries stays pooled. The switch is exhaustive with no `default`, so a new
/// `WasmPolicyError` case fails to compile until it is given a verdict here.
/// An error that is not listed is not classified here (`nil`): the caller
/// retries it, so a failure of this node can never become a verdict.
public enum WasmPolicyErrorVerdict: Sendable, Equatable {
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

public func wasmPolicyErrorVerdict(_ error: Error) -> WasmPolicyErrorVerdict? {
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
