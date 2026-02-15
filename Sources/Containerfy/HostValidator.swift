import Foundation
import Virtualization

struct HostValidationResult {
    let canProceed: Bool
    let errors: [String]
    let warnings: [String]
}

enum HostValidator {
    static func validate() -> HostValidationResult {
        var errors: [String] = []
        var warnings: [String] = []

        // Hard fail: wrong architecture (must be arm64)
        #if !arch(arm64)
        errors.append("Containerfy requires Apple Silicon (arm64)")
        #endif

        // Hard fail: macOS version < 14
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 14 {
            errors.append("Containerfy requires macOS 14 (Sonoma) or later")
        }

        // Hard fail: insufficient physical memory (< 2 GB)
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let memoryGB = Double(physicalMemory) / (1024 * 1024 * 1024)
        if memoryGB < 2.0 {
            errors.append("Insufficient memory: \(String(format: "%.1f", memoryGB)) GB available, 2 GB required")
        }

        // Hard fail: insufficient disk space (< 1 GB free)
        if let freeSpace = freeDiskSpaceBytes() {
            let freeGB = Double(freeSpace) / (1024 * 1024 * 1024)
            if freeGB < 1.0 {
                errors.append("Insufficient disk space: \(String(format: "%.1f", freeGB)) GB free, 1 GB required")
            }
        }

        // Hard fail: Virtualization.framework not supported
        if !VZVirtualMachine.isSupported {
            errors.append("Virtualization.framework is not supported on this Mac")
        }

        // Soft warn: CPU cores < 4
        let cpuCount = ProcessInfo.processInfo.processorCount
        if cpuCount < 4 {
            warnings.append("Low CPU count (\(cpuCount) cores). Performance may be degraded; 4+ cores recommended")
        }

        return HostValidationResult(
            canProceed: errors.isEmpty,
            errors: errors,
            warnings: warnings
        )
    }

    private static func freeDiskSpaceBytes() -> Int64? {
        let url = Paths.applicationSupport
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else {
            // Fallback: try the home directory
            let home = FileManager.default.homeDirectoryForCurrentUser
            guard let homeValues = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else {
                return nil
            }
            return homeValues.volumeAvailableCapacityForImportantUsage
        }
        return values.volumeAvailableCapacityForImportantUsage
    }
}
