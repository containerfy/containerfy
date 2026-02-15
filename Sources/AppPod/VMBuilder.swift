import Foundation
import Virtualization

/// Boots the pre-built VM base image and uses Docker inside it to pull app images
/// and create a compressed ext4 root disk with everything baked in.
enum VMBuilder {

    struct BuildResult {
        let rootImagePath: String   // vm-root.img.lz4
        let kernelPath: String      // vmlinuz-lts
        let initramfsPath: String   // initramfs-lts
    }

    enum BuildError: LocalizedError {
        case baseImageNotFound(String)
        case vmBootFailed(String)
        case healthTimeout
        case buildFailed(String)
        case packFailed(String)
        case artifactsMissing(String)

        var errorDescription: String? {
            switch self {
            case .baseImageNotFound(let path): return "VM base image not found: \(path)"
            case .vmBootFailed(let reason): return "VM boot failed: \(reason)"
            case .healthTimeout: return "VM did not become healthy within timeout"
            case .buildFailed(let reason): return "Image pull failed: \(reason)"
            case .packFailed(let reason): return "Pack failed: \(reason)"
            case .artifactsMissing(let name): return "Expected artifact not found: \(name)"
            }
        }
    }

    /// Base image location: ~/.apppod/base/
    static var baseDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".apppod/base")
    }

    static var baseImagePath: String { (baseDir as NSString).appendingPathComponent("vm-base.img.lz4") }
    static var baseKernelPath: String { (baseDir as NSString).appendingPathComponent("vmlinuz-lts") }
    static var baseInitramfsPath: String { (baseDir as NSString).appendingPathComponent("initramfs-lts") }

    /// Build a root image by booting the VM, pulling images, and creating ext4.
    ///
    /// - Parameters:
    ///   - config: Parsed compose config with images list
    ///   - workspaceDir: Directory containing docker-compose.yml and env files
    ///   - outputDir: Directory where artifacts will be written
    ///   - onProgress: Progress callback for status updates
    @MainActor
    static func build(
        config: ComposeConfig,
        workspaceDir: String,
        outputDir: String,
        onProgress: @escaping (String) -> Void
    ) async throws -> BuildResult {
        let fm = FileManager.default

        // Verify base image exists
        guard fm.fileExists(atPath: baseImagePath) else {
            throw BuildError.baseImageNotFound(baseImagePath)
        }
        guard fm.fileExists(atPath: baseKernelPath) else {
            throw BuildError.baseImageNotFound(baseKernelPath)
        }
        guard fm.fileExists(atPath: baseInitramfsPath) else {
            throw BuildError.baseImageNotFound(baseInitramfsPath)
        }

        // Create temp directory for writable VM root copy
        let tempDir = NSTemporaryDirectory() + "apppod-build-\(ProcessInfo.processInfo.globallyUniqueString)"
        try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tempDir) }

        let tempRootPath = (tempDir as NSString).appendingPathComponent("vm-root.img")
        let tempKernelPath = (tempDir as NSString).appendingPathComponent("vmlinuz-lts")
        let tempInitramfsPath = (tempDir as NSString).appendingPathComponent("initramfs-lts")

        // Decompress base image to temp (writable copy)
        onProgress("Decompressing VM base image...")
        try decompressLZ4(src: baseImagePath, dst: tempRootPath)
        try fm.copyItem(atPath: baseKernelPath, toPath: tempKernelPath)
        try fm.copyItem(atPath: baseInitramfsPath, toPath: tempInitramfsPath)

        // Create temp data disk for build workspace
        let dataDiskPath = (tempDir as NSString).appendingPathComponent("vm-data.img")
        try createSparseDisk(at: dataDiskPath, sizeGB: 10)

        // Ensure output directory exists
        try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        // Configure and boot VM
        onProgress("Booting build VM...")
        let vmConfig = try createBuildVMConfiguration(
            kernelPath: tempKernelPath,
            initramfsPath: tempInitramfsPath,
            rootDiskPath: tempRootPath,
            dataDiskPath: dataDiskPath,
            workspaceDir: workspaceDir,
            outputDir: outputDir
        )

        let vm = VZVirtualMachine(configuration: vmConfig)

        try await vm.start()
        onProgress("VM started, waiting for health...")

        // Wait for VM agent health
        guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw BuildError.vmBootFailed("No vsock device found")
        }

        let healthy = try await waitForHealth(device: socketDevice, timeout: 120)
        guard healthy else {
            throw BuildError.healthTimeout
        }
        onProgress("VM healthy")

        // Send BUILD command with image list
        if !config.images.isEmpty {
            let imageList = config.images.joined(separator: ",")
            onProgress("Pulling \(config.images.count) image(s) inside VM...")
            try await sendBuildCommand(device: socketDevice, images: imageList, onProgress: onProgress)
        }

        // Send PACK command to create ext4
        onProgress("Creating root image...")
        try await sendPackCommand(device: socketDevice, onProgress: onProgress)

        // Shut down VM gracefully
        onProgress("Shutting down build VM...")
        _ = await VSockControl.sendShutdown(to: socketDevice)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        try? await vm.stop()

        // Verify artifacts exist in output directory
        let rootImgPath = (outputDir as NSString).appendingPathComponent("vm-root.img.lz4")
        let kernelOutPath = (outputDir as NSString).appendingPathComponent("vmlinuz-lts")
        let initramfsOutPath = (outputDir as NSString).appendingPathComponent("initramfs-lts")

        guard fm.fileExists(atPath: rootImgPath) else {
            throw BuildError.artifactsMissing("vm-root.img.lz4")
        }
        guard fm.fileExists(atPath: kernelOutPath) else {
            throw BuildError.artifactsMissing("vmlinuz-lts")
        }
        guard fm.fileExists(atPath: initramfsOutPath) else {
            throw BuildError.artifactsMissing("initramfs-lts")
        }

        return BuildResult(
            rootImagePath: rootImgPath,
            kernelPath: kernelOutPath,
            initramfsPath: initramfsOutPath
        )
    }

    // MARK: - VM Configuration

    @MainActor
    private static func createBuildVMConfiguration(
        kernelPath: String,
        initramfsPath: String,
        rootDiskPath: String,
        dataDiskPath: String,
        workspaceDir: String,
        outputDir: String
    ) throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()

        config.cpuCount = min(4, ProcessInfo.processInfo.processorCount)
        config.memorySize = 4 * 1024 * 1024 * 1024 // 4 GB

        // Boot loader
        let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: kernelPath))
        bootLoader.commandLine = "console=hvc0 root=/dev/vda rw"
        bootLoader.initialRamdiskURL = URL(fileURLWithPath: initramfsPath)
        config.bootLoader = bootLoader

        // Disks
        let rootAttachment = try VZDiskImageStorageDeviceAttachment(
            url: URL(fileURLWithPath: rootDiskPath),
            readOnly: false
        )
        let dataAttachment = try VZDiskImageStorageDeviceAttachment(
            url: URL(fileURLWithPath: dataDiskPath),
            readOnly: false
        )
        config.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: rootAttachment),
            VZVirtioBlockDeviceConfiguration(attachment: dataAttachment),
        ]

        // Networking (NAT for outbound internet — needed to pull images)
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [networkDevice]

        // vsock
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        // VirtIO shared directories for host↔VM file exchange
        let workspaceShare = VZVirtioFileSystemDeviceConfiguration(tag: "workspace")
        workspaceShare.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: URL(fileURLWithPath: workspaceDir), readOnly: true)
        )

        let outputShare = VZVirtioFileSystemDeviceConfiguration(tag: "output")
        outputShare.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: URL(fileURLWithPath: outputDir), readOnly: false)
        )

        config.directorySharingDevices = [workspaceShare, outputShare]

        // Console
        let consoleDevice = VZVirtioConsoleDeviceConfiguration()
        let serialPort = VZVirtioConsolePortConfiguration()
        serialPort.name = "console"
        serialPort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: FileHandle.nullDevice,
            fileHandleForWriting: FileHandle.standardError
        )
        consoleDevice.ports[0] = serialPort
        config.consoleDevices = [consoleDevice]

        // Entropy + memory balloon
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        try config.validate()
        return config
    }

    // MARK: - Health Polling

    private static func waitForHealth(device: VZVirtioSocketDevice, timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = await VSockControl.send(command: "HEALTH", to: device, timeout: 3.0)
            if response == "OK" {
                return true
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return false
    }

    // MARK: - Build Commands

    private static func sendBuildCommand(
        device: VZVirtioSocketDevice,
        images: String,
        onProgress: @escaping (String) -> Void
    ) async throws {
        let connection = try await device.connect(toPort: 1024)
        let input = connection.fileHandleForReading
        let output = connection.fileHandleForWriting

        defer {
            try? input.close()
            try? output.close()
        }

        output.write("BUILD:\(images)\n".data(using: .utf8)!)

        // Read responses line by line until BUILD_IMAGES_DONE or error
        while true {
            let data = input.availableData
            if data.isEmpty { break }
            guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                continue
            }

            for responseLine in line.components(separatedBy: "\n") {
                let trimmed = responseLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("PULLING:") {
                    let image = String(trimmed.dropFirst("PULLING:".count))
                    onProgress("Pulling \(image)...")
                } else if trimmed.hasPrefix("PULLED:") {
                    let image = String(trimmed.dropFirst("PULLED:".count))
                    onProgress("Pulled \(image)")
                } else if trimmed.hasPrefix("ERR:pull-failed:") {
                    let image = String(trimmed.dropFirst("ERR:pull-failed:".count))
                    throw BuildError.buildFailed("Failed to pull \(image)")
                } else if trimmed == "BUILD_IMAGES_DONE" {
                    return
                }
            }
        }

        throw BuildError.buildFailed("Connection closed before BUILD_IMAGES_DONE")
    }

    private static func sendPackCommand(
        device: VZVirtioSocketDevice,
        onProgress: @escaping (String) -> Void
    ) async throws {
        let connection = try await device.connect(toPort: 1024)
        let input = connection.fileHandleForReading
        let output = connection.fileHandleForWriting

        defer {
            try? input.close()
            try? output.close()
        }

        output.write("PACK\n".data(using: .utf8)!)

        // Read responses until PACK_DONE or error
        while true {
            let data = input.availableData
            if data.isEmpty { break }
            guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                continue
            }

            for responseLine in line.components(separatedBy: "\n") {
                let trimmed = responseLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("PACK_STEP:") {
                    let step = String(trimmed.dropFirst("PACK_STEP:".count))
                    onProgress("Pack: \(step)")
                } else if trimmed == "PACK_DONE" {
                    return
                } else if trimmed.hasPrefix("ERR:") {
                    throw BuildError.packFailed(trimmed)
                }
            }
        }

        throw BuildError.packFailed("Connection closed before PACK_DONE")
    }

    // MARK: - Disk Utilities

    private static func decompressLZ4(src: String, dst: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lz4")
        process.arguments = ["-d", "-f", src, dst]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BuildError.vmBootFailed("lz4 decompression failed with exit code \(process.terminationStatus)")
        }
    }

    private static func createSparseDisk(at path: String, sizeGB: Int) throws {
        let handle = FileManager.default.createFile(atPath: path, contents: nil)
        guard handle else {
            throw BuildError.vmBootFailed("Failed to create data disk at \(path)")
        }
        let fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try fileHandle.truncate(atOffset: UInt64(sizeGB) * 1024 * 1024 * 1024)
        try fileHandle.close()
    }
}
