# AAXCPlayer

A Swift package that provides AAXC (Audible Enhanced Audiobook) file playback for iOS and macOS. 
This allows you to decrypt and play AAXC files using native iOS frameworks like AVFoundation.

## Legal Notice and Intended Use

**This library is designed for legitimate compatibility purposes only.**

- Audible provides download links for AAXC files on their website for customers who have legally purchased audiobooks
- There are currently no widely available media players that support the AAXC format natively
- This library enables developers to create players that allow users to play audiobook files they have legally purchased
- **Important**: Any player implementation using this library must adhere to Audible's strict license requirements and terms of service
- This library is **not intended** for any form of abuse, circumvention of digital rights management, or unauthorized distribution
- Users and developers are responsible for ensuring compliance with all applicable laws and license agreements

This library exists solely to provide compatibility and accessibility for legally purchased content.

## Features

- ✅ Pure Swift implementation
- ✅ AES-128 CBC decryption with surgical MP4 container conversion
- ✅ Selective decryption that preserves MP4 structure
- ✅ Native AVFoundation integration for seamless playback
- ✅ Command-line tool for AAXC to M4A conversion
- ✅ Metadata extraction (title, artist, chapters, cover art, etc.)
- ✅ Comprehensive error handling
- ✅ Unit tests included

## Requirements

- iOS 14.0+ / macOS 11.0+
- Swift 5.9+
- Xcode 15.0+

## Installation

### Swift Package Manager

Add this package to your project using Xcode:

1. File → Add Package Dependencies
2. Enter the repository URL
3. Choose the version range

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "your-repo-url", from: "1.0.0")
]
```

## Usage

### Command-Line Tool

Convert AAXC files to M4A format:

#### Setup Required

1. **Place your AAXC file**: `test/input.aaxc`
2. **Create keys file**: `test/keys.json` with format:
   ```json
   {
       "key": "your_32_character_hex_key_here",
       "iv": "your_32_character_hex_iv_here"
   }
   ```

#### Run Conversion

```bash
swift run aaxc-tool
```

Output will be saved as:
- `test/swift.m4a` - The converted audio file
- `test/swift.json` - Metadata extracted from the file

### Basic Usage in iOS App

```swift
import AAXCPlayer

// Convert AAXC to M4A and play using streaming
func playAAXCFile(aaxcURL: URL, keyHex: String, ivHex: String) async throws {
    // Convert hex strings to Data
    guard let key = Data(hexString: keyHex), key.count == 16 else {
        throw AAXCError.invalidKeySize
    }
    
    guard let iv = Data(hexString: ivHex), iv.count == 16 else {
        throw AAXCError.invalidIVSize
    }
    
    // Create selective player with streaming support
    let player = try AAXCSelectivePlayer(key: key, iv: iv, inputURL: aaxcURL)
    
    // Extract metadata (no decryption needed)
    let metadata = try player.parseMetadata()
    
    // Convert to M4A format using streaming (efficient for large files)
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("m4a")
    
    try player.convertToM4A(outputPath: tempURL.path)
    
    // Save metadata as JSON
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: aaxcURL.path)
    let fileSize = fileAttributes[.size] as? Int ?? 0
    
    let jsonURL = tempURL.deletingPathExtension().appendingPathExtension("json")
    let jsonDict = metadata.toJSON(fileSize: fileSize)
    let jsonData = try JSONSerialization.data(withJSONObject: jsonDict, options: .prettyPrinted)
    try jsonData.write(to: jsonURL)
    
    // Play with AVFoundation
    let asset = AVAsset(url: tempURL)
    let playerItem = AVPlayerItem(asset: asset)
    let avPlayer = AVPlayer(playerItem: playerItem)
    avPlayer.play()
}
```

### Using Keys from JSON File

```swift
// JSON format: {"key": "hex_string", "iv": "hex_string"}
func playAAXCWithKeysFile(aaxcURL: URL, keysURL: URL) async throws {
    // Load keys from JSON
    let keysData = try Data(contentsOf: keysURL)
    let keysJson = try JSONSerialization.jsonObject(with: keysData) as! [String: String]
    
    guard let keyHex = keysJson["key"], let ivHex = keysJson["iv"] else {
        throw AAXCError.invalidKeySize
    }
    
    try await playAAXCFile(aaxcURL: aaxcURL, keyHex: keyHex, ivHex: ivHex)
}
```

### Streaming Conversion (Recommended for Large Files)

```swift
func convertAAXCWithStreaming(aaxcURL: URL, keyHex: String, ivHex: String) throws {
    guard let key = Data(hexString: keyHex), key.count == 16 else {
        throw AAXCError.invalidKeySize
    }
    
    guard let iv = Data(hexString: ivHex), iv.count == 16 else {
        throw AAXCError.invalidIVSize
    }
    
    // Use file path for efficient streaming (no full file loaded in memory)
    let player = try AAXCSelectivePlayer(key: key, iv: iv, inputPath: aaxcURL.path)
    
    // Optional: Extract metadata first if needed
    let metadata = try player.parseMetadata()
    print("Title: \(metadata.title ?? "Unknown")")
    
    // Stream conversion directly to output file
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("m4a")
    
    try player.convertToM4A(outputPath: tempURL.path)
    
    // IMPORTANT: Only use temporary files - never save to accessible storage
    // Temporary files are automatically cleaned up by the system
}
```

### Metadata-Only Extraction

Extract metadata without decrypting the audio data:

```swift
func extractMetadataOnly(aaxcURL: URL) throws -> MP4StructureParser.Metadata {
    // Metadata extraction doesn't require decryption keys
    // Use the parser directly for efficiency
    let fileHandle = try FileHandle(forReadingFrom: aaxcURL)
    let parser = MP4StructureParser(fileHandle: fileHandle)
    
    // Extract metadata without any decryption
    return try parser.parseMetadata()
}
```

## How It Works

This package implements a comprehensive approach for AAXC file playback:

1. **MP4 Structure Parsing**: Analyzes the complete MP4 container structure
2. **Sample Table Analysis**: Extracts audio sample locations from MP4 metadata
3. **Selective Decryption**: Decrypts only audio samples, preserving container structure
4. **Surgical Conversion**: Converts container metadata from AAXC to M4A format:
   - `ftyp` box: `aaxc` → `M4A ` (file type)
   - `stsd` box: `aavd` → `mp4a` (codec identifier)

### Key Technical Details

- **Encryption**: AES-128 CBC mode with IV reset per sample
- **Block Processing**: Only complete 16-byte blocks are decrypted
- **Container Preservation**: Original MP4 structure is maintained
- **Format Conversion**: Surgical metadata changes for M4A compatibility

## Error Handling

The package provides comprehensive error handling with three error enums:

### AAXCError (AAXCSelectivePlayer)
```swift
enum AAXCError: Error {
    case invalidKeySize     // Key must be exactly 16 bytes
    case invalidIVSize      // IV must be exactly 16 bytes
    case noAudioTrack      // No audio track found in file
    case cryptorCreationFailed  // AES cryptor initialization failed
    case decryptionFailed   // AES decryption failed
    case invalidData       // Invalid file data
    case invalidSampleOffset // Audio sample offset is invalid
}
```

### AAXCPlayerError (AAXCPlayer)
```swift
enum AAXCPlayerError: Error {
    case invalidKeySize     // Key must be exactly 16 bytes
    case invalidIVSize      // IV must be exactly 16 bytes
    case invalidFileFormat  // Not a valid AAXC file
    case decryptionFailed   // AES decryption failed
    case unsupportedFormat  // File format not supported
}
```

### MP4ParserError (MP4StructureParser)
```swift
enum MP4ParserError: Error {
    case invalidAtomSize    // MP4 atom size is invalid
    case notAAXCFile       // File is not an AAXC file
    case noAudioTrack      // No audio track found
    case invalidTrackStructure // Track structure is malformed
}
```

## Testing

The package includes comprehensive unit tests:

### Test Setup Required

Before running tests, you need to provide test files in the `test/` directory:

1. **`test/input.aaxc`**: A sample AAXC file for testing
2. **`test/keys.json`**: Corresponding decryption keys in JSON format

#### Keys.json Format

Create `test/keys.json` with your AAXC decryption keys:

```json
{
    "key": "your_32_character_hex_key_here",
    "iv": "your_32_character_hex_iv_here"
}
```

### Running Tests

```bash
swift test
```

## Performance Considerations

### Memory Usage
- **Streaming Architecture**: Files are processed in chunks without loading entire file into memory
- **Selective Decryption**: Only audio samples are decrypted, preserving container structure
- **Efficient Processing**: Handles files of any size with minimal memory footprint
- **In-Place Operations**: Minimizes memory allocations during decryption

## Security Notes

⚠️ **Important Security Considerations**:

1. **Key Storage**: Never hardcode keys in your app. Use secure storage mechanisms.
2. **Key Transmission**: Always use encrypted channels for key distribution.
3. **Decrypted Content Storage**: **NEVER** save decrypted M4A content to user-accessible storage (Documents, Library, etc.). Only use temporary files that the system automatically manages and cleans up.
4. **Temporary Files**: Always use `FileManager.default.temporaryDirectory` for any file creation. These files are automatically cleaned up by the system and cannot be accessed by users or other apps.
5. **Memory**: Decrypted data exists in memory during processing - consider secure memory handling for sensitive applications.
6. **Content Protection**: Respect the original content's licensing and DRM intentions - this library is for compatibility, not circumvention.


## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass
5. Submit a pull request

## License

This project is licensed under the MIT License - see the LICENSE file for details.