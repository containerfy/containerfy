import Foundation

enum Paths {
    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Containerfy")
    }

    static var stateFileURL: URL {
        applicationSupport.appendingPathComponent("state.json")
    }

    /// Compose file from the app bundle (placed there by `containerfy pack`)
    static var composeFileURL: URL? {
        Bundle.main.url(forResource: "docker-compose", withExtension: "yml")
    }

    /// Fallback compose file in Application Support (for development/testing)
    static var composeFileFallbackURL: URL {
        applicationSupport.appendingPathComponent("docker-compose.yml")
    }

    /// Path to the podman binary. Checks app bundle first (packed apps), then common install locations.
    static var podmanBinary: URL {
        if let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("podman"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }

        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/podman"),
            URL(fileURLWithPath: "/usr/local/bin/podman"),
        ]
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return URL(fileURLWithPath: "/opt/homebrew/bin/podman")
    }

    static func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )
    }
}
