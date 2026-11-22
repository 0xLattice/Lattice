import LatticeBlockTree

// The node's avoid-and-retry descent (lattice-node `ChainSelection`), which
// Lattice no longer ships: written over public API alone, so this file
// imports nothing `@testable`. The oracle checks it against the spec's
// descent (`ReferenceSubject`'s `NodeIndex`) on every step.

extension ChainTree {
    /// The act-on descent with `avoided` blocks, and all they lead to, left
    /// out: from the parent of the root-most avoided block on the act-on
    /// chain, the heaviest executed step at each fork that is not avoided —
    /// at the genesis fork when that block is a root. The act-on tip when
    /// none of them is on its chain, or no other root is executed.
    func heaviestExecutedTip(avoiding avoided: Set<String>) -> String {
        let tip = heaviestExecutedTip()
        guard !tip.isEmpty, let floor = avoided.compactMap(height(of:)).min() else { return tip }
        var lowest: String?
        var cursor: String? = tip
        while let block = cursor, let blockHeight = height(of: block), blockHeight >= floor {
            if avoided.contains(block) { lowest = block }
            cursor = parent(of: block)
        }
        guard let lowest else { return tip }
        // Fork choice's step: the heaviest by subtree work, ties to the
        // preferred CID; an unrouted block has no weight and is never taken.
        func preferred(_ blocks: [String]) -> String? {
            blocks.compactMap { hash in forkChoiceWeight(of: hash).map { (hash: hash, work: $0) } }
                .min { $0.work != $1.work ? $0.work > $1.work : forkChoicePrefersBlock($0.hash, over: $1.hash) }?
                .hash
        }
        guard var current = parent(of: lowest) ?? preferred(genesisRoots.filter {
            hasExecutedAncestry(blockHash: $0) && !avoided.contains($0)
        }) else { return tip }
        while let next = preferred(children(of: current).filter {
            isExecuted(blockHash: $0) && !avoided.contains($0)
        }) {
            current = next
        }
        return current
    }
}
