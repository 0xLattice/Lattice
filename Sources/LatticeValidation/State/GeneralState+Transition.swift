import cashew
import LatticePrimitives

public extension GeneralStateHeader {
    func proveAndUpdateState(allActions: [Action], fetcher: Fetcher) async throws -> (GeneralStateHeader, StateDiff) {
        if allActions.isEmpty { return (self, .empty) }

        // Determine proof types and build transforms from action semantics
        var proofs = [[String]: SparseMerkleProof]()
        var transforms = [[String]: Transform]()
        for action in allActions {
            if proofs[[action.key]] != nil { throw StateErrors.conflictingActions }
            if action.newValue == nil {
                proofs[[action.key]] = .deletion
                transforms[[action.key]] = .delete
            } else if action.oldValue == nil {
                proofs[[action.key]] = .insertion
                transforms[[action.key]] = .insert(action.newValue!)
            } else {
                proofs[[action.key]] = .mutation
                transforms[[action.key]] = .update(action.newValue!)
            }
        }

        // Resolve targeted paths to validate current values against declared oldValues
        var resolvePaths = [[String]: ResolutionStrategy]()
        for action in allActions {
            resolvePaths[[action.key]] = .targeted
        }
        let resolved = try await resolve(paths: resolvePaths, fetcher: fetcher)

        if let dictNode = resolved.node {
            for action in allActions {
                if action.oldValue == nil {
                    let existing: String? = try? dictNode.get(key: action.key)
                    if existing != nil { throw StateErrors.conflictingActions }
                } else {
                    guard let actual: String = try? dictNode.get(key: action.key) else {
                        throw StateErrors.conflictingActions
                    }
                    // Bytes, not String ==: canonical equivalence depends on
                    // the runtime's Unicode tables, which differ across nodes.
                    guard actual.utf8.elementsEqual(action.oldValue!.utf8) else {
                        throw StateErrors.conflictingActions
                    }
                }
            }
        }

        let proven = try await resolved.proof(paths: proofs, fetcher: fetcher)
        guard let result = try proven.transform(transforms: transforms) else {
            throw TransformErrors.transformFailed("general state transform returned nil")
        }
        return (result, diffCIDs(old: proven, new: result))
    }
}
