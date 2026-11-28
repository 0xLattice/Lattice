import cashew

/// How a transition changed the places each node holds in the state tree,
/// `created[cid]` places gained, `replaced[cid]` places lost. One
/// dictionary's diff (`init(cidChanges:)`) nets each CID, so one CID is on
/// one side at most. A `merge` of diffs sums them, and may hold a CID on
/// both sides. A block's diff (`LatticeState`'s transition, and what a
/// block fact keeps) is such a merge, so it is not netted: a consumer nets
/// `created - replaced` per CID, as a node storing the nodes a transition
/// created does.
public struct StateDiff: Codable, Sendable, Equatable {
    public var replaced: [String: Int]
    public var created: [String: Int]

    public static let empty = StateDiff(replaced: [:], created: [:])

    public var isEmpty: Bool { replaced.isEmpty && created.isEmpty }

    public func merging(_ other: StateDiff) -> StateDiff {
        var r = replaced
        for (cid, count) in other.replaced { r[cid, default: 0] += count }
        var c = created
        for (cid, count) in other.created { c[cid, default: 0] += count }
        return StateDiff(replaced: r, created: c)
    }

    public mutating func merge(_ other: StateDiff) {
        for (cid, count) in other.replaced { replaced[cid, default: 0] += count }
        for (cid, count) in other.created { created[cid, default: 0] += count }
    }
}

public extension StateDiff {
    /// The diff of one dictionary's update (`Header.updating`), from the CID
    /// changes it netted.
    init(cidChanges: [String: Int]) {
        var replaced: [String: Int] = [:]
        var created: [String: Int] = [:]
        for (cid, change) in cidChanges {
            if change > 0 { created[cid] = change } else if change < 0 { replaced[cid] = -change }
        }
        self.init(replaced: replaced, created: created)
    }
}
