import Foundation

/// Abstraction over shell process execution, enabling test injection.
protocol ShellExecutor {
    func run(executable: String, arguments: [String]) throws -> ProcessResult
    func run(executable: String, arguments: [String], environment: [String: String]?) throws -> ProcessResult
}

extension ShellExecutor {
    func run(executable: String, arguments: [String]) throws -> ProcessResult {
        try run(executable: executable, arguments: arguments, environment: nil)
    }
}

/// Result of a shell command execution.
struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Default implementation that runs real processes via Foundation.Process.
struct SystemShellExecutor: ShellExecutor {
    func run(executable: String, arguments: [String], environment: [String: String]? = nil) throws -> ProcessResult {
        let process = Process()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        if let environment {
            process.environment = environment
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
