import LatticePoW

// Node-local finality (§9.11). A node may choose a window and decline what
// lands beyond it: a header attaching under a block, or work credited at a
// block, older than the window. Age is measured from the timestamp of the best
// weighed tip, never the node's clock, so every node holding the same graph
// draws the line in the same place. The protocol itself has no finality; a
// node that declines is choosing not to store, as it may for any input.

extension ChainTree {
    /// The oldest timestamp still inside a window of `windowMilliseconds`, or
    /// nil before the tree holds a tip.
    public func windowStart(windowMilliseconds: Int64) -> Int64? {
        guard let tip = frontier.snapshot(of: canonicalTip) else { return nil }
        let (start, overflow) = tip.timestamp.subtractingReportingOverflow(max(windowMilliseconds, 0))
        return overflow ? Int64.min : start
    }

    /// Whether a header attaching under `blockHash`, or work credited at it,
    /// lands beyond the window: the block is held and older than the window's
    /// start. The tip is never beyond, so a stalled chain can always be
    /// extended.
    public func isBeyondWindow(_ blockHash: String, windowMilliseconds: Int64) -> Bool {
        guard blockHash != canonicalTip,
              let start = windowStart(windowMilliseconds: windowMilliseconds),
              let block = frontier.snapshot(of: blockHash) else { return false }
        return block.timestamp < start
    }

    /// The work a branch attaching under `parentHash` beyond the window must
    /// prove before it could change a fork-choice decision: nil when the
    /// attachment is inside the window. Otherwise the subtree work of the
    /// canonical child at the fork point, less what the attachment's own side
    /// of that fork already weighs — what `preferred(among:)` compares there.
    /// A branch below it cannot change the canonical choice at the fork point.
    public func deepForkBar(attachingTo parentHash: String, windowMilliseconds: Int64) -> WorkSum? {
        guard graph.contains(parentHash),
              isBeyondWindow(parentHash, windowMilliseconds: windowMilliseconds) else { return nil }
        var side: String?
        var forkPoint = parentHash
        while !canonicalHashes.contains(forkPoint) {
            guard let parent = graph.parent(of: forkPoint) else {
                // A root other than the canonical one: its whole tree is the
                // side, competing at the roots.
                guard let canonicalRoot = canonicalHashByHeight[0],
                      let rival = forkChoice.weight(of: canonicalRoot) else { return nil }
                return rival.subtracting(forkChoice.weight(of: forkPoint) ?? .zero) ?? .zero
            }
            side = forkPoint
            forkPoint = parent
        }
        guard let height = graph.height(of: forkPoint),
              let canonicalChild = canonicalHashByHeight[height + 1],
              let rival = forkChoice.weight(of: canonicalChild) else { return nil }
        guard let side else { return rival }
        return rival.subtracting(forkChoice.weight(of: side) ?? .zero) ?? .zero
    }
}
