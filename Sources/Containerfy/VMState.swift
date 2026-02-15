import Foundation

enum VMState: String, Sendable {
    case stopped
    case validatingHost
    case preparingFirstLaunch
    case startingVM
    case waitingForHealth
    case running
    case paused
    case stopping
    case destroying
    case error

    func canTransition(to target: VMState) -> Bool {
        switch (self, target) {
        case (.stopped, .validatingHost),
             (.stopped, .startingVM),
             (.stopped, .preparingFirstLaunch),
             (.stopped, .destroying):
            return true

        case (.validatingHost, .preparingFirstLaunch),
             (.validatingHost, .startingVM),
             (.validatingHost, .error),
             (.validatingHost, .stopped):
            return true

        case (.preparingFirstLaunch, .startingVM),
             (.preparingFirstLaunch, .error):
            return true

        case (.startingVM, .waitingForHealth),
             (.startingVM, .error):
            return true

        case (.waitingForHealth, .running),
             (.waitingForHealth, .error),
             (.waitingForHealth, .stopping):
            return true

        case (.running, .stopping),
             (.running, .paused),
             (.running, .error):
            return true

        case (.paused, .running),
             (.paused, .stopping),
             (.paused, .error):
            return true

        case (.stopping, .stopped),
             (.stopping, .error):
            return true

        case (.destroying, .stopped),
             (.destroying, .error):
            return true

        case (.error, .startingVM),
             (.error, .validatingHost),
             (.error, .stopping),
             (.error, .stopped),
             (.error, .destroying):
            return true

        default:
            return false
        }
    }
}

@MainActor
final class VMStateController {
    private(set) var currentState: VMState = .stopped
    private(set) var errorReason: String?
    var onStateChange: ((VMState) -> Void)?

    @discardableResult
    func transition(to newState: VMState, reason: String? = nil) -> Bool {
        guard currentState.canTransition(to: newState) else {
            print("[State] Invalid transition: \(currentState.rawValue) → \(newState.rawValue)")
            return false
        }
        print("[State] \(currentState.rawValue) → \(newState.rawValue)")
        currentState = newState
        if newState == .error {
            errorReason = reason
        } else {
            errorReason = nil
        }
        onStateChange?(newState)
        return true
    }
}
