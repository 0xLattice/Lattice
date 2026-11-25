import cashew
import Foundation

public struct Action: Codable, Sendable {
    public let key: String
    public let oldValue: String?
    public let newValue: String?

    public init(key: String, oldValue: String?, newValue: String?) {
        self.key = key
        self.oldValue = oldValue
        self.newValue = newValue
    }
    
    public func stateDelta() -> Int {
        let keyCount = key.utf8.count
        if oldValue == nil {
            return newValue!.utf8.count + keyCount
        }
        if newValue == nil {
            return 0 - oldValue!.utf8.count - keyCount
        }
        return newValue!.utf8.count - oldValue!.utf8.count
    }

    /// An assert names a value the key holds and keeps it: oldValue and
    /// newValue are the same bytes. It checks the key and writes nothing.
    /// Bytes, not String ==: canonical equivalence depends on the runtime's
    /// Unicode tables, which differ across nodes.
    public var isAssert: Bool {
        guard let oldValue, let newValue else { return false }
        return oldValue.utf8.elementsEqual(newValue.utf8)
    }

}
