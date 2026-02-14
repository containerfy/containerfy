import Foundation
import Virtualization

@MainActor
final class VSockHealthCheck {
    private let socketDevice: VZVirtioSocketDevice
    private let stateController: VMStateController
    private var pollingTask: Task<Void, Never>?

    private let pollInterval: TimeInterval = 2.0
    private let startupTimeout: TimeInterval = 120.0

    init(socketDevice: VZVirtioSocketDevice, stateController: VMStateController) {
        self.socketDevice = socketDevice
        self.stateController = stateController
    }

    func beginPolling() {
        stop()

        let device = socketDevice
        let timeout = startupTimeout
        let interval = pollInterval

        pollingTask = Task { [weak self] in
            let startTime = Date()

            while !Task.isCancelled {
                if Date().timeIntervalSince(startTime) > timeout {
                    await self?.handleTimeout()
                    return
                }

                let healthy = await Self.checkHealth(device: device)
                if healthy {
                    await self?.handleHealthy()
                    return
                }

                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func handleTimeout() {
        print("[Health] Startup timeout (\(startupTimeout)s) exceeded")
        stateController.transition(to: .error)
    }

    private func handleHealthy() {
        print("[Health] VM is healthy")
        stateController.transition(to: .running)
        stop()
    }

    private static func checkHealth(device: VZVirtioSocketDevice) async -> Bool {
        do {
            let connection = try await device.connect(toPort: 1024)
            let input = connection.fileHandleForReading
            let output = connection.fileHandleForWriting

            let command = "HEALTH\n"
            output.write(command.data(using: .utf8)!)

            let data = input.availableData
            let response = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            try? input.close()
            try? output.close()

            return response == "OK"
        } catch {
            print("[Health] Poll failed: \(error.localizedDescription)")
            return false
        }
    }
}
