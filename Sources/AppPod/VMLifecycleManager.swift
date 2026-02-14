import Foundation
import Virtualization

@MainActor
final class VMLifecycleManager: NSObject, VZVirtualMachineDelegate {
    private var vm: VZVirtualMachine?
    private var healthCheck: VSockHealthCheck?
    private var portForwarder: PortForwarder?
    private var healthMonitor: HealthMonitor?
    private let stateController: VMStateController
    private var composeConfig: ComposeConfig = .empty

    /// Read-only access to the underlying VM for pause/resume.
    var virtualMachine: VZVirtualMachine? { vm }

    /// Read-only access to the port forwarder for sleep/wake rebuild.
    var currentPortForwarder: PortForwarder? { portForwarder }

    // Auto-restart state
    private var autoRestartCount = 0
    private let maxAutoRestarts = 3
    private var autoRestartEnabled = true

    /// Callback when disk usage exceeds threshold.
    var onDiskWarning: ((Int, Int) -> Void)?

    init(stateController: VMStateController) {
        self.stateController = stateController
        super.init()
    }

    func setComposeConfig(_ config: ComposeConfig) {
        self.composeConfig = config
    }

    // MARK: - VM Configuration

    private func createConfiguration() throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()

        // CPU & Memory
        config.cpuCount = 4
        config.memorySize = 4 * 1024 * 1024 * 1024 // 4 GB

        // Boot loader
        let bootLoader = VZLinuxBootLoader(kernelURL: Paths.kernelURL)
        bootLoader.commandLine = "console=hvc0 root=/dev/vda rw"
        bootLoader.initialRamdiskURL = Paths.initramfsURL
        config.bootLoader = bootLoader

        // Dual-disk: root (/dev/vda) + data (/dev/vdb)
        let rootAttachment = try VZDiskImageStorageDeviceAttachment(
            url: Paths.rootDiskURL,
            readOnly: false
        )
        let dataAttachment = try VZDiskImageStorageDeviceAttachment(
            url: Paths.dataDiskURL,
            readOnly: false
        )
        config.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: rootAttachment),
            VZVirtioBlockDeviceConfiguration(attachment: dataAttachment),
        ]

        // Networking (NAT for outbound internet)
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [networkDevice]

        // vsock
        let vsockDevice = VZVirtioSocketDeviceConfiguration()
        config.socketDevices = [vsockDevice]

        // Virtio console (stdout for debugging)
        let consoleDevice = VZVirtioConsoleDeviceConfiguration()
        let serialPort = VZVirtioConsolePortConfiguration()
        serialPort.name = "console"
        serialPort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: FileHandle.nullDevice,
            fileHandleForWriting: FileHandle.standardOutput
        )
        consoleDevice.ports[0] = serialPort
        config.consoleDevices = [consoleDevice]

        // Entropy
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Memory balloon
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        try config.validate()
        return config
    }

    // MARK: - Lifecycle

    func startVM() async {
        // Host validation
        guard stateController.transition(to: .validatingHost) else { return }

        let validation = HostValidator.validate()
        for warning in validation.warnings {
            print("[Validation] Warning: \(warning)")
        }
        guard validation.canProceed else {
            let reason = validation.errors.joined(separator: "; ")
            print("[Validation] Failed: \(reason)")
            stateController.transition(to: .error, reason: reason)
            return
        }

        do {
            try Paths.ensureDirectoryExists()

            // First-launch decompression if root disk doesn't exist
            if DiskManager.needsFirstLaunchDecompression {
                guard stateController.transition(to: .preparingFirstLaunch) else { return }
                try DiskManager.decompressRootDisk()
            }

            // Ensure data disk exists
            try DiskManager.createDataDisk()

            // Pre-validate ports before starting the VM
            if !composeConfig.portMappings.isEmpty {
                for mapping in composeConfig.portMappings {
                    guard PortForwarder.isPortAvailable(mapping.hostPort) else {
                        throw PortForwarder.PortForwarderError.portInUse(mapping.hostPort)
                    }
                }
                print("[Ports] All \(composeConfig.portMappings.count) port(s) available")
            }

            guard stateController.transition(to: .startingVM) else { return }

            let config = try createConfiguration()
            let virtualMachine = VZVirtualMachine(configuration: config)
            virtualMachine.delegate = self
            self.vm = virtualMachine

            try await virtualMachine.start()
            print("[VM] Started successfully")

            guard stateController.transition(to: .waitingForHealth) else { return }

            // Begin health polling over vsock
            if let socketDevice = virtualMachine.socketDevices.first as? VZVirtioSocketDevice {
                let check = VSockHealthCheck(
                    socketDevice: socketDevice,
                    stateController: stateController
                )
                self.healthCheck = check

                // When vsock health succeeds (→ .running), start port forwarding + HTTP monitoring
                check.onHealthy = { [weak self] in
                    Task { @MainActor in
                        await self?.startPostBootServices()
                    }
                }

                check.beginPolling()
            }
        } catch {
            print("[VM] Start failed: \(error.localizedDescription)")
            stateController.transition(to: .error, reason: error.localizedDescription)
        }
    }

    func stopVM() async {
        guard stateController.transition(to: .stopping) else { return }

        // Stop monitoring and forwarding first
        stopPostBootServices()

        healthCheck?.stop()
        healthCheck = nil

        guard let vm = vm else {
            self.vm = nil
            stateController.transition(to: .stopped)
            return
        }

        // Step 1: Send SHUTDOWN via vsock (5s timeout for ACK)
        var gracefulShutdownInitiated = false
        if let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice {
            print("[VM] Sending SHUTDOWN command...")
            gracefulShutdownInitiated = await VSockControl.sendShutdown(to: socketDevice)
            if gracefulShutdownInitiated {
                print("[VM] SHUTDOWN ACK received, waiting for guest to stop...")
            } else {
                print("[VM] SHUTDOWN ACK not received")
            }
        }

        // Step 2: Wait for guest to stop gracefully (30s)
        if gracefulShutdownInitiated {
            let stopped = await waitForVMState(.stopped, timeout: 30.0)
            if stopped {
                print("[VM] Guest stopped gracefully")
                self.vm = nil
                if stateController.currentState != .stopped {
                    stateController.transition(to: .stopped)
                }
                return
            }
            print("[VM] Guest did not stop within 30s")
        }

        // Step 3: ACPI power button (requestStop) + wait 10s
        do {
            try vm.requestStop()
            print("[VM] ACPI power button sent, waiting 10s...")
            let stopped = await waitForVMState(.stopped, timeout: 10.0)
            if stopped {
                print("[VM] Guest stopped via ACPI")
                self.vm = nil
                if stateController.currentState != .stopped {
                    stateController.transition(to: .stopped)
                }
                return
            }
        } catch {
            print("[VM] requestStop failed: \(error.localizedDescription)")
        }

        // Step 4: Force kill
        do {
            try await vm.stop()
            print("[VM] Force stopped")
        } catch {
            print("[VM] Force stop error: \(error.localizedDescription)")
        }

        self.vm = nil
        stateController.transition(to: .stopped)
    }

    /// Waits for the VM to reach `.stopped` state or timeout.
    private func waitForVMState(_ targetState: VMState, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if stateController.currentState == targetState || vm == nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }
        return stateController.currentState == targetState || vm == nil
    }

    func restartVM() async {
        print("[VM] Restarting...")
        autoRestartCount = 0 // Manual restart resets counter
        await stopVM()
        await startVM()
    }

    func destroyVM() async {
        if vm != nil {
            await stopVM()
        }

        guard stateController.transition(to: .destroying) else { return }

        DiskManager.destroyAllDisks()
        StateFile.remove()
        print("[VM] All VM data destroyed")

        stateController.transition(to: .stopped)
    }

    // MARK: - Post-Boot Services (Port Forwarding + Health Monitoring)

    private func startPostBootServices() async {
        guard let vm = vm,
              let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else { return }

        // Start port forwarding
        if !composeConfig.portMappings.isEmpty {
            let forwarder = PortForwarder(
                socketDevice: socketDevice,
                portMappings: composeConfig.portMappings
            )
            do {
                try await forwarder.start()
                self.portForwarder = forwarder
            } catch {
                print("[Ports] Port forwarding failed: \(error.localizedDescription)")
                // Port forwarding failure is not fatal — log and continue
            }
        }

        // Start HTTP health monitoring (if configured)
        if let hcConfig = composeConfig.healthCheck {
            let monitor = HealthMonitor(
                config: hcConfig,
                socketDevice: socketDevice,
                stateController: stateController
            )

            monitor.onDiskWarning = { [weak self] used, total in
                self?.onDiskWarning?(used, total)
            }

            monitor.onHealthFailure = { [weak self] in
                Task { @MainActor in
                    self?.handleHealthFailure()
                }
            }

            monitor.startMonitoring()
            self.healthMonitor = monitor
        }
    }

    private func stopPostBootServices() {
        healthMonitor?.stop()
        healthMonitor = nil
        portForwarder?.stop()
        portForwarder = nil
    }

    // MARK: - Error Recovery (Auto-Restart)

    private func handleHealthFailure() {
        guard autoRestartEnabled else {
            stateController.transition(to: .error, reason: "Health check failed (auto-restart disabled)")
            return
        }

        autoRestartCount += 1

        if autoRestartCount > maxAutoRestarts {
            print("[Recovery] Max auto-restarts (\(maxAutoRestarts)) exceeded — giving up")
            autoRestartEnabled = false
            stateController.transition(to: .error, reason: "Health check failed after \(maxAutoRestarts) restart attempts")
            return
        }

        print("[Recovery] Health failure detected — auto-restart attempt \(autoRestartCount)/\(maxAutoRestarts)")
        stateController.transition(to: .error, reason: "Health check failed — restarting...")

        Task {
            // Brief delay before restart
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self.stopVM()
            await self.startVM()
        }
    }

    /// Resets auto-restart counter. Called when user manually starts/restarts.
    func resetAutoRestart() {
        autoRestartCount = 0
        autoRestartEnabled = true
    }

    // MARK: - VZVirtualMachineDelegate

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("[VM] Guest did stop")
        Task { @MainActor in
            self.stopPostBootServices()
            self.healthCheck?.stop()
            self.healthCheck = nil
            self.vm = nil
            self.stateController.transition(to: .stopped)
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        print("[VM] Stopped with error: \(error.localizedDescription)")
        Task { @MainActor in
            self.stopPostBootServices()
            self.healthCheck?.stop()
            self.healthCheck = nil
            self.vm = nil
            self.stateController.transition(to: .error, reason: error.localizedDescription)
        }
    }
}

// MARK: - PortForwarder public helper (used by VMLifecycleManager for pre-validation)

extension PortForwarder {
    /// Public wrapper for port availability check.
    nonisolated static func isPortAvailable(_ port: UInt16) -> Bool {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
