import Foundation
import CommonCrypto
import AVFoundation

/// AAXC file player errors
public enum AAXCPlayerError: Error, Equatable {
    case invalidKeySize
    case invalidIVSize
    case invalidFileFormat
    case decryptionFailed
    case unsupportedFormat
}


public class AAXCPlayer {
    private let key: Data
    private let iv: Data
    
    /// Initialize with 16-byte key and IV
    /// - Parameters:
    ///   - key: 16-byte AES-128 decryption key
    ///   - iv: 16-byte initialization vector
    public init(key: Data, iv: Data) throws {
        guard key.count == 16 else {
            throw AAXCPlayerError.invalidKeySize
        }
        
        guard iv.count == 16 else {
            throw AAXCPlayerError.invalidIVSize
        }
        
        self.key = key
        self.iv = iv
    }
    
    /// Initialize with hex strings (as typically provided)
    /// - Parameters:
    ///   - keyHex: 32-character hex string for the key
    ///   - ivHex: 32-character hex string for the IV
    public convenience init(keyHex: String, ivHex: String) throws {
        guard let keyData = Data(hexString: keyHex) else {
            throw AAXCPlayerError.invalidKeySize
        }
        
        guard let ivData = Data(hexString: ivHex) else {
            throw AAXCPlayerError.invalidIVSize
        }
        
        try self.init(key: keyData, iv: ivData)
    }
    

    /// - Parameter encryptedData: The encrypted data chunk
    /// - Returns: Decrypted data
    public func decryptData(_ encryptedData: Data) throws -> Data {
        guard !encryptedData.isEmpty else {
            return Data()
        }
        
        // Only decrypt complete 16-byte blocks, leave trailing bytes as-is
        let blockSize = 16
        let completeBlocks = encryptedData.count / blockSize
        let trailingBytes = encryptedData.count % blockSize
        
        guard completeBlocks > 0 else {
            // No complete blocks to decrypt, return data as-is
            return encryptedData
        }
        
        let encryptedBlocksData = encryptedData.prefix(completeBlocks * blockSize)
        let trailingData = encryptedData.suffix(trailingBytes)
        
        // Decrypt the complete blocks using AES-128 CBC
        let decryptedBlocks = try decryptAES128CBC(data: encryptedBlocksData)
        
        // Combine decrypted blocks with unencrypted trailing bytes
        var result = Data()
        result.append(decryptedBlocks)
        result.append(trailingData)
        
        return result
    }
    
    /// Convert AAXC to M4A using selective decryption (recommended approach)
    /// - Parameter inputData: AAXC file data
    /// - Returns: Decrypted M4A file data
    public func convertToM4A(inputData: Data) throws -> Data {
        let player = try AAXCSelectivePlayer(key: key, iv: iv, inputData: inputData)
        return try player.convertToM4A()
    }
    
    /// Extract metadata from AAXC file without decrypting
    /// - Parameter inputData: AAXC file data
    /// - Returns: Metadata extracted from the file including title, artist, chapters, etc.
    /// - Throws: `MP4ParserError` if the file structure is invalid
    /// - Note: This method only reads metadata without performing any decryption
    public func extractMetadata(inputData: Data) throws -> MP4StructureParser.Metadata {
        let parser = MP4StructureParser(data: inputData)
        return try parser.parseMetadata()
    }
    
    // MARK: - Private Methods
    
    private func decryptAES128CBC(data: Data) throws -> Data {
        // raw AES CBC without padding, so we use no options
        let operation = CCOperation(kCCDecrypt)
        let algorithm = CCAlgorithm(kCCAlgorithmAES)
        let options = CCOptions(0) // No padding, raw AES
        
        // For raw AES, output size equals input size
        var decryptedData = Data(count: data.count)
        var numBytesDecrypted = 0
        
        // Make a mutable copy of IV since it gets overwritten
        var ivCopy = iv
        let decryptedDataCount = decryptedData.count
        
        let cryptStatus = data.withUnsafeBytes { dataBytes in
            key.withUnsafeBytes { keyBytes in
                ivCopy.withUnsafeMutableBytes { ivBytes in
                    decryptedData.withUnsafeMutableBytes { decryptedBytes in
                        CCCrypt(
                            operation,
                            algorithm,
                            options,
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, data.count,
                            decryptedBytes.baseAddress, decryptedDataCount,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }
        
        guard cryptStatus == kCCSuccess else {
            throw AAXCPlayerError.decryptionFailed
        }
        
        decryptedData.count = numBytesDecrypted
        return decryptedData
    }
}

// MARK: - Data Extension for Hex Conversion

public extension Data {
    init?(hexString: String) {
        let cleanHex = hexString.replacingOccurrences(of: " ", with: "")
        guard cleanHex.count % 2 == 0 else { return nil }
        
        var data = Data(capacity: cleanHex.count / 2)
        
        var index = cleanHex.startIndex
        while index < cleanHex.endIndex {
            let nextIndex = cleanHex.index(index, offsetBy: 2)
            let byteString = String(cleanHex[index..<nextIndex])
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        
        self = data
    }
    
    var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}