import Foundation

/// Thin wrapper around Apple's signing + notarization CLI tools.
///
/// Pipeline: resolve identity → sign .app → verify → DMG → sign DMG → notarize → staple.
enum CodeSigner {

    /// Full signing + packaging pipeline. Returns path to the notarized DMG.
    static func signAndPackage(
        appPath: String,
        appName: String,
        outputDir: String,
        keychainProfile: String,
        onProgress: (String) -> Void
    ) throws -> String {
        // 1. Resolve signing identity
        onProgress("Resolving signing identity...")
        let identity = try resolveIdentity()

        // 2. Sign .app
        onProgress("Signing \(appName).app...")
        let entitlements = "Resources/Entitlements.plist"
        var codesignArgs = ["--force", "--sign", identity, "--options", "runtime", "--timestamp", "--deep"]
        if FileManager.default.fileExists(atPath: entitlements) {
            codesignArgs += ["--entitlements", entitlements]
        }
        codesignArgs.append(appPath)
        let signResult = try run("/usr/bin/codesign", arguments: codesignArgs)
        guard signResult.exitCode == 0 else { fatal("codesign failed: \(signResult.stderr)") }

        // 3. Verify
        onProgress("Verifying signature...")
        let verifyResult = try run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", appPath])
        guard verifyResult.exitCode == 0 else { fatal("Verification failed: \(verifyResult.stderr)") }

        // 4. Create DMG
        onProgress("Creating DMG...")
        let stagingDir = NSTemporaryDirectory() + "containerfy-dmg-\(ProcessInfo.processInfo.globallyUniqueString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: stagingDir) }
        try fm.copyItem(atPath: appPath, toPath: (stagingDir as NSString).appendingPathComponent((appPath as NSString).lastPathComponent))
        try fm.createSymbolicLink(atPath: (stagingDir as NSString).appendingPathComponent("Applications"), withDestinationPath: "/Applications")

        let dmgPath = (outputDir as NSString).appendingPathComponent("\(appName).dmg")
        if fm.fileExists(atPath: dmgPath) { try fm.removeItem(atPath: dmgPath) }
        let dmgResult = try run("/usr/bin/hdiutil", arguments: ["create", "-volname", appName, "-srcfolder", stagingDir, "-ov", "-format", "UDZO", dmgPath])
        guard dmgResult.exitCode == 0 else { fatal("DMG creation failed: \(dmgResult.stderr)") }

        // 5. Sign DMG
        onProgress("Signing DMG...")
        let dmgSignResult = try run("/usr/bin/codesign", arguments: ["--force", "--sign", identity, "--timestamp", dmgPath])
        guard dmgSignResult.exitCode == 0 else { fatal("DMG signing failed: \(dmgSignResult.stderr)") }

        // 6. Notarize
        onProgress("Submitting for notarization (this may take several minutes)...")
        let notarizeResult = try run("/usr/bin/xcrun", arguments: [
            "notarytool", "submit", dmgPath, "--keychain-profile", keychainProfile, "--wait",
        ])
        guard notarizeResult.exitCode == 0 else {
            fatal("""
                Notarization failed: \(notarizeResult.stderr.isEmpty ? notarizeResult.stdout : notarizeResult.stderr)
                Set up credentials: xcrun notarytool store-credentials \(keychainProfile)
                """)
        }

        // 7. Staple (non-fatal)
        onProgress("Stapling notarization ticket...")
        let stapleResult = try run("/usr/bin/xcrun", arguments: ["stapler", "staple", dmgPath])
        if stapleResult.exitCode != 0 {
            printWarning("Stapling failed (Gatekeeper will verify online): \(stapleResult.stderr)")
        }

        return dmgPath
    }

    /// Parse `security find-identity` output. Auto-pick if one, prompt if multiple.
    static func resolveIdentity() throws -> String {
        let result = try run("/usr/bin/security", arguments: ["find-identity", "-v", "-p", "codesigning"])
        guard result.exitCode == 0 else { fatal("security find-identity failed: \(result.stderr)") }

        let pattern = #"^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"(.+)"$"#
        let regex = try NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
        let range = NSRange(result.stdout.startIndex..., in: result.stdout)
        var identities: [(hash: String, name: String)] = []
        regex.enumerateMatches(in: result.stdout, range: range) { match, _, _ in
            guard let match = match,
                  let hashRange = Range(match.range(at: 1), in: result.stdout),
                  let nameRange = Range(match.range(at: 2), in: result.stdout) else { return }
            identities.append((hash: String(result.stdout[hashRange]), name: String(result.stdout[nameRange])))
        }

        guard !identities.isEmpty else {
            fatal("No signing identities found. Install a Developer ID certificate from developer.apple.com")
        }
        if identities.count == 1 { return identities[0].hash }

        // Multiple — prompt
        print("\nAvailable signing identities:")
        for (i, id) in identities.enumerated() {
            print("  \(i + 1)) \(id.name)")
        }
        while true {
            print("Select identity (1-\(identities.count)): ", terminator: "")
            guard let line = readLine(), let choice = Int(line), choice >= 1, choice <= identities.count else {
                print("Invalid selection.")
                continue
            }
            return identities[choice - 1].hash
        }
    }

    // MARK: - Helpers

    private static func run(_ executable: String, arguments: [String]) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (stdout, stderr, process.terminationStatus)
    }

    private static func fatal(_ message: String) -> Never {
        var stderr = FileHandle.standardError
        print("Error: \(message)", to: &stderr)
        exit(1)
    }

    private static func printWarning(_ message: String) {
        var stderr = FileHandle.standardError
        print("Warning: \(message)", to: &stderr)
    }
}
