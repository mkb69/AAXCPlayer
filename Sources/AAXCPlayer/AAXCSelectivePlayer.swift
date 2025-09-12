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
    
    deinit {
        // Ensure OS file buffers are released when the player is deallocated
        inputFileHandle.closeFile()
    }
    
    /// Explicitly release resources early (e.g., after conversion)
    public func close() {
        inputFileHandle.closeFile()
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
        
        // Use streaming parser with file handle
        self.parser = MP4StructureParser(fileHandle: handle)
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
        
        // Use streaming parser with file handle
        self.parser = MP4StructureParser(fileHandle: inputFileHandle)
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
        
        // Create streaming decrypted MP4 without materializing all sample locations
        try createStreamingDecryptedMP4(
            inputHandle: inputFileHandle,
            outputPath: outputPath,
            track: audioTrack
        )
        // Close input handle to drop file-backed caches ASAP
        close()
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
    private func createStreamingDecryptedMP4(inputHandle: FileHandle, outputPath: String, track: MP4StructureParser.Track) throws {
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

        // Streaming traversal of samples by chunk (no big arrays)
        let totalSamples = track.sampleTable.sampleSizes.count
        var globalSampleIndex = 0

        debugLog("🔄 Processing file with \(totalSamples) audio samples (streaming)")

        for (chunkIndex, chunkOffset) in track.sampleTable.chunkOffsets.enumerated() {
            let samplesInChunk = Int(parser.getSamplesPerChunk(chunkIndex: chunkIndex, track: track))
            var offsetInChunk: UInt64 = 0

            for _ in 0..<samplesInChunk {
                guard globalSampleIndex < totalSamples else { break }
                let size = track.sampleTable.sampleSizes[globalSampleIndex]
                let sampleOffset = chunkOffset + offsetInChunk

                // Copy any non-audio bytes up to this sample
                if currentPosition < sampleOffset {
                    var remaining = sampleOffset - currentPosition
                    while remaining > 0 {
                        let toRead = Int(min(UInt64(chunkSize), remaining))
                        autoreleasepool {
                            inputHandle.seek(toFileOffset: currentPosition)
                            let data = inputHandle.readData(ofLength: toRead)
                            if !data.isEmpty { outputHandle.write(data) }
                            currentPosition += UInt64(data.count)
                            remaining -= UInt64(data.count)
                        }
                        if toRead == 0 { break }
                    }
                }

                // Decrypt this sample streaming
                let sample = MP4StructureParser.AudioSample(
                    offset: sampleOffset,
                    size: size,
                    chunkIndex: chunkIndex,
                    sampleIndex: globalSampleIndex
                )
                try processAudioSampleStreaming(
                    inputHandle: inputHandle,
                    outputHandle: outputHandle,
                    sample: sample,
                    cryptor: validCryptor
                )

                currentPosition = sampleOffset + UInt64(size)
                offsetInChunk += UInt64(size)
                globalSampleIndex += 1

                if globalSampleIndex % 50000 == 0 || globalSampleIndex == totalSamples {
                    debugLog("   Processed \(globalSampleIndex)/\(totalSamples) audio samples")
                }
            }
        }

        // Copy remaining tail after last sample
        if currentPosition < fileSize {
            var remaining = fileSize - currentPosition
            while remaining > 0 {
                let toRead = Int(min(UInt64(chunkSize), remaining))
                autoreleasepool {
                    inputHandle.seek(toFileOffset: currentPosition)
                    let data = inputHandle.readData(ofLength: toRead)
                    if !data.isEmpty { outputHandle.write(data) }
                    currentPosition += UInt64(data.count)
                    remaining -= UInt64(data.count)
                }
                if toRead == 0 { break }
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
        let blockSize = 16
        let ioBuffer = 256 * 1024 // 256KB I/O buffer per chunk
        var remaining = sampleSize

        // Seek to sample position
        inputHandle.seek(toFileOffset: sample.offset)

        // Reset IV for each sample (CBC must restart per sample)
        CCCryptorReset(cryptor, iv.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress })

        // Decrypt full 16-byte blocks using small chunks
        while remaining >= blockSize {
            autoreleasepool {
                let toRead = min(ioBuffer, remaining)
                let aligned = toRead - (toRead % blockSize)
                if aligned <= 0 { return }

                let encryptedChunk = inputHandle.readData(ofLength: aligned)
                if encryptedChunk.isEmpty { return }

                if let decrypted = try? decryptData(encryptedChunk, using: cryptor) {
                    outputHandle.write(decrypted)
                }
                remaining -= encryptedChunk.count
            }
        }

        // Write any trailing bytes (< 16) unencrypted
        if remaining > 0 {
            let trailing = inputHandle.readData(ofLength: remaining)
            if !trailing.isEmpty {
                outputHandle.write(trailing)
            }
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
