import Foundation
import Virtualization

/// Monitors application health via HTTP polling through the port forwarder,
/// and periodically queries disk usage via vsock DISK command.
/// Replaces VSockHealthCheck for ongoing monitoring once the VM is running.
@MainActor
final class HealthMonitor {
    private let config: HealthCheckConfig
    private let socketDevice: VZVirtioSocketDevice
    private let stateController: VMStateController
    var onDiskWarning: ((Int, Int) -> Void)?  // (usedMB, totalMB)
    var onHealthFailure: (() -> Void)?

    private var healthTask: Task<Void, Never>?
    private var diskTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 3
    private let diskCheckInterval: TimeInterval = 60.0
    private let diskWarningThreshold = 0.90

    init(
        config: HealthCheckConfig,
        socketDevice: VZVirtioSocketDevice,
        stateController: VMStateController
    ) {
        self.config = config
        self.socketDevice = socketDevice
        self.stateController = stateController
    }

    // MARK: - HTTP Health Polling

    func startMonitoring() {
        stop()
        consecutiveFailures = 0

        let url = config.url
        let interval = TimeInterval(config.intervalSeconds)
        let timeout = TimeInterval(config.timeoutSeconds)

        healthTask = Task { [weak self] in
            // Initial delay — let the app finish starting up inside the container
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))

            while !Task.isCancelled {
                guard let self else { return }

                let healthy = await Self.checkHTTPHealth(urlString: url, timeout: timeout)

                if healthy {
                    if self.consecutiveFailures > 0 {
                        print("[HealthMonitor] Recovered after \(self.consecutiveFailures) failure(s)")
                    }
                    self.consecutiveFailures = 0
                } else {
                    self.consecutiveFailures += 1
                    print("[HealthMonitor] HTTP health check failed (\(self.consecutiveFailures)/\(self.maxConsecutiveFailures))")

                    if self.consecutiveFailures >= self.maxConsecutiveFailures {
                        print("[HealthMonitor] \(self.maxConsecutiveFailures) consecutive failures — triggering error")
                        self.onHealthFailure?()
                        return
                    }
                }

                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }

        // Start disk monitoring
        startDiskMonitoring()

        print("[HealthMonitor] Started HTTP health polling to \(url) every \(config.intervalSeconds)s")
    }

    func stop() {
        healthTask?.cancel()
        healthTask = nil
        diskTask?.cancel()
        diskTask = nil
        consecutiveFailures = 0
    }

    // MARK: - HTTP Check

    private static func checkHTTPHealth(urlString: String, timeout: TimeInterval) async -> Bool {
        guard let url = URL(string: urlString) else { return false }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)

        do {
            let (_, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            let success = httpResponse.statusCode >= 200 && httpResponse.statusCode < 400
            return success
        } catch {
            return false
        }
    }

    // MARK: - Disk Usage Monitoring

    private func startDiskMonitoring() {
        let device = socketDevice
        let interval = diskCheckInterval
        let threshold = diskWarningThreshold

        diskTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }

                let usage = await Self.queryDiskUsage(device: device)
                if let (used, total) = usage, total > 0 {
                    let ratio = Double(used) / Double(total)
                    if ratio >= threshold {
                        print("[DiskMonitor] Warning: data disk at \(Int(ratio * 100))% (\(used)/\(total) MB)")
                        self.onDiskWarning?(used, total)
                    }
                }
            }
        }
    }

    /// Sends DISK command via vsock and parses response `DISK:<used>/<total>`.
    static func queryDiskUsage(device: VZVirtioSocketDevice) async -> (used: Int, total: Int)? {
        guard let response = await VSockControl.send(command: "DISK", to: device, timeout: 5.0) else {
            return nil
        }

        // Parse "DISK:<used>/<total>"
        guard response.hasPrefix("DISK:") else { return nil }
        let payload = String(response.dropFirst(5))
        let parts = payload.split(separator: "/")
        guard parts.count == 2,
              let used = Int(parts[0]),
              let total = Int(parts[1]) else { return nil }

        return (used, total)
    }
}
