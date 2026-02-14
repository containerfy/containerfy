import AppKit
import ServiceManagement

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let appName: String

    private let statusMenuItem: NSMenuItem
    private let diskWarningMenuItem: NSMenuItem
    private var openMenuItems: [NSMenuItem] = []
    private let viewLogsMenuItem: NSMenuItem
    private let startMenuItem: NSMenuItem
    private let stopMenuItem: NSMenuItem
    private let restartMenuItem: NSMenuItem
    private let launchAtLoginMenuItem: NSMenuItem
    private let removeAppDataMenuItem: NSMenuItem
    private let quitMenuItem: NSMenuItem

    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onRestart: (() -> Void)?
    var onQuit: (() -> Void)?
    var onViewLogs: (() -> Void)?
    var onRemoveAppData: (() -> Void)?

    init(displayName: String?, services: [ServiceInfo]) {
        self.appName = displayName ?? "AppPod"

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()

        // Status line (disabled, informational)
        statusMenuItem = NSMenuItem(title: "Status: Stopped", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false

        // Disk warning (hidden by default)
        diskWarningMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        diskWarningMenuItem.isEnabled = false
        diskWarningMenuItem.isHidden = true

        // View Logs
        viewLogsMenuItem = NSMenuItem(title: "View Logs...", action: nil, keyEquivalent: "l")

        // Start / Stop / Restart
        startMenuItem = NSMenuItem(title: "Start", action: nil, keyEquivalent: "")
        stopMenuItem = NSMenuItem(title: "Stop", action: nil, keyEquivalent: "")
        restartMenuItem = NSMenuItem(title: "Restart", action: nil, keyEquivalent: "")

        // Launch at Login
        launchAtLoginMenuItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")

        // Remove App Data
        removeAppDataMenuItem = NSMenuItem(title: "Remove App Data...", action: nil, keyEquivalent: "")

        // Quit
        quitMenuItem = NSMenuItem(title: "Quit \(appName)", action: nil, keyEquivalent: "q")

        super.init()

        // Build menu structure
        menu.addItem(statusMenuItem)
        menu.addItem(diskWarningMenuItem)
        menu.addItem(NSMenuItem.separator())

        // Dynamic "Open" items from services with ports
        for service in services {
            guard let url = service.openURL else { continue }
            let item = NSMenuItem(
                title: "Open \(service.displayLabel)",
                action: #selector(openServiceClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = url
            item.isEnabled = false
            openMenuItems.append(item)
            menu.addItem(item)
        }

        if !openMenuItems.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        viewLogsMenuItem.target = self
        viewLogsMenuItem.action = #selector(viewLogsClicked)
        menu.addItem(viewLogsMenuItem)
        menu.addItem(NSMenuItem.separator())

        restartMenuItem.target = self
        restartMenuItem.action = #selector(restartClicked)
        menu.addItem(restartMenuItem)

        stopMenuItem.target = self
        stopMenuItem.action = #selector(stopClicked)
        menu.addItem(stopMenuItem)

        startMenuItem.target = self
        startMenuItem.action = #selector(startClicked)
        menu.addItem(startMenuItem)
        menu.addItem(NSMenuItem.separator())

        launchAtLoginMenuItem.target = self
        launchAtLoginMenuItem.action = #selector(toggleLaunchAtLogin)
        menu.addItem(launchAtLoginMenuItem)

        removeAppDataMenuItem.target = self
        removeAppDataMenuItem.action = #selector(removeAppDataClicked)
        menu.addItem(removeAppDataMenuItem)
        menu.addItem(NSMenuItem.separator())

        quitMenuItem.target = self
        quitMenuItem.action = #selector(quitClicked)
        menu.addItem(quitMenuItem)

        statusItem.menu = menu

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: "Stopped")
            button.image?.isTemplate = true
            button.title = " \(appName)"
            button.imagePosition = .imageLeading
        }

        updateForState(.stopped)
        updateLaunchAtLoginState()
    }

    // MARK: - State Updates

    func updateForState(_ state: VMState) {
        switch state {
        case .stopped:
            statusMenuItem.title = "Status: Stopped"
            startMenuItem.isEnabled = true
            stopMenuItem.isEnabled = false
            restartMenuItem.isEnabled = false
            setOpenItemsEnabled(false)
            viewLogsMenuItem.isEnabled = false
            clearDiskWarning()
        case .validatingHost:
            statusMenuItem.title = "Status: Validating..."
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = false
            restartMenuItem.isEnabled = false
            setOpenItemsEnabled(false)
            viewLogsMenuItem.isEnabled = false
        case .preparingFirstLaunch:
            statusMenuItem.title = "Status: Preparing first launch..."
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = false
            restartMenuItem.isEnabled = false
            setOpenItemsEnabled(false)
            viewLogsMenuItem.isEnabled = false
        case .startingVM:
            statusMenuItem.title = "Status: Starting VM..."
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = true
            restartMenuItem.isEnabled = false
            setOpenItemsEnabled(false)
            viewLogsMenuItem.isEnabled = false
        case .waitingForHealth:
            statusMenuItem.title = "Status: Waiting for health..."
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = true
            restartMenuItem.isEnabled = false
            setOpenItemsEnabled(false)
            viewLogsMenuItem.isEnabled = true
        case .running:
            statusMenuItem.title = "Status: Running"
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = true
            restartMenuItem.isEnabled = true
            setOpenItemsEnabled(true)
            viewLogsMenuItem.isEnabled = true
        case .paused:
            statusMenuItem.title = "Status: Paused"
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = true
            restartMenuItem.isEnabled = false
            setOpenItemsEnabled(false)
            viewLogsMenuItem.isEnabled = false
        case .stopping:
            statusMenuItem.title = "Status: Stopping..."
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = false
            restartMenuItem.isEnabled = false
            setOpenItemsEnabled(false)
            viewLogsMenuItem.isEnabled = false
        case .destroying:
            statusMenuItem.title = "Status: Removing VM..."
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = false
            restartMenuItem.isEnabled = false
            setOpenItemsEnabled(false)
            viewLogsMenuItem.isEnabled = false
        case .error:
            statusMenuItem.title = "Status: Error"
            startMenuItem.isEnabled = true
            stopMenuItem.isEnabled = true
            restartMenuItem.isEnabled = true
            setOpenItemsEnabled(false)
            viewLogsMenuItem.isEnabled = true
        }

        // Update status bar icon
        if let button = statusItem.button {
            let symbolName: String
            switch state {
            case .stopped:
                symbolName = "stop.circle"
            case .running:
                symbolName = "play.circle.fill"
            case .paused:
                symbolName = "pause.circle"
            case .error:
                symbolName = "exclamationmark.triangle"
            default:
                symbolName = "hourglass"
            }
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: state.rawValue)
            button.image?.isTemplate = true
        }
    }

    func showDiskWarning(usedMB: Int, totalMB: Int) {
        let percent = totalMB > 0 ? Int(Double(usedMB) / Double(totalMB) * 100) : 0
        diskWarningMenuItem.title = "Disk: \(percent)% used (\(usedMB)/\(totalMB) MB)"
        diskWarningMenuItem.isHidden = false
    }

    // MARK: - Private Helpers

    private func setOpenItemsEnabled(_ enabled: Bool) {
        for item in openMenuItems {
            item.isEnabled = enabled
        }
    }

    private func clearDiskWarning() {
        diskWarningMenuItem.isHidden = true
    }

    private func updateLaunchAtLoginState() {
        launchAtLoginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: - Actions

    @objc private func openServiceClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func viewLogsClicked() {
        onViewLogs?()
    }

    @objc private func startClicked() {
        onStart?()
    }

    @objc private func stopClicked() {
        onStop?()
    }

    @objc private func restartClicked() {
        onRestart?()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            let service = SMAppService.mainApp
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            print("[Prefs] Launch at Login toggle failed: \(error.localizedDescription)")
        }
        updateLaunchAtLoginState()
    }

    @objc private func removeAppDataClicked() {
        let alert = NSAlert()
        alert.messageText = "Remove App Data?"
        alert.informativeText = "This will stop the VM and delete all application data, including Docker volumes. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            onRemoveAppData?()
        }
    }

    @objc private func quitClicked() {
        onQuit?()
    }
}
