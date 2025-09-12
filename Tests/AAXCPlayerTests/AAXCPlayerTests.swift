import XCTest
import AVFoundation
@testable import AAXCPlayer

final class AAXCPlayerTests: XCTestCase {
    
    private var testKey: String = ""
    private var testIV: String = ""
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        
        // Load test keys from test/keys.json
        let keysPath = "test/keys.json"
        let keysURL = URL(fileURLWithPath: keysPath)
        
        guard FileManager.default.fileExists(atPath: keysPath) else {
            throw XCTSkip("Test keys file not found at \(keysPath). Please create test/keys.json with your AAXC decryption keys.")
        }
        
        let keysData = try Data(contentsOf: keysURL)
        let keysJson = try JSONSerialization.jsonObject(with: keysData) as? [String: String]
        
        guard let keysJson = keysJson,
              let key = keysJson["key"],
              let iv = keysJson["iv"] else {
            throw XCTSkip("Invalid keys.json format. Expected: {\"key\": \"32_hex_chars\", \"iv\": \"32_hex_chars\"}")
        }
        
        self.testKey = key
        self.testIV = iv
    }
    
    func testPlayerInitialization() throws {
        // Test initialization with hex strings
        let player = try AAXCPlayer(keyHex: testKey, ivHex: testIV)
        XCTAssertNotNil(player)
        
        // Test initialization with invalid key size
        XCTAssertThrowsError(try AAXCPlayer(keyHex: "invalid", ivHex: testIV)) { error in
            XCTAssertEqual(error as? AAXCPlayerError, .invalidKeySize)
        }
        
        // Test initialization with invalid IV size
        XCTAssertThrowsError(try AAXCPlayer(keyHex: testKey, ivHex: "invalid")) { error in
            XCTAssertEqual(error as? AAXCPlayerError, .invalidIVSize)
        }
    }
    
    func testSelectivePlayerInitialization() throws {
        guard let key = Data(hexString: testKey), key.count == 16,
              let iv = Data(hexString: testIV), iv.count == 16 else {
            XCTFail("Invalid test keys")
            return
        }
        
        // Create a temporary test file
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.aaxc")
        let testData = Data(count: 1024)
        try testData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        let player = try AAXCSelectivePlayer(key: key, iv: iv, inputPath: tempURL.path)
        XCTAssertNotNil(player)
        
        // Test with invalid key size
        let invalidKey = Data(count: 8)
        XCTAssertThrowsError(try AAXCSelectivePlayer(key: invalidKey, iv: iv, inputPath: tempURL.path)) { error in
            XCTAssertEqual(error as? AAXCError, .invalidKeySize)
        }
        
        // Test with invalid IV size
        let invalidIV = Data(count: 8)
        XCTAssertThrowsError(try AAXCSelectivePlayer(key: key, iv: invalidIV, inputPath: tempURL.path)) { error in
            XCTAssertEqual(error as? AAXCError, .invalidIVSize)
        }
    }
    
    func testDataDecryption() throws {
        let player = try AAXCPlayer(keyHex: testKey, ivHex: testIV)
        
        // Test with empty data
        let emptyResult = try player.decryptData(Data())
        XCTAssertTrue(emptyResult.isEmpty)
        
        // Test with small data (less than 16 bytes)
        let smallData = Data([0x01, 0x02, 0x03])
        let smallResult = try player.decryptData(smallData)
        XCTAssertEqual(smallData, smallResult) // Should be unchanged
        
        // Test with exactly 16 bytes
        let sixteenBytes = Data(repeating: 0x42, count: 16)
        let sixteenResult = try player.decryptData(sixteenBytes)
        XCTAssertEqual(sixteenResult.count, 16)
        XCTAssertNotEqual(sixteenBytes, sixteenResult) // Should be different after decryption
        
        // Test with 17 bytes (16 encrypted + 1 unencrypted)
        let seventeenBytes = Data(repeating: 0x42, count: 17)
        let seventeenResult = try player.decryptData(seventeenBytes)
        XCTAssertEqual(seventeenResult.count, 17)
        XCTAssertEqual(seventeenResult.last, 0x42) // Last byte should be unchanged
    }
    
    func testDataExtensions() {
        // Test hex string conversion
        let testHex = "deadbeef"
        let data = Data(hexString: testHex)
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.count, 4)
        XCTAssertEqual(data?.hexString, testHex)
        
        // Test invalid hex string
        let invalidData = Data(hexString: "invalid")
        XCTAssertNil(invalidData)
        
        // Test odd length hex string
        let oddData = Data(hexString: "123")
        XCTAssertNil(oddData)
        
        // Test empty hex string
        let emptyData = Data(hexString: "")
        XCTAssertNotNil(emptyData)
        XCTAssertEqual(emptyData?.count, 0)
        
        // Test hex with spaces
        let spacedData = Data(hexString: "de ad be ef")
        XCTAssertNotNil(spacedData)
        XCTAssertEqual(spacedData?.count, 4)
    }
    
    func testDecryptionConsistency() throws {
        // Test that decrypting the same data multiple times gives same result
        let player = try AAXCPlayer(keyHex: testKey, ivHex: testIV)
        let testData = Data(repeating: 0x55, count: 32)
        
        let result1 = try player.decryptData(testData)
        let result2 = try player.decryptData(testData)
        
        XCTAssertEqual(result1, result2)
    }
    
    func testMP4StructureParser() {
        // Test with minimal MP4-like data
        let testData = Data([
            // Minimal ftyp box
            0x00, 0x00, 0x00, 0x20, // size = 32
            0x66, 0x74, 0x79, 0x70, // "ftyp"
            0x61, 0x61, 0x78, 0x63, // "aaxc" major brand
            0x00, 0x00, 0x00, 0x00, // minor version
            0x61, 0x61, 0x78, 0x63, // compatible brand
            0x69, 0x73, 0x6f, 0x6d, // "isom"
            0x6d, 0x70, 0x34, 0x31, // "mp41"
            0x6d, 0x70, 0x34, 0x32, // "mp42"
        ])
        
        let parser = MP4StructureParser(data: testData)
        XCTAssertNotNil(parser)
        XCTAssertEqual(parser.data.count, testData.count)
    }
    
    func testKeyValidation() {
        // Test various key formats
        let validKey32 = "1234567890abcdef1234567890abcdef"
        let validKey = Data(hexString: validKey32)
        XCTAssertNotNil(validKey)
        XCTAssertEqual(validKey?.count, 16)
        
        let invalidKeyShort = "1234"
        let shortKey = Data(hexString: invalidKeyShort)
        XCTAssertNotNil(shortKey)
        XCTAssertNotEqual(shortKey?.count, 16)
        
        let invalidKeyLong = "1234567890abcdef1234567890abcdef12345678"
        let longKey = Data(hexString: invalidKeyLong)
        XCTAssertNotNil(longKey)
        XCTAssertNotEqual(longKey?.count, 16)
    }
    
    // Performance test for data decryption
    func testDecryptionPerformance() throws {
        let player = try AAXCPlayer(keyHex: testKey, ivHex: testIV)
        let largeData = Data(repeating: 0x42, count: 1024 * 1024) // 1MB
        
        measure {
            _ = try! player.decryptData(largeData)
        }
    }
    
    // Test block alignment handling
    func testBlockAlignment() throws {
        let player = try AAXCPlayer(keyHex: testKey, ivHex: testIV)
        
        // Test various sizes around 16-byte boundaries
        for size in [0, 1, 15, 16, 17, 31, 32, 33] {
            let testData = Data(repeating: 0x55, count: size)
            let result = try player.decryptData(testData)
            
            XCTAssertEqual(result.count, size, "Result size should match input size for \(size) bytes")
            
            // Check that trailing bytes (non-16-byte aligned) are unchanged
            let trailingBytes = size % 16
            if trailingBytes > 0 {
                let inputTrailing = testData.suffix(trailingBytes)
                let resultTrailing = result.suffix(trailingBytes)
                XCTAssertEqual(inputTrailing, resultTrailing, "Trailing bytes should be unchanged for \(size) bytes")
            }
        }
    }
}

// Note: Error enums automatically conform to Equatable for testing