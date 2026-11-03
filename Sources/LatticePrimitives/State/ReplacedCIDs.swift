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

/// The change from `old` to `new`, netted per CID. A child with one CID
/// on both sides did not change, and is skipped; below a pair that
/// differs, every node loaded on each side counts, down to where a side
/// is not loaded. That is exact because a transform does not change what
/// its proof did not load: such a node is kept or moved, unloaded on both
/// sides, or, loaded, kept as the same loaded header (cashew's radix
/// transforms reuse the children they leave alone), so it cancels.
public func diffCIDs(old: any Header, new: any Header) -> StateDiff {
    var net: [String: Int] = [:]
    accumulateChange(from: old, to: new, into: &net)
    var replaced: [String: Int] = [:]
    var created: [String: Int] = [:]
    for (cid, change) in net {
        if change > 0 { created[cid] = change } else if change < 0 { replaced[cid] = -change }
    }
    return StateDiff(replaced: replaced, created: created)
}

private func accumulateChange(from old: any Header, to new: any Header, into net: inout [String: Int]) {
    if old.rawCID == new.rawCID { return }
    guard let oldNode = old.node, let newNode = new.node else {
        // A split or a merge moved what stands here: what is loaded on
        // either side below it is that side's whole change.
        collectMaterialized(new, adding: 1, into: &net)
        collectMaterialized(old, adding: -1, into: &net)
        return
    }
    net[old.rawCID, default: 0] -= 1
    net[new.rawCID, default: 0] += 1
    for property in oldNode.properties().union(newNode.properties()) {
        switch (oldNode.get(property: property), newNode.get(property: property)) {
        case let (oldChild?, newChild?): accumulateChange(from: oldChild, to: newChild, into: &net)
        case let (oldChild?, nil): collectMaterialized(oldChild, adding: -1, into: &net)
        case let (nil, newChild?): collectMaterialized(newChild, adding: 1, into: &net)
        case (nil, nil): continue
        }
    }
}

/// Adds `amount` for each place a loaded node holds under `header`.
private func collectMaterialized(_ header: any Header, adding amount: Int, into counts: inout [String: Int]) {
    guard let node = header.node else { return }
    counts[header.rawCID, default: 0] += amount
    for property in node.properties() {
        if let child = node.get(property: property) { collectMaterialized(child, adding: amount, into: &counts) }
    }
}
