import Foundation

/// Assembles a .app bundle from compose config and podman binaries.
///
/// Layout:
///   <name>.app/Contents/
///   +-- MacOS/Containerfy
///   +-- MacOS/podman
///   +-- MacOS/vfkit
///   +-- MacOS/gvproxy
///   +-- Resources/
///   |   +-- docker-compose.yml
///   |   +-- *.env
///   +-- Info.plist
enum BundleAssembler {

    enum AssemblyError: LocalizedError {
        case missingArtifact(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingArtifact(let name): return "Missing: \(name)"
            case .writeFailed(let reason): return "Bundle assembly failed: \(reason)"
            }
        }
    }

    /// Locate podman, gvproxy, and vfkit binaries.
    /// Expects them in the same directory as the running Containerfy binary.
    static func findPodmanBinaries() throws -> (podman: String, gvproxy: String, vfkit: String) {
        let execPath = CommandLine.arguments[0]
        // Resolve symlinks (e.g. /usr/local/bin/containerfy → /usr/local/lib/containerfy/containerfy)
        let resolved = (execPath as NSString).resolvingSymlinksInPath
        let dir = (resolved as NSString).deletingLastPathComponent

        let podman = (dir as NSString).appendingPathComponent("podman")
        let gvproxy = (dir as NSString).appendingPathComponent("gvproxy")
        let vfkit = (dir as NSString).appendingPathComponent("vfkit")

        let fm = FileManager.default
        guard fm.fileExists(atPath: podman) else { throw AssemblyError.missingArtifact("podman not found at \(podman)") }
        guard fm.fileExists(atPath: gvproxy) else { throw AssemblyError.missingArtifact("gvproxy not found at \(gvproxy)") }
        guard fm.fileExists(atPath: vfkit) else { throw AssemblyError.missingArtifact("vfkit not found at \(vfkit)") }

        return (podman, gvproxy, vfkit)
    }

    /// Assembles a .app bundle.
    static func assemble(
        config: ComposeConfig,
        podmanPath: String,
        gvproxyPath: String,
        vfkitPath: String,
        outputPath: String,
        binaryPath: String? = nil,
        shell: ShellExecutor = SystemShellExecutor()
    ) throws {
        let fm = FileManager.default

        let appDir = outputPath.hasSuffix(".app") ? outputPath : outputPath + ".app"
        let contentsDir = (appDir as NSString).appendingPathComponent("Contents")
        let macosDir = (contentsDir as NSString).appendingPathComponent("MacOS")
        let resourcesDir = (contentsDir as NSString).appendingPathComponent("Resources")

        // Remove existing bundle if present
        if fm.fileExists(atPath: appDir) {
            try fm.removeItem(atPath: appDir)
        }

        // Create directory structure
        for dir in [macosDir, resourcesDir] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // Copy compose file
        if let composePath = config.composePath {
            let dst = (resourcesDir as NSString).appendingPathComponent("docker-compose.yml")
            try fm.copyItem(atPath: composePath, toPath: dst)
        }

        // Copy env files
        for envFile in config.envFiles {
            let fileName = (envFile as NSString).lastPathComponent
            let dst = (resourcesDir as NSString).appendingPathComponent(fileName)
            try fm.copyItem(atPath: envFile, toPath: dst)
        }

        // Generate Info.plist
        let plist = generateInfoPlist(config: config)
        let plistPath = (contentsDir as NSString).appendingPathComponent("Info.plist")
        try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)

        // Copy Containerfy binary
        let binaryDst = (macosDir as NSString).appendingPathComponent("Containerfy")
        let binarySrc = binaryPath ?? CommandLine.arguments[0]
        if fm.fileExists(atPath: binarySrc) {
            try fm.copyItem(atPath: binarySrc, toPath: binaryDst)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryDst)
        } else {
            print("  Warning: Containerfy binary not found at \(binarySrc)")
        }

        // Copy podman binary
        let podmanDst = (macosDir as NSString).appendingPathComponent("podman")
        try fm.copyItem(atPath: podmanPath, toPath: podmanDst)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: podmanDst)
        try adHocSignBinary(path: podmanDst, shell: shell)

        // Copy vfkit binary (needs VZ entitlements)
        let vfkitDst = (macosDir as NSString).appendingPathComponent("vfkit")
        try fm.copyItem(atPath: vfkitPath, toPath: vfkitDst)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vfkitDst)
        try signVFKit(path: vfkitDst, shell: shell)

        // Copy gvproxy binary
        let gvproxyDst = (macosDir as NSString).appendingPathComponent("gvproxy")
        try fm.copyItem(atPath: gvproxyPath, toPath: gvproxyDst)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gvproxyDst)
        try adHocSignBinary(path: gvproxyDst, shell: shell)

        // Ad-hoc sign the whole bundle
        try adHocSign(appPath: appDir, shell: shell)

        print("  -> \(appDir)")
    }

    // MARK: - Ad-hoc Signing

    static func adHocSign(appPath: String, shell: ShellExecutor = SystemShellExecutor()) throws {
        let result = try shell.run(
            executable: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", appPath]
        )
        if result.exitCode != 0 {
            print("  Warning: Ad-hoc signing failed: \(result.stderr)")
        }
    }

    static func adHocSignBinary(path: String, shell: ShellExecutor = SystemShellExecutor()) throws {
        let result = try shell.run(
            executable: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", path]
        )
        if result.exitCode != 0 {
            print("  Warning: Ad-hoc signing of \(path) failed: \(result.stderr)")
        }
    }

    // MARK: - vfkit Signing

    static func signVFKit(path: String, shell: ShellExecutor = SystemShellExecutor()) throws {
        let entitlementsPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.security.virtualization</key>
            <true/>
            <key>com.apple.security.network.server</key>
            <true/>
            <key>com.apple.security.network.client</key>
            <true/>
        </dict>
        </plist>
        """

        let tmpEntitlements = NSTemporaryDirectory() + "vfkit-entitlements-\(ProcessInfo.processInfo.globallyUniqueString).plist"
        try entitlementsPlist.write(toFile: tmpEntitlements, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpEntitlements) }

        let result = try shell.run(
            executable: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", "--entitlements", tmpEntitlements, path]
        )
        if result.exitCode != 0 {
            print("  Warning: vfkit signing failed: \(result.stderr)")
        }
    }

    // MARK: - Info.plist Generation

    private static func generateInfoPlist(config: ComposeConfig) -> String {
        let name = config.name ?? "Containerfy"
        let version = config.version ?? "1.0.0"
        let displayName = config.displayName ?? titleCase(name)

        var bundleID = config.identifier ?? "com.containerfy.\(name)"
        if !bundleID.contains(".") {
            bundleID = bundleID.replacingOccurrences(of: "/", with: ".")
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>CFBundleIdentifier</key>
        \t<string>\(bundleID)</string>
        \t<key>CFBundleName</key>
        \t<string>\(name)</string>
        \t<key>CFBundleDisplayName</key>
        \t<string>\(displayName)</string>
        \t<key>CFBundleExecutable</key>
        \t<string>Containerfy</string>
        \t<key>CFBundleVersion</key>
        \t<string>\(version)</string>
        \t<key>CFBundleShortVersionString</key>
        \t<string>\(version)</string>
        \t<key>CFBundlePackageType</key>
        \t<string>APPL</string>
        \t<key>CFBundleInfoDictionaryVersion</key>
        \t<string>6.0</string>
        \t<key>LSUIElement</key>
        \t<true/>
        \t<key>LSMinimumSystemVersion</key>
        \t<string>14.0</string>
        \t<key>NSHumanReadableCopyright</key>
        \t<string>Built with Containerfy</string>
        </dict>
        </plist>
        """
    }

    private static func titleCase(_ name: String) -> String {
        name.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}
