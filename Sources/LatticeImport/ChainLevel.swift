import Foundation
import UInt256
import LatticePrimitives
import LatticeBlockTree

/// Consensus runtime for exactly one chain. Other chains are evidence sources,
/// never recursively-owned runtimes.
public actor ChainLevel {
    public let chain: ChainState
    public nonisolated let context: ChainRuntimeContext
    let importIdentity = UUID()

    /// Package-only: a level made from an arbitrary chain would skip the
    /// root chain's genesis pin. Public levels come from `bootstrap` or
    /// `restore`, which enforce it.
    package init(chain: ChainState, context: ChainRuntimeContext) {
        self.chain = chain
        self.context = context
    }

    /// A level over `tree`, which it takes over: the caller hands over its
    /// one reference (`ChainTree.mutableGraph`). O(1), whatever the history.
    /// Nil for a tree made without a context. Keeps the genesis pin: a tree
    /// carrying a context took every root through the pin check when it was
    /// inserted.
    public init?(tree: ChainTree) {
        guard let context = tree.context else { return nil }
        self.init(chain: ChainState(tree: tree), context: context)
    }

    /// The level of `context` restored from its durable facts. On a root
    /// chain any root genesis but the pinned one fails the restore.
    public static func restore(
        replaying batches: [BlockImportBatch],
        revisionFloor: UInt64 = 0,
        context: ChainRuntimeContext
    ) async throws -> ChainLevel {
        ChainLevel(
            chain: try await ChainState.restore(
                replaying: batches, revisionFloor: revisionFloor, context: context
            ),
            context: context
        )
    }
}
