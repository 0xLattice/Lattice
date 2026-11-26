import cashew
import DagCBORMacro
import Foundation

let ACCOUNT_STATE_PROPERTY = "accountState"
let GENERAL_STATE_PROPERTY = "generalState"
let DEPOSIT_STATE_PROPERTY = "depositState"
let RECEIPT_STATE_PROPERTY = "receiptState"

let LATTICE_STATE_PROPERTIES: Set<String> = Set([
    ACCOUNT_STATE_PROPERTY,
    GENERAL_STATE_PROPERTY,
    DEPOSIT_STATE_PROPERTY,
    RECEIPT_STATE_PROPERTY
])

@DagCBORCodable
public struct LatticeState: Node {
    public let accountState: AccountStateHeader
    public let generalState: GeneralStateHeader
    public let depositState: DepositStateHeader
    public let receiptState: ReceiptStateHeader

    package init(
        accountState: AccountStateHeader,
        generalState: GeneralStateHeader,
        depositState: DepositStateHeader,
        receiptState: ReceiptStateHeader
    ) {
        self.accountState = accountState
        self.generalState = generalState
        self.depositState = depositState
        self.receiptState = receiptState
    }

    static let empty = Self(
        // known-valid local node; CID computation cannot fail (no Float/Double fields)
        accountState: try! AccountStateHeader(node: AccountState()),
        // known-valid local node; CID computation cannot fail (no Float/Double fields)
        generalState: try! GeneralStateHeader(node: GeneralState()),
        // known-valid local node; CID computation cannot fail (no Float/Double fields)
        depositState: try! DepositStateHeader(node: DepositState()),
        // known-valid local node; CID computation cannot fail (no Float/Double fields)
        receiptState: try! ReceiptStateHeader(node: ReceiptState())
    )
    // known-valid local node; CID computation cannot fail (no Float/Double fields)
    public static let emptyHeader = try! LatticeStateHeader(node: empty)

    package static func emptyState() -> Self { empty }

    public func get(property: PathSegment) -> (any cashew.Header)? {
        switch property {
            case ACCOUNT_STATE_PROPERTY: return accountState
            case GENERAL_STATE_PROPERTY: return generalState
            case DEPOSIT_STATE_PROPERTY: return depositState
            case RECEIPT_STATE_PROPERTY: return receiptState
            default: return nil
        }
    }

    public func properties() -> Set<PathSegment> {
        return LATTICE_STATE_PROPERTIES
    }

    public func set(properties: [PathSegment : any cashew.Header]) -> LatticeState {
        return Self(
            accountState: properties[ACCOUNT_STATE_PROPERTY] as? AccountStateHeader ?? accountState,
            generalState: properties[GENERAL_STATE_PROPERTY] as? GeneralStateHeader ?? generalState,
            depositState: properties[DEPOSIT_STATE_PROPERTY] as? DepositStateHeader ?? depositState,
            receiptState: properties[RECEIPT_STATE_PROPERTY] as? ReceiptStateHeader ?? receiptState
        )
    }
}

public typealias LatticeStateHeader = VolumeImpl<LatticeState>
