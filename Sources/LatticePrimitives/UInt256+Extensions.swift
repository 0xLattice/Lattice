import Foundation
import UInt256
import Crypto

public extension UInt256 {

    /// Converts UInt256 to hexadecimal string with "0x" prefix
    /// - Returns: A hexadecimal string representation with "0x" prefix
    func toPrefixedHexString() -> String {
        let hexString = String(self, radix: 16)
        return "0x" + hexString
    }
    
    /// Creates a UInt256 from a hexadecimal string
    /// - Parameter hexString: A hexadecimal string with or without "0x" prefix
    /// - Returns: A UInt256 value if parsing succeeds, nil otherwise
    static func fromHexString(_ hexString: String) -> UInt256? {
        let cleanHex = hexString.hasPrefix("0x") || hexString.hasPrefix("0X") 
            ? String(hexString.dropFirst(2))
            : hexString
        return fromHexDigits(cleanHex)
    }

    /// `UInt256(_:radix: 16)`, without its multiply per digit: up to 64 plain
    /// hex digits fill the four words directly, and every other spelling goes
    /// to the general parser, so the accepted set is the same.
    static func fromHexDigits(_ cleanHex: String) -> UInt256? {
        let digits = cleanHex.utf8
        guard (1...64).contains(digits.count) else { return UInt256(cleanHex, radix: 16) }
        var parts: [UInt64] = [0, 0, 0, 0]
        var position = 64 - digits.count
        for digit in digits {
            let value: UInt64
            switch digit {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): value = UInt64(digit - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): value = UInt64(digit - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): value = UInt64(digit - UInt8(ascii: "A") + 10)
            default: return UInt256(cleanHex, radix: 16)
            }
            parts[position / 16] |= value << UInt64(4 * (15 - position % 16))
            position += 1
        }
        return UInt256(parts)
    }

}

extension UInt256: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.toPrefixedHexString())
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hexString = try container.decode(String.self)
        guard let value = UInt256.fromHexString(hexString) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid UInt256 hex string: \(hexString)"
            )
        }
        self = value
    }
}

public extension UInt256 {
    /// Creates a UInt256 hash from data using SHA-256
    /// - Parameter data: The data to hash
    /// - Returns: A UInt256 representing the SHA-256 hash
    static func hash(_ data: Data) -> UInt256 {
        let sha256Hash = SHA256.hash(data: data)
        let hashData = Data(sha256Hash)
        
        // Convert 32-byte hash to UInt256 (4 UInt64 parts)
        var parts: [UInt64] = [0, 0, 0, 0]
        
        // Fill parts from hash data (big-endian)
        for i in 0..<4 {
            let startIndex = i * 8
            let endIndex = startIndex + 8 < hashData.count ? startIndex + 8 : hashData.count
            if startIndex < hashData.count {
                let slice = hashData[startIndex..<endIndex]
                var value: UInt64 = 0
                for (index, byte) in slice.enumerated() {
                    value |= UInt64(byte) << (8 * (7 - index))
                }
                parts[i] = value
            }
        }
        
        return UInt256(parts)
    }
    
    /// Creates a UInt256 hash from a string using SHA-256
    /// - Parameter string: The string to hash
    /// - Returns: A UInt256 representing the SHA-256 hash
    static func hash(_ string: String) -> UInt256 {
        guard let data = string.data(using: .utf8) else {
            return UInt256()
        }
        return hash(data)
    }
}
