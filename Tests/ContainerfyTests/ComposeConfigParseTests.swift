import XCTest
@testable import ContainerfyCore

final class ComposeConfigParseTests: XCTestCase {

    private typealias CError = ComposeConfigParser.ComposeError

    // MARK: - Port Formats

    func testPortStringHostContainer() throws {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertEqual(config.portMappings.count, 1)
        XCTAssertEqual(config.portMappings[0].hostPort, 8080)
        XCTAssertEqual(config.portMappings[0].containerPort, 80)
    }

    func testPortStringSamePort() throws {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080"
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertEqual(config.portMappings.count, 1)
        XCTAssertEqual(config.portMappings[0].hostPort, 8080)
        XCTAssertEqual(config.portMappings[0].containerPort, 8080)
    }

    func testPortInteger() throws {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - 8080
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertEqual(config.portMappings.count, 1)
        XCTAssertEqual(config.portMappings[0].hostPort, 8080)
        XCTAssertEqual(config.portMappings[0].containerPort, 8080)
    }

    func testPortLongForm() throws {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - published: 8080
                target: 80
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertEqual(config.portMappings.count, 1)
        XCTAssertEqual(config.portMappings[0].hostPort, 8080)
        XCTAssertEqual(config.portMappings[0].containerPort, 80)
    }

    func testPortWithIPPrefix() throws {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "127.0.0.1:8080:80"
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertEqual(config.portMappings.count, 1)
        XCTAssertEqual(config.portMappings[0].hostPort, 8080)
        XCTAssertEqual(config.portMappings[0].containerPort, 80)
    }

    func testPortWithProtocol() throws {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80/tcp"
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertEqual(config.portMappings.count, 1)
        XCTAssertEqual(config.portMappings[0].hostPort, 8080)
        XCTAssertEqual(config.portMappings[0].containerPort, 80)
    }

    // MARK: - Port Edge Cases

    func testMalformedPortStringSkipped() throws {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "abc:xyz"
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertTrue(config.portMappings.isEmpty, "Non-numeric port string should be silently skipped")
        XCTAssertTrue(config.services.isEmpty)
    }

    func testPortOutOfUInt16RangeSkipped() throws {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - 99999
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertTrue(config.portMappings.isEmpty, "Port > 65535 should be silently skipped")
    }

    func testMultiplePortsOnOneService() throws {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
              - "8443:443"
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertEqual(config.portMappings.count, 2)
        XCTAssertEqual(config.services.count, 1)
        XCTAssertEqual(config.services[0].ports.count, 2)
    }

    func testMixOfValidAndInvalidPortsKeepsValid() throws {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
              - "not:a:port:mapping:really"
              - 3000
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertEqual(config.portMappings.count, 2)
        XCTAssertEqual(config.portMappings[0].hostPort, 8080)
        XCTAssertEqual(config.portMappings[1].hostPort, 3000)
    }

    func testLongFormPortWithStringValues() throws {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - published: "8080"
                target: "80"
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertEqual(config.portMappings.count, 1)
        XCTAssertEqual(config.portMappings[0].hostPort, 8080)
        XCTAssertEqual(config.portMappings[0].containerPort, 80)
    }

    // MARK: - Display Name

    func testDisplayNameExplicit() throws {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
        x-containerfy:
          display_name: My Cool App
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertEqual(config.displayName, "My Cool App")
    }

    func testDisplayNameFallbackToName() throws {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
        x-containerfy:
          name: myapp
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertEqual(config.displayName, "myapp")
    }

    func testDisplayNameNone() throws {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertNil(config.displayName)
    }

    // MARK: - Empty / Missing Services

    func testEmptyServicesNoPortMappings() throws {
        let yaml = """
        services:
          worker:
            image: myworker
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertTrue(config.portMappings.isEmpty)
        XCTAssertTrue(config.services.isEmpty)
    }

    func testMissingServicesKeyReturnsEmpty() throws {
        let yaml = """
        x-containerfy:
          name: myapp
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertTrue(config.portMappings.isEmpty)
        XCTAssertTrue(config.services.isEmpty)
    }

    func testServiceWithoutPortsMixedWithServiceWithPorts() throws {
        let yaml = """
        services:
          worker:
            image: myworker
          web:
            image: nginx
            ports:
              - "8080:80"
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertEqual(config.services.count, 1)
        XCTAssertEqual(config.services[0].name, "web")
        XCTAssertEqual(config.portMappings.count, 1)
    }

    // MARK: - Title Case (via ServiceInfo.displayLabel)

    func testTitleCaseHyphen() throws {
        let yaml = """
        services:
          my-service:
            image: nginx
            ports:
              - "8080:80"
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertEqual(config.services[0].displayLabel, "My Service")
    }

    func testTitleCaseUnderscore() throws {
        let yaml = """
        services:
          my_app:
            image: nginx
            ports:
              - "3000:3000"
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertEqual(config.services[0].displayLabel, "My App")
    }

    func testTitleCaseSingleWord() throws {
        let yaml = """
        services:
          nginx:
            image: nginx
            ports:
              - "8080:80"
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertEqual(config.services[0].displayLabel, "Nginx")
    }

    // MARK: - ServiceInfo.openURL

    func testOpenURL() throws {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "3000:80"
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertEqual(config.services[0].openURL, URL(string: "http://127.0.0.1:3000"))
    }

    func testOpenURLNilWhenNoPorts() {
        let info = ServiceInfo(name: "worker", displayLabel: "Worker", ports: [])
        XCTAssertNil(info.openURL)
    }

    func testOpenURLUsesFirstPort() {
        let info = ServiceInfo(name: "web", displayLabel: "Web", ports: [
            PortMapping(hostPort: 3000, containerPort: 80),
            PortMapping(hostPort: 3001, containerPort: 443),
        ])
        XCTAssertEqual(info.openURL, URL(string: "http://127.0.0.1:3000"))
    }

    // MARK: - Multiple Services

    func testMultipleServicesAlphabetical() throws {
        let yaml = """
        services:
          beta:
            image: nginx
            ports:
              - "8081:80"
          alpha:
            image: nginx
            ports:
              - "8080:80"
        """
        let config = try ComposeConfigParser.parse(yaml: yaml)
        XCTAssertEqual(config.services.count, 2)
        XCTAssertEqual(config.services[0].name, "alpha")
        XCTAssertEqual(config.services[1].name, "beta")
        XCTAssertEqual(config.portMappings.count, 2)
    }

    // MARK: - Invalid YAML / Structure

    func testInvalidYAMLThrows() {
        XCTAssertThrowsError(try ComposeConfigParser.parse(yaml: "not: [valid: yaml: {"))
    }

    func testNonDictRootThrowsInvalidFormat() {
        XCTAssertThrowsError(try ComposeConfigParser.parse(yaml: "- just\n- a\n- list\n")) { error in
            guard let ce = error as? CError, case .invalidFormat = ce else {
                return XCTFail("Expected ComposeError.invalidFormat, got: \(error)")
            }
        }
    }

    func testScalarRootThrowsInvalidFormat() {
        XCTAssertThrowsError(try ComposeConfigParser.parse(yaml: "just a string")) { error in
            guard let ce = error as? CError, case .invalidFormat = ce else {
                return XCTFail("Expected ComposeError.invalidFormat, got: \(error)")
            }
        }
    }
}
