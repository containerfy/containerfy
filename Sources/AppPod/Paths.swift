import Foundation

enum Paths {
    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AppPod")
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

    static func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )
    }
}
