import Foundation
import cashew
import DagCBORMacro

public typealias WasmPolicyModuleHeader = VolumeImpl<WasmPolicyModule>

public struct WasmPolicyModule: Scalar {
    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }
}

@DagCBORCodable
public struct WasmPolicyRef: Codable, Hashable, Sendable {
    public enum Scope: String, Codable, Hashable, Sendable, DagCBORCodable {
        case transaction
        case action
    }

    public static let currentABIVersion: UInt16 = 1

    public let moduleCID: String
    public let sourceCID: String?
    public let abiVersion: UInt16
    public let scope: Scope
    public let entrypoint: String

    enum CodingKeys: String, CodingKey {
        case moduleCID
        case sourceCID
        case abiVersion
        case scope
        case entrypoint
    }

    public init(
        moduleCID: String,
        sourceCID: String? = nil,
        abiVersion: UInt16 = WasmPolicyRef.currentABIVersion,
        scope: Scope,
        entrypoint: String? = nil
    ) {
        self.moduleCID = moduleCID
        self.sourceCID = sourceCID
        self.abiVersion = abiVersion
        self.scope = scope
        self.entrypoint = entrypoint ?? scope.defaultEntrypoint
    }
}

public extension WasmPolicyRef.Scope {
    var defaultEntrypoint: String {
        switch self {
        case .transaction: return "lattice_validate_transaction"
        case .action: return "lattice_validate_action"
        }
    }
}
