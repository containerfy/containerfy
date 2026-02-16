import Foundation
@testable import ContainerfyCore

// MARK: - MockShellExecutor

final class MockShellExecutor: ShellExecutor {
    struct Call {
        let executable: String
        let arguments: [String]
    }

    var calls: [Call] = []
    var resultToReturn: ProcessResult = ProcessResult(exitCode: 0, stdout: "", stderr: "")
    var errorToThrow: Error?

    func run(executable: String, arguments: [String], environment: [String: String]?) throws -> ProcessResult {
        calls.append(Call(executable: executable, arguments: arguments))
        if let error = errorToThrow { throw error }
        return resultToReturn
    }
}

// MARK: - MockStateFile

final class MockStateFile: StateFilePersistence {
    var persistedState: VMState?
    var persistedVMStartTime: Date?
    var storedState: PersistedState?
    var removed = false
    var crashDetected = false

    func persist(state: VMState, vmStartTime: Date?) {
        persistedState = state
        persistedVMStartTime = vmStartTime
    }

    func read() -> PersistedState? {
        return storedState
    }

    func remove() {
        removed = true
        storedState = nil
    }

    func detectCrash() -> Bool {
        return crashDetected
    }
}
