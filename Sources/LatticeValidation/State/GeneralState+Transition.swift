import cashew
import LatticePrimitives

public extension GeneralStateHeader {
    func proveAndUpdateState(allActions: [Action], fetcher: Fetcher) async throws -> (GeneralStateHeader, StateDiff) {
        if allActions.isEmpty { return (self, .empty) }

        // Each write from its action. An assert (`isAssert`) writes nothing.
        // Asserts never conflict with each other; a key written in the block
        // may not also be asserted, so every assert still holds after the
        // block (no write skew), and order is irrelevant.
        var writes: [String: KeyChange<String>] = [:]
        var asserted = Set<String>()
        for action in allActions {
            if action.isAssert { asserted.insert(action.key); continue }
            let write: KeyChange<String> = if let newValue = action.newValue {
                action.oldValue == nil ? .insert(newValue) : .update(newValue)
            } else {
                .delete
            }
            if writes.updateValue(write, forKey: action.key) != nil { throw StateErrors.conflictingActions }
        }
        if asserted.contains(where: { writes[$0] != nil }) { throw StateErrors.conflictingActions }

        // Read every key in one walk, each action's declared oldValue checked
        // against the value stored, and write the key the block writes.
        var actionsByKey: [String: [Action]] = [:]
        for action in allActions { actionsByKey[action.key, default: []].append(action) }
        let update = try await updating(keys: actionsByKey.keys, fetcher: fetcher) { key, actual in
            for action in actionsByKey[key]! {
                if action.oldValue == nil {
                    if actual != nil { throw StateErrors.conflictingActions }
                } else {
                    guard let actual else { throw StateErrors.conflictingActions }
                    // Bytes, not String ==: canonical equivalence depends on
                    // the runtime's Unicode tables, which differ across nodes.
                    guard actual.utf8.elementsEqual(action.oldValue!.utf8) else {
                        throw StateErrors.conflictingActions
                    }
                }
            }
            return writes[key] ?? .keep
        }
        return (update.header, StateDiff(cidChanges: update.cidChanges))
    }
}
