import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var stateController: VMStateController!
    private var menuBarController: MenuBarController!
    private var vmManager: VMLifecycleManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        stateController = VMStateController()
        menuBarController = MenuBarController()
        vmManager = VMLifecycleManager(stateController: stateController)

        // Wire state changes to menu bar
        stateController.onStateChange = { [weak self] state in
            self?.menuBarController.updateForState(state)
        }

        // Wire menu bar actions
        menuBarController.onStart = { [weak self] in
            guard let self else { return }
            Task {
                await self.vmManager.startVM()
            }
        }

        menuBarController.onStop = { [weak self] in
            guard let self else { return }
            Task {
                await self.vmManager.stopVM()
            }
        }

        menuBarController.onQuit = { [weak self] in
            guard let self else { return }
            Task {
                await self.vmManager.stopVM()
                NSApp.terminate(nil)
            }
        }

        // Auto-start VM on launch
        Task {
            await vmManager.startVM()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Defensive cleanup — stopVM is idempotent
        Task {
            await vmManager.stopVM()
        }
    }
}
