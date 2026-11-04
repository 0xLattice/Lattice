import cashew

/// How a transition changed the places each node holds in the state tree,
/// as far as the transition loaded it: `created[cid]` places gained,
/// `replaced[cid]` places lost. `diffCIDs` nets each CID, so one CID is on
/// one side at most. A `merge` of diffs sums them, and may hold a CID on
/// both sides. A block's diff (`LatticeState`'s transition, and what a
/// block fact keeps) is such a merge, so it is not netted: a consumer nets
/// `created - replaced` per CID, as `storeMaterialized(createdBy:)` does.
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

/// The change from `old` to `new`, netted per CID. Children are paired by
/// the key they end at, not by the character they hang under: a split or
/// a merge changes a node's prefix, and then one character names different
/// keys on the two sides. A pair with one CID at one key is one place on
/// both sides, and is skipped; one CID at different keys is two places.
/// A node at a key the other side has no node at counts on its side, and
/// so does everything loaded under a pair where either side is not loaded.
/// That is exact because a transform does not change what its proof did
/// not load: such a node keeps its keys, so it stands at the same key on
/// both sides, unloaded, and cancels.
public func diffCIDs(old: any Header, new: any Header) -> StateDiff {
    var net: [String: Int] = [:]
    accumulateChange(from: old, at: "", to: new, at: "", into: &net)
    var replaced: [String: Int] = [:]
    var created: [String: Int] = [:]
    for (cid, change) in net {
        if change > 0 { created[cid] = change } else if change < 0 { replaced[cid] = -change }
    }
    return StateDiff(replaced: replaced, created: created)
}

/// `oldBase` and `newBase` are the keys above `old` and `new`, so each
/// ends at its base and its radix prefix.
private func accumulateChange(
    from old: any Header, at oldBase: String, to new: any Header, at newBase: String,
    into net: inout [String: Int]
) {
    if old.rawCID == new.rawCID && oldBase == newBase { return }
    guard let oldNode = old.node, let newNode = new.node else {
        collectMaterialized(new, adding: 1, into: &net)
        collectMaterialized(old, adding: -1, into: &net)
        return
    }
    let oldEnd = oldBase + ((oldNode as? any RadixNode)?.prefix ?? "")
    let newEnd = newBase + ((newNode as? any RadixNode)?.prefix ?? "")
    if oldEnd == newEnd {
        net[old.rawCID, default: 0] -= 1
        net[new.rawCID, default: 0] += 1
        for property in oldNode.properties().union(newNode.properties()) {
            switch (oldNode.get(property: property), newNode.get(property: property)) {
            case let (oldChild?, newChild?):
                accumulateChange(from: oldChild, at: oldEnd, to: newChild, at: newEnd, into: &net)
            case let (oldChild?, nil): collectMaterialized(oldChild, adding: -1, into: &net)
            case let (nil, newChild?): collectMaterialized(newChild, adding: 1, into: &net)
            case (nil, nil): continue
            }
        }
    } else if oldEnd.hasPrefix(newEnd) {
        // A split: the new node branches above the old one, which stands
        // under the new child toward its key.
        net[new.rawCID, default: 0] += 1
        let toward = String(oldEnd.dropFirst(newEnd.count).prefix(1))
        for property in newNode.properties() where property != toward {
            if let child = newNode.get(property: property) { collectMaterialized(child, adding: 1, into: &net) }
        }
        if let newChild = newNode.get(property: toward) {
            accumulateChange(from: old, at: oldBase, to: newChild, at: newEnd, into: &net)
        } else {
            collectMaterialized(old, adding: -1, into: &net)
        }
    } else if newEnd.hasPrefix(oldEnd) {
        // A merge: the old node branched above the new one, which stands
        // where the old child toward its key did.
        net[old.rawCID, default: 0] -= 1
        let toward = String(newEnd.dropFirst(oldEnd.count).prefix(1))
        for property in oldNode.properties() where property != toward {
            if let child = oldNode.get(property: property) { collectMaterialized(child, adding: -1, into: &net) }
        }
        if let oldChild = oldNode.get(property: toward) {
            accumulateChange(from: oldChild, at: oldEnd, to: new, at: newBase, into: &net)
        } else {
            collectMaterialized(new, adding: 1, into: &net)
        }
    } else {
        collectMaterialized(new, adding: 1, into: &net)
        collectMaterialized(old, adding: -1, into: &net)
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
