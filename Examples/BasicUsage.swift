import Foundation
import AVFoundation
import AAXCPlayer

/// Simple example showing how to use AAXCPlayer in an iOS app
/// This demonstrates the typical flow: local AAXC file + keys → playable audio

class SimpleAAXCAudioPlayer {
    private var avPlayer: AVPlayer?
    
    /// Play a local AAXC file with provided decryption keys
    /// - Parameters:
    ///   - localFileURL: URL to the AAXC file on device (Documents, Bundle, etc.)
    ///   - keyHex: 32-character hex string for the decryption key
    ///   - ivHex: 32-character hex string for the initialization vector
    func playAAXCFile(localFileURL: URL, keyHex: String, ivHex: String) async throws {
        
        // Step 1: Load the local AAXC file
        let aaxcData = try Data(contentsOf: localFileURL)
        print("📁 Loaded AAXC file: \(aaxcData.count) bytes")
        
        // Step 2: Convert hex keys to Data
        guard let key = Data(hexString: keyHex), key.count == 16 else {
            throw AAXCError.invalidKeySize
        }
        guard let iv = Data(hexString: ivHex), iv.count == 16 else {
            throw AAXCError.invalidIVSize
        }
        print("🔑 Keys validated")
        
        // Step 3: Create the player
        let player = try AAXCSelectivePlayer(key: key, iv: iv, inputData: aaxcData)
        
        // Step 4: Extract metadata (no decryption needed)
        print("📚 Extracting metadata...")
        let metadata = try player.parseMetadata()
        print("📚 Title: \(metadata.title ?? "Unknown")")
        print("🎤 Artist: \(metadata.artist ?? "Unknown")")
        
        // Step 5: Convert AAXC to M4A
        print("🔄 Converting AAXC to M4A...")
        let m4aData = try player.convertToM4A()
        print("✅ Conversion complete: \(m4aData.count) bytes")
        
        // Step 6: Save to temporary files for AVFoundation and metadata
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try m4aData.write(to: tempURL)
        print("💾 Saved temporary M4A file")
        
        // Save metadata as JSON
        let jsonURL = tempURL.deletingPathExtension().appendingPathExtension("json")
        let jsonDict = metadata.toJSON(fileSize: aaxcData.count)
        let jsonData = try JSONSerialization.data(withJSONObject: jsonDict, options: .prettyPrinted)
        try jsonData.write(to: jsonURL)
        print("📋 Saved metadata JSON")
        
        // Step 7: Play with standard AVFoundation
        await MainActor.run {
            let asset = AVAsset(url: tempURL)
            let playerItem = AVPlayerItem(asset: asset)
            avPlayer = AVPlayer(playerItem: playerItem)
            avPlayer?.play()
            print("🎵 Playback started!")
        }
    }
    
    /// Stop playback and cleanup
    func stop() {
        avPlayer?.pause()
        avPlayer = nil
    }
}

// MARK: - Usage Examples

/// Example 1: Playing an AAXC file from Documents directory
func example1_PlayFromDocuments() {
    let audioPlayer = SimpleAAXCAudioPlayer()
    
    // Get file from Documents directory
    let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let aaxcURL = documentsURL.appendingPathComponent("my_audiobook.aaxc")
    
    // Your decryption keys (obtain these securely!)
    let keyHex = "your_32_character_key_here"
    let ivHex = "your_32_character_iv_here"
    
    Task {
        do {
            try await audioPlayer.playAAXCFile(
                localFileURL: aaxcURL,
                keyHex: keyHex,
                ivHex: ivHex
            )
            print("Playback started successfully!")
        } catch {
            print("Failed to play AAXC file: \(error)")
        }
    }
}

/// Example 2: Playing an AAXC file from app bundle
func example2_PlayFromBundle() {
    let audioPlayer = SimpleAAXCAudioPlayer()
    
    // Get file from app bundle
    guard let aaxcURL = Bundle.main.url(forResource: "sample_audiobook", withExtension: "aaxc") else {
        print("AAXC file not found in bundle")
        return
    }
    
    // Load keys from JSON file in bundle
    guard let keysURL = Bundle.main.url(forResource: "keys", withExtension: "json") else {
        print("Keys file not found in bundle")
        return
    }
    
    Task {
        do {
            // Load keys from JSON
            let keysData = try Data(contentsOf: keysURL)
            let keysJson = try JSONSerialization.jsonObject(with: keysData) as! [String: String]
            
            let keyHex = keysJson["key"]!
            let ivHex = keysJson["iv"]!
            
            try await audioPlayer.playAAXCFile(
                localFileURL: aaxcURL,
                keyHex: keyHex,
                ivHex: ivHex
            )
            print("Playback started successfully!")
        } catch {
            print("Failed to play AAXC file: \(error)")
        }
    }
}

/// Example 3: Convert AAXC to M4A in memory (for advanced processing)
func example3_ConvertInMemory() {
    let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let aaxcURL = documentsURL.appendingPathComponent("input.aaxc")
    
    Task {
        do {
            // Load AAXC file
            let aaxcData = try Data(contentsOf: aaxcURL)
            
            // Your keys
            let keyHex = "your_key_here"
            let ivHex = "your_iv_here"
            
            guard let key = Data(hexString: keyHex), key.count == 16,
                  let iv = Data(hexString: ivHex), iv.count == 16 else {
                print("Invalid keys")
                return
            }
            
            // Create player and extract metadata first
            let player = try AAXCSelectivePlayer(key: key, iv: iv, inputData: aaxcData)
            let metadata = try player.parseMetadata()
            print("📚 Metadata - Title: \(metadata.title ?? "Unknown"), Chapters: \(metadata.chapters.count)")
            
            // Convert to M4A data in memory
            let m4aData = try player.convertToM4A()
            print("✅ Conversion completed: \(m4aData.count) bytes in memory")
            
            // IMPORTANT: M4A data is now in memory only
            // Use it for streaming, analysis, or temporary playback
            // Never save decrypted content to accessible storage!
            
            // Example: Create temporary file for immediate playback only
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")
            
            try m4aData.write(to: tempURL)
            
            // Play immediately
            let asset = AVAsset(url: tempURL)
            // ... use asset for playback
            
            // Temporary file will be automatically cleaned up by system
            
        } catch {
            print("Conversion failed: \(error)")
        }
    }
}

// MARK: - Helper Extensions

extension Data {
    init?(hexString: String) {
        let cleanedHex = hexString.replacingOccurrences(of: " ", with: "")
        guard cleanedHex.count % 2 == 0 else { return nil }
        
        var data = Data()
        var index = cleanedHex.startIndex
        
        while index < cleanedHex.endIndex {
            let nextIndex = cleanedHex.index(index, offsetBy: 2)
            let byteString = cleanedHex[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        
        self = data
    }
}