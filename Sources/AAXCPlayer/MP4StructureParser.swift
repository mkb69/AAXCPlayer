import Foundation
import os.log

/// Complete MP4 structure parser for AAXC files
/// This handles the full MP4 atom hierarchy needed for selective decryption
public class MP4StructureParser {
    
    // Debug logging (only enabled in DEBUG builds)
    private func debugLog(_ message: String) {
        #if DEBUG
        os_log("%{public}@", log: OSLog(subsystem: "AAXCPlayer", category: "MP4Parser"), type: .debug, message)
        #endif
    }
    
    /// Represents a complete MP4 track with all necessary information for decryption
    public struct Track {
        let trackId: UInt32
        let mediaType: String // "soun" for audio
        let codec: String // codec identifier
        let sampleTable: SampleTable
        let duration: UInt64
        let timescale: UInt32
    }
    
    /// Sample table information extracted from stbl atom
    public struct SampleTable {
        let sampleSizes: [UInt32] // from stsz
        let chunkOffsets: [UInt64] // from stco/co64
        let samplesPerChunk: [SampleToChunk] // from stsc
        let timeToSample: [TimeToSample] // from stts
    }
    
    public struct SampleToChunk {
        let firstChunk: UInt32
        let samplesPerChunk: UInt32
        let sampleDescriptionIndex: UInt32
    }
    
    public struct TimeToSample {
        let sampleCount: UInt32
        let sampleDuration: UInt32
    }
    
    /// Audio sample location within mdat
    public struct AudioSample {
        let offset: UInt64 // absolute offset in file
        let size: UInt32   // size in bytes
        let chunkIndex: Int
        let sampleIndex: Int
    }
    
    public let data: Data
    private var position: Int = 0
    
    public init(data: Data) {
        self.data = data
    }
    
    /// Parse the complete MP4 structure and extract track information
    public func parseStructure() throws -> (tracks: [Track], mdatOffset: UInt64, mdatSize: UInt64) {
        position = 0
        var tracks: [Track] = []
        var mdatOffset: UInt64 = 0
        var mdatSize: UInt64 = 0
        
        // Parse top-level atoms
        while position < data.count {
            guard let atom = try parseAtom() else { break }
            
            switch atom.type {
            case "ftyp":
                try validateAAXCBrand(atom)
            case "moov":
                tracks = try parseMovieAtom(atom)
            case "mdat":
                mdatOffset = atom.dataOffset
                mdatSize = atom.dataSize
            default:
                break
            }
            
            position = Int(atom.dataOffset + atom.dataSize)
        }
        
        return (tracks: tracks, mdatOffset: mdatOffset, mdatSize: mdatSize)
    }
    
    /// Calculate audio sample locations using track information
    public func calculateAudioSampleLocations(track: Track, mdatOffset: UInt64) -> [AudioSample] {
        var samples: [AudioSample] = []
        var sampleIndex = 0
        
        // Process each chunk
        for (chunkIndex, chunkOffset) in track.sampleTable.chunkOffsets.enumerated() {
            let samplesInThisChunk = getSamplesPerChunk(chunkIndex: chunkIndex, track: track)
            var offsetInChunk: UInt64 = 0
            
            // Process each sample in the chunk
            for _ in 0..<samplesInThisChunk {
                guard sampleIndex < track.sampleTable.sampleSizes.count else { break }
                
                let sampleSize = track.sampleTable.sampleSizes[sampleIndex]
                // Note: chunkOffset is already absolute file offset, not relative to mdat
                let absoluteOffset = chunkOffset + offsetInChunk
                
                samples.append(AudioSample(
                    offset: absoluteOffset,
                    size: sampleSize,
                    chunkIndex: chunkIndex,
                    sampleIndex: sampleIndex
                ))
                
                offsetInChunk += UInt64(sampleSize)
                sampleIndex += 1
            }
        }
        
        return samples
    }
    
    // MARK: - Private Implementation
    
    private struct Atom {
        let size: UInt64
        let type: String
        let headerSize: Int
        let dataOffset: UInt64
        let dataSize: UInt64
        let extendedSize: Bool
        
        var totalSize: UInt64 { return UInt64(headerSize) + dataSize }
    }
    
    private func parseAtom() throws -> Atom? {
        guard position + 8 <= data.count else { return nil }
        
        // Read size (4 bytes)
        let sizeData = data.subdata(in: position..<position+4)
        let size = sizeData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        // Read type (4 bytes)
        let typeData = data.subdata(in: position+4..<position+8)
        let type = String(data: typeData, encoding: .ascii) ?? "unknown"
        
        var headerSize = 8
        var actualSize = UInt64(size)
        var extendedSize = false
        
        // Handle 64-bit size
        if size == 1 {
            guard position + 16 <= data.count else { throw MP4ParserError.invalidAtomSize }
            let extSizeData = data.subdata(in: position+8..<position+16)
            actualSize = extSizeData.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
            headerSize = 16
            extendedSize = true
        } else if size == 0 {
            actualSize = UInt64(data.count - position)
        }
        
        let dataOffset = UInt64(position + headerSize)
        let dataSize = actualSize - UInt64(headerSize)
        
        guard dataOffset + dataSize <= data.count else {
            throw MP4ParserError.invalidAtomSize
        }
        
        return Atom(
            size: actualSize,
            type: type,
            headerSize: headerSize,
            dataOffset: dataOffset,
            dataSize: dataSize,
            extendedSize: extendedSize
        )
    }
    
    private func validateAAXCBrand(_ atom: Atom) throws {
        let brandData = data.subdata(in: Int(atom.dataOffset)..<Int(atom.dataOffset)+4)
        let brand = String(data: brandData, encoding: .ascii) ?? ""
        guard brand == "aaxc" else {
            throw MP4ParserError.notAAXCFile
        }
    }
    
    private func parseMovieAtom(_ moovAtom: Atom) throws -> [Track] {
        let savedPosition = position
        defer { position = savedPosition }
        
        position = Int(moovAtom.dataOffset)
        let endPosition = Int(moovAtom.dataOffset + moovAtom.dataSize)
        var tracks: [Track] = []
        
        while position < endPosition {
            guard let atom = try parseAtom() else { break }
            
            if atom.type == "trak" {
                if let track = try parseTrackAtom(atom) {
                    tracks.append(track)
                }
            }
            
            position = Int(atom.dataOffset + atom.dataSize)
        }
        
        return tracks
    }
    
    private func parseTrackAtom(_ trakAtom: Atom) throws -> Track? {
        let savedPosition = position
        defer { position = savedPosition }
        
        position = Int(trakAtom.dataOffset)
        let endPosition = Int(trakAtom.dataOffset + trakAtom.dataSize)
        
        var trackId: UInt32 = 0
        var mediaType: String = ""
        var codec: String = ""
        var sampleTable: SampleTable?
        var duration: UInt64 = 0
        var timescale: UInt32 = 0
        
        while position < endPosition {
            guard let atom = try parseAtom() else { break }
            
            switch atom.type {
            case "tkhd":
                trackId = try parseTrackHeader(atom)
            case "mdia":
                let mediaInfo = try parseMediaAtom(atom)
                mediaType = mediaInfo.mediaType
                codec = mediaInfo.codec
                sampleTable = mediaInfo.sampleTable
                duration = mediaInfo.duration
                timescale = mediaInfo.timescale
            default:
                break
            }
            
            position = Int(atom.dataOffset + atom.dataSize)
        }
        
        guard let validSampleTable = sampleTable else {
            return nil // Need valid sample table
        }
        
        // Accept both audio and other media types for analysis
        if mediaType != "soun" {
            debugLog("   Found non-audio track: mediaType=\(mediaType), codec=\(codec)")
        }
        
        return Track(
            trackId: trackId,
            mediaType: mediaType,
            codec: codec,
            sampleTable: validSampleTable,
            duration: duration,
            timescale: timescale
        )
    }
    
    private func parseTrackHeader(_ tkhdAtom: Atom) throws -> UInt32 {
        let headerData = data.subdata(in: Int(tkhdAtom.dataOffset)..<Int(tkhdAtom.dataOffset)+32)
        
        // Read version/flags (4 bytes)
        let version = headerData[0]
        
        if version == 1 {
            // 64-bit version - track ID at offset 20
            guard headerData.count >= 24 else { throw MP4ParserError.invalidAtomSize }
            return headerData.subdata(in: 20..<24).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        } else {
            // 32-bit version - track ID at offset 12
            guard headerData.count >= 16 else { throw MP4ParserError.invalidAtomSize }
            return headerData.subdata(in: 12..<16).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        }
    }
    
    private func parseMediaAtom(_ mdiaAtom: Atom) throws -> (mediaType: String, codec: String, sampleTable: SampleTable?, duration: UInt64, timescale: UInt32) {
        let savedPosition = position
        defer { position = savedPosition }
        
        position = Int(mdiaAtom.dataOffset)
        let endPosition = Int(mdiaAtom.dataOffset + mdiaAtom.dataSize)
        
        var mediaType: String = ""
        var codec: String = ""
        var sampleTable: SampleTable?
        var duration: UInt64 = 0
        var timescale: UInt32 = 0
        
        while position < endPosition {
            guard let atom = try parseAtom() else { break }
            
            switch atom.type {
            case "mdhd":
                let mediaInfo = try parseMediaHeader(atom)
                duration = mediaInfo.duration
                timescale = mediaInfo.timescale
            case "hdlr":
                mediaType = try parseHandlerReference(atom)
            case "minf":
                let minfInfo = try parseMediaInformation(atom)
                codec = minfInfo.codec
                sampleTable = minfInfo.sampleTable
            default:
                break
            }
            
            position = Int(atom.dataOffset + atom.dataSize)
        }
        
        return (mediaType: mediaType, codec: codec, sampleTable: sampleTable, duration: duration, timescale: timescale)
    }
    
    private func parseMediaHeader(_ mdhdAtom: Atom) throws -> (duration: UInt64, timescale: UInt32) {
        let headerData = data.subdata(in: Int(mdhdAtom.dataOffset)..<Int(mdhdAtom.dataOffset)+32)
        let version = headerData[0]
        
        if version == 1 {
            // 64-bit version
            guard headerData.count >= 32 else { throw MP4ParserError.invalidAtomSize }
            let timescale = headerData.subdata(in: 20..<24).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let duration = headerData.subdata(in: 24..<32).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
            return (duration: duration, timescale: timescale)
        } else {
            // 32-bit version  
            guard headerData.count >= 24 else { throw MP4ParserError.invalidAtomSize }
            let timescale = headerData.subdata(in: 12..<16).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let duration = UInt64(headerData.subdata(in: 16..<20).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            return (duration: duration, timescale: timescale)
        }
    }
    
    private func parseHandlerReference(_ hdlrAtom: Atom) throws -> String {
        guard hdlrAtom.dataSize >= 24 else { throw MP4ParserError.invalidAtomSize }
        let handlerData = data.subdata(in: Int(hdlrAtom.dataOffset)+8..<Int(hdlrAtom.dataOffset)+12)
        return String(data: handlerData, encoding: .ascii) ?? ""
    }
    
    private func parseMediaInformation(_ minfAtom: Atom) throws -> (codec: String, sampleTable: SampleTable?) {
        let savedPosition = position
        defer { position = savedPosition }
        
        position = Int(minfAtom.dataOffset)
        let endPosition = Int(minfAtom.dataOffset + minfAtom.dataSize)
        
        var codec: String = ""
        var sampleTable: SampleTable?
        
        while position < endPosition {
            guard let atom = try parseAtom() else { break }
            
            switch atom.type {
            case "stbl":
                let stblInfo = try parseSampleTable(atom)
                codec = stblInfo.codec
                sampleTable = stblInfo.sampleTable
            default:
                break
            }
            
            position = Int(atom.dataOffset + atom.dataSize)
        }
        
        return (codec: codec, sampleTable: sampleTable)
    }
    
    private func parseSampleTable(_ stblAtom: Atom) throws -> (codec: String, sampleTable: SampleTable) {
        let savedPosition = position
        defer { position = savedPosition }
        
        position = Int(stblAtom.dataOffset)
        let endPosition = Int(stblAtom.dataOffset + stblAtom.dataSize)
        
        var codec: String = ""
        var sampleSizes: [UInt32] = []
        var chunkOffsets: [UInt64] = []
        var samplesPerChunk: [SampleToChunk] = []
        var timeToSample: [TimeToSample] = []
        
        while position < endPosition {
            guard let atom = try parseAtom() else { break }
            
            switch atom.type {
            case "stsd":
                codec = try parseSampleDescription(atom)
            case "stsz":
                sampleSizes = try parseSampleSizes(atom)
            case "stco":
                chunkOffsets = try parseChunkOffsets32(atom)
            case "co64":
                chunkOffsets = try parseChunkOffsets64(atom)
            case "stsc":
                samplesPerChunk = try parseSampleToChunk(atom)
            case "stts":
                timeToSample = try parseTimeToSample(atom)
            default:
                break
            }
            
            position = Int(atom.dataOffset + atom.dataSize)
        }
        
        let sampleTable = SampleTable(
            sampleSizes: sampleSizes,
            chunkOffsets: chunkOffsets,
            samplesPerChunk: samplesPerChunk,
            timeToSample: timeToSample
        )
        
        return (codec: codec, sampleTable: sampleTable)
    }
    
    private func parseSampleDescription(_ stsdAtom: Atom) throws -> String {
        guard stsdAtom.dataSize >= 16 else { throw MP4ParserError.invalidAtomSize }
        
        // Skip version/flags (4) + entry count (4) + sample description size (4)
        let codecData = data.subdata(in: Int(stsdAtom.dataOffset)+12..<Int(stsdAtom.dataOffset)+16)
        return String(data: codecData, encoding: .ascii) ?? ""
    }
    
    private func parseSampleSizes(_ stszAtom: Atom) throws -> [UInt32] {
        guard stszAtom.dataSize >= 12 else { throw MP4ParserError.invalidAtomSize }
        
        let headerData = data.subdata(in: Int(stszAtom.dataOffset)..<Int(stszAtom.dataOffset)+12)
        let sampleSize = headerData.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let sampleCount = headerData.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        if sampleSize != 0 {
            // All samples have the same size
            return Array(repeating: sampleSize, count: Int(sampleCount))
        } else {
            // Individual sample sizes
            guard stszAtom.dataSize >= 12 + UInt64(sampleCount * 4) else { throw MP4ParserError.invalidAtomSize }
            
            var sizes: [UInt32] = []
            for i in 0..<sampleCount {
                let offset = Int(stszAtom.dataOffset) + 12 + Int(i * 4)
                let sizeData = data.subdata(in: offset..<offset+4)
                let size = sizeData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                sizes.append(size)
            }
            return sizes
        }
    }
    
    private func parseChunkOffsets32(_ stcoAtom: Atom) throws -> [UInt64] {
        guard stcoAtom.dataSize >= 8 else { throw MP4ParserError.invalidAtomSize }
        
        let entryCountData = data.subdata(in: Int(stcoAtom.dataOffset)+4..<Int(stcoAtom.dataOffset)+8)
        let entryCount = entryCountData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        guard stcoAtom.dataSize >= 8 + UInt64(entryCount * 4) else { throw MP4ParserError.invalidAtomSize }
        
        var offsets: [UInt64] = []
        for i in 0..<entryCount {
            let offset = Int(stcoAtom.dataOffset) + 8 + Int(i * 4)
            let offsetData = data.subdata(in: offset..<offset+4)
            let chunkOffset = UInt64(offsetData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            offsets.append(chunkOffset)
        }
        return offsets
    }
    
    private func parseChunkOffsets64(_ co64Atom: Atom) throws -> [UInt64] {
        guard co64Atom.dataSize >= 8 else { throw MP4ParserError.invalidAtomSize }
        
        let entryCountData = data.subdata(in: Int(co64Atom.dataOffset)+4..<Int(co64Atom.dataOffset)+8)
        let entryCount = entryCountData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        guard co64Atom.dataSize >= 8 + UInt64(entryCount * 8) else { throw MP4ParserError.invalidAtomSize }
        
        var offsets: [UInt64] = []
        for i in 0..<entryCount {
            let offset = Int(co64Atom.dataOffset) + 8 + Int(i * 8)
            let offsetData = data.subdata(in: offset..<offset+8)
            let chunkOffset = offsetData.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
            offsets.append(chunkOffset)
        }
        return offsets
    }
    
    private func parseSampleToChunk(_ stscAtom: Atom) throws -> [SampleToChunk] {
        guard stscAtom.dataSize >= 8 else { throw MP4ParserError.invalidAtomSize }
        
        let entryCountData = data.subdata(in: Int(stscAtom.dataOffset)+4..<Int(stscAtom.dataOffset)+8)
        let entryCount = entryCountData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        guard stscAtom.dataSize >= 8 + UInt64(entryCount * 12) else { throw MP4ParserError.invalidAtomSize }
        
        var entries: [SampleToChunk] = []
        for i in 0..<entryCount {
            let offset = Int(stscAtom.dataOffset) + 8 + Int(i * 12)
            let entryData = data.subdata(in: offset..<offset+12)
            
            let firstChunk = entryData.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let samplesPerChunk = entryData.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let sampleDescIndex = entryData.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            
            entries.append(SampleToChunk(
                firstChunk: firstChunk,
                samplesPerChunk: samplesPerChunk,
                sampleDescriptionIndex: sampleDescIndex
            ))
        }
        return entries
    }
    
    private func parseTimeToSample(_ sttsAtom: Atom) throws -> [TimeToSample] {
        guard sttsAtom.dataSize >= 8 else { throw MP4ParserError.invalidAtomSize }
        
        let entryCountData = data.subdata(in: Int(sttsAtom.dataOffset)+4..<Int(sttsAtom.dataOffset)+8)
        let entryCount = entryCountData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        guard sttsAtom.dataSize >= 8 + UInt64(entryCount * 8) else { throw MP4ParserError.invalidAtomSize }
        
        var entries: [TimeToSample] = []
        for i in 0..<entryCount {
            let offset = Int(sttsAtom.dataOffset) + 8 + Int(i * 8)
            let entryData = data.subdata(in: offset..<offset+8)
            
            let sampleCount = entryData.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let sampleDuration = entryData.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            
            entries.append(TimeToSample(
                sampleCount: sampleCount,
                sampleDuration: sampleDuration
            ))
        }
        return entries
    }
    
    private func getSamplesPerChunk(chunkIndex: Int, track: Track) -> UInt32 {
        let stsc = track.sampleTable.samplesPerChunk
        
        for i in (0..<stsc.count).reversed() {
            if UInt32(chunkIndex + 1) >= stsc[i].firstChunk {
                return stsc[i].samplesPerChunk
            }
        }
        
        return stsc.first?.samplesPerChunk ?? 1
    }
}

public enum MP4ParserError: Error {
    case invalidAtomSize
    case notAAXCFile
    case noAudioTrack
    case invalidTrackStructure
}