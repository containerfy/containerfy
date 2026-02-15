import Foundation

/// Assembles a .app bundle from build artifacts and compose config.
///
/// Layout:
///   <name>.app/Contents/
///   +-- MacOS/Containerfy
///   +-- Resources/
///   |   +-- docker-compose.yml
///   |   +-- *.env
///   |   +-- vmlinuz-lts
///   |   +-- initramfs-lts
///   |   +-- vm-root.img.lz4
///   +-- Info.plist
enum BundleAssembler {

    enum AssemblyError: LocalizedError {
        case missingArtifact(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingArtifact(let name): return "Missing build artifact: \(name)"
            case .writeFailed(let reason): return "Bundle assembly failed: \(reason)"
            }
        }
    }

    /// Assembles a .app bundle from build artifacts.
    ///
    /// - Parameters:
    ///   - config: Parsed compose config with metadata
    ///   - buildResult: Paths to VM artifacts from VMBuilder
    ///   - outputPath: Output path for the .app bundle (without .app suffix)
    static func assemble(
        config: ComposeConfig,
        buildResult: VMBuilder.BuildResult,
        outputPath: String
    ) throws {
        let fm = FileManager.default

        let appDir = outputPath.hasSuffix(".app") ? outputPath : outputPath + ".app"
        let contentsDir = (appDir as NSString).appendingPathComponent("Contents")
        let macosDir = (contentsDir as NSString).appendingPathComponent("MacOS")
        let resourcesDir = (contentsDir as NSString).appendingPathComponent("Resources")

        // Create directory structure
        for dir in [macosDir, resourcesDir] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // Copy build artifacts to Resources
        let artifacts: [(src: String, dst: String)] = [
            (buildResult.rootImagePath, "vm-root.img.lz4"),
            (buildResult.kernelPath, "vmlinuz-lts"),
            (buildResult.initramfsPath, "initramfs-lts"),
        ]

        for (src, dstName) in artifacts {
            let dst = (resourcesDir as NSString).appendingPathComponent(dstName)
            guard fm.fileExists(atPath: src) else {
                throw AssemblyError.missingArtifact(dstName)
            }
            try fm.copyItem(atPath: src, toPath: dst)
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

        // Copy current binary as the app binary
        let binaryDst = (macosDir as NSString).appendingPathComponent("Containerfy")
        let binarySrc = findBinary()

        if let src = binarySrc {
            try fm.copyItem(atPath: src, toPath: binaryDst)
            // Ensure executable
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryDst)
        } else {
            print("  Warning: Containerfy binary not found — bundle needs manual binary placement at:")
            print("  \(binaryDst)")
        }

        print("  -> \(appDir)")
    }

    // MARK: - Binary Discovery

    private static func findBinary() -> String? {
        // First: use our own executable path
        let selfPath = CommandLine.arguments[0]
        if FileManager.default.fileExists(atPath: selfPath) {
            return selfPath
        }

        // Fallback locations
        let candidates = [
            "Containerfy",
            "Containerfy.app/Contents/MacOS/Containerfy",
            ".build/release/Containerfy",
            ".build/debug/Containerfy",
        ]
        for c in candidates {
            if FileManager.default.fileExists(atPath: c) {
                return c
            }
        }
        return nil
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
