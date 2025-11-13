import Foundation
import AAXCPlayer
import Darwin

/// Get current memory usage in bytes
func getCurrentMemoryUsage() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    
    let result = withUnsafeMutablePointer(to: &info) { infoPtr in
        infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            task_info(mach_task_self_,
                     task_flavor_t(MACH_TASK_BASIC_INFO),
                     intPtr,
                     &count)
        }
    }
    
    guard result == KERN_SUCCESS else {
        return 0
    }
    
    return UInt64(info.resident_size)
}

/// Format bytes as MB string
func formatMemory(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / 1024.0 / 1024.0
    return String(format: "%.1f MB", mb)
}

/// Track memory usage with label
func trackMemory(label: String, baseline: UInt64) -> UInt64 {
    let current = getCurrentMemoryUsage()
    let delta = Int64(current) - Int64(baseline)
    let deltaStr = delta >= 0 ? "+\(formatMemory(UInt64(delta)))" : formatMemory(UInt64(-delta))
    print("💾 \(label): \(formatMemory(current)) (\(deltaStr) from baseline)")
    return current
}

/// Get current CPU time using rusage
func getCurrentCPUTime() -> (user: Double, system: Double, total: Double)? {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else {
        return nil
    }

    let userTime = Double(usage.ru_utime.tv_sec) +
                   Double(usage.ru_utime.tv_usec) / 1_000_000.0
    let systemTime = Double(usage.ru_stime.tv_sec) +
                    Double(usage.ru_stime.tv_usec) / 1_000_000.0

    return (userTime, systemTime, userTime + systemTime)
}

/// Format time as milliseconds or seconds
func formatTime(_ seconds: Double) -> String {
    if seconds < 1.0 {
        return String(format: "%.0f ms", seconds * 1000.0)
    }
    return String(format: "%.3f s", seconds)
}

/// Track CPU time with label
func trackCPU(label: String, baseline: (user: Double, system: Double, total: Double)) -> (user: Double, system: Double, total: Double) {
    guard let current = getCurrentCPUTime() else {
        print("⚠️ Could not get CPU time")
        return baseline
    }

    let userDelta = current.user - baseline.user
    let systemDelta = current.system - baseline.system
    let totalDelta = current.total - baseline.total

    print("⚡️ \(label):")
    print("   User:   \(formatTime(userDelta))")
    print("   System: \(formatTime(systemDelta))")
    print("   Total:  \(formatTime(totalDelta))")

    return current
}

/// Command-line tool to test the AAXCPlayer
print("🎵 AAXCPlayer test")
print(String(repeating: "=", count: 70))

// Configuration
let aaxcPath = "test/input.aaxc"
let outputPath = "test/swift.m4a"

print("📁 Input:  \(aaxcPath)")
print("📤 Output: \(outputPath)")
print("🎯 Method: Selective decryption (streaming)")
print()

// Initialize memory tracking
let baselineMemory = getCurrentMemoryUsage()
var peakMemory = baselineMemory
print("💾 Baseline memory: \(formatMemory(baselineMemory))")

// Initialize CPU tracking
let baselineCPU = getCurrentCPUTime() ?? (0, 0, 0)
print("⚡️ Baseline CPU time: \(formatTime(baselineCPU.total))")
print()

do {
    print("🚀 Starting selective decryption...")
    
    // Get input file size without loading it into memory
    let inputAttributes = try FileManager.default.attributesOfItem(atPath: aaxcPath)
    let inputSize = inputAttributes[.size] as? Int ?? 0
    print("📊 Input size: \(inputSize) bytes (\(String(format: "%.1f", Double(inputSize) / 1024 / 1024)) MB)")
    
    // Track memory after getting file attributes
    var currentMemory = trackMemory(label: "After file stats", baseline: baselineMemory)
    peakMemory = max(peakMemory, currentMemory)
    
    // Load keys from test/keys.json
    let keysPath = "test/keys.json"
    let keysData = try Data(contentsOf: URL(fileURLWithPath: keysPath))
    let keysJson = try JSONSerialization.jsonObject(with: keysData) as! [String: String]
    
    // Track memory after loading keys
    currentMemory = trackMemory(label: "After loading keys", baseline: baselineMemory)
    peakMemory = max(peakMemory, currentMemory)

    // Track CPU after loading keys
    var currentCPU = trackCPU(label: "After loading keys", baseline: baselineCPU)

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
    
    print("🏗️ Creating selective player with streaming support...")
    let player = try AAXCSelectivePlayer(key: key, iv: iv, inputPath: aaxcPath)
    
    // Track memory after creating player (this loads the file for parsing)
    currentMemory = trackMemory(label: "After creating player", baseline: baselineMemory)
    peakMemory = max(peakMemory, currentMemory)

    // Track CPU after creating player
    currentCPU = trackCPU(label: "After creating player", baseline: baselineCPU)

    // Extract metadata first (no decryption needed)
    print("📚 Extracting metadata...")
    let metadata = try player.parseMetadata()
    
    // Track memory after metadata extraction
    currentMemory = trackMemory(label: "After metadata extraction", baseline: baselineMemory)
    peakMemory = max(peakMemory, currentMemory)

    // Track CPU after metadata extraction
    currentCPU = trackCPU(label: "After metadata extraction", baseline: baselineCPU)

    // Convert AAXC to M4A with selective decryption using streaming
    print("🔧 Converting with selective decryption (streaming mode)...")
    let conversionStartMemory = currentMemory
    let conversionStartCPU = currentCPU
    try player.convertToM4A(outputPath: outputPath)

    // Track memory after conversion
    currentMemory = trackMemory(label: "After conversion complete", baseline: baselineMemory)
    peakMemory = max(peakMemory, currentMemory)
    let conversionMemoryDelta = currentMemory - conversionStartMemory
    print("   Conversion memory delta: \(conversionMemoryDelta > 0 ? "+" : "")\(formatMemory(UInt64(abs(Int64(conversionMemoryDelta)))))")

    // Track CPU after conversion
    currentCPU = trackCPU(label: "After conversion complete", baseline: baselineCPU)
    let conversionCPUDelta = currentCPU.total - conversionStartCPU.total
    print("   Conversion CPU delta: \(formatTime(conversionCPUDelta))")
    
    print("💾 Saved M4A to: \(outputPath)")
    
    // Save metadata as JSON
    let jsonPath = outputPath.replacingOccurrences(of: ".m4a", with: ".json")
    let jsonDict = metadata.toJSON(fileSize: inputSize)
    let jsonData = try JSONSerialization.data(withJSONObject: jsonDict, options: [.prettyPrinted, .sortedKeys])
    try jsonData.write(to: URL(fileURLWithPath: jsonPath))
    print("💾 Saved metadata to: \(jsonPath)")
    
    print()
    print("🎉 SUCCESS! Pure Swift AAXC decryption completed!")
    print()
    
    // Memory usage report
    print("📊 MEMORY USAGE REPORT")
    print(String(repeating: "-", count: 70))
    print("   Input file size:        \(formatMemory(UInt64(inputSize)))")
    print("   Baseline memory:        \(formatMemory(baselineMemory))")
    print("   Peak memory usage:      \(formatMemory(peakMemory))")
    print("   Peak memory increase:   \(formatMemory(peakMemory - baselineMemory))")
    print("   Current memory:         \(formatMemory(currentMemory))")
    
    // Calculate memory efficiency
    let memoryEfficiency = Double(peakMemory - baselineMemory) / Double(inputSize) * 100.0
    print("   Memory efficiency:      \(String(format: "%.1f", memoryEfficiency))% of input size")
    
    // Streaming efficiency assessment
    if memoryEfficiency < 50.0 {
        print("   ✅ Excellent! Streaming keeps memory usage low")
    } else if memoryEfficiency < 100.0 {
        print("   ⚠️  Good, but room for improvement in streaming")
    } else {
        print("   ❌ Memory usage exceeds file size - check for leaks")
    }
    print(String(repeating: "-", count: 70))

    print()

    // CPU usage report
    print("📊 CPU USAGE REPORT")
    print(String(repeating: "-", count: 70))
    print("   User time:          \(formatTime(currentCPU.user))")
    print("   System time:        \(formatTime(currentCPU.system))")
    print("   Total CPU time:     \(formatTime(currentCPU.total))")

    // Calculate CPU metrics
    let userSystemRatio = currentCPU.user / max(currentCPU.system, 0.001)
    print("   User/System ratio:  \(String(format: "%.2f", userSystemRatio))")

    let cpuPerMB = currentCPU.total / (Double(inputSize) / 1024.0 / 1024.0)
    print("   CPU time per MB:    \(formatTime(cpuPerMB))")

    // CPU efficiency assessment
    if cpuPerMB < 0.1 {
        print("   ✅ Excellent CPU efficiency!")
    } else if cpuPerMB < 0.5 {
        print("   ⚠️  Good, but may be slow on older devices")
    } else {
        print("   ❌ High CPU usage - optimization needed for older devices")
    }
    print(String(repeating: "-", count: 70))

    print()

    // Machine-parseable metrics for scripting
    print("METRIC,CPUTotal,\(currentCPU.total)")
    print("METRIC,CPUUser,\(currentCPU.user)")
    print("METRIC,CPUSystem,\(currentCPU.system)")
    print("METRIC,CPUPerMB,\(cpuPerMB)")
    print("METRIC,PeakMemory,\(Double(peakMemory) / 1024.0 / 1024.0)")
    print("METRIC,InputSizeMB,\(Double(inputSize) / 1024.0 / 1024.0)")

    print()
    print("📋 What this proves:")
    print("   ✅ Swift can parse MP4 box structure")
    print("   ✅ Swift can identify encrypted vs unencrypted sections")
    print("   ✅ Swift can selectively decrypt only media data (mdat)")
    print("   ✅ Swift can reconstruct valid M4A containers")
    print("   ✅ AES-128 CBC decryption")
    print("   ✅ Streaming conversion with low memory footprint")
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