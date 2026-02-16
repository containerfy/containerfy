import AppKit

public class AppDelegate: NSObject, NSApplicationDelegate {
    private var stateController: VMStateController!
    private var menuBarController: MenuBarController!
    private var podman: PodmanMachine!
    private var logsWindowController: LogsWindowController!
    private var stateFile: StateFile!

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        try? Paths.ensureDirectoryExists()

        let composeConfig = ComposeConfigParser.load()

        stateController = VMStateController()
        stateFile = StateFile()
        menuBarController = MenuBarController(
            displayName: composeConfig.displayName,
            services: composeConfig.services
        )
        podman = PodmanMachine(stateController: stateController, composeConfig: composeConfig)
        logsWindowController = LogsWindowController(appName: composeConfig.displayName ?? "Containerfy")

        // Wire log fetching
        logsWindowController.fetchLogs = { [weak self] in
            guard let self else { return nil }
            return await self.podman.fetchLogs()
        }

        // Crash detection from previous run
        if stateFile.detectCrash() {
            print("[App] Previous run crashed — cleaning up stale state file")
            stateFile.remove()
        }

        // Wire state changes to menu bar + state persistence
        stateController.onStateChange = { [weak self] state in
            self?.menuBarController.updateForState(state)
            self?.stateFile.persist(state: state)
        }

        // Wire menu bar actions
        menuBarController.onViewLogs = { [weak self] in
            self?.logsWindowController.showWindow()
        }

        menuBarController.onRemoveAppData = { [weak self] in
            guard let self else { return }
            Task {
                await self.podman.destroyVM()
            }
        }

        menuBarController.onQuit = { [weak self] in
            guard let self else { return }
            Task {
                await self.podman.stopVM()
                NSApp.terminate(nil)
            }
        }

        // Auto-start on launch
        Task {
            await podman.startVM()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        stateFile.remove()

        Task {
            await podman.stopVM()
        }
    }
}
