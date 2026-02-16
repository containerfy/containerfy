import XCTest
@testable import ContainerfyCore

final class VMStateTests: XCTestCase {

    // MARK: - Valid Transitions

    func testValidTransitionsFromStopped() {
        XCTAssertTrue(VMState.stopped.canTransition(to: .starting))
    }

    func testValidTransitionsFromStarting() {
        XCTAssertTrue(VMState.starting.canTransition(to: .running))
        XCTAssertTrue(VMState.starting.canTransition(to: .error))
    }

    func testValidTransitionsFromRunning() {
        XCTAssertTrue(VMState.running.canTransition(to: .stopping))
        XCTAssertTrue(VMState.running.canTransition(to: .error))
    }

    func testValidTransitionsFromStopping() {
        XCTAssertTrue(VMState.stopping.canTransition(to: .stopped))
        XCTAssertTrue(VMState.stopping.canTransition(to: .error))
    }

    func testValidTransitionsFromError() {
        XCTAssertTrue(VMState.error.canTransition(to: .starting))
        XCTAssertTrue(VMState.error.canTransition(to: .stopping))
        XCTAssertTrue(VMState.error.canTransition(to: .stopped))
    }

    // MARK: - Invalid Transitions

    func testInvalidTransitionStoppedToRunning() {
        XCTAssertFalse(VMState.stopped.canTransition(to: .running))
    }

    func testInvalidTransitionRunningToStarting() {
        XCTAssertFalse(VMState.running.canTransition(to: .starting))
    }

    func testInvalidTransitionStartingToStopped() {
        XCTAssertFalse(VMState.starting.canTransition(to: .stopped))
    }

    func testInvalidTransitionStoppingToRunning() {
        XCTAssertFalse(VMState.stopping.canTransition(to: .running))
    }

    // MARK: - Self-Transitions

    func testSelfTransitionsInvalid() {
        let allStates: [VMState] = [.stopped, .starting, .running, .stopping, .error]
        for state in allStates {
            XCTAssertFalse(
                state.canTransition(to: state),
                "\(state.rawValue) → \(state.rawValue) should be invalid"
            )
        }
    }

    // MARK: - Exhaustive

    func testExhaustiveTransitions() {
        let allStates: [VMState] = [.stopped, .starting, .running, .stopping, .error]

        let validPairs: Set<String> = [
            "stopped→starting",
            "starting→running", "starting→error",
            "running→stopping", "running→error",
            "stopping→stopped", "stopping→error",
            "error→starting", "error→stopping", "error→stopped",
        ]

        for from in allStates {
            for to in allStates {
                let key = "\(from.rawValue)→\(to.rawValue)"
                let expected = validPairs.contains(key)
                XCTAssertEqual(
                    from.canTransition(to: to), expected,
                    "Transition \(key): expected \(expected), got \(!expected)"
                )
            }
        }
    }

    // MARK: - VMStateController

    @MainActor
    func testControllerValidTransition() {
        let controller = VMStateController()
        XCTAssertTrue(controller.transition(to: .starting))
        XCTAssertEqual(controller.currentState, .starting)
    }

    @MainActor
    func testControllerInvalidTransition() {
        let controller = VMStateController()
        XCTAssertFalse(controller.transition(to: .running))
        XCTAssertEqual(controller.currentState, .stopped)
    }

    @MainActor
    func testControllerFullLifecycle() {
        let controller = VMStateController()
        var log: [VMState] = []
        controller.onStateChange = { log.append($0) }

        XCTAssertTrue(controller.transition(to: .starting))
        XCTAssertTrue(controller.transition(to: .running))
        XCTAssertTrue(controller.transition(to: .stopping))
        XCTAssertTrue(controller.transition(to: .stopped))

        XCTAssertEqual(log, [.starting, .running, .stopping, .stopped])
    }

    @MainActor
    func testControllerErrorSetsReason() {
        let controller = VMStateController()
        controller.transition(to: .starting)
        controller.transition(to: .error, reason: "podman failed")
        XCTAssertEqual(controller.errorReason, "podman failed")
    }

    @MainActor
    func testControllerNonErrorClearsReason() {
        let controller = VMStateController()
        controller.transition(to: .starting)
        controller.transition(to: .error, reason: "err")
        controller.transition(to: .starting)
        XCTAssertNil(controller.errorReason)
    }
}
