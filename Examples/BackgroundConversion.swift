import Foundation
import AVFoundation
import AAXCPlayer

/// Advanced example showing background-safe AAXC conversion with CPU throttling
/// This demonstrates how to convert AAXC files safely while the app is in background
/// or while other CPU-intensive tasks (like audio playback) are running.

class BackgroundSafeAAXCConverter {
    private var avPlayer: AVPlayer?
    private var currentConversion: AAXCSelectivePlayer?

    // MARK: - Aggressive Throttling (Recommended for Production)

    /// Convert AAXC file in background with aggressive CPU throttling
    /// This prevents iOS watchdog termination and is safe for older devices
    func convertWithAggressiveThrottling(
        aaxcURL: URL,
        key: Data,
        iv: Data,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        do {
            // Create player
            let player = try AAXCSelectivePlayer(key: key, iv: iv, inputURL: aaxcURL)
            self.currentConversion = player

            // Configure AGGRESSIVE throttling (recommended for production)
            player.cpuThrottlingEnabled = true
            player.yieldInterval = 500      // Yield every 500 samples (more frequent)
            player.yieldDuration = 0.02     // 20ms sleep (longer pauses)
            player.qosClass = .utility      // Background priority

            print("🔄 Starting background conversion with aggressive throttling...")
            print("⚡️ Config: yield every 500 samples, 20ms sleep, .utility QoS")

            // Generate temporary output path
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")

            // Convert asynchronously on background queue
            player.convertToM4AAsync(outputPath: outputURL.path) { [weak self] result in
                self?.currentConversion = nil

                switch result {
                case .success:
                    print("✅ Background conversion complete!")
                    print("💾 Output: \(outputURL.path)")
                    completion(.success(outputURL))

                case .failure(let error):
                    print("❌ Conversion failed: \(error)")
                    completion(.failure(error))
                }
            }
        } catch {
            print("❌ Failed to initialize player: \(error)")
            completion(.failure(error))
        }
    }

    // MARK: - Balanced Throttling

    /// Convert with balanced throttling (good for newer devices)
    func convertWithBalancedThrottling(
        aaxcURL: URL,
        key: Data,
        iv: Data,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        do {
            let player = try AAXCSelectivePlayer(key: key, iv: iv, inputURL: aaxcURL)
            self.currentConversion = player

            // Configure BALANCED throttling
            player.cpuThrottlingEnabled = true
            player.yieldInterval = 1000     // Yield every 1000 samples
            player.yieldDuration = 0.01     // 10ms sleep
            player.qosClass = .utility      // Background priority

            print("🔄 Starting conversion with balanced throttling...")

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")

            player.convertToM4AAsync(outputPath: outputURL.path) { [weak self] result in
                self?.currentConversion = nil
                completion(result.map { _ in outputURL })
            }
        } catch {
            completion(.failure(error))
        }
    }

    // MARK: - Custom Throttling Configuration

    /// Convert with custom throttling parameters
    /// Use this to fine-tune for your specific app's requirements
    func convertWithCustomThrottling(
        aaxcURL: URL,
        key: Data,
        iv: Data,
        yieldInterval: Int,
        yieldDuration: TimeInterval,
        qos: DispatchQoS.QoSClass = .utility,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        do {
            let player = try AAXCSelectivePlayer(key: key, iv: iv, inputURL: aaxcURL)
            self.currentConversion = player

            // Configure CUSTOM throttling
            player.cpuThrottlingEnabled = true
            player.yieldInterval = yieldInterval
            player.yieldDuration = yieldDuration
            player.qosClass = qos

            print("🔄 Starting conversion with custom throttling...")
            print("⚡️ Config: yield every \(yieldInterval) samples, \(yieldDuration)s sleep, \(qos) QoS")

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")

            player.convertToM4AAsync(outputPath: outputURL.path) { [weak self] result in
                self?.currentConversion = nil
                completion(result.map { _ in outputURL })
            }
        } catch {
            completion(.failure(error))
        }
    }

    // MARK: - Convert While Playing Audio

    /// Real-world example: Convert AAXC in background while playing existing audio
    /// This simulates the common scenario where conversion happens during playback
    func convertWhilePlayingAudio(
        aaxcURL: URL,
        key: Data,
        iv: Data,
        playbackURL: URL? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        do {
            // Optional: Start audio playback first to simulate real conditions
            if let playbackURL = playbackURL {
                startPlayback(url: playbackURL)
                print("🎵 Audio playback started")
            }

            let player = try AAXCSelectivePlayer(key: key, iv: iv, inputURL: aaxcURL)
            self.currentConversion = player

            // Use aggressive throttling when other audio is playing
            player.cpuThrottlingEnabled = true
            player.yieldInterval = 500      // More frequent yields
            player.yieldDuration = 0.02     // Longer sleeps
            player.qosClass = .utility      // Don't interfere with playback

            print("🔄 Converting AAXC while audio is playing...")
            print("⚡️ Using aggressive throttling to avoid watchdog termination")

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")

            player.convertToM4AAsync(outputPath: outputURL.path) { [weak self] result in
                self?.currentConversion = nil

                switch result {
                case .success:
                    print("✅ Conversion complete (audio playback continued)")
                    completion(.success(outputURL))

                case .failure(let error):
                    print("❌ Conversion failed: \(error)")
                    completion(.failure(error))
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    // MARK: - Metadata + Async Conversion

    /// Extract metadata first, then convert asynchronously
    /// Useful for showing metadata to user before conversion completes
    func extractMetadataThenConvert(
        aaxcURL: URL,
        key: Data,
        iv: Data,
        metadataHandler: @escaping (MP4StructureParser.Metadata) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        do {
            let player = try AAXCSelectivePlayer(key: key, iv: iv, inputURL: aaxcURL)
            self.currentConversion = player

            // Step 1: Extract metadata immediately (no decryption needed)
            let metadata = try player.parseMetadata()
            print("📚 Metadata extracted")
            print("   Title: \(metadata.title ?? "Unknown")")
            print("   Artist: \(metadata.artist ?? "Unknown")")
            print("   Duration: \(metadata.duration ?? 0)s")
            print("   Chapters: \(metadata.chapters.count)")

            // Call metadata handler to update UI
            metadataHandler(metadata)

            // Step 2: Convert in background with throttling
            player.cpuThrottlingEnabled = true
            player.yieldInterval = 500
            player.yieldDuration = 0.02
            player.qosClass = .utility

            print("🔄 Starting background conversion...")

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")

            player.convertToM4AAsync(outputPath: outputURL.path) { [weak self] result in
                self?.currentConversion = nil
                completion(result.map { _ in outputURL })
            }
        } catch {
            completion(.failure(error))
        }
    }

    // MARK: - Helper Methods

    private func startPlayback(url: URL) {
        let asset = AVAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        avPlayer = AVPlayer(playerItem: playerItem)
        avPlayer?.play()
    }

    func stopPlayback() {
        avPlayer?.pause()
        avPlayer = nil
    }
}

// MARK: - Usage Examples

/// Example 1: Basic background conversion with aggressive throttling
func example1_AggressiveThrottling() {
    let converter = BackgroundSafeAAXCConverter()

    // Your AAXC file and keys
    let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let aaxcURL = documentsURL.appendingPathComponent("audiobook.aaxc")

    let keyHex = "your_32_character_key_here"
    let ivHex = "your_32_character_iv_here"

    guard let key = Data(hexString: keyHex), key.count == 16,
          let iv = Data(hexString: ivHex), iv.count == 16 else {
        print("Invalid keys")
        return
    }

    // Convert with aggressive throttling (recommended for production)
    converter.convertWithAggressiveThrottling(aaxcURL: aaxcURL, key: key, iv: iv) { result in
        switch result {
        case .success(let m4aURL):
            print("✅ Success! M4A file at: \(m4aURL.path)")
            // Play the converted file
            playConvertedFile(url: m4aURL)

        case .failure(let error):
            print("❌ Error: \(error)")
        }
    }
}

/// Example 2: Convert while playing audio (real-world scenario)
func example2_ConvertDuringPlayback() {
    let converter = BackgroundSafeAAXCConverter()

    let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let aaxcURL = documentsURL.appendingPathComponent("new_audiobook.aaxc")
    let currentlyPlayingURL = documentsURL.appendingPathComponent("current_audio.m4a")

    let keyHex = "your_key"
    let ivHex = "your_iv"

    guard let key = Data(hexString: keyHex), key.count == 16,
          let iv = Data(hexString: ivHex), iv.count == 16 else {
        return
    }

    // Convert new audiobook while current one is playing
    converter.convertWhilePlayingAudio(
        aaxcURL: aaxcURL,
        key: key,
        iv: iv,
        playbackURL: currentlyPlayingURL
    ) { result in
        switch result {
        case .success(let m4aURL):
            print("✅ Background conversion complete!")
            print("   Converted file: \(m4aURL.path)")
            print("   Audio playback continued without interruption")

        case .failure(let error):
            print("❌ Conversion failed: \(error)")
        }
    }
}

/// Example 3: Show metadata immediately, convert in background
func example3_MetadataFirstThenConvert() {
    let converter = BackgroundSafeAAXCConverter()

    let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let aaxcURL = documentsURL.appendingPathComponent("audiobook.aaxc")

    let keyHex = "your_key"
    let ivHex = "your_iv"

    guard let key = Data(hexString: keyHex), key.count == 16,
          let iv = Data(hexString: ivHex), iv.count == 16 else {
        return
    }

    converter.extractMetadataThenConvert(
        aaxcURL: aaxcURL,
        key: key,
        iv: iv,
        metadataHandler: { metadata in
            // Update UI with metadata immediately
            print("📚 Showing metadata to user:")
            print("   Title: \(metadata.title ?? "Unknown")")
            print("   Artist: \(metadata.artist ?? "Unknown")")
            if let coverData = metadata.coverArt {
                print("   Cover art: \(coverData.count) bytes")
            }

            // User can browse chapters while conversion happens in background
            for (index, chapter) in metadata.chapters.enumerated() {
                print("   Chapter \(index + 1): \(chapter.title ?? "Untitled")")
            }
        },
        completion: { result in
            switch result {
            case .success(let m4aURL):
                print("✅ Conversion complete! Ready to play.")
                playConvertedFile(url: m4aURL)

            case .failure(let error):
                print("❌ Conversion failed: \(error)")
            }
        }
    )
}

/// Example 4: Custom throttling configuration for testing
func example4_CustomThrottling() {
    let converter = BackgroundSafeAAXCConverter()

    let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let aaxcURL = documentsURL.appendingPathComponent("audiobook.aaxc")

    let keyHex = "your_key"
    let ivHex = "your_iv"

    guard let key = Data(hexString: keyHex), key.count == 16,
          let iv = Data(hexString: ivHex), iv.count == 16 else {
        return
    }

    // Test different configurations
    // For iPhone 6s/7/8 era devices:
    converter.convertWithCustomThrottling(
        aaxcURL: aaxcURL,
        key: key,
        iv: iv,
        yieldInterval: 400,         // Very frequent yields
        yieldDuration: 0.025,       // Longer sleeps
        qos: .background            // Lowest priority
    ) { result in
        switch result {
        case .success(let m4aURL):
            print("✅ Ultra-safe conversion complete!")
            playConvertedFile(url: m4aURL)

        case .failure(let error):
            print("❌ Error: \(error)")
        }
    }
}

// MARK: - Helper Functions

func playConvertedFile(url: URL) {
    let asset = AVAsset(url: url)
    let playerItem = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: playerItem)
    player.play()
    print("🎵 Playing converted file")
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
