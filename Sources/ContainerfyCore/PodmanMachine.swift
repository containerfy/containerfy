import Foundation

/// Manages a podman machine lifecycle: init, start, compose up/down, stop, remove.
/// Replaces the custom VFKit/gvproxy/vsock implementation with a simple shell-out to podman.
final class PodmanMachine: @unchecked Sendable {
    private let stateController: VMStateController
    private let machineName: String
    private let composeFileURL: URL?
    private let cpus: Int
    private let memoryMB: Int
    private let diskGB: Int
    private let shell: ShellExecutor

    private let logLock = NSLock()
    private var logBuffer: String = ""

    init(
        stateController: VMStateController,
        composeConfig: ComposeConfig,
        shell: ShellExecutor = SystemShellExecutor()
    ) {
        self.stateController = stateController
        self.shell = shell

        // Derive machine name from app identifier (e.g. "com.containerfy.test-app" → "containerfy-test-app")
        let name = composeConfig.name ?? "app"
        self.machineName = "containerfy-\(name)"

        // Compose file from bundle
        self.composeFileURL = Paths.composeFileURL ?? {
            let fallback = Paths.composeFileFallbackURL
            return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
        }()

        // VM resource config from compose
        self.cpus = composeConfig.cpuRecommended ?? composeConfig.cpuMin ?? 2
        self.memoryMB = composeConfig.memoryMBRecommended ?? composeConfig.memoryMBMin ?? 2048
        // Fedora CoreOS needs ~5GB for itself; enforce minimum 10GB
        self.diskGB = max(10, (composeConfig.diskMB ?? 10240) / 1024)
    }

    // MARK: - Lifecycle

    func startVM() async {
        await MainActor.run { _ = stateController.transition(to: .starting) }

        do {
            // Try starting existing machine
            appendLog("Starting podman machine '\(machineName)'...")
            let startResult = try runPodman(["machine", "start", machineName])

            if startResult.exitCode != 0 {
                let combined = startResult.stderr + " " + startResult.stdout

                if combined.lowercased().contains("does not exist") ||
                   combined.lowercased().contains("not exist") ||
                   combined.lowercased().contains("no machine") {
                    // Machine doesn't exist — init + start
                    appendLog("Machine not found, initializing...")
                    let initResult = try runPodman([
                        "machine", "init",
                        "--cpus", "\(cpus)",
                        "--memory", "\(memoryMB)",
                        "--disk-size", "\(diskGB)",
                        "--now",
                        machineName,
                    ])
                    if initResult.exitCode != 0 {
                        let msg = "podman machine init failed: \(initResult.stderr)"
                        appendLog(msg)
                        await MainActor.run { _ = stateController.transition(to: .error, reason: msg) }
                        return
                    }
                    appendLog("Machine initialized and started")
                } else if combined.lowercased().contains("already running") {
                    appendLog("Machine already running")
                } else {
                    let msg = "podman machine start failed: \(combined)"
                    appendLog(msg)
                    await MainActor.run { _ = stateController.transition(to: .error, reason: msg) }
                    return
                }
            } else {
                appendLog("Machine started")
            }

            // Run compose up
            if let composeURL = composeFileURL {
                appendLog("Running compose up...")
                let composeResult = try runPodman(["compose", "-f", composeURL.path, "up", "-d"])
                if composeResult.exitCode != 0 {
                    let msg = "podman compose up failed: \(composeResult.stderr)"
                    appendLog(msg)
                    await MainActor.run { _ = stateController.transition(to: .error, reason: msg) }
                    return
                }
                appendLog("Compose services started")
            } else {
                appendLog("No compose file found — machine running without services")
            }

            await MainActor.run { _ = stateController.transition(to: .running) }
        } catch {
            let msg = error.localizedDescription
            appendLog("Error: \(msg)")
            await MainActor.run { _ = stateController.transition(to: .error, reason: msg) }
        }
    }

    func stopVM() async {
        let current = await MainActor.run { stateController.currentState }
        guard current != .stopped, current != .stopping else { return }

        await MainActor.run { _ = stateController.transition(to: .stopping) }

        // Compose down
        if let composeURL = composeFileURL {
            appendLog("Running compose down...")
            let _ = try? runPodman(["compose", "-f", composeURL.path, "down"])
        }

        // Stop machine
        appendLog("Stopping podman machine '\(machineName)'...")
        let _ = try? runPodman(["machine", "stop", machineName])
        appendLog("Machine stopped")

        await MainActor.run { _ = stateController.transition(to: .stopped) }
    }

    func destroyVM() async {
        await stopVM()
        appendLog("Removing podman machine '\(machineName)'...")
        let _ = try? runPodman(["machine", "rm", "-f", machineName])
        appendLog("Machine removed")
    }

    func fetchLogs() async -> String? {
        let snapshot = getLogSnapshot()

        // Append container logs if compose is running
        var logs = snapshot
        if let composeURL = composeFileURL {
            if let result = try? runPodman(["compose", "-f", composeURL.path, "logs", "--tail", "100"]),
               result.exitCode == 0, !result.stdout.isEmpty {
                logs += "\n--- Container Logs ---\n" + result.stdout
            }
        }

        return logs.isEmpty ? nil : logs
    }

    private nonisolated func getLogSnapshot() -> String {
        logLock.lock()
        defer { logLock.unlock() }
        return logBuffer
    }

    // MARK: - Private

    /// Path to the podman binary. Checks app bundle (MacOS/) first, then system.
    private var podmanPath: String {
        if let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("podman"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }

        let candidates = ["/opt/homebrew/bin/podman", "/usr/local/bin/podman"]
        for p in candidates {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return "podman"
    }

    /// Environment for podman process — points to bundled helpers.
    private var podmanEnvironment: [String: String]? {
        guard let macosDir = Bundle.main.executableURL?.deletingLastPathComponent(),
              FileManager.default.fileExists(atPath: macosDir.appendingPathComponent("podman").path) else {
            return nil
        }
        var env = ProcessInfo.processInfo.environment
        env["CONTAINERS_HELPER_BINARY_DIR"] = macosDir.path
        return env
    }

    @discardableResult
    private func runPodman(_ arguments: [String]) throws -> ProcessResult {
        let path = podmanPath
        appendLog("$ podman \(arguments.joined(separator: " "))")
        let result = try shell.run(executable: path, arguments: arguments, environment: podmanEnvironment)
        if !result.stdout.isEmpty { appendLog(result.stdout) }
        if !result.stderr.isEmpty { appendLog(result.stderr) }
        return result
    }

    private func appendLog(_ message: String) {
        logLock.lock()
        logBuffer += message + "\n"
        logLock.unlock()
        print("[Podman] \(message)")
    }
}
