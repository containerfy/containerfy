import Foundation

enum VMState: String, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case error

    func canTransition(to target: VMState) -> Bool {
        switch (self, target) {
        case (.stopped, .starting):
            return true
        case (.starting, .running),
             (.starting, .error):
            return true
        case (.running, .stopping),
             (.running, .error):
            return true
        case (.stopping, .stopped),
             (.stopping, .error):
            return true
        case (.error, .starting),
             (.error, .stopping),
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
