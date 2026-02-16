import Foundation

struct PersistedState: Codable, Equatable {
    let vmState: String
    let timestamp: Date
    let pid: Int32
    let vmStartTime: Date?
}

protocol StateFilePersistence {
    func persist(state: VMState, vmStartTime: Date?)
    func read() -> PersistedState?
    func remove()
    func detectCrash() -> Bool
}

struct StateFile: StateFilePersistence {
    let fileURL: URL
    let currentPID: Int32

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .prettyPrinted
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(fileURL: URL = Paths.stateFileURL, currentPID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.fileURL = fileURL
        self.currentPID = currentPID
    }

    func persist(state: VMState, vmStartTime: Date? = nil) {
        let persisted = PersistedState(
            vmState: state.rawValue,
            timestamp: Date(),
            pid: currentPID,
            vmStartTime: vmStartTime
        )

        do {
            let data = try encoder.encode(persisted)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[StateFile] Failed to persist state: \(error.localizedDescription)")
        }
    }

    func read() -> PersistedState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(PersistedState.self, from: data)
        } catch {
            print("[StateFile] Failed to read state: \(error.localizedDescription)")
            return nil
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func detectCrash() -> Bool {
        guard let persisted = read() else { return false }

        let activeStates: Set<String> = [
            VMState.running.rawValue,
            VMState.starting.rawValue,
        ]

        guard activeStates.contains(persisted.vmState) else { return false }

        // Check if the PID from the state file is still alive
        let result = kill(persisted.pid, 0)
        if result == -1 && errno == ESRCH {
            print("[StateFile] Detected crash from previous run (PID \(persisted.pid), state: \(persisted.vmState))")
            return true
        }

        return false
    }
}
