import AppKit
import ServiceManagement

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let appName: String

    private let statusMenuItem: NSMenuItem
    private var openMenuItems: [NSMenuItem] = []
    private let viewLogsMenuItem: NSMenuItem
    private let launchAtLoginMenuItem: NSMenuItem
    private let removeAppDataMenuItem: NSMenuItem
    private let quitMenuItem: NSMenuItem

    var onQuit: (() -> Void)?
    var onViewLogs: (() -> Void)?
    var onRemoveAppData: (() -> Void)?

    init(displayName: String?, services: [ServiceInfo]) {
        self.appName = displayName ?? "Containerfy"

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()

        // Status line (disabled, informational)
        statusMenuItem = NSMenuItem(title: "Status: Stopped", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false

        // View Logs
        viewLogsMenuItem = NSMenuItem(title: "View Logs...", action: nil, keyEquivalent: "l")

        // Launch at Login
        launchAtLoginMenuItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")

        // Remove App Data
        removeAppDataMenuItem = NSMenuItem(title: "Remove App Data...", action: nil, keyEquivalent: "")

        // Quit
        quitMenuItem = NSMenuItem(title: "Quit \(appName)", action: nil, keyEquivalent: "q")

        super.init()

        // Build menu structure
        menu.addItem(statusMenuItem)
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
            setOpenItemsEnabled(false)
            viewLogsMenuItem.isEnabled = false
        case .starting:
            statusMenuItem.title = "Status: Starting..."
            setOpenItemsEnabled(false)
            viewLogsMenuItem.isEnabled = false
        case .running:
            statusMenuItem.title = "Status: Running"
            setOpenItemsEnabled(true)
            viewLogsMenuItem.isEnabled = true
        case .stopping:
            statusMenuItem.title = "Status: Stopping..."
            setOpenItemsEnabled(false)
            viewLogsMenuItem.isEnabled = false
        case .error:
            statusMenuItem.title = "Status: Error"
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
            case .error:
                symbolName = "exclamationmark.triangle"
            default:
                symbolName = "hourglass"
            }
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: state.rawValue)
            button.image?.isTemplate = true
        }
    }

    // MARK: - Private Helpers

    private func setOpenItemsEnabled(_ enabled: Bool) {
        for item in openMenuItems {
            item.isEnabled = enabled
        }
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
        alert.informativeText = "This will stop the VM and delete all application data, including container volumes. This cannot be undone."
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
