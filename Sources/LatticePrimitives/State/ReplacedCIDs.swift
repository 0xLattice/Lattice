import cashew

/// How a transition changed the places each node holds in the state tree,
/// as far as the transition loaded it: `created[cid]` places gained,
/// `replaced[cid]` places lost. `diffCIDs` nets each CID, so one CID is on
/// one side at most. A `merge` of diffs sums them, and may hold a CID on
/// both sides: a consumer nets `created - replaced` per CID, as
/// `storeMaterialized(createdBy:)` does.
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

/// The change from `old` to `new`: every node loaded under `new`, less
/// every node loaded under `old`, netted per CID. A node the transition did
/// not load it did not change, only kept or moved, so it is unloaded on
/// both sides and drops out. Nothing pairs old and new children by place:
/// a split or a merge moves nodes, and a pairing by property name meets
/// unrelated nodes.
public func diffCIDs(old: any Header, new: any Header) -> StateDiff {
    if old.rawCID == new.rawCID { return .empty }
    var net: [String: Int] = [:]
    collectMaterialized(new, adding: 1, into: &net)
    collectMaterialized(old, adding: -1, into: &net)
    var replaced: [String: Int] = [:]
    var created: [String: Int] = [:]
    for (cid, change) in net {
        if change > 0 { created[cid] = change } else if change < 0 { replaced[cid] = -change }
    }
    return StateDiff(replaced: replaced, created: created)
}

/// Adds `amount` for each place a loaded node holds under `header`.
private func collectMaterialized(_ header: any Header, adding amount: Int, into counts: inout [String: Int]) {
    guard let node = header.node else { return }
    counts[header.rawCID, default: 0] += amount
    for property in node.properties() {
        if let child = node.get(property: property) { collectMaterialized(child, adding: amount, into: &counts) }
    }
}
