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
    
    /// Metadata extracted from the MP4 file
    public struct Metadata {
        public var title: String?
        public var artist: String?
        public var albumArtist: String?
        public var album: String?
        public var genre: String?
        public var description: String?
        public var longDescription: String?
        public var copyright: String?
        public var encodingTool: String?
        public var purchaseDate: String?
        public var releaseDate: String?
        public var coverArt: Data?
        public var chapters: [Chapter] = []
        public var duration: UInt64 = 0
        public var timescale: UInt32 = 0
        
        public init() {}
        
        /// Convert metadata to JSON-compatible dictionary matching the requested format
        public func toJSON(fileSize: Int) -> [String: Any] {
            var json: [String: Any] = [:]
            
            // Title
            if let title = title {
                json["title"] = title
            }
            
            // Author as array
            if let artist = artist {
                json["author"] = [artist]
            }
            
            // Length in seconds (round to 2 decimal places)
            if duration > 0 && timescale > 0 {
                let lengthInSeconds = Double(duration) / Double(timescale)
                json["length"] = Double(round(lengthInSeconds * 100)) / 100.0
            }
            
            // Year from release date
            if let releaseDate = releaseDate {
                let yearComponents = releaseDate.components(separatedBy: "-")
                if let year = yearComponents.first {
                    json["year"] = year
                }
            }
            
            // Bitrate in kbps
            if duration > 0 && timescale > 0 && fileSize > 0 {
                let durationInSeconds = Double(duration) / Double(timescale)
                let fileSizeInBits = Double(fileSize) * 8
                let bitrate = Int(fileSizeInBits / durationInSeconds / 1000)
                json["bitrate_kbs"] = bitrate
            }
            
            // Chapters as dictionary with string keys
            if !chapters.isEmpty {
                var chaptersDict: [String: Any] = [:]
                for (index, chapter) in chapters.enumerated() {
                    // Times are already rounded in Chapter init
                    chaptersDict[String(index)] = [
                        "startTime": chapter.startTime,
                        "endTime": chapter.endTime,
                        "title": chapter.title
                    ]
                }
                json["chapters"] = chaptersDict
            }
            
            // Description (truncated if needed)
            if let desc = description ?? longDescription {
                let maxLength = 250
                if desc.count > maxLength {
                    let endIndex = desc.index(desc.startIndex, offsetBy: maxLength)
                    json["description"] = String(desc[..<endIndex])
                } else {
                    json["description"] = desc
                }
            }
            
            return json
        }
    }
    
    /// Chapter information
    public struct Chapter {
        public let startTime: TimeInterval // in seconds
        public let endTime: TimeInterval   // in seconds (not duration)
        public let title: String
        
        public init(startTime: TimeInterval, endTime: TimeInterval, title: String) {
            // Round to 2 decimal places to avoid floating-point precision issues
            self.startTime = round(startTime * 100) / 100
            self.endTime = round(endTime * 100) / 100
            self.title = title
        }
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
    
    /// Parse metadata from the MP4 file
    public func parseMetadata() throws -> Metadata {
        position = 0
        var metadata = Metadata()
        var tracks: [Track] = []
        
        // Parse top-level atoms looking for metadata
        while position < data.count {
            guard let atom = try parseAtom() else { break }
            
            switch atom.type {
            case "moov":
                // Parse both tracks and metadata from moov
                let moovData = try parseMovieAtomWithMetadata(atom)
                tracks = moovData.tracks
                if let extractedMetadata = moovData.metadata {
                    metadata = extractedMetadata
                }
            case "meta":
                // Sometimes meta can be at top level
                do {
                    if let extractedMetadata = try parseMetaAtom(atom) {
                        // Merge with existing metadata
                        mergeMetadata(&metadata, with: extractedMetadata)
                        debugLog("📚 Found top-level meta atom with metadata")
                    }
                } catch {
                    debugLog("⚠️ Failed to parse top-level meta atom: \(error)")
                }
            default:
                break
            }
            
            position = Int(atom.dataOffset + atom.dataSize)
        }
        
        // Extract chapters from tracks if available
        for track in tracks {
            if track.mediaType == "text" || track.mediaType == "sbtl" {
                // This might be a chapter track
                do {
                    if let chapters = try extractChaptersFromTrack(track) {
                        metadata.chapters.append(contentsOf: chapters)
                        debugLog("📖 Extracted \(chapters.count) chapters from track")
                    }
                } catch {
                    debugLog("⚠️ Failed to extract chapters from track: \(error)")
                }
            }
        }
        
        return metadata
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
        let type = String(data: typeData, encoding: .isoLatin1) ?? "unknown"
        
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
    
    private func parseMovieHeaderAtom(_ mvhdAtom: Atom) throws -> (duration: UInt64, timescale: UInt32) {
        // Movie header has the same structure as media header for duration/timescale
        return try parseMediaHeader(mvhdAtom)
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
    
    // MARK: - Metadata Parsing
    
    private func parseMovieAtomWithMetadata(_ moovAtom: Atom) throws -> (tracks: [Track], metadata: Metadata?) {
        let savedPosition = position
        defer { position = savedPosition }
        
        position = Int(moovAtom.dataOffset)
        let endPosition = Int(moovAtom.dataOffset + moovAtom.dataSize)
        var tracks: [Track] = []
        var metadata: Metadata?
        
        while position < endPosition {
            guard let atom = try parseAtom() else { break }
            
            switch atom.type {
            case "mvhd":
                // Parse movie header for overall duration/timescale
                if metadata == nil {
                    metadata = Metadata()
                }
                let mvhdData = try parseMovieHeaderAtom(atom)
                metadata?.duration = mvhdData.duration
                metadata?.timescale = mvhdData.timescale
            case "trak":
                if let track = try parseTrackAtom(atom) {
                    tracks.append(track)
                }
            case "udta":
                let udtaMetadata = try parseUserDataAtom(atom)
                if metadata == nil {
                    metadata = udtaMetadata
                } else if let udtaMetadata = udtaMetadata {
                    mergeMetadata(&metadata!, with: udtaMetadata)
                }
            case "meta":
                let metaMetadata = try parseMetaAtom(atom)
                if metadata == nil {
                    metadata = metaMetadata
                } else if let metaMetadata = metaMetadata {
                    mergeMetadata(&metadata!, with: metaMetadata)
                }
            default:
                break
            }
            
            position = Int(atom.dataOffset + atom.dataSize)
        }
        
        return (tracks: tracks, metadata: metadata)
    }
    
    private func parseUserDataAtom(_ udtaAtom: Atom) throws -> Metadata? {
        let savedPosition = position
        defer { position = savedPosition }
        
        position = Int(udtaAtom.dataOffset)
        let endPosition = Int(udtaAtom.dataOffset + udtaAtom.dataSize)
        var metadata = Metadata()
        var hasMetadata = false
        
        while position < endPosition {
            guard let atom = try parseAtom() else { break }
            
            if atom.type == "meta" {
                do {
                    if let metaData = try parseMetaAtom(atom) {
                        metadata = metaData
                        hasMetadata = true
                        debugLog("📚 Found metadata in udta atom")
                    }
                } catch {
                    debugLog("⚠️ Failed to parse meta atom in udta: \(error)")
                }
            }
            
            position = Int(atom.dataOffset + atom.dataSize)
        }
        
        return hasMetadata ? metadata : nil
    }
    
    private func parseMetaAtom(_ metaAtom: Atom) throws -> Metadata? {
        let savedPosition = position
        defer { position = savedPosition }
        
        // Skip version/flags (4 bytes) if present
        position = Int(metaAtom.dataOffset) + 4
        let endPosition = Int(metaAtom.dataOffset + metaAtom.dataSize)
        
        var metadata: Metadata?
        
        while position < endPosition {
            guard let atom = try parseAtom() else { break }
            
            switch atom.type {
            case "ilst":
                do {
                    metadata = try parseItemListAtom(atom)
                    debugLog("📚 Successfully parsed item list metadata")
                } catch {
                    debugLog("⚠️ Failed to parse item list atom: \(error)")
                }
            case "hdlr":
                // Handler reference - skip for now
                break
            default:
                break
            }
            
            position = Int(atom.dataOffset + atom.dataSize)
        }
        
        return metadata
    }
    
    private func parseItemListAtom(_ ilstAtom: Atom) throws -> Metadata {
        let savedPosition = position
        defer { position = savedPosition }
        
        position = Int(ilstAtom.dataOffset)
        let endPosition = Int(ilstAtom.dataOffset + ilstAtom.dataSize)
        var metadata = Metadata()
        
        while position < endPosition {
            guard let atom = try parseAtom() else { break }
            
            // iTunes metadata atoms
            switch atom.type {
            case "©nam":
                metadata.title = try parseStringMetadataAtom(atom)
            case "©ART":
                metadata.artist = try parseStringMetadataAtom(atom)
            case "aART":
                metadata.albumArtist = try parseStringMetadataAtom(atom)
            case "©alb":
                metadata.album = try parseStringMetadataAtom(atom)
            case "©gen":
                metadata.genre = try parseStringMetadataAtom(atom)
            case "©des", "desc":
                metadata.description = try parseStringMetadataAtom(atom)
            case "ldes":
                metadata.longDescription = try parseStringMetadataAtom(atom)
            case "©cpy", "cprt":
                metadata.copyright = try parseStringMetadataAtom(atom)
            case "©too":
                metadata.encodingTool = try parseStringMetadataAtom(atom)
            case "purd":
                metadata.purchaseDate = try parseStringMetadataAtom(atom)
            case "©day":
                metadata.releaseDate = try parseStringMetadataAtom(atom)
            case "covr":
                metadata.coverArt = try parseCoverArtAtom(atom)
            default:
                break
            }
            
            position = Int(atom.dataOffset + atom.dataSize)
        }
        
        return metadata
    }
    
    private func parseStringMetadataAtom(_ atom: Atom) throws -> String? {
        let savedPosition = position
        defer { position = savedPosition }
        
        position = Int(atom.dataOffset)
        let endPosition = Int(atom.dataOffset + atom.dataSize)
        
        // Look for data atom inside
        while position < endPosition {
            guard let dataAtom = try parseAtom() else { break }
            
            if dataAtom.type == "data" && dataAtom.dataSize >= 8 {
                // Skip type and locale (8 bytes)
                let stringStart = Int(dataAtom.dataOffset) + 8
                let stringLength = Int(dataAtom.dataSize) - 8
                
                if stringStart + stringLength <= data.count && stringLength > 0 {
                    let stringData = data.subdata(in: stringStart..<stringStart + stringLength)
                    if let result = String(data: stringData, encoding: .utf8) {
                        return result
                    } else {
                        debugLog("⚠️ Failed to decode string metadata as UTF-8")
                    }
                } else {
                    debugLog("⚠️ Invalid string metadata bounds: start=\(stringStart), length=\(stringLength), dataSize=\(data.count)")
                }
            }
            
            position = Int(dataAtom.dataOffset + dataAtom.dataSize)
        }
        
        debugLog("⚠️ No data atom found in metadata atom \(atom.type)")
        return nil
    }
    
    private func parseCoverArtAtom(_ atom: Atom) throws -> Data? {
        let savedPosition = position
        defer { position = savedPosition }
        
        position = Int(atom.dataOffset)
        let endPosition = Int(atom.dataOffset + atom.dataSize)
        
        // Look for data atom inside
        while position < endPosition {
            guard let dataAtom = try parseAtom() else { break }
            
            if dataAtom.type == "data" && dataAtom.dataSize >= 8 {
                // Skip type and flags (8 bytes)
                let imageStart = Int(dataAtom.dataOffset) + 8
                let imageLength = Int(dataAtom.dataSize) - 8
                
                if imageStart + imageLength <= data.count && imageLength > 0 {
                    debugLog("🖼️ Found cover art: \(imageLength) bytes")
                    return data.subdata(in: imageStart..<imageStart + imageLength)
                } else {
                    debugLog("⚠️ Invalid cover art bounds: start=\(imageStart), length=\(imageLength), dataSize=\(data.count)")
                }
            }
            
            position = Int(dataAtom.dataOffset + dataAtom.dataSize)
        }
        
        debugLog("⚠️ No cover art data atom found")
        return nil
    }
    
    private func extractChaptersFromTrack(_ track: Track) throws -> [Chapter]? {
        guard track.mediaType == "text" || track.mediaType == "sbtl" else {
            return nil
        }
        
        var chapters: [Chapter] = []
        var sampleTimes: [(index: Int, time: Double)] = []
        
        // First, build a list of all samples with their timestamps
        var currentTime: Double = 0
        var sampleIndex = 0
        
        for entry in track.sampleTable.timeToSample {
            for _ in 0..<entry.sampleCount {
                if sampleIndex >= track.sampleTable.sampleSizes.count {
                    break
                }
                
                if track.sampleTable.sampleSizes[sampleIndex] > 0 {
                    sampleTimes.append((index: sampleIndex, time: currentTime))
                }
                
                currentTime += Double(entry.sampleDuration)
                sampleIndex += 1
            }
        }
        
        // Now extract chapter data for each sample with content
        for (i, (sampleIdx, startTimeUnits)) in sampleTimes.enumerated() {
            if let chapterData = try? extractSampleData(track: track, sampleIndex: sampleIdx) {
                if let chapterTitle = parseChapterTitle(from: chapterData) {
                    let startTime = startTimeUnits / Double(track.timescale)
                    
                    // End time is the start of the next chapter, or track duration
                    let endTime: Double
                    if i + 1 < sampleTimes.count {
                        endTime = sampleTimes[i + 1].time / Double(track.timescale)
                    } else {
                        endTime = Double(track.duration) / Double(track.timescale)
                    }
                    
                    chapters.append(Chapter(
                        startTime: startTime,
                        endTime: endTime,
                        title: chapterTitle
                    ))
                }
            }
        }
        
        return chapters.isEmpty ? nil : chapters
    }
    
    private func extractSampleData(track: Track, sampleIndex: Int) throws -> Data? {
        // Find which chunk contains this sample
        var currentSample = 0
        var chunkIndex = 0
        
        for (idx, _) in track.sampleTable.chunkOffsets.enumerated() {
            let samplesInThisChunk = getSamplesPerChunk(chunkIndex: idx, track: track)
            if currentSample + Int(samplesInThisChunk) > sampleIndex {
                // Found the chunk
                chunkIndex = idx
                break
            }
            currentSample += Int(samplesInThisChunk)
        }
        
        // Calculate offset within chunk
        var offsetInChunk: UInt64 = 0
        let firstSampleInChunk = currentSample
        for i in firstSampleInChunk..<sampleIndex {
            if i < track.sampleTable.sampleSizes.count {
                offsetInChunk += UInt64(track.sampleTable.sampleSizes[i])
            }
        }
        
        // Get sample data
        guard chunkIndex < track.sampleTable.chunkOffsets.count,
              sampleIndex < track.sampleTable.sampleSizes.count else {
            return nil
        }
        
        let chunkOffset = track.sampleTable.chunkOffsets[chunkIndex]
        let sampleOffset = Int(chunkOffset + offsetInChunk)
        let sampleSize = Int(track.sampleTable.sampleSizes[sampleIndex])
        
        guard sampleOffset + sampleSize <= data.count else {
            return nil
        }
        
        return data.subdata(in: sampleOffset..<sampleOffset + sampleSize)
    }
    
    private func parseChapterTitle(from data: Data) -> String? {
        // Text samples in MP4 typically have a 2-byte length prefix followed by UTF-8 or UTF-16 text
        guard data.count >= 2 else { return nil }
        
        // Try parsing as a QuickTime text sample (common for chapters)
        // Format: 2-byte length + text
        let textLength = data.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        
        guard data.count >= 2 + Int(textLength) else {
            // Try without length prefix
            if let title = String(data: data, encoding: .utf8) {
                return title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let title = String(data: data, encoding: .utf16) {
                return title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
        
        let textData = data.subdata(in: 2..<2 + Int(textLength))
        
        // Try UTF-8 first, then UTF-16
        if let title = String(data: textData, encoding: .utf8) {
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let title = String(data: textData, encoding: .utf16) {
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return nil
    }
    
    private func mergeMetadata(_ target: inout Metadata, with source: Metadata) {
        target.title = target.title ?? source.title
        target.artist = target.artist ?? source.artist
        target.albumArtist = target.albumArtist ?? source.albumArtist
        target.album = target.album ?? source.album
        target.genre = target.genre ?? source.genre
        target.description = target.description ?? source.description
        target.longDescription = target.longDescription ?? source.longDescription
        target.copyright = target.copyright ?? source.copyright
        target.encodingTool = target.encodingTool ?? source.encodingTool
        target.purchaseDate = target.purchaseDate ?? source.purchaseDate
        target.releaseDate = target.releaseDate ?? source.releaseDate
        target.coverArt = target.coverArt ?? source.coverArt
        target.chapters.append(contentsOf: source.chapters)
        
        // Preserve duration/timescale if not already set
        if target.duration == 0 {
            target.duration = source.duration
        }
        if target.timescale == 0 {
            target.timescale = source.timescale
        }
    }
}

public enum MP4ParserError: Error {
    case invalidAtomSize
    case notAAXCFile
    case noAudioTrack
    case invalidTrackStructure
}