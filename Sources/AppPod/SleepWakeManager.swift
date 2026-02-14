import AppKit
import Virtualization

@MainActor
final class SleepWakeManager {
    private let vmManager: VMLifecycleManager
    private let stateController: VMStateController
    private var willSleepObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?

    init(vmManager: VMLifecycleManager, stateController: VMStateController) {
        self.vmManager = vmManager
        self.stateController = stateController
        registerObservers()
    }

    private func registerObservers() {
        let center = NSWorkspace.shared.notificationCenter

        willSleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.handleSleep()
            }
        }

        didWakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.handleWake()
            }
        }
    }

    private func handleSleep() async {
        guard stateController.currentState == .running,
              let vm = vmManager.virtualMachine else { return }

        print("[Sleep] Pausing VM...")
        do {
            try await vm.pause()
            stateController.transition(to: .paused)
            print("[Sleep] VM paused")
        } catch {
            print("[Sleep] Pause failed: \(error.localizedDescription)")
            stateController.transition(to: .error, reason: "Pause failed: \(error.localizedDescription)")
        }
    }

    private func handleWake() async {
        guard stateController.currentState == .paused,
              let vm = vmManager.virtualMachine else { return }

        print("[Wake] Resuming VM...")
        do {
            try await vm.resume()
            stateController.transition(to: .running)
            print("[Wake] VM resumed")
        } catch {
            print("[Wake] Resume failed: \(error.localizedDescription)")
            stateController.transition(to: .error, reason: "Resume failed: \(error.localizedDescription)")
        }
    }

    deinit {
        if let observer = willSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = didWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
