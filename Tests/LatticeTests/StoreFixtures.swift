import Foundation
@testable import LatticePrimitives
import cashew

// What a node stores for a block or a transition, as fixtures: Lattice
// stores nothing itself (lattice-node owns acquisition and persistence), so
// tests put content into their in-memory stores with these.

extension VolumeImpl where NodeType == Block {
    /// Store ONLY this block's own Volume boundary: the root node plus its
    /// in-boundary transaction trie and child index. The transaction bodies,
    /// chain spec, prev/parent/post state, parent block, child blocks, and WASM
    /// policy modules are all independent nested Volumes and are deliberately
    /// excluded — none is resolved or stored. This is the tier-2 possession a
    /// weighed (not-yet-executed) block needs: it is servable and locally present
    /// for fork choice, but its body is deferred until the block is validated.
    ///
    /// The transaction trie is resolved `.list` (structure only, leaf Volumes
    /// left unresolved) and the child index as its one node, so no
    /// transaction-body / child-block Volume is fetched, then the single block
    /// boundary Volume is stored.
    func storeBlockBoundary(fetcher: any Fetcher, storer: any VolumeStorer) async throws {
        let content = try await resolve(
            paths: [
                [TRANSACTIONS_PROPERTY, ""]: .list,
                [CHILDREN_PROPERTY]: .targeted,
            ],
            fetcher: fetcher
        )
        try await content.store(storer: storer)
    }

    /// Store the complete block Volume and exactly the nested Volumes needed to
    /// validate it. Policy modules are independent Volumes; parent blocks and
    /// post-state remain independent roots with caller-owned retention policy.
    ///
    /// The transactions are fetched under the chain's own `maxBlockSize`: once
    /// their verified unique bytes exceed it the block is invalid, so this
    /// throws `BlockContentSizeError.exceedsLimit`, requests nothing further,
    /// and stores nothing. That error is a reason to execute the block, not a
    /// verdict on it: execution applies the rule itself.
    func storeBlock(fetcher: any Fetcher, storer: any VolumeStorer) async throws {
        let (content, spec) = try await resolveBoundedContent(fetcher: fetcher)
        guard let block = content.node, block.transactions.node != nil else {
            throw DataErrors.nodeNotAvailable
        }
        let resolutionPaths = Block.validationPaths(
            transactionBodies: try Self.transactionBodies(of: content),
            rewardRecipient: block.rewardRecipient
        )
        let resolved = try await content.resolve(paths: resolutionPaths, fetcher: fetcher)
        let storagePaths: [[String]: StorageStrategy] = resolutionPaths.compactMapValues {
            switch $0 {
            case .targeted: .targeted
            case .recursive: .recursive
            case .list, .range: nil
            }
        }
        try await resolved.store(paths: storagePaths, storer: storer)
        for moduleCID in Set(spec.wasmPolicies.map(\.moduleCID)).sorted() {
            try await WasmPolicyModuleHeader(rawCID: moduleCID)
                .resolve(fetcher: fetcher)
                .store(storer: storer)
        }
        if block.height == 0 {
            try await LatticeState.emptyHeader.storeRecursively(storer: storer)
        }
    }

    /// Convenience for a combined fetcher/Volume storer.
    func storeBlock(storer: any VolumeStorer) async throws {
        guard let fetcher = storer as? any Fetcher else {
            throw DataErrors.nodeNotAvailable
        }
        try await storeBlock(fetcher: fetcher, storer: storer)
    }
}

private func collectMaterializedVolumes(
    from volume: any Volume,
    selecting cids: Set<String>,
    into volumes: inout [String: any Volume]
) {
    guard let node = volume.node else { return }
    for property in node.properties() {
        guard let child = node.get(property: property) as? any Volume,
              child.node != nil else { continue }
        if cids.contains(child.rawCID) {
            volumes[child.rawCID] = child
        }
        collectMaterializedVolumes(
            from: child,
            selecting: cids,
            into: &volumes
        )
    }
}

extension VolumeImpl where NodeType == LatticeState {
    func storeMaterialized(createdBy diff: StateDiff, storer: any VolumeStorer) async throws {
        var created = Set(diff.created.compactMap { cid, count in
            count > diff.replaced[cid, default: 0] ? cid : nil
        })
        created.remove(rawCID)

        var volumes: [String: any Volume] = [:]
        collectMaterializedVolumes(
            from: self,
            selecting: created,
            into: &volumes
        )
        guard Set(volumes.keys) == created else {
            throw DataErrors.nodeNotAvailable
        }
        try await store(storer: storer)
        for cid in volumes.keys.sorted() {
            try await volumes[cid]?.store(storer: storer)
        }
    }
}
