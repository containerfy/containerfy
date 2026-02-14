import Foundation

enum VMState: String, Sendable {
    case stopped
    case validatingHost
    case startingVM
    case waitingForHealth
    case running
    case stopping
    case error

    func canTransition(to target: VMState) -> Bool {
        switch (self, target) {
        case (.stopped, .validatingHost),
             (.stopped, .startingVM):
            return true

        case (.validatingHost, .startingVM),
             (.validatingHost, .error),
             (.validatingHost, .stopped):
            return true

        case (.startingVM, .waitingForHealth),
             (.startingVM, .error):
            return true

        case (.waitingForHealth, .running),
             (.waitingForHealth, .error),
             (.waitingForHealth, .stopping):
            return true

        case (.running, .stopping),
             (.running, .error):
            return true

        case (.stopping, .stopped),
             (.stopping, .error):
            return true

        case (.error, .startingVM),
             (.error, .stopped):
            return true

        default:
            return false
        }
    }
}

@MainActor
final class VMStateController {
    private(set) var currentState: VMState = .stopped
    var onStateChange: ((VMState) -> Void)?

    @discardableResult
    func transition(to newState: VMState) -> Bool {
        guard currentState.canTransition(to: newState) else {
            print("[State] Invalid transition: \(currentState.rawValue) → \(newState.rawValue)")
            return false
        }
        print("[State] \(currentState.rawValue) → \(newState.rawValue)")
        currentState = newState
        onStateChange?(newState)
        return true
    }
}
