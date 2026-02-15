import Foundation

/// CLI `pack` command — orchestrates compose validation, VM-based build, .app assembly,
/// and optional signing + notarization.
///
/// Usage: containerfy pack [--compose <path>] [--output <path>] [--signed <keychain-profile>]
enum PackCommand {

    static func run(arguments: [String]) async {
        // Parse flags
        var composePath = "./docker-compose.yml"
        var outputPath: String?
        var signedProfile: String?

        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--compose":
                i += 1
                guard i < arguments.count else {
                    printError("--compose requires a path argument")
                    exit(1)
                }
                composePath = arguments[i]
            case "--output":
                i += 1
                guard i < arguments.count else {
                    printError("--output requires a path argument")
                    exit(1)
                }
                outputPath = arguments[i]
            case "--signed":
                i += 1
                guard i < arguments.count else {
                    printError("--signed requires a keychain profile name")
                    exit(1)
                }
                signedProfile = arguments[i]
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                printError("Unknown flag: \(arguments[i])")
                printUsage()
                exit(1)
            }
            i += 1
        }

        // Step 1: Parse and validate compose file
        printStep(1, "Parsing \(composePath)...")
        let config: ComposeConfig
        do {
            config = try ComposeConfigParser.parseBuild(composePath: composePath)
        } catch {
            printError("Compose validation failed: \(error.localizedDescription)")
            exit(1)
        }

        let name = config.name ?? "Containerfy"
        let version = config.version ?? "1.0.0"
        let identifier = config.identifier ?? "unknown"

        print("    App: \(name) v\(version) (\(identifier))")
        print("    Images: \(config.images.count), Ports: \(config.portMappings.map { String($0.hostPort) }.joined(separator: ", "))")
        if !config.envFiles.isEmpty {
            print("    Env files: \(config.envFiles.count)")
        }

        // Step 2: Verify base VM image is available
        printStep(2, "Checking VM base image...")
        let fm = FileManager.default
        guard fm.fileExists(atPath: VMBuilder.baseImagePath) else {
            printError("VM base image not found at \(VMBuilder.baseDir)")
            printError("Run the install script to download base images, or check ~/.containerfy/base/")
            exit(1)
        }
        print("    Base image: \(VMBuilder.baseDir)")

        // Prepare workspace directory with compose file and env files
        let workspaceDir = NSTemporaryDirectory() + "containerfy-workspace-\(ProcessInfo.processInfo.globallyUniqueString)"
        let artifactDir = NSTemporaryDirectory() + "containerfy-artifacts-\(ProcessInfo.processInfo.globallyUniqueString)"

        do {
            try fm.createDirectory(atPath: workspaceDir, withIntermediateDirectories: true)

            // Copy compose file to workspace
            if let composeSrc = config.composePath {
                let composeDst = (workspaceDir as NSString).appendingPathComponent("docker-compose.yml")
                try fm.copyItem(atPath: composeSrc, toPath: composeDst)
            }

            // Copy env files to workspace
            for envFile in config.envFiles {
                let fileName = (envFile as NSString).lastPathComponent
                let dst = (workspaceDir as NSString).appendingPathComponent(fileName)
                try fm.copyItem(atPath: envFile, toPath: dst)
            }
        } catch {
            printError("Failed to prepare workspace: \(error.localizedDescription)")
            exit(1)
        }

        defer {
            try? fm.removeItem(atPath: workspaceDir)
            try? fm.removeItem(atPath: artifactDir)
        }

        // Steps 3-6: Build root image via VM
        printStep(3, "Building root image via VM...")
        let buildResult: VMBuilder.BuildResult
        do {
            buildResult = try await VMBuilder.build(
                config: config,
                workspaceDir: workspaceDir,
                outputDir: artifactDir,
                onProgress: { status in
                    print("    \(status)")
                }
            )
        } catch {
            printError("Build failed: \(error.localizedDescription)")
            exit(1)
        }

        // Step 7: Assemble .app bundle
        let output = outputPath ?? "./\(name)"
        printStep(7, "Assembling .app bundle...")
        do {
            try BundleAssembler.assemble(
                config: config,
                buildResult: buildResult,
                outputPath: output
            )
        } catch {
            printError("Bundle assembly failed: \(error.localizedDescription)")
            exit(1)
        }

        let appPath = output.hasSuffix(".app") ? output : output + ".app"
        print("")

        if let profile = signedProfile {
            // Signed build: sign → verify → DMG → notarize → staple
            printStep(8, "Signing and packaging...")
            do {
                let outputDir = (appPath as NSString).deletingLastPathComponent
                let dmgPath = try CodeSigner.signAndPackage(
                    appPath: appPath,
                    appName: name,
                    outputDir: outputDir.isEmpty ? "." : outputDir,
                    keychainProfile: profile,
                    onProgress: { status in
                        print("    \(status)")
                    }
                )
                print("")
                print("Build complete: \(dmgPath)")
            } catch {
                printError("Signing failed: \(error.localizedDescription)")
                exit(1)
            }
        } else {
            // Unsigned (default)
            print("Build complete (unsigned): \(appPath)")
            print("Note: Unsigned apps will trigger a Gatekeeper warning on end-user machines.")
            print("      To sign and notarize: containerfy pack --signed <keychain-profile>")
            print("      Set up credentials:   xcrun notarytool store-credentials <profile-name>")
        }
    }

    // MARK: - Output Helpers

    private static func printStep(_ step: Int, _ message: String) {
        print("[\(step)] \(message)")
    }

    private static func printError(_ message: String) {
        var stderr = FileHandle.standardError
        stderr.write("Error: \(message)\n".data(using: .utf8)!)
    }

    private static func printUsage() {
        print("""
        Usage: containerfy pack [flags]

        Build a distributable .app bundle from a docker-compose.yml.
        By default, produces an unsigned .app. Use --signed to sign, notarize, and create a .dmg.

        Flags:
          --compose <path>           Path to docker-compose.yml (default: ./docker-compose.yml)
          --output <path>            Output path for .app bundle (default: ./<name> from x-containerfy)
          --signed <keychain-profile>  Sign .app, create .dmg, notarize, and staple.
                                       Requires a Developer ID certificate and keychain profile.
                                       Set up credentials: xcrun notarytool store-credentials <name>
          --help, -h                 Show this help message
        """)
    }
}

extension FileHandle: @retroactive TextOutputStream {
    public func write(_ string: String) {
        let data = Data(string.utf8)
        self.write(data)
    }
}
