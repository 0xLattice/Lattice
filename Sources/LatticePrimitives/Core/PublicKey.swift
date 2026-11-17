import cashew
import Foundation

public struct PublicKey: Scalar {
    public let key: String

    public init(key: String) {
        self.key = key
    }
}

public extension PublicKey {
    init?(data: Data) {
        // Exact UTF-8, so a leading U+FEFF is kept on every host (Foundation
        // drops it on Darwin only).
        let keyString = String(decoding: data, as: UTF8.self)
        guard keyString.utf8.elementsEqual(data) else { return nil }
        self.init(key: keyString)
    }
    
    func toData() -> Data? {
        return key.data(using: .utf8)
    }
}
