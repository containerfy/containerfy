import XCTest
@testable import ContainerfyCore

final class ComposeConfigParseBuildTests: XCTestCase {

    private typealias CError = ComposeConfigParser.ComposeError

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("containerfy-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func writeCompose(_ yaml: String, filename: String = "docker-compose.yml") -> String {
        let path = tempDir.appendingPathComponent(filename).path
        FileManager.default.createFile(atPath: path, contents: yaml.data(using: .utf8))
        return path
    }

    private func writeEnvFile(_ name: String, contents: String = "FOO=bar") {
        let path = tempDir.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: contents.data(using: .utf8))
    }

    // MARK: - Minimal valid compose for reuse

    private let validXContainerfy = """
    x-containerfy:
      name: testapp
      version: "1.0.0"
      identifier: com.example.testapp
      vm:
        cpu:
          min: 2
          recommended: 4
        memory_mb:
          min: 1024
          recommended: 2048
        disk_mb: 4096
    """

    private var validCompose: String {
        """
        services:
          web:
            image: nginx:latest
            ports:
              - "8080:80"
        \(validXContainerfy)
        """
    }

    // MARK: - Valid Full Compose

    func testValidFullCompose() throws {
        let path = writeCompose(validCompose)
        let config = try ComposeConfigParser.parseBuild(composePath: path)

        XCTAssertEqual(config.name, "testapp")
        XCTAssertEqual(config.version, "1.0.0")
        XCTAssertEqual(config.identifier, "com.example.testapp")
        XCTAssertEqual(config.cpuMin, 2)
        XCTAssertEqual(config.cpuRecommended, 4)
        XCTAssertEqual(config.memoryMBMin, 1024)
        XCTAssertEqual(config.memoryMBRecommended, 2048)
        XCTAssertEqual(config.diskMB, 4096)
        XCTAssertEqual(config.images, ["nginx:latest"])
        XCTAssertEqual(config.portMappings.count, 1)
        XCTAssertNotNil(config.composePath)
        XCTAssertNotNil(config.composeDir)
    }

    // MARK: - Missing x-containerfy

    func testMissingXContainerfy() {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .missingField("x-containerfy") = ce else {
                return XCTFail("Expected missingField(x-containerfy), got: \(error)")
            }
        }
    }

    // MARK: - Name Validation

    func testNameStartsWithNumber() {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
        x-containerfy:
          name: "1badname"
          version: "1.0.0"
          identifier: com.example.test
          vm:
            cpu: { min: 2 }
            memory_mb: { min: 1024 }
            disk_mb: 4096
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .invalidValue("x-containerfy.name", _, _) = ce else {
                return XCTFail("Expected invalidValue for name, got: \(error)")
            }
        }
    }

    func testNameTooLong() {
        let longName = "a" + String(repeating: "b", count: 64) // 65 chars total
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
        x-containerfy:
          name: "\(longName)"
          version: "1.0.0"
          identifier: com.example.test
          vm:
            cpu: { min: 2 }
            memory_mb: { min: 1024 }
            disk_mb: 4096
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .invalidValue("x-containerfy.name", _, _) = ce else {
                return XCTFail("Expected invalidValue for name, got: \(error)")
            }
        }
    }

    func testNameAtMaxLength() throws {
        let name64 = "a" + String(repeating: "b", count: 63) // exactly 64 chars — valid
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
        x-containerfy:
          name: "\(name64)"
          version: "1.0.0"
          identifier: com.example.test
          vm:
            cpu: { min: 2 }
            memory_mb: { min: 1024 }
            disk_mb: 4096
        """
        let path = writeCompose(yaml)
        let config = try ComposeConfigParser.parseBuild(composePath: path)
        XCTAssertEqual(config.name, name64)
    }

    func testNameSpecialChars() {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
        x-containerfy:
          name: "bad name!"
          version: "1.0.0"
          identifier: com.example.test
          vm:
            cpu: { min: 2 }
            memory_mb: { min: 1024 }
            disk_mb: 4096
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .invalidValue("x-containerfy.name", _, _) = ce else {
                return XCTFail("Expected invalidValue for name, got: \(error)")
            }
        }
    }

    // MARK: - Version Validation

    func testVersionNotSemver() {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
        x-containerfy:
          name: testapp
          version: "not-semver"
          identifier: com.example.test
          vm:
            cpu: { min: 2 }
            memory_mb: { min: 1024 }
            disk_mb: 4096
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .invalidValue("x-containerfy.version", "not-semver", _) = ce else {
                return XCTFail("Expected invalidValue for version, got: \(error)")
            }
        }
    }

    // MARK: - Missing Required Fields

    func testMissingIdentifier() {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
        x-containerfy:
          name: testapp
          version: "1.0.0"
          vm:
            cpu: { min: 2 }
            memory_mb: { min: 1024 }
            disk_mb: 4096
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .missingField("x-containerfy.identifier") = ce else {
                return XCTFail("Expected missingField(x-containerfy.identifier), got: \(error)")
            }
        }
    }

    func testMissingVM() {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
        x-containerfy:
          name: testapp
          version: "1.0.0"
          identifier: com.example.test
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .missingField("x-containerfy.vm") = ce else {
                return XCTFail("Expected missingField(x-containerfy.vm), got: \(error)")
            }
        }
    }

    // MARK: - VM Config Validation

    func testCPUZero() {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
        x-containerfy:
          name: testapp
          version: "1.0.0"
          identifier: com.example.test
          vm:
            cpu: { min: 0 }
            memory_mb: { min: 1024 }
            disk_mb: 4096
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .invalidValue("x-containerfy.vm.cpu.min", "0", _) = ce else {
                return XCTFail("Expected invalidValue for cpu.min, got: \(error)")
            }
        }
    }

    func testCPUAboveMax() {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
        x-containerfy:
          name: testapp
          version: "1.0.0"
          identifier: com.example.test
          vm:
            cpu: { min: 17 }
            memory_mb: { min: 1024 }
            disk_mb: 4096
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .invalidValue("x-containerfy.vm.cpu.min", "17", _) = ce else {
                return XCTFail("Expected invalidValue for cpu.min=17, got: \(error)")
            }
        }
    }

    func testCPURecommendedLessThanMin() {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
        x-containerfy:
          name: testapp
          version: "1.0.0"
          identifier: com.example.test
          vm:
            cpu: { min: 4, recommended: 2 }
            memory_mb: { min: 1024 }
            disk_mb: 4096
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .invalidValue("x-containerfy.vm.cpu.recommended", "2", _) = ce else {
                return XCTFail("Expected invalidValue for cpu.recommended, got: \(error)")
            }
        }
    }

    func testCPURecommendedDefaultsToMinWhenOmitted() throws {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
        x-containerfy:
          name: testapp
          version: "1.0.0"
          identifier: com.example.test
          vm:
            cpu: { min: 2 }
            memory_mb: { min: 1024 }
            disk_mb: 4096
        """
        let path = writeCompose(yaml)
        let config = try ComposeConfigParser.parseBuild(composePath: path)
        XCTAssertEqual(config.cpuRecommended, 2, "recommended should default to min when omitted")
    }

    func testMemoryBelowMin() {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
        x-containerfy:
          name: testapp
          version: "1.0.0"
          identifier: com.example.test
          vm:
            cpu: { min: 2 }
            memory_mb: { min: 256 }
            disk_mb: 4096
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .invalidValue("x-containerfy.vm.memory_mb.min", "256", _) = ce else {
                return XCTFail("Expected invalidValue for memory_mb.min, got: \(error)")
            }
        }
    }

    func testMemoryAboveMax() {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
        x-containerfy:
          name: testapp
          version: "1.0.0"
          identifier: com.example.test
          vm:
            cpu: { min: 2 }
            memory_mb: { min: 33000 }
            disk_mb: 4096
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .invalidValue("x-containerfy.vm.memory_mb.min", "33000", _) = ce else {
                return XCTFail("Expected invalidValue for memory_mb.min=33000, got: \(error)")
            }
        }
    }

    func testDiskTooSmall() {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
        x-containerfy:
          name: testapp
          version: "1.0.0"
          identifier: com.example.test
          vm:
            cpu: { min: 2 }
            memory_mb: { min: 1024 }
            disk_mb: 512
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .invalidValue("x-containerfy.vm.disk_mb", "512", _) = ce else {
                return XCTFail("Expected invalidValue for disk_mb, got: \(error)")
            }
        }
    }

    // MARK: - Hard Rejects

    func testRejectBuild() {
        let yaml = """
        services:
          web:
            build: .
            ports:
              - "8080:80"
        \(validXContainerfy)
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .rejected("web", "build:", _) = ce else {
                return XCTFail("Expected rejected(web, build:), got: \(error)")
            }
        }
    }

    func testRejectExtends() {
        let yaml = """
        services:
          web:
            image: nginx
            extends:
              service: base
            ports:
              - "8080:80"
        \(validXContainerfy)
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .rejected("web", "extends:", _) = ce else {
                return XCTFail("Expected rejected(web, extends:), got: \(error)")
            }
        }
    }

    func testRejectProfiles() {
        let yaml = """
        services:
          web:
            image: nginx
            profiles:
              - debug
            ports:
              - "8080:80"
        \(validXContainerfy)
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .rejected("web", "profiles:", _) = ce else {
                return XCTFail("Expected rejected(web, profiles:), got: \(error)")
            }
        }
    }

    func testRejectNetworkModeHost() {
        let yaml = """
        services:
          web:
            image: nginx
            network_mode: host
            ports:
              - "8080:80"
        \(validXContainerfy)
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .rejected("web", "network_mode: host", _) = ce else {
                return XCTFail("Expected rejected(web, network_mode: host), got: \(error)")
            }
        }
    }

    func testNetworkModeBridgeAllowed() throws {
        let yaml = """
        services:
          web:
            image: nginx
            network_mode: bridge
            ports:
              - "8080:80"
        \(validXContainerfy)
        """
        let path = writeCompose(yaml)
        let config = try ComposeConfigParser.parseBuild(composePath: path)
        XCTAssertEqual(config.portMappings.count, 1)
    }

    // MARK: - Bind Mount Detection

    func testRejectBindMountRelative() {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
            volumes:
              - ./data:/data
        \(validXContainerfy)
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .rejected("web", _, _) = ce else {
                return XCTFail("Expected rejected for bind mount, got: \(error)")
            }
        }
    }

    func testRejectBindMountAbsolute() {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
            volumes:
              - /host:/container
        \(validXContainerfy)
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .rejected("web", _, _) = ce else {
                return XCTFail("Expected rejected for bind mount, got: \(error)")
            }
        }
    }

    func testRejectBindMountTilde() {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
            volumes:
              - ~/data:/data
        \(validXContainerfy)
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .rejected("web", _, _) = ce else {
                return XCTFail("Expected rejected for bind mount, got: \(error)")
            }
        }
    }

    func testRejectBindMountLongForm() {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
            volumes:
              - type: bind
                source: ./data
                target: /data
        \(validXContainerfy)
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .rejected("web", "bind mount volume", _) = ce else {
                return XCTFail("Expected rejected(web, bind mount volume), got: \(error)")
            }
        }
    }

    func testNamedVolumeAllowed() throws {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
            volumes:
              - mydata:/data
        \(validXContainerfy)
        """
        let path = writeCompose(yaml)
        let config = try ComposeConfigParser.parseBuild(composePath: path)
        XCTAssertEqual(config.name, "testapp")
    }

    // MARK: - env_file

    func testEnvFileString() throws {
        writeEnvFile(".env")
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
            env_file: .env
        \(validXContainerfy)
        """
        let path = writeCompose(yaml)
        let config = try ComposeConfigParser.parseBuild(composePath: path)
        XCTAssertEqual(config.envFiles.count, 1)
        XCTAssertTrue(config.envFiles[0].hasSuffix(".env"))
    }

    func testEnvFileArray() throws {
        writeEnvFile(".env")
        writeEnvFile("app.env")
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
            env_file:
              - .env
              - app.env
        \(validXContainerfy)
        """
        let path = writeCompose(yaml)
        let config = try ComposeConfigParser.parseBuild(composePath: path)
        XCTAssertEqual(config.envFiles.count, 2)
    }

    func testEnvFileDictWithPath() throws {
        writeEnvFile("custom.env")
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
            env_file:
              - path: custom.env
        \(validXContainerfy)
        """
        let path = writeCompose(yaml)
        let config = try ComposeConfigParser.parseBuild(composePath: path)
        XCTAssertEqual(config.envFiles.count, 1)
        XCTAssertTrue(config.envFiles[0].hasSuffix("custom.env"))
    }

    func testEnvFileNotFoundThrows() {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
            env_file: missing.env
        \(validXContainerfy)
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .validationFailed(let msg) = ce else {
                return XCTFail("Expected validationFailed for missing env_file, got: \(error)")
            }
            XCTAssertTrue(msg.contains("missing.env"), "Error should mention the missing file")
        }
    }

    // MARK: - No Exposed Ports

    func testNoExposedPortsError() {
        let yaml = """
        services:
          worker:
            image: myworker
        \(validXContainerfy)
        """
        let path = writeCompose(yaml)
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: path)) { error in
            guard let ce = error as? CError, case .validationFailed(let msg) = ce else {
                return XCTFail("Expected validationFailed, got: \(error)")
            }
            XCTAssertTrue(msg.contains("port"), "Error should mention missing ports")
        }
    }

    // MARK: - Duplicate Image Deduplication

    func testDuplicateImageDedup() throws {
        let yaml = """
        services:
          web1:
            image: nginx:latest
            ports:
              - "8080:80"
          web2:
            image: nginx:latest
            ports:
              - "8081:80"
        \(validXContainerfy)
        """
        let path = writeCompose(yaml)
        let config = try ComposeConfigParser.parseBuild(composePath: path)
        XCTAssertEqual(config.images.count, 1)
        XCTAssertEqual(config.images[0], "nginx:latest")
    }

    func testMultipleDistinctImages() throws {
        let yaml = """
        services:
          web:
            image: nginx:latest
            ports:
              - "8080:80"
          db:
            image: postgres:16
        \(validXContainerfy)
        """
        let path = writeCompose(yaml)
        let config = try ComposeConfigParser.parseBuild(composePath: path)
        XCTAssertEqual(config.images.count, 2)
        XCTAssertTrue(config.images.contains("nginx:latest"))
        XCTAssertTrue(config.images.contains("postgres:16"))
    }

    // MARK: - File Not Found

    func testFileNotFound() {
        XCTAssertThrowsError(try ComposeConfigParser.parseBuild(composePath: "/nonexistent/path/compose.yml")) { error in
            guard let ce = error as? CError, case .fileNotFound = ce else {
                return XCTFail("Expected fileNotFound, got: \(error)")
            }
        }
    }

    // MARK: - Services sorted alphabetically

    func testServicesSortedAlphabetically() throws {
        let yaml = """
        services:
          zeta:
            image: nginx
            ports:
              - "8082:80"
          alpha:
            image: nginx
            ports:
              - "8080:80"
          mu:
            image: nginx
            ports:
              - "8081:80"
        \(validXContainerfy)
        """
        let path = writeCompose(yaml)
        let config = try ComposeConfigParser.parseBuild(composePath: path)
        XCTAssertEqual(config.services.map(\.name), ["alpha", "mu", "zeta"])
    }
}
