import cashew

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

public func diffCIDs(old: any Header, new: any Header) -> StateDiff {
    if old.rawCID == new.rawCID { return .empty }

    var replaced: [String: Int] = [:]
    var created: [String: Int] = [:]

    // Children pair by property name, so a node a split or a merge moved
    // meets an unrelated node: one side loaded, the other not. What the
    // proof did not load the transform did not change, only kept or moved,
    // so it is unloaded on both sides and cancels; what is loaded on the one
    // side is all of that side's change below this place.
    guard let oldNode = old.node, let newNode = new.node else {
        return StateDiff(replaced: collectMaterialized(old), created: collectMaterialized(new))
    }
    replaced[old.rawCID, default: 0] += 1
    created[new.rawCID, default: 0] += 1

    for property in oldNode.properties() {
        guard let oldChild = oldNode.get(property: property) else { continue }
        if let newChild = newNode.get(property: property) {
            if oldChild.rawCID != newChild.rawCID {
                let sub = diffCIDs(old: oldChild, new: newChild)
                for (cid, count) in sub.replaced { replaced[cid, default: 0] += count }
                for (cid, count) in sub.created { created[cid, default: 0] += count }
            }
        } else {
            for (cid, count) in collectMaterialized(oldChild) { replaced[cid, default: 0] += count }
        }
    }

    for property in newNode.properties() {
        if oldNode.get(property: property) == nil,
           let newChild = newNode.get(property: property) {
            for (cid, count) in collectMaterialized(newChild) { created[cid, default: 0] += count }
        }
    }

    return StateDiff(replaced: replaced, created: created)
}

private func collectMaterialized(_ header: any Header) -> [String: Int] {
    guard let node = header.node else { return [:] }
    var cids: [String: Int] = [header.rawCID: 1]
    for property in node.properties() {
        if let child = node.get(property: property) {
            for (cid, count) in collectMaterialized(child) { cids[cid, default: 0] += count }
        }
    }
    return cids
}
