import Foundation

enum Paths {
    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Containerfy")
    }

    static var kernelURL: URL {
        applicationSupport.appendingPathComponent("vmlinuz-lts")
    }

    static var initramfsURL: URL {
        applicationSupport.appendingPathComponent("initramfs-lts")
    }

    static var rootDiskURL: URL {
        applicationSupport.appendingPathComponent("vm-root.img")
    }

    static var dataDiskURL: URL {
        applicationSupport.appendingPathComponent("vm-data.img")
    }

    static var stateFileURL: URL {
        applicationSupport.appendingPathComponent("state.json")
    }

    static var compressedRootDiskURL: URL? {
        Bundle.main.url(forResource: "vm-root.img", withExtension: "lz4")
    }

    /// Compose file from the app bundle (placed there by `containerfy pack`)
    static var composeFileURL: URL? {
        Bundle.main.url(forResource: "docker-compose", withExtension: "yml")
    }

    /// Fallback compose file in Application Support (for development/testing)
    static var composeFileFallbackURL: URL {
        applicationSupport.appendingPathComponent("docker-compose.yml")
    }

    static func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )
    }
}
