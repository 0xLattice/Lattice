import Foundation
import UInt256
@testable import LatticePrimitives
@testable import LatticeValidation

// Mining is the node's (or a miner's): tests grind a nonce with this.
extension BlockBuilder {
    /// The first nonce from 0 whose proof-of-work hash meets `target`.
    static func mine(
        block: Block,
        target: UInt256,
        maxAttempts: UInt64 = UInt64.max
    ) -> Block? {
        for nonce in 0..<maxAttempts {
            let data = Block.makeProofOfWorkPreimage(block: block, nonce: nonce)
            let hash = UInt256.hash(data)
            if target >= hash {
                return Block(
                    version: block.version,
                    parent: block.parent,
                    transactions: block.transactions,
                    target: block.target,
                    nextTarget: block.nextTarget,
                    spec: block.spec,
                    parentState: block.parentState,
                    prevState: block.prevState,
                    postState: block.postState,
                    children: block.children,
                    height: block.height,
                    timestamp: block.timestamp,
                    rewardRecipient: block.rewardRecipient,
                    nonce: nonce
                )
            }
        }
        return nil
    }
}
