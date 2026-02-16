import Foundation

/// CLI `pack` command — validates compose, locates podman binaries, assembles .app bundle,
/// and optionally signs + notarizes.
///
/// Usage: containerfy pack [--compose <path>] [--output <path>] [--signed <keychain-profile>]
public struct PackCommand {

    let signer: CodeSigner

    public init() {
        self.signer = CodeSigner()
    }

    init(signer: CodeSigner) {
        self.signer = signer
    }

    /// Runs the pack command. Returns an exit code (0 = success).
    public func run(arguments: [String]) -> Int32 {
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
                    Self.printError("--compose requires a path argument")
                    return 1
                }
                composePath = arguments[i]
            case "--output":
                i += 1
                guard i < arguments.count else {
                    Self.printError("--output requires a path argument")
                    return 1
                }
                outputPath = arguments[i]
            case "--signed":
                i += 1
                guard i < arguments.count else {
                    Self.printError("--signed requires a keychain profile name")
                    return 1
                }
                signedProfile = arguments[i]
            case "--help", "-h":
                Self.printUsage()
                return 0
            default:
                Self.printError("Unknown flag: \(arguments[i])")
                Self.printUsage()
                return 1
            }
            i += 1
        }

        // Step 1: Parse and validate compose file
        Self.printStep(1, "Parsing \(composePath)...")
        let config: ComposeConfig
        do {
            config = try ComposeConfigParser.parseBuild(composePath: composePath)
        } catch {
            Self.printError("Compose validation failed: \(error.localizedDescription)")
            return 1
        }

        let name = config.name ?? "Containerfy"
        let version = config.version ?? "1.0.0"
        let identifier = config.identifier ?? "unknown"

        print("    App: \(name) v\(version) (\(identifier))")
        print("    Images: \(config.images.count), Ports: \(config.portMappings.map { String($0.hostPort) }.joined(separator: ", "))")

        // Step 2: Locate podman binaries (must be alongside the containerfy binary)
        Self.printStep(2, "Locating podman binaries...")
        let podmanPath: String
        let gvproxyPath: String
        let vfkitPath: String
        do {
            (podmanPath, gvproxyPath, vfkitPath) = try BundleAssembler.findPodmanBinaries()
            print("    podman:  \(podmanPath)")
            print("    gvproxy: \(gvproxyPath)")
            print("    vfkit:   \(vfkitPath)")
        } catch {
            Self.printError("\(error.localizedDescription)")
            return 1
        }

        // Step 3: Assemble .app bundle
        let output = outputPath ?? "./\(name)"
        Self.printStep(3, "Assembling .app bundle...")
        do {
            try BundleAssembler.assemble(
                config: config,
                podmanPath: podmanPath,
                gvproxyPath: gvproxyPath,
                vfkitPath: vfkitPath,
                outputPath: output
            )
        } catch {
            Self.printError("Bundle assembly failed: \(error.localizedDescription)")
            return 1
        }

        let appPath = output.hasSuffix(".app") ? output : output + ".app"
        print("")

        if let profile = signedProfile {
            Self.printStep(4, "Signing and packaging...")
            do {
                let outputDir = (appPath as NSString).deletingLastPathComponent
                let dmgPath = try signer.signAndPackage(
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
                Self.printError("Signing failed: \(error.localizedDescription)")
                return 1
            }
        } else {
            print("Build complete (unsigned): \(appPath)")
            print("Note: Unsigned apps will trigger a Gatekeeper warning on end-user machines.")
            print("      To sign and notarize: containerfy pack --signed <keychain-profile>")
        }

        return 0
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
        Requires podman installed (brew install podman).

        Flags:
          --compose <path>           Path to docker-compose.yml (default: ./docker-compose.yml)
          --output <path>            Output path for .app bundle (default: ./<name> from x-containerfy)
          --signed <keychain-profile>  Sign .app, create .dmg, notarize, and staple.
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
