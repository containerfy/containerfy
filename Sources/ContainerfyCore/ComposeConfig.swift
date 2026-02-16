import Foundation
import Yams

/// Port mapping extracted from a compose service's `ports:` list.
struct PortMapping: Sendable {
    let hostPort: UInt16
    let containerPort: UInt16
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

/// Parsed subset of docker-compose.yml that Containerfy needs at runtime.
struct ComposeConfig: Sendable {
    let portMappings: [PortMapping]
    let displayName: String?
    let services: [ServiceInfo]

    // Build-time fields (populated by parseBuild, nil at runtime)
    let name: String?
    let version: String?
    let identifier: String?
    let icon: String?
    let cpuMin: Int?
    let cpuRecommended: Int?
    let memoryMBMin: Int?
    let memoryMBRecommended: Int?
    let diskMB: Int?
    let images: [String]
    let envFiles: [String]
    let composePath: String?
    let composeDir: String?

    /// No compose file found — run with no port forwarding.
    static let empty = ComposeConfig(
        portMappings: [], displayName: nil, services: [],
        name: nil, version: nil, identifier: nil, icon: nil,
        cpuMin: nil, cpuRecommended: nil, memoryMBMin: nil, memoryMBRecommended: nil, diskMB: nil,
        images: [], envFiles: [], composePath: nil, composeDir: nil
    )
}

enum ComposeConfigParser {

    // MARK: - Runtime loading (GUI mode)

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

    /// Runtime parse — extracts ports, displayName, name (for machine naming). Lenient.
    static func parse(yaml: String) throws -> ComposeConfig {
        guard let root = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw ComposeError.invalidFormat
        }

        let (portMappings, services) = parseServices(from: root)
        let displayName = parseDisplayName(from: root)
        let xContainerfy = root["x-containerfy"] as? [String: Any]
        let name = xContainerfy?["name"] as? String
        let vm = xContainerfy?["vm"] as? [String: Any]
        let cpuMin = (vm?["cpu"] as? [String: Any])?["min"] as? Int
        let memoryMBMin = (vm?["memory_mb"] as? [String: Any])?["min"] as? Int
        let diskMB = vm?["disk_mb"] as? Int

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
            displayName: displayName,
            services: services,
            name: name, version: nil, identifier: nil, icon: nil,
            cpuMin: cpuMin, cpuRecommended: nil, memoryMBMin: memoryMBMin, memoryMBRecommended: nil, diskMB: diskMB,
            images: [], envFiles: [], composePath: nil, composeDir: nil
        )
    }

    // MARK: - Build-time parsing (CLI mode)

    private static let nameRegex = try! NSRegularExpression(pattern: #"^[a-zA-Z][a-zA-Z0-9-]{0,63}$"#)
    private static let semverRegex = try! NSRegularExpression(pattern: #"^\d+\.\d+\.\d+"#)

    /// Full build-time parse — validates x-containerfy, rejects unsupported keywords, extracts images/env_files.
    static func parseBuild(composePath: String) throws -> ComposeConfig {
        let absPath = (composePath as NSString).standardizingPath
        let fullPath: String
        if absPath.hasPrefix("/") {
            fullPath = absPath
        } else {
            fullPath = FileManager.default.currentDirectoryPath + "/" + composePath
        }

        let composeDir = (fullPath as NSString).deletingLastPathComponent

        guard let data = FileManager.default.contents(atPath: fullPath) else {
            throw ComposeError.fileNotFound(fullPath)
        }
        guard let contents = String(data: data, encoding: .utf8) else {
            throw ComposeError.invalidFormat
        }
        guard let root = try Yams.load(yaml: contents) as? [String: Any] else {
            throw ComposeError.invalidFormat
        }

        // Parse x-containerfy block (required for build)
        guard let xContainerfy = root["x-containerfy"] as? [String: Any] else {
            throw ComposeError.missingField("x-containerfy")
        }

        // name (required)
        guard let name = xContainerfy["name"] as? String, !name.isEmpty else {
            throw ComposeError.missingField("x-containerfy.name")
        }
        let nameRange = NSRange(name.startIndex..., in: name)
        guard nameRegex.firstMatch(in: name, range: nameRange) != nil else {
            throw ComposeError.invalidValue("x-containerfy.name", name, "must match ^[a-zA-Z][a-zA-Z0-9-]{0,63}$")
        }

        // version (required)
        guard let version = xContainerfy["version"] as? String, !version.isEmpty else {
            throw ComposeError.missingField("x-containerfy.version")
        }
        let versionRange = NSRange(version.startIndex..., in: version)
        guard semverRegex.firstMatch(in: version, range: versionRange) != nil else {
            throw ComposeError.invalidValue("x-containerfy.version", version, "not valid semver")
        }

        // identifier (required)
        guard let identifier = xContainerfy["identifier"] as? String, !identifier.isEmpty else {
            throw ComposeError.missingField("x-containerfy.identifier")
        }

        // display_name (optional)
        let displayName = (xContainerfy["display_name"] as? String) ?? (xContainerfy["name"] as? String)

        // icon (optional)
        let icon = xContainerfy["icon"] as? String

        // vm (required)
        guard let vm = xContainerfy["vm"] as? [String: Any] else {
            throw ComposeError.missingField("x-containerfy.vm")
        }
        let (cpuMin, cpuRecommended, memoryMBMin, memoryMBRecommended, diskMB) = try parseVMConfig(vm)

        // Parse services with full validation
        guard let svcs = root["services"] as? [String: Any] else {
            throw ComposeError.missingField("services")
        }

        var allMappings: [PortMapping] = []
        var serviceInfos: [ServiceInfo] = []
        var images: [String] = []
        var seenImages = Set<String>()
        var hostPorts: [Int] = []
        var envFiles: [String] = []

        for (svcName, svcRaw) in svcs {
            guard let svc = svcRaw as? [String: Any] else { continue }

            // Hard-reject validation
            if svc["build"] != nil {
                throw ComposeError.rejected(svcName, "build:", "use pre-built images only")
            }
            if svc["extends"] != nil {
                throw ComposeError.rejected(svcName, "extends:", "not supported")
            }
            if let profiles = svc["profiles"], profiles != nil {
                throw ComposeError.rejected(svcName, "profiles:", "not supported in v1")
            }
            if let nm = svc["network_mode"] as? String, nm == "host" {
                throw ComposeError.rejected(svcName, "network_mode: host", "breaks port forwarding")
            }

            // Check volumes for bind mounts
            if let vols = svc["volumes"] as? [Any] {
                for v in vols {
                    if let volStr = v as? String, isBindMount(volStr) {
                        throw ComposeError.rejected(svcName, "bind mount volume \"\(volStr)\"", "only named volumes are supported")
                    }
                    if let volMap = v as? [String: Any], (volMap["type"] as? String) == "bind" {
                        throw ComposeError.rejected(svcName, "bind mount volume", "only named volumes are supported")
                    }
                }
            }

            // Extract image
            if let image = svc["image"] as? String, !image.isEmpty {
                if !seenImages.contains(image) {
                    seenImages.insert(image)
                    images.append(image)
                }
            }

            // Extract ports
            var svcMappings: [PortMapping] = []
            if let ports = svc["ports"] as? [Any] {
                for port in ports {
                    if let mapping = parsePortEntry(port) {
                        svcMappings.append(mapping)
                        hostPorts.append(Int(mapping.hostPort))
                    }
                }
            }

            if !svcMappings.isEmpty {
                allMappings.append(contentsOf: svcMappings)
                serviceInfos.append(ServiceInfo(
                    name: svcName,
                    displayLabel: titleCase(svcName),
                    ports: svcMappings
                ))
            }

            // Extract env_file references
            let svcEnvFiles = try extractEnvFiles(svc, serviceName: svcName, composeDir: composeDir)
            envFiles.append(contentsOf: svcEnvFiles)
        }

        serviceInfos.sort { $0.name < $1.name }

        // Must have at least one exposed port
        if hostPorts.isEmpty {
            throw ComposeError.validationFailed("no services with ports: found — at least one exposed port is required")
        }

        return ComposeConfig(
            portMappings: allMappings,
            displayName: displayName,
            services: serviceInfos,
            name: name,
            version: version,
            identifier: identifier,
            icon: icon,
            cpuMin: cpuMin,
            cpuRecommended: cpuRecommended,
            memoryMBMin: memoryMBMin,
            memoryMBRecommended: memoryMBRecommended,
            diskMB: diskMB,
            images: images,
            envFiles: envFiles,
            composePath: fullPath,
            composeDir: composeDir
        )
    }

    // MARK: - VM Config

    private static func parseVMConfig(_ vm: [String: Any]) throws -> (cpuMin: Int, cpuRec: Int, memMin: Int, memRec: Int, diskMB: Int) {
        guard let cpu = vm["cpu"] as? [String: Any] else {
            throw ComposeError.missingField("x-containerfy.vm.cpu")
        }
        let cpuMin = toInt(cpu["min"])
        if cpuMin < 1 || cpuMin > 16 {
            throw ComposeError.invalidValue("x-containerfy.vm.cpu.min", "\(cpuMin)", "must be 1-16")
        }
        var cpuRec = toInt(cpu["recommended"])
        if cpuRec == 0 { cpuRec = cpuMin }
        if cpuRec < cpuMin {
            throw ComposeError.invalidValue("x-containerfy.vm.cpu.recommended", "\(cpuRec)", "must be >= min (\(cpuMin))")
        }

        guard let mem = vm["memory_mb"] as? [String: Any] else {
            throw ComposeError.missingField("x-containerfy.vm.memory_mb")
        }
        let memMin = toInt(mem["min"])
        if memMin < 512 || memMin > 32768 {
            throw ComposeError.invalidValue("x-containerfy.vm.memory_mb.min", "\(memMin)", "must be 512-32768")
        }
        var memRec = toInt(mem["recommended"])
        if memRec == 0 { memRec = memMin }
        if memRec < memMin {
            throw ComposeError.invalidValue("x-containerfy.vm.memory_mb.recommended", "\(memRec)", "must be >= min (\(memMin))")
        }

        let diskMB = toInt(vm["disk_mb"])
        if diskMB < 1024 {
            throw ComposeError.invalidValue("x-containerfy.vm.disk_mb", "\(diskMB)", "must be >= 1024")
        }

        return (cpuMin, cpuRec, memMin, memRec, diskMB)
    }

    // MARK: - Env Files

    private static func extractEnvFiles(_ svc: [String: Any], serviceName: String, composeDir: String) throws -> [String] {
        guard let ef = svc["env_file"] else { return [] }

        var paths: [String] = []
        if let s = ef as? String {
            paths = [s]
        } else if let arr = ef as? [Any] {
            for item in arr {
                if let s = item as? String {
                    paths.append(s)
                } else if let m = item as? [String: Any], let p = m["path"] as? String {
                    paths.append(p)
                }
            }
        }

        var result: [String] = []
        let fm = FileManager.default
        for p in paths {
            let abs: String
            if (p as NSString).isAbsolutePath {
                abs = p
            } else {
                abs = (composeDir as NSString).appendingPathComponent(p)
            }
            guard fm.fileExists(atPath: abs) else {
                throw ComposeError.validationFailed("service \"\(serviceName)\" references env_file \"\(p)\" which does not exist")
            }
            result.append(abs)
        }

        return result
    }

    // MARK: - Bind Mount Detection

    private static func isBindMount(_ vol: String) -> Bool {
        let parts = vol.split(separator: ":", maxSplits: 1)
        guard parts.count >= 2 else { return false }
        let src = String(parts[0])
        return src.hasPrefix(".") || src.hasPrefix("/") || src.hasPrefix("~")
    }

    // MARK: - Private Parsers (runtime)

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

    private static func parseDisplayName(from root: [String: Any]) -> String? {
        guard let xContainerfy = root["x-containerfy"] as? [String: Any] else { return nil }
        return (xContainerfy["display_name"] as? String) ?? (xContainerfy["name"] as? String)
    }

    private static func asUInt16(_ value: Any) -> UInt16? {
        if let i = value as? Int { return UInt16(exactly: i) }
        if let s = value as? String { return UInt16(s) }
        return nil
    }

    private static func toInt(_ value: Any?) -> Int {
        guard let v = value else { return 0 }
        if let n = v as? Int { return n }
        if let n = v as? Double { return Int(n) }
        if let s = v as? String { return Int(s) ?? 0 }
        return 0
    }

    enum ComposeError: LocalizedError {
        case invalidFormat
        case fileNotFound(String)
        case missingField(String)
        case invalidValue(String, String, String)
        case rejected(String, String, String)
        case validationFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return "docker-compose.yml is not valid YAML or has unexpected structure"
            case .fileNotFound(let path):
                return "compose file not found: \(path)"
            case .missingField(let field):
                return "\(field) is required"
            case .invalidValue(let field, let value, let reason):
                return "\(field) \"\(value)\" is invalid: \(reason)"
            case .rejected(let service, let keyword, let reason):
                return "service \"\(service)\" uses \(keyword) which is not supported — \(reason)"
            case .validationFailed(let msg):
                return msg
            }
        }
    }
}
