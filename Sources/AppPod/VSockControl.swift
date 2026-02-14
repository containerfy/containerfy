import Foundation
import Virtualization

enum VSockControl {
    /// Sends a line-based command over vsock and returns the response.
    /// Timeout in seconds. Returns nil on connection or timeout failure.
    static func send(
        command: String,
        to device: VZVirtioSocketDevice,
        port: UInt32 = 1024,
        timeout: TimeInterval = 5.0
    ) async -> String? {
        do {
            let connection = try await device.connect(toPort: port)
            let input = connection.fileHandleForReading
            let output = connection.fileHandleForWriting

            output.write((command + "\n").data(using: .utf8)!)

            // Read response with timeout
            let response: String? = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let workItem = DispatchWorkItem {
                        let data = input.availableData
                        let result = String(data: data, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(returning: result)
                    }

                    let timeoutItem = DispatchWorkItem {
                        workItem.cancel()
                        continuation.resume(returning: nil)
                    }

                    DispatchQueue.global().async(execute: workItem)
                    DispatchQueue.global().asyncAfter(
                        deadline: .now() + timeout,
                        execute: timeoutItem
                    )

                    // When work completes, cancel the timeout
                    workItem.notify(queue: .global()) {
                        timeoutItem.cancel()
                    }
                }
            } onCancel: {
                try? input.close()
                try? output.close()
            }

            try? input.close()
            try? output.close()

            return response
        } catch {
            print("[VSock] Command '\(command)' failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Sends a SHUTDOWN command and returns true if ACK received.
    static func sendShutdown(to device: VZVirtioSocketDevice, timeout: TimeInterval = 5.0) async -> Bool {
        let response = await send(command: "SHUTDOWN", to: device, timeout: timeout)
        return response == "ACK"
    }

    /// Fetches recent docker compose logs from the VM.
    /// The VM agent closes the connection after sending logs, so we read until EOF.
    static func fetchLogs(
        lines: Int,
        from device: VZVirtioSocketDevice,
        timeout: TimeInterval = 10.0
    ) async -> String? {
        do {
            let connection = try await device.connect(toPort: 1024)
            let input = connection.fileHandleForReading
            let output = connection.fileHandleForWriting

            output.write("LOGS:\(lines)\n".data(using: .utf8)!)

            let result: String? = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let workItem = DispatchWorkItem {
                        var buffer = Data()
                        while true {
                            let chunk = input.availableData
                            if chunk.isEmpty { break }
                            buffer.append(chunk)
                        }

                        guard let response = String(data: buffer, encoding: .utf8),
                              response.hasPrefix("LOGS:") else {
                            continuation.resume(returning: nil)
                            return
                        }

                        // Parse past "LOGS:<byte_count>\n" header
                        if let newlineIndex = response.firstIndex(of: "\n") {
                            let logData = String(response[response.index(after: newlineIndex)...])
                            continuation.resume(returning: logData)
                        } else {
                            continuation.resume(returning: "")
                        }
                    }

                    let timeoutItem = DispatchWorkItem {
                        workItem.cancel()
                        continuation.resume(returning: nil)
                    }

                    DispatchQueue.global().async(execute: workItem)
                    DispatchQueue.global().asyncAfter(
                        deadline: .now() + timeout,
                        execute: timeoutItem
                    )
                    workItem.notify(queue: .global()) {
                        timeoutItem.cancel()
                    }
                }
            } onCancel: {
                try? input.close()
                try? output.close()
            }

            try? input.close()
            try? output.close()

            return result
        } catch {
            print("[VSock] LOGS fetch failed: \(error.localizedDescription)")
            return nil
        }
    }
}
