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

    static func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )
    }
}
