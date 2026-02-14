import Foundation
import Virtualization

@MainActor
final class VMLifecycleManager: NSObject, VZVirtualMachineDelegate {
    private var vm: VZVirtualMachine?
    private var healthCheck: VSockHealthCheck?
    private let stateController: VMStateController

    init(stateController: VMStateController) {
        self.stateController = stateController
        super.init()
    }

    // MARK: - VM Configuration (hardcoded for Phase 0)

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

        // Root disk
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: Paths.rootDiskURL,
            readOnly: false
        )
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

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
        guard stateController.transition(to: .startingVM) else { return }

        do {
            try Paths.ensureDirectoryExists()

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
                check.beginPolling()
            }
        } catch {
            print("[VM] Start failed: \(error.localizedDescription)")
            stateController.transition(to: .error)
        }
    }

    func stopVM() async {
        guard stateController.transition(to: .stopping) else { return }

        healthCheck?.stop()
        healthCheck = nil

        do {
            if let vm = vm {
                try await vm.stop()
                print("[VM] Stopped")
            }
        } catch {
            print("[VM] Stop error: \(error.localizedDescription)")
        }

        self.vm = nil
        stateController.transition(to: .stopped)
    }

    // MARK: - VZVirtualMachineDelegate

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("[VM] Guest did stop")
        Task { @MainActor in
            self.healthCheck?.stop()
            self.healthCheck = nil
            self.vm = nil
            self.stateController.transition(to: .stopped)
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        print("[VM] Stopped with error: \(error.localizedDescription)")
        Task { @MainActor in
            self.healthCheck?.stop()
            self.healthCheck = nil
            self.vm = nil
            self.stateController.transition(to: .error)
        }
    }
}
