import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var stateController: VMStateController!
    private var menuBarController: MenuBarController!
    private var vmManager: VMLifecycleManager!
    private var sleepWakeManager: SleepWakeManager!
    private var logsWindowController: LogsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load compose config first (needed for menu bar setup)
        let composeConfig = ComposeConfigParser.load()

        stateController = VMStateController()
        menuBarController = MenuBarController(
            displayName: composeConfig.displayName,
            services: composeConfig.services
        )
        vmManager = VMLifecycleManager(stateController: stateController)
        sleepWakeManager = SleepWakeManager(vmManager: vmManager, stateController: stateController)
        logsWindowController = LogsWindowController(appName: composeConfig.displayName ?? "AppPod")

        vmManager.setComposeConfig(composeConfig)

        // Wire log fetching
        logsWindowController.fetchLogs = { [weak self] in
            guard let self else { return nil }
            return await self.vmManager.fetchLogs()
        }

        // Crash detection from previous run
        if StateFile.detectCrash() {
            print("[App] Previous run crashed — cleaning up stale state file")
            StateFile.remove()
        }

        // Wire state changes to menu bar + state persistence
        stateController.onStateChange = { [weak self] state in
            self?.menuBarController.updateForState(state)
            StateFile.persist(state: state)
        }

        // Wire disk usage warnings to menu bar
        vmManager.onDiskWarning = { [weak self] used, total in
            self?.menuBarController.showDiskWarning(usedMB: used, totalMB: total)
        }

        // Wire menu bar actions
        menuBarController.onStart = { [weak self] in
            guard let self else { return }
            Task {
                self.vmManager.resetAutoRestart()
                await self.vmManager.startVM()
            }
        }

        menuBarController.onStop = { [weak self] in
            guard let self else { return }
            Task {
                await self.vmManager.stopVM()
            }
        }

        menuBarController.onRestart = { [weak self] in
            guard let self else { return }
            Task {
                await self.vmManager.restartVM()
            }
        }

        menuBarController.onViewLogs = { [weak self] in
            self?.logsWindowController.showWindow()
        }

        menuBarController.onRemoveAppData = { [weak self] in
            guard let self else { return }
            Task {
                await self.vmManager.destroyVM()
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
        // Clean state file on normal exit
        StateFile.remove()

        // Defensive cleanup — stopVM is idempotent
        Task {
            await vmManager.stopVM()
        }
    }
}
