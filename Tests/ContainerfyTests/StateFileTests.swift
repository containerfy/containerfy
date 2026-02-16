import XCTest
@testable import ContainerfyCore

final class StateFileTests: XCTestCase {

    private var tempDir: URL!
    private var stateFileURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("statefile-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        stateFileURL = tempDir.appendingPathComponent("state.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Persist / Read Roundtrip

    func testPersistAndReadRoundtrip() {
        let sf = StateFile(fileURL: stateFileURL, currentPID: 12345)
        sf.persist(state: .running, vmStartTime: nil)

        let persisted = sf.read()
        XCTAssertNotNil(persisted)
        XCTAssertEqual(persisted?.vmState, "running")
        XCTAssertEqual(persisted?.pid, 12345)
        XCTAssertNil(persisted?.vmStartTime)
    }

    func testReadReturnsNilWhenMissing() {
        let sf = StateFile(fileURL: stateFileURL, currentPID: 1)
        XCTAssertNil(sf.read())
    }

    func testReadReturnsNilOnCorruptJSON() {
        try! "not valid json {{{".data(using: .utf8)!.write(to: stateFileURL)
        let sf = StateFile(fileURL: stateFileURL, currentPID: 1)
        XCTAssertNil(sf.read())
    }

    // MARK: - Remove

    func testRemoveDeletesFile() {
        let sf = StateFile(fileURL: stateFileURL, currentPID: 1)
        sf.persist(state: .stopped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateFileURL.path))

        sf.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFileURL.path))
    }

    func testRemoveNoOpWhenMissing() {
        let sf = StateFile(fileURL: stateFileURL, currentPID: 1)
        sf.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFileURL.path))
    }

    // MARK: - Crash Detection

    func testDetectCrashFalseWhenStopped() {
        let sf = StateFile(fileURL: stateFileURL, currentPID: 1)
        sf.persist(state: .stopped)
        XCTAssertFalse(sf.detectCrash())
    }

    func testDetectCrashTrueWhenRunningAndPIDDead() {
        let deadPID: Int32 = 99999
        let sf = StateFile(fileURL: stateFileURL, currentPID: deadPID)
        sf.persist(state: .running)

        let checker = StateFile(fileURL: stateFileURL, currentPID: 1)
        XCTAssertTrue(checker.detectCrash())
    }

    func testDetectCrashFalseWhenNoStateFile() {
        let sf = StateFile(fileURL: stateFileURL, currentPID: 1)
        XCTAssertFalse(sf.detectCrash())
    }

    func testDetectCrashTrueWhenStartingAndPIDDead() {
        let deadPID: Int32 = 99999
        let sf = StateFile(fileURL: stateFileURL, currentPID: deadPID)
        sf.persist(state: .starting)

        let checker = StateFile(fileURL: stateFileURL, currentPID: 1)
        XCTAssertTrue(checker.detectCrash())
    }

    // MARK: - PID Persistence

    func testPersistIncludesPID() {
        let sf = StateFile(fileURL: stateFileURL, currentPID: 42)
        sf.persist(state: .running)

        let persisted = sf.read()
        XCTAssertEqual(persisted?.pid, 42)
    }

    // MARK: - vmStartTime

    func testPersistIncludesVMStartTime() {
        let sf = StateFile(fileURL: stateFileURL, currentPID: 1)
        let startTime = Date(timeIntervalSince1970: 1000000)
        sf.persist(state: .running, vmStartTime: startTime)

        let persisted = sf.read()
        XCTAssertNotNil(persisted?.vmStartTime)
        XCTAssertEqual(persisted!.vmStartTime!.timeIntervalSince1970, 1000000, accuracy: 1)
    }
}
