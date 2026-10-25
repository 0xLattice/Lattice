import Foundation
import cashew
import UInt256
import LatticePrimitives

/// Compute proof-of-work for a given target threshold.
/// Higher target value = easier proof; work is inversely proportional.
///
/// Proof validity is INCLUSIVE (`hash <= target`), so `target + 1` hashes satisfy
/// it (`0...target`) and the expected number of tries to find one is
/// `2^256 / (target + 1)`. This is Bitcoin's chainwork, `(~target / (target+1)) + 1`,
/// in 256-bit arithmetic. The exclusive `2^256 / target` form over-credits by up
/// to ~2x at tiny targets (e.g. target 1 has two valid hashes but would be scored
/// ~2^256 instead of 2^255) — exploitable now that a miner may select any
/// `target <= parent.nextTarget`. For realistic (huge) targets the two agree to
/// within one unit.
public func workForTarget(_ target: UInt256) -> UInt256 {
    guard target > UInt256.zero else { return UInt256.zero }
    guard target < UInt256.max else { return UInt256(1) }
    return (UInt256.max - target) / (target + UInt256(1)) + UInt256(1)
}

/// Work demonstrated by one observed hash. This is used for the setup-wide
/// traversal floor, which is deliberately independent of any chain target.
///
/// The root-work test is inclusive (`observedHash <= threshold`), so a hash `h`
/// demonstrates the same work as a target of `h`: `2^256 / (h + 1)`, the
/// inclusive form used by `workForTarget`. The old exclusive `2^256 / h`
/// over-credited by up to ~2x at tiny hashes (hash 1 scored ~2^256 rather than
/// its true ~2^255). Saturating edges: hash 0 is the single smallest output
/// (maximal work, clamped to `.max`); hash `.max` is trivially met (one unit).
public func workForHash(_ hash: UInt256) -> UInt256 {
    guard hash > UInt256.zero else { return UInt256.max }
    guard hash < UInt256.max else { return UInt256(1) }
    return (UInt256.max - hash) / (hash + UInt256(1)) + UInt256(1)
}

/// The block the difficulty schedule is measured from: height 1 of this block's
/// OWN ancestry, carried forward so it costs nothing to reach.
///
/// Not genesis, because a genesis timestamp measures nothing — no one mined
/// before block 1 — and a chain that stamps genesis far before its first block
/// would read that gap as one enormous solve time.
///
/// Not a single chain-wide value either. Block 1 can be reorged like any other
/// block, and a chain-wide anchor would then change under every block already
/// built on it, retroactively altering targets that were already validated. An
/// anchor that belongs to the block's own ancestry cannot: two branches forking
/// at height 1 simply carry two anchors, each branch internally consistent,
/// which is exactly what such a reorg means.
public struct DifficultyAnchor: Sendable, Equatable {
    public let blockHeight: UInt64
    public let timestamp: Int64
    public let target: UInt256

    public init(blockHeight: UInt64, timestamp: Int64, target: UInt256) {
        self.blockHeight = blockHeight
        self.timestamp = timestamp
        self.target = target
    }
}

/// A consensus work fact derived by admission from authenticated proof bytes.
/// Live mutation accepts these only from package-internal verification. Public
/// recovery replay accepts the same fact only after node-owned authentication
/// and durability.
public struct VerifiedWorkContribution: Codable, Sendable, Equatable {
    public let id: String
    public let work: UInt256

    package init(id: String, work: UInt256) {
        self.id = CIDIdentity.canonicalString(id) ?? id
        self.work = work
    }

    /// A contribution rebuilt from what a tree holds: `heldID` was
    /// normalized when it was first held, so it is not normalized again.
    package init(heldID: String, work: UInt256) {
        self.id = heldID
        self.work = work
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decode(String.self, forKey: .id)
        id = CIDIdentity.canonicalString(decodedID) ?? decodedID
        work = try container.decode(UInt256.self, forKey: .work)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case work
    }
}

public extension Block {
    private static let fieldSeparator: [UInt8] = [0x00]

    /// Canonical proof-of-work preimage *prefix*: every consensus field hashed
    /// before the nonce, terminated by the field separator that precedes the
    /// nonce. This is the single source of truth for the nonce-independent bytes,
    /// so optimized miners can hash it once into a midstate and append only the
    /// nonce per attempt (see / #135, where a hand-copy drifted by
    /// omitting `version`). Any change here is consensus-breaking.
    static func makeProofOfWorkPreimagePrefix(block: Block) -> Data {
        var data = Data()
        data.reserveCapacity(512)
        data.append(contentsOf: String(block.version).utf8)
        data.append(contentsOf: Block.fieldSeparator)
        if let parentCID = block.parent?.rawCID {
            data.append(contentsOf: parentCID.utf8)
        }
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: block.transactions.rawCID.utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: block.target.toHexString().utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: block.nextTarget.toHexString().utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: block.spec.rawCID.utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: block.parentState.rawCID.utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: block.prevState.rawCID.utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: block.postState.rawCID.utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: block.children.rawCID.utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: String(block.height).utf8)
        data.append(contentsOf: Block.fieldSeparator)
        data.append(contentsOf: String(block.timestamp).utf8)
        data.append(contentsOf: Block.fieldSeparator)
        // The coinbase recipient is covered by the block CID but not by any
        // field above, so it is bound here: without it a relayer could swap
        // the recipient and keep the nonce. Presence is encoded explicitly —
        // absent is 0x00, present is 0x01 || utf8 || 0x00 — so `nil` and `""`
        // (distinct CIDs) never share a preimage and cannot double-count work.
        if let recipient = block.rewardRecipient {
            data.append(0x01)
            data.append(contentsOf: recipient.utf8)
        }
        data.append(contentsOf: Block.fieldSeparator)
        return data
    }

    /// Fixed-width (8-byte, big-endian) encoding of the PoW nonce — the single
    /// source of truth for how the nonce is appended to the preimage. Fixed width
    /// keeps the total preimage length constant across every nonce, so the SHA-256
    /// padding and block count are identical for all attempts. That is what makes
    /// the per-nonce work divergence-free on a GPU and lets miners reuse a single
    /// prefix midstate (a variable-length ASCII-decimal nonce broke both). External
    /// miners MUST encode the nonce with this exact function. Consensus-breaking.
    static func proofOfWorkNonceBytes(_ nonce: UInt64) -> [UInt8] {
        withUnsafeBytes(of: nonce.bigEndian) { Array($0) }
    }

    /// Canonical proof-of-work preimage. This is the single source of truth for the
    /// bytes hashed during mining and PoW validation; downstream nodes/miners must
    /// reuse this rather than re-deriving it (see / #135, where a hand-copy
    /// drifted by omitting `version`). Any change here is consensus-breaking.
    static func makeProofOfWorkPreimage(block: Block, nonce: UInt64) -> Data {
        var data = makeProofOfWorkPreimagePrefix(block: block)
        data.append(contentsOf: proofOfWorkNonceBytes(nonce))
        return data
    }

    func proofOfWorkHash() -> UInt256 {
        let data = Block.makeProofOfWorkPreimage(block: self, nonce: nonce)
        return UInt256.hash(data)
    }

    func validateProofOfWork(nexusHash: UInt256) -> Bool {
        // Target 0 is met by no hash — keep the predicate total so it agrees with
        // the positive-work rule (workForTarget(0) == 0, which durable replay
        // rejects). Without the `target > .zero` guard, the degenerate
        // (target 0, hash 0) case would pass here yet fail on restore.
        return target > .zero && target >= nexusHash
    }
}
