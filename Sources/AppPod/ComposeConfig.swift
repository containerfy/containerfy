import Foundation
import Yams

/// Port mapping extracted from a compose service's `ports:` list.
struct PortMapping: Sendable {
    let hostPort: UInt16
    let containerPort: UInt16

    /// The vsock data port used to tunnel this mapping. Deterministic: 10000 + hostPort.
    var vsockPort: UInt32 { UInt32(10000) + UInt32(hostPort) }
}

/// Health check configuration from `x-apppod.healthcheck`.
struct HealthCheckConfig: Sendable {
    let url: String
    let intervalSeconds: Int
    let timeoutSeconds: Int
    let startupTimeoutSeconds: Int
}

/// A compose service with exposed ports (generates "Open" menu items).
struct ServiceInfo: Sendable {
    let name: String
    let displayLabel: String
    let ports: [PortMapping]

    /// URL for the "Open" menu item: http://127.0.0.1:<first host port>
    var openURL: URL? {
        guard let first = ports.first else { return nil }
        return URL(string: "http://127.0.0.1:\(first.hostPort)")
    }
}

/// Parsed subset of docker-compose.yml that AppPod needs at runtime.
struct ComposeConfig: Sendable {
    let portMappings: [PortMapping]
    let healthCheck: HealthCheckConfig?
    let displayName: String?
    let services: [ServiceInfo]

    /// No compose file found — run with no port forwarding or health monitoring.
    static let empty = ComposeConfig(portMappings: [], healthCheck: nil, displayName: nil, services: [])
}

enum ComposeConfigParser {
    /// Loads and parses the compose file, checking bundle first then Application Support.
    static func load() -> ComposeConfig {
        let url: URL

        if let bundleURL = Paths.composeFileURL,
           FileManager.default.fileExists(atPath: bundleURL.path) {
            url = bundleURL
        } else if FileManager.default.fileExists(atPath: Paths.composeFileFallbackURL.path) {
            url = Paths.composeFileFallbackURL
        } else {
            print("[Compose] No docker-compose.yml found — running without port forwarding")
            return .empty
        }

        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            return try parse(yaml: contents)
        } catch {
            print("[Compose] Failed to parse \(url.lastPathComponent): \(error.localizedDescription)")
            return .empty
        }
    }

    static func parse(yaml: String) throws -> ComposeConfig {
        guard let root = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw ComposeError.invalidFormat
        }

        let (portMappings, services) = parseServices(from: root)
        let healthCheck = parseHealthCheck(from: root)
        let displayName = parseDisplayName(from: root)

        if portMappings.isEmpty {
            print("[Compose] No port mappings found in compose file")
        } else {
            print("[Compose] Found \(portMappings.count) port mapping(s): \(portMappings.map { "\($0.hostPort):\($0.containerPort)" }.joined(separator: ", "))")
        }

        if !services.isEmpty {
            print("[Compose] Menu items: \(services.map { "Open \($0.displayLabel)" }.joined(separator: ", "))")
        }

        return ComposeConfig(
            portMappings: portMappings,
            healthCheck: healthCheck,
            displayName: displayName,
            services: services
        )
    }

    // MARK: - Private Parsers

    private static func parseServices(from root: [String: Any]) -> (portMappings: [PortMapping], services: [ServiceInfo]) {
        guard let svcs = root["services"] as? [String: Any] else { return ([], []) }

        var allMappings: [PortMapping] = []
        var serviceInfos: [ServiceInfo] = []

        for (name, serviceConfig) in svcs {
            guard let config = serviceConfig as? [String: Any],
                  let ports = config["ports"] as? [Any] else { continue }

            var svcMappings: [PortMapping] = []
            for port in ports {
                if let mapping = parsePortEntry(port) {
                    svcMappings.append(mapping)
                }
            }

            if !svcMappings.isEmpty {
                allMappings.append(contentsOf: svcMappings)
                serviceInfos.append(ServiceInfo(
                    name: name,
                    displayLabel: titleCase(name),
                    ports: svcMappings
                ))
            }
        }

        // Sort services alphabetically for consistent menu ordering
        serviceInfos.sort { $0.name < $1.name }

        return (allMappings, serviceInfos)
    }

    private static func titleCase(_ name: String) -> String {
        name.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    /// Parses a single port entry. Supports:
    /// - `"8000:8000"` (string, host:container)
    /// - `"8000"` (string, same host and container)
    /// - `8000` (integer, same host and container)
    /// - `{ published: 8000, target: 8000 }` (long-form)
    private static func parsePortEntry(_ entry: Any) -> PortMapping? {
        if let str = entry as? String {
            return parsePortString(str)
        }
        if let num = entry as? Int, let port = UInt16(exactly: num) {
            return PortMapping(hostPort: port, containerPort: port)
        }
        if let dict = entry as? [String: Any] {
            guard let published = dict["published"], let target = dict["target"] else { return nil }
            guard let hostPort = asUInt16(published), let containerPort = asUInt16(target) else { return nil }
            return PortMapping(hostPort: hostPort, containerPort: containerPort)
        }
        return nil
    }

    /// Parses `"8000:8000"`, `"127.0.0.1:8000:8000"`, `"8000:8000/tcp"`, `"8000"`.
    private static func parsePortString(_ str: String) -> PortMapping? {
        // Strip protocol suffix (e.g. "/tcp", "/udp")
        let base = str.split(separator: "/").first.map(String.init) ?? str

        let parts = base.split(separator: ":").map(String.init)

        switch parts.count {
        case 1:
            // "8000" — same host and container
            guard let port = UInt16(parts[0]) else { return nil }
            return PortMapping(hostPort: port, containerPort: port)
        case 2:
            // "8000:8000"
            guard let hostPort = UInt16(parts[0]), let containerPort = UInt16(parts[1]) else { return nil }
            return PortMapping(hostPort: hostPort, containerPort: containerPort)
        case 3:
            // "127.0.0.1:8000:8000" — IP:host:container
            guard let hostPort = UInt16(parts[1]), let containerPort = UInt16(parts[2]) else { return nil }
            return PortMapping(hostPort: hostPort, containerPort: containerPort)
        default:
            return nil
        }
    }

    private static func parseHealthCheck(from root: [String: Any]) -> HealthCheckConfig? {
        guard let xApppod = root["x-apppod"] as? [String: Any],
              let hc = xApppod["healthcheck"] as? [String: Any],
              let url = hc["url"] as? String else { return nil }

        return HealthCheckConfig(
            url: url,
            intervalSeconds: (hc["interval_seconds"] as? Int) ?? 10,
            timeoutSeconds: (hc["timeout_seconds"] as? Int) ?? 5,
            startupTimeoutSeconds: (hc["startup_timeout_seconds"] as? Int) ?? 120
        )
    }

    private static func parseDisplayName(from root: [String: Any]) -> String? {
        guard let xApppod = root["x-apppod"] as? [String: Any] else { return nil }
        return (xApppod["display_name"] as? String) ?? (xApppod["name"] as? String)
    }

    private static func asUInt16(_ value: Any) -> UInt16? {
        if let i = value as? Int { return UInt16(exactly: i) }
        if let s = value as? String { return UInt16(s) }
        return nil
    }

    enum ComposeError: LocalizedError {
        case invalidFormat

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return "docker-compose.yml is not valid YAML or has unexpected structure"
            }
        }
    }
}
