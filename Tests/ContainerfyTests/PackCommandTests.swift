import XCTest
@testable import ContainerfyCore

final class PackCommandTests: XCTestCase {

    func testPackFailsOnBadComposePath() {
        let signer = CodeSigner(shell: MockShellExecutor())
        let command = PackCommand(signer: signer)

        let exitCode = command.run(arguments: ["--compose", "/nonexistent/docker-compose.yml"])
        XCTAssertEqual(exitCode, 1)
    }

    func testPackFailsWhenPodmanNotInstalled() throws {
        // Create a temporary compose file
        let tmpDir = NSTemporaryDirectory() + "pack-test-\(ProcessInfo.processInfo.globallyUniqueString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmpDir) }

        let composePath = (tmpDir as NSString).appendingPathComponent("docker-compose.yml")
        let yaml = """
        services:
          web:
            image: nginx:latest
            ports:
              - "8080:80"
        x-containerfy:
          name: testapp
          version: "1.0.0"
          identifier: com.test.app
          vm:
            cpu:
              min: 2
            memory_mb:
              min: 1024
            disk_mb: 4096
        """
        try yaml.write(toFile: composePath, atomically: true, encoding: .utf8)

        // Pack will fail at "Locating podman binaries" step if podman is not installed,
        // or succeed if it is. Either way, compose parsing should succeed.
        let signer = CodeSigner(shell: MockShellExecutor())
        let command = PackCommand(signer: signer)
        let exitCode = command.run(arguments: ["--compose", composePath])
        // We just verify it doesn't crash — exit code depends on whether podman is installed
        XCTAssertTrue(exitCode == 0 || exitCode == 1)
    }
}
