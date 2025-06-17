import Foundation
import CommonCrypto
import os.log

/// Errors that can occur during AAXC decryption and M4A reconstruction
public enum AAXCError: Error {
    case invalidKeySize
    case invalidIVSize
    case noAudioTrack
    case cryptorCreationFailed
    case decryptionFailed
    case invalidData
    case invalidSampleOffset
}

/// Selective AAXC player that only decrypts audio samples while preserving MP4 container structure
public class AAXCSelectivePlayer {
    
    private let key: Data
    private let iv: Data
    private let parser: MP4StructureParser
    
    // Debug logging (only enabled in DEBUG builds)
    private func debugLog(_ message: String) {
        #if DEBUG
        os_log("%{public}@", log: OSLog(subsystem: "AAXCPlayer", category: "SelectivePlayer"), type: .debug, message)
        #endif
    }
    
    public init(key: Data, iv: Data, inputData: Data) throws {
        guard key.count == 16 else { throw AAXCError.invalidKeySize }
        guard iv.count == 16 else { throw AAXCError.invalidIVSize }
        
        self.key = key
        self.iv = iv
        self.parser = MP4StructureParser(data: inputData)
    }
    
    /// Convert AAXC to M4A by selectively decrypting only audio samples
    public func convertToM4A() throws -> Data {
        let (data, _) = try convertToM4AWithMetadata()
        return data
    }
    
    /// Convert AAXC to M4A and extract metadata
    public func convertToM4AWithMetadata() throws -> (data: Data, metadata: MP4StructureParser.Metadata) {
        // Parse the complete MP4 structure
        let structure = try parser.parseStructure()
        debugLog("🔍 Parsed \(structure.tracks.count) tracks, mdat at offset \(structure.mdatOffset)")
        
        // Find the first audio track
        guard let audioTrack = structure.tracks.first(where: { $0.mediaType == "soun" }) else {
            throw AAXCError.noAudioTrack
        }
        debugLog("🎵 Found audio track with \(audioTrack.sampleTable.sampleSizes.count) samples")
        debugLog("   Chunks: \(audioTrack.sampleTable.chunkOffsets.count)")
        debugLog("   Sample-to-chunk entries: \(audioTrack.sampleTable.samplesPerChunk.count)")
        
        // Show first few chunk offsets
        let firstChunks = audioTrack.sampleTable.chunkOffsets.prefix(5)
        debugLog("   First chunk offsets: \(firstChunks.map(String.init).joined(separator: ", "))")
        let lastChunks = audioTrack.sampleTable.chunkOffsets.suffix(3)
        debugLog("   Last chunk offsets: \(lastChunks.map(String.init).joined(separator: ", "))")
        
        // Calculate locations of all audio samples
        let audioSamples = parser.calculateAudioSampleLocations(track: audioTrack, mdatOffset: structure.mdatOffset)
        debugLog("📍 Calculated \(audioSamples.count) audio sample locations")
        
        if let firstSample = audioSamples.first {
            debugLog("   First sample: offset=\(firstSample.offset), size=\(firstSample.size)")
        }
        if let lastSample = audioSamples.last {
            debugLog("   Last sample: offset=\(lastSample.offset), size=\(lastSample.size)")
        }
        
        // Validate samples are within file bounds
        let fileSize = UInt64(parser.data.count)
        debugLog("   File size: \(fileSize)")
        let invalidSamples = audioSamples.filter { $0.offset + UInt64($0.size) > fileSize }
        if !invalidSamples.isEmpty {
            debugLog("   ⚠️ Found \(invalidSamples.count) samples beyond file bounds")
            if let first = invalidSamples.first {
                debugLog("   First invalid: offset=\(first.offset), size=\(first.size), end=\(first.offset + UInt64(first.size))")
            }
            // Filter out invalid samples for now
            let validSamples = audioSamples.filter { $0.offset + UInt64($0.size) <= fileSize }
            debugLog("   Using \(validSamples.count) valid samples")
            
            // Extract metadata
            let metadata = try parser.parseMetadata()
            debugLog("📚 Extracted metadata - Title: \(metadata.title ?? "N/A"), Artist: \(metadata.artist ?? "N/A")")
            
            let decryptedData = try createDecryptedMP4(
                originalData: parser.data,
                audioSamples: validSamples,
                mdatOffset: structure.mdatOffset,
                mdatSize: structure.mdatSize
            )
            
            return (data: decryptedData, metadata: metadata)
        }
        
        // Extract metadata before decryption
        let metadata = try parser.parseMetadata()
        debugLog("📚 Extracted metadata - Title: \(metadata.title ?? "N/A"), Artist: \(metadata.artist ?? "N/A")")
        
        // Create output data with selectively decrypted audio
        let decryptedData = try createDecryptedMP4(
            originalData: parser.data,
            audioSamples: audioSamples,
            mdatOffset: structure.mdatOffset,
            mdatSize: structure.mdatSize
        )
        
        return (data: decryptedData, metadata: metadata)
    }
    
    // MARK: - Private Implementation
    
    private func createDecryptedMP4(originalData: Data, audioSamples: [MP4StructureParser.AudioSample], mdatOffset: UInt64, mdatSize: UInt64) throws -> Data {
        // Start with the original file data
        var outputData = originalData
        debugLog("🔧 Created output data with size: \(outputData.count) (original: \(originalData.count))")
        
        // Initialize AES decryption context
        var cryptor: CCCryptorRef?
        let status = CCCryptorCreate(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(0), // No padding - we handle block alignment manually
            key.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress },
            key.count,
            iv.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress },
            &cryptor
        )
        
        guard status == kCCSuccess, let validCryptor = cryptor else {
            throw AAXCError.cryptorCreationFailed
        }
        
        defer {
            CCCryptorRelease(validCryptor)
        }
        
        // Decrypt each audio sample in place
        debugLog("🔄 Decrypting \(audioSamples.count) audio samples...")
        for (index, sample) in audioSamples.enumerated() {
            if index % 50000 == 0 || index == audioSamples.count - 1 {
                debugLog("   Processing sample \(index)/\(audioSamples.count)")
            }
            try decryptAudioSample(
                in: &outputData,
                sample: sample,
                cryptor: validCryptor
            )
        }
        
        // Convert container metadata for M4A compatibility (surgical approach)
        debugLog("🔄 Converting container metadata to M4A format...")
        outputData = convertToM4AFormat(data: outputData)
        
        return outputData
    }
    
    private func decryptAudioSample(in data: inout Data, sample: MP4StructureParser.AudioSample, cryptor: CCCryptorRef) throws {
        let sampleOffset = Int(sample.offset)
        let sampleSize = Int(sample.size)
        
        // Extract the encrypted sample data
        guard sampleOffset + sampleSize <= data.count else {
            throw AAXCError.invalidSampleOffset
        }
        
        let encryptedSample = data.subdata(in: sampleOffset..<sampleOffset + sampleSize)
        
        // Only decrypt complete 16-byte blocks
        let completeBlocks = sampleSize / 16
        let bytesToDecrypt = completeBlocks * 16
        
        if bytesToDecrypt > 0 {
            let encryptedBlocks = encryptedSample.prefix(bytesToDecrypt)
            
            // CRITICAL: Reset IV for each sample
            CCCryptorReset(cryptor, iv.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress })
            
            let decryptedBlocks = try decryptData(encryptedBlocks, using: cryptor)
            
            // Debug first sample to see if decryption is working
            if sampleOffset == 2318198 {
                let beforeHex = encryptedBlocks.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                let afterHex = decryptedBlocks.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                debugLog("🔍 First sample before: \(beforeHex)")
                debugLog("🔍 First sample after:  \(afterHex)")
            }
            
            // Replace the encrypted blocks with decrypted data
            data.replaceSubrange(sampleOffset..<sampleOffset + bytesToDecrypt, with: decryptedBlocks)
        }
        
        // Note: Any remaining bytes (< 16) are left unencrypted
    }
    
    private func decryptData(_ encryptedData: Data, using cryptor: CCCryptorRef) throws -> Data {
        let outputLength = encryptedData.count + kCCBlockSizeAES128
        var outputData = Data(count: outputLength)
        var bytesDecrypted = 0
        
        let status = encryptedData.withUnsafeBytes { encryptedBytes in
            outputData.withUnsafeMutableBytes { outputBytes in
                CCCryptorUpdate(
                    cryptor,
                    encryptedBytes.bindMemory(to: UInt8.self).baseAddress,
                    encryptedData.count,
                    outputBytes.bindMemory(to: UInt8.self).baseAddress,
                    outputLength,
                    &bytesDecrypted
                )
            }
        }
        
        guard status == kCCSuccess else {
            throw AAXCError.decryptionFailed
        }
        
        // For block-by-block decryption without padding, bytesDecrypted should equal input size
        outputData.count = bytesDecrypted
        return outputData
    }
    
    /// Convert AAXC container to M4A format with surgical precision
    private func convertToM4AFormat(data: Data) -> Data {
        var outputData = data
        
        // 1. Convert file type box (ftyp) from aaxc to M4A 
        outputData = convertFileTypeBox(in: outputData)
        
        // 2. Convert codec from aavd to mp4a ONLY in sample description boxes (stsd)
        outputData = convertCodecInSampleDescription(in: outputData)
        
        return outputData
    }
    
    /// Convert ftyp box major brand from aaxc to M4A (surgical approach)
    private func convertFileTypeBox(in data: Data) -> Data {
        var outputData = data
        
        // Find ftyp box at the beginning of file
        if data.count >= 12 && data.subdata(in: 4..<8) == "ftyp".data(using: .ascii) {
            let majorBrandOffset = 8
            let currentBrand = data.subdata(in: majorBrandOffset..<majorBrandOffset+4)
            if String(data: currentBrand, encoding: .ascii) == "aaxc" {
                outputData.replaceSubrange(majorBrandOffset..<majorBrandOffset+4, with: "M4A ".data(using: .ascii)!)
                debugLog("   ✅ Converted ftyp major brand: aaxc -> M4A")
            }
        }
        
        return outputData
    }
    
    /// Convert codec from aavd to mp4a ONLY within sample description (stsd) boxes
    private func convertCodecInSampleDescription(in data: Data) -> Data {
        var outputData = data
        var conversions = 0
        
        // First, let's find and process all stsd boxes
        var offset = 0
        while offset < data.count - 8 {
            let sizeBytes = data.subdata(in: offset..<offset+4)
            let size = sizeBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            
            let typeBytes = data.subdata(in: offset+4..<offset+8)
            let type = String(data: typeBytes, encoding: .ascii) ?? ""
            
            if type == "stsd" && size > 8 {
                let stsdEnd = min(offset + Int(size), data.count)
                debugLog("   🔍 Found stsd box at offset \(offset), size \(size)")
                
                // Search for aavd within this stsd box
                let stsdContent = outputData.subdata(in: offset..<stsdEnd)
                if let aavdRange = stsdContent.range(of: "aavd".data(using: .ascii)!) {
                    let globalOffset = offset + aavdRange.lowerBound
                    outputData.replaceSubrange(globalOffset..<globalOffset+4, with: "mp4a".data(using: .ascii)!)
                    conversions += 1
                    debugLog("   ✅ Converted aavd -> mp4a in stsd box")
                }
            }
            
            if size <= 8 { break }
            offset += Int(size)
        }
        
        // If no stsd boxes found, do a more targeted search in the moov box
        if conversions == 0 {
            debugLog("   🔍 No stsd boxes found, searching in moov box...")
            conversions += convertCodecInMovieBox(in: &outputData)
        }
        
        if conversions > 0 {
            debugLog("   ✅ Total codec conversions: \(conversions)")
        } else {
            debugLog("   ⚠️  No aavd codec identifiers found to convert")
        }
        
        return outputData
    }
    
    /// Search for and convert aavd to mp4a within the moov box
    private func convertCodecInMovieBox(in data: inout Data) -> Int {
        var conversions = 0
        
        // Find moov box
        var offset = 0
        while offset < data.count - 8 {
            let sizeBytes = data.subdata(in: offset..<offset+4)
            let size = sizeBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            
            let typeBytes = data.subdata(in: offset+4..<offset+8)
            let type = String(data: typeBytes, encoding: .ascii) ?? ""
            
            if type == "moov" && size > 8 {
                let moovEnd = min(offset + Int(size), data.count)
                debugLog("   🔍 Found moov box at offset \(offset), searching for aavd...")
                
                // Search for all aavd occurrences within moov box
                let moovContent = data.subdata(in: offset..<moovEnd)
                let aavdPattern = "aavd".data(using: .ascii)!
                var searchStart = 0
                
                while let localRange = moovContent.range(of: aavdPattern, in: searchStart..<moovContent.count) {
                    let globalOffset = offset + localRange.lowerBound
                    data.replaceSubrange(globalOffset..<globalOffset+4, with: "mp4a".data(using: .ascii)!)
                    conversions += 1
                    searchStart = localRange.upperBound
                }
                
                if conversions > 0 {
                    debugLog("   ✅ Converted \(conversions) aavd -> mp4a in moov box")
                }
                break
            }
            
            if size <= 8 { break }
            offset += Int(size)
        }
        
        return conversions
    }
}

// MARK: - Error Handling
// AAXCError is defined at the top of this file