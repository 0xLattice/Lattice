import Foundation
import Crypto
import cashew
import UInt256
import CollectionConcurrencyKit

let PARENT_PROPERTY = "parent"
let TRANSACTIONS_PROPERTY = "transactions"
let SPEC_PROPERTY = "spec"
let PARENT_STATE_PROPERTY = "parentState"
let PREV_STATE_PROPERTY = "prevState"
let POST_STATE_PROPERTY = "postState"
package let CHILDREN_PROPERTY = "children"
/// General-state key prefix of a transaction child commitment:
/// `child/<directory>` = the child block CID the carrying block must hold at
/// `children[<directory>]`.
public let CHILD_COMMITMENT_KEY_PREFIX = "child/"

let BLOCK_PROPERTIES = Set([
    TRANSACTIONS_PROPERTY,
    SPEC_PROPERTY,
    PARENT_STATE_PROPERTY,
    PREV_STATE_PROPERTY,
    POST_STATE_PROPERTY,
    CHILDREN_PROPERTY,
])

public struct Block: Hashable {
    public static let currentVersion: UInt16 = 1

    public let version: UInt16
    public let parent: VolumeImpl<Block>?
    public let transactions: HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>>
    public let target: UInt256
    public let nextTarget: UInt256
    public let spec: VolumeImpl<ChainSpec>
    public let parentState: LatticeStateHeader
    public let prevState: LatticeStateHeader
    public let postState: LatticeStateHeader
    /// Directory → child block, in one flat node; every key a valid child
    /// directory and every child a standard CID (`isWellFormed`).
    public let children: HeaderImpl<FlatDictionary<BlockHeader>>
    public let height: UInt64
    public let timestamp: Int64
    /// Account credited with this block's reward plus its fees (the coinbase).
    /// `nil` burns that amount. Bound into the proof-of-work preimage, so it
    /// cannot be swapped without redoing the work. Omitted from the encoding
    /// when `nil`.
    public let rewardRecipient: String?
    public let nonce: UInt64

    public init(version: UInt16 = Block.currentVersion, parent: VolumeImpl<Block>?, transactions: HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>>, target: UInt256, nextTarget: UInt256, spec: VolumeImpl<ChainSpec>, parentState: LatticeStateHeader, prevState: LatticeStateHeader, postState: LatticeStateHeader, children: HeaderImpl<FlatDictionary<BlockHeader>>, height: UInt64, timestamp: Int64, rewardRecipient: String?, nonce: UInt64) {
        self.version = version
        self.parent = parent
        self.transactions = transactions
        self.target = target
        self.nextTarget = nextTarget
        self.spec = spec
        self.parentState = parentState
        self.prevState = prevState
        self.postState = postState
        self.children = children
        self.height = height
        self.timestamp = timestamp
        self.rewardRecipient = rewardRecipient
        self.nonce = nonce
    }

    enum CodingKeys: String, CodingKey {
        case version
        case parent
        case transactions
        case target
        case nextTarget
        case spec
        case parentState
        case prevState
        case postState
        case children
        case height
        case timestamp
        case rewardRecipient
        case nonce
    }

    /// Decoding enforces well-formedness: a header any of whose links is not
    /// the standard CID (`hasStandardLinks`) is not a Lattice header, so it
    /// never becomes a `Block` — it is refused like any undecodable bytes,
    /// never weighed, never stored.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: try container.decode(UInt16.self, forKey: .version),
            parent: try container.decodeIfPresent(VolumeImpl<Block>.self, forKey: .parent),
            transactions: try container.decode(HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>>.self, forKey: .transactions),
            target: try container.decode(UInt256.self, forKey: .target),
            nextTarget: try container.decode(UInt256.self, forKey: .nextTarget),
            spec: try container.decode(VolumeImpl<ChainSpec>.self, forKey: .spec),
            parentState: try container.decode(LatticeStateHeader.self, forKey: .parentState),
            prevState: try container.decode(LatticeStateHeader.self, forKey: .prevState),
            postState: try container.decode(LatticeStateHeader.self, forKey: .postState),
            children: try container.decode(HeaderImpl<FlatDictionary<BlockHeader>>.self, forKey: .children),
            height: try container.decode(UInt64.self, forKey: .height),
            timestamp: try container.decode(Int64.self, forKey: .timestamp),
            rewardRecipient: try container.decodeIfPresent(String.self, forKey: .rewardRecipient),
            nonce: try container.decode(UInt64.self, forKey: .nonce)
        )
        guard hasStandardLinks else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "a header link is not a standard CID"
            ))
        }
    }

    /// Structural rule: every CID link in the header — parent, transactions,
    /// spec, parent/prev/post state, children — is the standard CID
    /// (`CIDIdentity.isStandard`), plain: no encryption info. Enforced by
    /// decoding (`init(from:)`); the child index's own links by
    /// `FlatDictionary.isWellFormed`.
    var hasStandardLinks: Bool {
        let links: [any cashew.Header] = [
            transactions, spec, parentState, prevState, postState, children,
        ] + (parent.map { [$0] } ?? [])
        return links.allSatisfy(isStandardLink)
    }

    public static func == (lhs: Block, rhs: Block) -> Bool {
        canonicalSerialization(lhs) == canonicalSerialization(rhs)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(UInt256.hash(Self.canonicalSerialization(self)))
    }

    private static func canonicalSerialization(_ block: Block) -> Data {
        guard let data = block.toData() else {
            preconditionFailure("Block canonical serialization failed")
        }
        return data
    }

    /// Structural rule: a present `rewardRecipient` is a canonical address.
    /// Checked where block bytes enter admission and child-proof roots, so a
    /// block with a malformed recipient never weighs.
    public var hasWellFormedRewardRecipient: Bool {
        rewardRecipient.map(CryptoUtils.isValidAddress) ?? true
    }

    public static func getTotalDeposited(_ allDepositActions: [DepositAction]) -> (total: UInt64, overflow: Bool) {
        var total: UInt64 = 0
        for action in allDepositActions {
            let (result, overflow) = total.addingReportingOverflow(action.amountDeposited)
            if overflow { return (0, true) }
            total = result
        }
        return (total, false)
    }

    public static func getTotalWithdrawn(_ allWithdrawalActions: [WithdrawalAction]) -> (total: UInt64, overflow: Bool) {
        var total: UInt64 = 0
        for action in allWithdrawalActions {
            let (result, overflow) = total.addingReportingOverflow(action.amountWithdrawn)
            if overflow { return (0, true) }
            total = result
        }
        return (total, false)
    }
}

extension Block: Node {
    public func get(property: PathSegment) -> (any cashew.Header)? {
        switch property {
            case PARENT_PROPERTY: return parent
            case TRANSACTIONS_PROPERTY: return transactions
            case SPEC_PROPERTY: return spec
            case PARENT_STATE_PROPERTY: return parentState
            case PREV_STATE_PROPERTY: return prevState
            case POST_STATE_PROPERTY: return postState
            case CHILDREN_PROPERTY: return children
            default: return nil
        }
    }

    public func properties() -> Set<PathSegment> {
        parent == nil ? BLOCK_PROPERTIES : BLOCK_PROPERTIES.union([PARENT_PROPERTY])
    }

    public func set(properties: [PathSegment : any cashew.Header]) -> Block {
        return Block(
            version: version,
            parent: properties[PARENT_PROPERTY] as? VolumeImpl<Block> ?? parent,
            transactions: properties[TRANSACTIONS_PROPERTY] as? HeaderImpl<MerkleDictionaryImpl<VolumeImpl<Transaction>>> ?? transactions,
            target: target,
            nextTarget: nextTarget,
            spec: properties[SPEC_PROPERTY] as? VolumeImpl<ChainSpec> ?? spec,
            parentState: properties[PARENT_STATE_PROPERTY] as? LatticeStateHeader ?? parentState,
            prevState: properties[PREV_STATE_PROPERTY] as? LatticeStateHeader ?? prevState,
            postState: properties[POST_STATE_PROPERTY] as? LatticeStateHeader ?? postState,
            children: properties[CHILDREN_PROPERTY] as? HeaderImpl<FlatDictionary<BlockHeader>> ?? children,
            height: height,
            timestamp: timestamp,
            rewardRecipient: rewardRecipient,
            nonce: nonce
        )
    }
}

public typealias BlockHeader = VolumeImpl<Block>

/// A header link in its one standard form: the standard CID
/// (`CIDIdentity.isStandard`) with no encryption info.
func isStandardLink(_ link: any cashew.Header) -> Bool {
    link.encryptionInfo == nil && CIDIdentity.isStandard(link.rawCID)
}

package extension FlatDictionary where Value == BlockHeader {
    /// Every child is a plain standard CID (`isStandardLink`) carried under
    /// a valid child directory. A received block whose `children` fail this
    /// is structurally invalid.
    var isWellFormed: Bool {
        entries.allSatisfy { isValidChildDirectory($0.key) && isStandardLink($0.value) }
    }
}
