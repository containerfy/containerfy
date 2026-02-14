import Foundation

enum DiskManager {
    static var needsFirstLaunchDecompression: Bool {
        !FileManager.default.fileExists(atPath: Paths.rootDiskURL.path)
    }

    /// Decompresses the lz4-compressed root disk from the app bundle.
    /// Uses /usr/bin/lz4 which ships with macOS.
    static func decompressRootDisk() throws {
        guard let compressedURL = Paths.compressedRootDiskURL else {
            throw DiskError.compressedImageNotFound
        }

        guard FileManager.default.fileExists(atPath: compressedURL.path) else {
            throw DiskError.compressedImageNotFound
        }

        print("[Disk] Decompressing root disk from \(compressedURL.lastPathComponent)...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lz4")
        process.arguments = ["-d", "-f", compressedURL.path, Paths.rootDiskURL.path]

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw DiskError.decompressionFailed(stderr)
        }

        print("[Disk] Root disk decompressed successfully")
    }

    /// Creates a sparse data disk image if it doesn't already exist.
    static func createDataDisk(sizeMB: Int = 10240) throws {
        let url = Paths.dataDiskURL
        guard !FileManager.default.fileExists(atPath: url.path) else {
            print("[Disk] Data disk already exists")
            return
        }

        print("[Disk] Creating sparse data disk (\(sizeMB) MB)...")

        // Create a sparse file — only consumes actual written blocks on disk
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(sizeMB) * 1024 * 1024)
        try handle.close()

        print("[Disk] Data disk created at \(url.path)")
    }

    /// Removes all VM disk images and state files.
    static func destroyAllDisks() {
        let fm = FileManager.default
        for url in [Paths.rootDiskURL, Paths.dataDiskURL] {
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
                print("[Disk] Removed \(url.lastPathComponent)")
            }
        }
    }

    enum DiskError: LocalizedError {
        case compressedImageNotFound
        case decompressionFailed(String)

        var errorDescription: String? {
            switch self {
            case .compressedImageNotFound:
                return "Compressed root disk image (vm-root.img.lz4) not found in app bundle"
            case .decompressionFailed(let detail):
                return "lz4 decompression failed: \(detail)"
            }
        }
    }
}
