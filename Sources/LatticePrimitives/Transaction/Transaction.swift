import cashew
import Foundation

let TRANSACTION_BODY_PROPERTY = "body"
let TRANSACTION_PROPERTIES = Set([TRANSACTION_BODY_PROPERTY])

struct SignatureEntry: Codable {
    let key: String
    let value: String
}

public struct Transaction {
    public let signatures: [String: String]
    public let body: HeaderImpl<TransactionBody>

    public init(signatures: [String: String], body: HeaderImpl<TransactionBody>) {
        self.signatures = Self.normalized(signatures) ?? signatures
        self.body = body
    }

    enum CodingKeys: String, CodingKey {
        case signatures, body
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let sortedSigs = signatures.sorted { $0.key < $1.key }
            .map { SignatureEntry(key: $0.key, value: $0.value) }
        try container.encode(sortedSigs, forKey: .signatures)
        try container.encode(body, forKey: .body)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decode([SignatureEntry].self, forKey: .signatures)
        var decodedSignatures: [String: String] = [:]
        for entry in entries {
            let key = Self.normalizedPublicKey(entry.key)
            let value = Data(hex: entry.value)?.hexString ?? entry.value
            if decodedSignatures[key] != nil {
                throw DecodingError.dataCorruptedError(
                    forKey: .signatures,
                    in: container,
                    debugDescription: "duplicate signature key"
                )
            }
            decodedSignatures[key] = value
        }
        signatures = decodedSignatures
        body = try container.decode(HeaderImpl<TransactionBody>.self, forKey: .body)
    }

    private static func normalizedPublicKey(_ value: String) -> String {
        CryptoUtils.multikey(fromHex: value)?.hex ?? value
    }

    package static func normalized(
        _ signatures: [String: String]
    ) -> [String: String]? {
        var result: [String: String] = [:]
        for (rawKey, rawSignature) in signatures {
            let key = normalizedPublicKey(rawKey)
            guard result[key] == nil else { return nil }
            result[key] = Data(hex: rawSignature)?.hexString ?? rawSignature
        }
        return result
    }

}

extension Transaction: Node {
    public func get(property: PathSegment) -> (any cashew.Header)? {
        if property == TRANSACTION_BODY_PROPERTY { return body }
        return nil
    }

    public func properties() -> Set<PathSegment> {
        return TRANSACTION_PROPERTIES
    }

    public func set(properties: [PathSegment : any cashew.Header]) -> Transaction {
        return Self(signatures: signatures, body: properties[TRANSACTION_BODY_PROPERTY] as? HeaderImpl<TransactionBody> ?? body)
    }
}
