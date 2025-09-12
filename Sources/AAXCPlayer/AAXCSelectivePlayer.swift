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
    private let inputFileHandle: FileHandle
    private let inputFilePath: String
    
    // Debug logging (only enabled in DEBUG builds)
    private func debugLog(_ message: String) {
        #if DEBUG
        os_log("%{public}@", log: OSLog(subsystem: "AAXCPlayer", category: "SelectivePlayer"), type: .debug, message)
        #endif
    }
    
    /// Initialize with file path for streaming (recommended for large files)
    public init(key: Data, iv: Data, inputPath: String) throws {
        guard key.count == 16 else { throw AAXCError.invalidKeySize }
        guard iv.count == 16 else { throw AAXCError.invalidIVSize }
        
        self.key = key
        self.iv = iv
        self.inputFilePath = inputPath
        
        // Open file handle for reading
        guard let handle = FileHandle(forReadingAtPath: inputPath) else {
            throw AAXCError.invalidData
        }
        self.inputFileHandle = handle
        
        // Read file data for parser (this still loads full file for parsing, but we'll optimize later)
        let inputData = try Data(contentsOf: URL(fileURLWithPath: inputPath))
        self.parser = MP4StructureParser(data: inputData)
    }
    
    /// Initialize with URL for streaming (recommended for large files)
    public init(key: Data, iv: Data, inputURL: URL) throws {
        guard key.count == 16 else { throw AAXCError.invalidKeySize }
        guard iv.count == 16 else { throw AAXCError.invalidIVSize }
        
        self.key = key
        self.iv = iv
        self.inputFilePath = inputURL.path
        
        // Open file handle for reading
        self.inputFileHandle = try FileHandle(forReadingFrom: inputURL)
        
        // Read file data for parser
        let inputData = try Data(contentsOf: inputURL)
        self.parser = MP4StructureParser(data: inputData)
    }
    
    
    
    /// Convert AAXC to M4A file using streaming
    public func convertToM4A(outputPath: String) throws {
        
        // Parse the complete MP4 structure
        let structure = try parser.parseStructure()
        debugLog("🔍 Parsed \(structure.tracks.count) tracks, mdat at offset \(structure.mdatOffset)")
        
        // Find the first audio track
        guard let audioTrack = structure.tracks.first(where: { $0.mediaType == "soun" }) else {
            throw AAXCError.noAudioTrack
        }
        debugLog("🎵 Found audio track with \(audioTrack.sampleTable.sampleSizes.count) samples")
        
        // Calculate locations of all audio samples
        let audioSamples = parser.calculateAudioSampleLocations(track: audioTrack, mdatOffset: structure.mdatOffset)
        debugLog("📍 Calculated \(audioSamples.count) audio sample locations")
        
        // Validate samples
        let fileSize = inputFileHandle.seekToEndOfFile()
        let validSamples = audioSamples.filter { $0.offset + UInt64($0.size) <= fileSize }
        if validSamples.count < audioSamples.count {
            debugLog("   ⚠️ Filtered out \(audioSamples.count - validSamples.count) invalid samples")
        }
        
        // Create streaming decrypted MP4
        try createStreamingDecryptedMP4(
            inputHandle: inputFileHandle,
            outputPath: outputPath,
            audioSamples: validSamples,
            mdatOffset: structure.mdatOffset,
            mdatSize: structure.mdatSize
        )
    }
    
    /// Parse metadata from AAXC file without decrypting audio
    public func parseMetadata() throws -> MP4StructureParser.Metadata {
        return try parser.parseMetadata()
    }
    
    // MARK: - Private Implementation
    
    
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
    
    
    /// Create decrypted MP4 using streaming approach (no double memory usage)
    private func createStreamingDecryptedMP4(inputHandle: FileHandle, outputPath: String, audioSamples: [MP4StructureParser.AudioSample], mdatOffset: UInt64, mdatSize: UInt64) throws {
        // Create output file
        FileManager.default.createFile(atPath: outputPath, contents: nil)
        guard let outputHandle = FileHandle(forWritingAtPath: outputPath) else {
            throw AAXCError.invalidData
        }
        defer { outputHandle.closeFile() }
        
        debugLog("🔧 Starting streaming conversion to: \(outputPath)")
        
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
        
        // Get file size
        let fileSize = inputHandle.seekToEndOfFile()
        
        // Process file in chunks
        let chunkSize = 1024 * 1024 // 1MB chunks for non-audio data
        var currentPosition: UInt64 = 0
        
        // Create sorted list of audio sample ranges
        let sampleRanges = audioSamples.map { (start: $0.offset, end: $0.offset + UInt64($0.size)) }.sorted { $0.start < $1.start }
        var sampleIndex = 0
        
        debugLog("🔄 Processing file with \(audioSamples.count) audio samples...")
        
        while currentPosition < fileSize {
            // Check if we're at an audio sample
            var isAudioSample = false
            var currentSample: MP4StructureParser.AudioSample?
            
            if sampleIndex < sampleRanges.count && currentPosition == sampleRanges[sampleIndex].start {
                isAudioSample = true
                currentSample = audioSamples[sampleIndex]
            }
            
            if isAudioSample, let sample = currentSample {
                // Process audio sample with decryption
                try processAudioSampleStreaming(
                    inputHandle: inputHandle,
                    outputHandle: outputHandle,
                    sample: sample,
                    cryptor: validCryptor
                )
                currentPosition = sample.offset + UInt64(sample.size)
                sampleIndex += 1
                
                if sampleIndex % 50000 == 0 || sampleIndex == audioSamples.count {
                    debugLog("   Processed \(sampleIndex)/\(audioSamples.count) audio samples")
                }
            } else {
                // Calculate next chunk size
                var nextChunkSize = chunkSize
                if sampleIndex < sampleRanges.count {
                    let bytesToNextSample = sampleRanges[sampleIndex].start - currentPosition
                    nextChunkSize = min(chunkSize, Int(bytesToNextSample))
                } else {
                    let bytesRemaining = fileSize - currentPosition
                    nextChunkSize = min(chunkSize, Int(bytesRemaining))
                }
                
                if nextChunkSize > 0 {
                    // Copy non-audio data directly
                    inputHandle.seek(toFileOffset: currentPosition)
                    if let chunk = inputHandle.readData(ofLength: nextChunkSize) as Data?, !chunk.isEmpty {
                        outputHandle.write(chunk)
                        currentPosition += UInt64(chunk.count)
                    } else {
                        break
                    }
                } else {
                    // Skip to next sample if needed
                    if sampleIndex < sampleRanges.count {
                        currentPosition = sampleRanges[sampleIndex].start
                    } else {
                        break
                    }
                }
            }
        }
        
        // Convert container metadata for M4A compatibility
        debugLog("🔄 Converting container metadata to M4A format...")
        try convertFileMetadataInPlace(at: outputPath)
        
        debugLog("✅ Streaming conversion completed successfully")
    }
    
    /// Process a single audio sample using streaming
    private func processAudioSampleStreaming(inputHandle: FileHandle, outputHandle: FileHandle, sample: MP4StructureParser.AudioSample, cryptor: CCCryptorRef) throws {
        let sampleSize = Int(sample.size)
        
        // Seek to sample position
        inputHandle.seek(toFileOffset: sample.offset)
        
        // Read encrypted sample
        guard let encryptedSample = inputHandle.readData(ofLength: sampleSize) as Data?, encryptedSample.count == sampleSize else {
            throw AAXCError.invalidSampleOffset
        }
        
        // Only decrypt complete 16-byte blocks
        let completeBlocks = sampleSize / 16
        let bytesToDecrypt = completeBlocks * 16
        let trailingBytes = sampleSize % 16
        
        if bytesToDecrypt > 0 {
            let encryptedBlocks = encryptedSample.prefix(bytesToDecrypt)
            
            // CRITICAL: Reset IV for each sample
            CCCryptorReset(cryptor, iv.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress })
            
            let decryptedBlocks = try decryptData(encryptedBlocks, using: cryptor)
            
            // Write decrypted blocks
            outputHandle.write(decryptedBlocks)
        }
        
        // Write any trailing bytes (< 16) unencrypted
        if trailingBytes > 0 {
            let trailing = encryptedSample.suffix(trailingBytes)
            outputHandle.write(trailing)
        }
    }
    
    /// Convert file type and codec metadata in-place in the output file
    private func convertFileMetadataInPlace(at path: String) throws {
        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
        defer { handle.closeFile() }
        
        // 1. Convert ftyp box (usually at the beginning)
        handle.seek(toFileOffset: 0)
        if let header = handle.readData(ofLength: 12) as Data?, header.count >= 12 {
            if header.subdata(in: 4..<8) == "ftyp".data(using: .ascii) {
                let currentBrand = header.subdata(in: 8..<12)
                if String(data: currentBrand, encoding: .ascii) == "aaxc" {
                    handle.seek(toFileOffset: 8)
                    handle.write("M4A ".data(using: .ascii)!)
                    debugLog("   ✅ Converted ftyp major brand: aaxc -> M4A")
                }
            }
        }
        
        // 2. Find and convert aavd to mp4a in the file
        let fileSize = handle.seekToEndOfFile()
        let searchChunkSize = 1024 * 1024 // 1MB search chunks
        var offset: UInt64 = 0
        var conversions = 0
        
        while offset < fileSize {
            handle.seek(toFileOffset: offset)
            let chunkSize = min(searchChunkSize, Int(fileSize - offset))
            
            if let chunk = handle.readData(ofLength: chunkSize) as Data?, !chunk.isEmpty {
                // Search for aavd in this chunk
                if let range = chunk.range(of: "aavd".data(using: .ascii)!) {
                    let globalOffset = offset + UInt64(range.lowerBound)
                    handle.seek(toFileOffset: globalOffset)
                    handle.write("mp4a".data(using: .ascii)!)
                    conversions += 1
                    debugLog("   ✅ Converted aavd -> mp4a at offset \(globalOffset)")
                }
                
                offset += UInt64(chunk.count)
            } else {
                break
            }
        }
        
        if conversions > 0 {
            debugLog("   ✅ Total codec conversions: \(conversions)")
        }
    }
    
}

// MARK: - Error Handling
// AAXCError is defined at the top of this file