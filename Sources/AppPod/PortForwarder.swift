import Foundation
import Network
import Virtualization

/// Manages TCP↔vsock port forwarding for all compose port mappings.
/// Binds 127.0.0.1:<hostPort> on the Mac and tunnels traffic through vsock
/// to the VM agent's socat bridges on port 10000+hostPort.
@MainActor
final class PortForwarder {
    private let socketDevice: VZVirtioSocketDevice
    private let portMappings: [PortMapping]
    private var listeners: [UInt16: NWListener] = [:]
    private var bridges: [UUID: ConnectionBridge] = [:]
    private let queue = DispatchQueue(label: "com.apppod.portforwarder", attributes: .concurrent)
    private var isRunning = false

    init(socketDevice: VZVirtioSocketDevice, portMappings: [PortMapping]) {
        self.socketDevice = socketDevice
        self.portMappings = portMappings
    }

    // MARK: - Start / Stop

    /// Sends FORWARD commands to the VM agent, then starts TCP listeners.
    func start() async throws {
        guard !isRunning, !portMappings.isEmpty else { return }

        // Tell the VM agent to start socat bridges
        for mapping in portMappings {
            let cmd = "FORWARD:\(mapping.vsockPort):\(mapping.containerPort)"
            let response = await VSockControl.send(command: cmd, to: socketDevice, timeout: 5.0)
            guard response == "ACK" else {
                print("[Ports] VM agent did not ACK \(cmd): \(response ?? "nil")")
                throw PortForwarderError.vmAgentFailed(mapping.hostPort)
            }
        }

        // Start TCP listeners
        for mapping in portMappings {
            try startListener(for: mapping)
        }

        isRunning = true
        print("[Ports] Port forwarding active for \(portMappings.count) port(s)")
    }

    func stop() {
        isRunning = false

        // Cancel all active connection bridges
        for (_, bridge) in bridges {
            bridge.cancel()
        }
        bridges.removeAll()

        // Stop all listeners
        for (port, listener) in listeners {
            listener.cancel()
            print("[Ports] Stopped listener on :\(port)")
        }
        listeners.removeAll()

        // Tell VM agent to stop socat bridges (best-effort, fire-and-forget)
        let device = socketDevice
        Task.detached {
            _ = await VSockControl.send(command: "FORWARD-STOP", to: device, timeout: 3.0)
        }

        print("[Ports] Port forwarding stopped")
    }

    /// Tears down active connection bridges but keeps listeners alive.
    /// Called on sleep/wake to reset stale vsock data connections.
    func rebuildConnections() {
        for (_, bridge) in bridges {
            bridge.cancel()
        }
        bridges.removeAll()
        print("[Ports] Active connections cleared for rebuild")
    }

    // MARK: - TCP Listener

    private func startListener(for mapping: PortMapping) throws {
        guard let port = NWEndpoint.Port(rawValue: mapping.hostPort) else {
            throw PortForwarderError.invalidPort(mapping.hostPort)
        }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)

        let listener = try NWListener(using: params)

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[Ports] Listening on 127.0.0.1:\(mapping.hostPort) → vsock:\(mapping.vsockPort)")
            case .failed(let error):
                print("[Ports] Listener failed on :\(mapping.hostPort): \(error)")
            default:
                break
            }
        }

        let device = self.socketDevice
        let vsockPort = mapping.vsockPort

        listener.newConnectionHandler = { [weak self] tcpConnection in
            guard let self else {
                tcpConnection.cancel()
                return
            }
            Task { @MainActor in
                self.handleNewConnection(tcpConnection, device: device, vsockPort: vsockPort)
            }
        }

        listener.start(queue: queue)
        listeners[mapping.hostPort] = listener
    }

    // MARK: - Connection Bridging

    private func handleNewConnection(
        _ tcpConnection: NWConnection,
        device: VZVirtioSocketDevice,
        vsockPort: UInt32
    ) {
        let bridgeID = UUID()
        let bridgeQueue = DispatchQueue(label: "com.apppod.bridge.\(bridgeID.uuidString.prefix(8))")

        Task {
            do {
                let vsockConnection = try await device.connect(toPort: vsockPort)
                let bridge = ConnectionBridge(
                    id: bridgeID,
                    tcpConnection: tcpConnection,
                    vsockInput: vsockConnection.fileHandleForReading,
                    vsockOutput: vsockConnection.fileHandleForWriting,
                    queue: bridgeQueue
                ) { [weak self] id in
                    Task { @MainActor in
                        self?.bridges.removeValue(forKey: id)
                    }
                }

                self.bridges[bridgeID] = bridge
                bridge.start()
            } catch {
                print("[Ports] Failed to open vsock connection to port \(vsockPort): \(error.localizedDescription)")
                tcpConnection.cancel()
            }
        }
    }

    // MARK: - Errors

    enum PortForwarderError: LocalizedError {
        case portInUse(UInt16)
        case invalidPort(UInt16)
        case vmAgentFailed(UInt16)

        var errorDescription: String? {
            switch self {
            case .portInUse(let port):
                return "Port \(port) is already in use"
            case .invalidPort(let port):
                return "Invalid port number: \(port)"
            case .vmAgentFailed(let port):
                return "VM agent failed to set up forwarding for port \(port)"
            }
        }
    }
}

// MARK: - ConnectionBridge

/// Bridges data bidirectionally between a TCP NWConnection and a vsock FileHandle pair.
final class ConnectionBridge: @unchecked Sendable {
    let id: UUID
    private let tcpConnection: NWConnection
    private let vsockInput: FileHandle
    private let vsockOutput: FileHandle
    private let queue: DispatchQueue
    private let onClose: (UUID) -> Void
    private var isCancelled = false

    init(
        id: UUID,
        tcpConnection: NWConnection,
        vsockInput: FileHandle,
        vsockOutput: FileHandle,
        queue: DispatchQueue,
        onClose: @escaping (UUID) -> Void
    ) {
        self.id = id
        self.tcpConnection = tcpConnection
        self.vsockInput = vsockInput
        self.vsockOutput = vsockOutput
        self.queue = queue
        self.onClose = onClose
    }

    func start() {
        tcpConnection.start(queue: queue)

        // vsock → TCP
        vsockInput.readabilityHandler = { [weak self] handle in
            guard let self, !self.isCancelled else { return }
            let data = handle.availableData
            if data.isEmpty {
                self.cancel()
                return
            }
            self.tcpConnection.send(content: data, completion: .contentProcessed { error in
                if error != nil {
                    self.cancel()
                }
            })
        }

        // TCP → vsock
        receiveTCP()
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true

        vsockInput.readabilityHandler = nil
        try? vsockInput.close()
        try? vsockOutput.close()
        tcpConnection.cancel()
        onClose(id)
    }

    private func receiveTCP() {
        guard !isCancelled else { return }
        tcpConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.isCancelled else { return }
            if let data, !data.isEmpty {
                self.vsockOutput.write(data)
            }
            if isComplete || error != nil {
                self.cancel()
                return
            }
            self.receiveTCP()
        }
    }
}
