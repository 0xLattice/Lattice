import XCTest
@testable import Lattice
@testable import LatticePrimitives
@testable import LatticePoW
@testable import LatticeValidation
@testable import LatticeProofs
@testable import LatticeBlockTree
@testable import LatticeImport
import UInt256
import Foundation

final class UInt256ExtensionsTests: XCTestCase {
    
    func testToPrefixedHexString() {
        let zero = UInt256(0)
        XCTAssertEqual(zero.toPrefixedHexString(), "0x0")
        
        let value = UInt256(255)
        XCTAssertEqual(value.toPrefixedHexString(), "0xff")
        
        let largeValue = UInt256(0xDEADBEEF)
        XCTAssertEqual(largeValue.toPrefixedHexString(), "0xdeadbeef")
    }
    
    func testFromHexString() {
        // Test with 0x prefix
        XCTAssertEqual(UInt256.fromHexString("0x0"), UInt256(0))
        XCTAssertEqual(UInt256.fromHexString("0xff"), UInt256(255))
        XCTAssertEqual(UInt256.fromHexString("0xdeadbeef"), UInt256(0xDEADBEEF))
        
        // Test with 0X prefix (uppercase)
        XCTAssertEqual(UInt256.fromHexString("0XFF"), UInt256(255))
        
        // Test without prefix
        XCTAssertEqual(UInt256.fromHexString("ff"), UInt256(255))
        XCTAssertEqual(UInt256.fromHexString("deadbeef"), UInt256(0xDEADBEEF))
        
        // Test invalid inputs
        XCTAssertNil(UInt256.fromHexString(""))
        XCTAssertNil(UInt256.fromHexString("0x"))
        XCTAssertNil(UInt256.fromHexString("0xGHI"))
        XCTAssertNil(UInt256.fromHexString("xyz"))
    }
    
    func testConsistency() {
        let testValue = UInt256(0xDEADBEEF)
        let hexString = testValue.toPrefixedHexString()
        let parsedValue = UInt256.fromHexString(hexString)

        XCTAssertEqual(parsedValue, testValue)
        XCTAssertEqual(hexString, "0xdeadbeef")
    }

    /// Round-trip across a range of magnitudes incl. values above 2^64 (the
    /// coverage the deleted `UInt256.roundTripTest()` helper provided —
    /// re-pointed inline rather than dropped).
    func testRoundTripAcrossMagnitudes() {
        let values: [UInt256] = [
            UInt256(0),
            UInt256(1),
            UInt256(255),
            UInt256(0xDEADBEEF),
            UInt256(UInt64.max),
            UInt256(UInt64.max) << 8,
        ]
        for value in values {
            let parsed = UInt256.fromHexString(value.toPrefixedHexString())
            XCTAssertEqual(parsed, value, "round-trip failed for \(value.toPrefixedHexString())")
        }
    }
    
    // MARK: - Hash Tests
    
    func testHashEmptyData() {
        let emptyData = Data()
        let hash = UInt256.hash(emptyData)
        
        // SHA-256 of empty data should be: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        let expectedHex = "0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        XCTAssertEqual(hash.toPrefixedHexString(), expectedHex)
    }
    
    func testHashEmptyString() {
        let hash = UInt256.hash("")
        
        // SHA-256 of empty string should be the same as empty data
        let expectedHex = "0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        XCTAssertEqual(hash.toPrefixedHexString(), expectedHex)
    }
    
    func testHashKnownString() {
        let hash = UInt256.hash("hello")
        
        // SHA-256 of "hello" should be: 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
        let expectedHex = "0x2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        XCTAssertEqual(hash.toPrefixedHexString(), expectedHex)
    }
    
    func testHashKnownData() {
        let data = "hello".data(using: .utf8)!
        let hash = UInt256.hash(data)
        
        // Should produce the same hash as the string version
        let expectedHex = "0x2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        XCTAssertEqual(hash.toPrefixedHexString(), expectedHex)
    }
    
    func testHashConsistency() {
        let testString = "blockchain"
        let hash1 = UInt256.hash(testString)
        let hash2 = UInt256.hash(testString)
        
        // Same input should always produce the same hash
        XCTAssertEqual(hash1, hash2)
    }
    
    func testHashStringVsData() {
        let testString = "test data for hashing"
        let testData = testString.data(using: .utf8)!
        
        let hashFromString = UInt256.hash(testString)
        let hashFromData = UInt256.hash(testData)
        
        // Hashing string vs its UTF-8 data should produce identical results
        XCTAssertEqual(hashFromString, hashFromData)
    }
    
    func testHashDifferentInputs() {
        let hash1 = UInt256.hash("input1")
        let hash2 = UInt256.hash("input2")
        
        // Different inputs should produce different hashes
        XCTAssertNotEqual(hash1, hash2)
    }
    
    func testHashLargeData() {
        // Test with larger data
        let largeString = String(repeating: "a", count: 1000)
        let hash = UInt256.hash(largeString)
        
        // Should not be zero and should be consistent
        XCTAssertNotEqual(hash, UInt256(0))
        XCTAssertEqual(hash, UInt256.hash(largeString))
    }
    
    func testHashBinaryData() {
        // Test with binary data
        var binaryData = Data()
        for i in 0..<256 {
            binaryData.append(UInt8(i))
        }
        
        let hash = UInt256.hash(binaryData)
        
        // Should produce a valid hash
        XCTAssertNotEqual(hash, UInt256(0))
        XCTAssertEqual(hash, UInt256.hash(binaryData)) // Consistency check
    }

    func testHexParsingMatchesTheGeneralParserOnEverySpelling() {
        var spellings = ["", "0", "f", "F", "00ff", "+ff", "-0", "-1", "g", "0x", " 1", "1 ", "1_0",
                         String(repeating: "f", count: 64), String(repeating: "f", count: 65),
                         "0" + String(repeating: "f", count: 64), "1" + String(repeating: "0", count: 64),
                         "8" + String(repeating: "0", count: 63), "0123456789abcdefABCDEF"]
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for length in 1...64 {
            var digits = ""
            for _ in 0..<length {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                digits.append(Array("0123456789abcdefABCDEF")[Int(seed >> 33) % 22])
            }
            spellings.append(digits)
        }
        for spelling in spellings {
            XCTAssertEqual(UInt256.fromHexDigits(spelling), UInt256(spelling, radix: 16), spelling)
            XCTAssertEqual(UInt256.fromHexString(spelling), UInt256(spelling, radix: 16), spelling)
            XCTAssertEqual(UInt256.fromHexString("0x" + spelling), UInt256(spelling, radix: 16), spelling)
        }
    }

    func testAParsedTargetEncodesBackToItself() {
        let target = UInt256.fromHexString("0x1c055fffffffffffffffffffffffffffffffffffffffffffffffffffffffff")!
        XCTAssertEqual(target.toPrefixedHexString(), "0x1c055fffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
    }
}