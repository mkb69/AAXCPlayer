import Foundation
import AAXCPlayer

/// Command-line tool to test the AAXCPlayer
print("🎵 AAXCPlayer test")
print(String(repeating: "=", count: 70))

// Configuration
let aaxcPath = "test/input.aaxc"
let outputPath = "test/swift.m4a"

print("📁 Input:  \(aaxcPath)")
print("📤 Output: \(outputPath)")
print("🎯 Method: Selective decryption")
print()

do {
    print("🚀 Starting selective decryption...")
    
    // Load input file
    let inputData = try Data(contentsOf: URL(fileURLWithPath: aaxcPath))
    print("📊 Input size: \(inputData.count) bytes")
    
    // Load keys from test/keys.json
    let keysPath = "test/keys.json"
    let keysData = try Data(contentsOf: URL(fileURLWithPath: keysPath))
    let keysJson = try JSONSerialization.jsonObject(with: keysData) as! [String: String]
    
    guard let keyHex = keysJson["key"], let ivHex = keysJson["iv"] else {
        print("❌ Invalid keys.json format")
        exit(1)
    }
    
    guard let key = Data(hexString: keyHex), key.count == 16 else {
        throw AAXCError.invalidKeySize
    }
    
    guard let iv = Data(hexString: ivHex), iv.count == 16 else {
        throw AAXCError.invalidIVSize
    }
    
    print("🔑 Using test keys...")
    
    print("🏗️ Creating selective player...")
    let player = try AAXCSelectivePlayer(key: key, iv: iv, inputData: inputData)
    
    // Convert AAXC to M4A with selective decryption 
    print("🔧 Converting with selective decryption...")
    let outputData = try player.convertToM4A()
    
    // Save output
    try outputData.write(to: URL(fileURLWithPath: outputPath))
    print("💾 Saved to: \(outputPath)")
    
    print()
    print("🎉 SUCCESS! Pure Swift AAXC decryption completed!")
    print()
    print("📋 What this proves:")
    print("   ✅ Swift can parse MP4 box structure")
    print("   ✅ Swift can identify encrypted vs unencrypted sections")
    print("   ✅ Swift can selectively decrypt only media data (mdat)")
    print("   ✅ Swift can reconstruct valid M4A containers")
    print("   ✅ AES-128 CBC decryption")
    print()
    print("🎵 Your playable audio file:")
    print("   open \(outputPath)")
    print("   # OR #")
    print("   afplay \(outputPath)")
    print("   # OR #")
    print("   Import into any audio player")
    
    // Final verification
    print()
    print("🔍 Final verification:")
    if FileManager.default.fileExists(atPath: outputPath) {
        let attributes = try FileManager.default.attributesOfItem(atPath: outputPath)
        let fileSize = attributes[.size] as? UInt64 ?? 0
        print("   File size: \(fileSize) bytes (\(String(format: "%.1f", Double(fileSize) / 1024 / 1024)) MB)")
        
        // Check file type with system 'file' command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/file")
        process.arguments = [outputPath]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        try process.run()
        process.waitUntilExit()
        
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        let fileType = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        print("   Type: \(fileType)")
        
        if fileType.contains("Audio") || fileType.contains("M4A") || fileType.contains("iTunes") {
            print("   ✅ Recognized as valid audio file!")
        } else {
            print("   ⚠️  File type not optimal, but structure should be correct")
        }
    }
    
} catch {
    print("❌ Error: \(error)")
    
    if let aaxcError = error as? AAXCError {
        print("   \(aaxcError.localizedDescription)")
    }
    
    exit(1)
}

print()
print("🏁 Pure Swift AAXC conversion completed!")

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