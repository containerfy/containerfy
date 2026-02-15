import Foundation

struct PersistedState: Codable {
    let vmState: String
    let timestamp: Date
    let pid: Int32
    let vmStartTime: Date?
}

enum StateFile {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .prettyPrinted
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func persist(state: VMState, vmStartTime: Date? = nil) {
        let persisted = PersistedState(
            vmState: state.rawValue,
            timestamp: Date(),
            pid: ProcessInfo.processInfo.processIdentifier,
            vmStartTime: vmStartTime
        )

        do {
            let data = try encoder.encode(persisted)
            try data.write(to: Paths.stateFileURL, options: .atomic)
        } catch {
            print("[StateFile] Failed to persist state: \(error.localizedDescription)")
        }
    }

    static func read() -> PersistedState? {
        guard FileManager.default.fileExists(atPath: Paths.stateFileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: Paths.stateFileURL)
            return try decoder.decode(PersistedState.self, from: data)
        } catch {
            print("[StateFile] Failed to read state: \(error.localizedDescription)")
            return nil
        }
    }

    static func remove() {
        try? FileManager.default.removeItem(at: Paths.stateFileURL)
    }

    /// Checks if the previous run crashed (state file shows active state but PID is dead).
    static func detectCrash() -> Bool {
        guard let persisted = read() else { return false }

        let activeStates: Set<String> = [
            VMState.running.rawValue,
            VMState.startingVM.rawValue,
            VMState.waitingForHealth.rawValue,
            VMState.validatingHost.rawValue,
            VMState.preparingFirstLaunch.rawValue,
            VMState.paused.rawValue,
        ]

        guard activeStates.contains(persisted.vmState) else { return false }

        // Check if the PID from the state file is still alive
        let result = kill(persisted.pid, 0)
        if result == -1 && errno == ESRCH {
            // Process does not exist — previous run crashed
            print("[StateFile] Detected crash from previous run (PID \(persisted.pid), state: \(persisted.vmState))")
            return true
        }

        return false
    }
}
