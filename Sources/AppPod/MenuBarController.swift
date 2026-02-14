import AppKit

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let menu: NSMenu

    private let statusMenuItem: NSMenuItem
    private let diskWarningMenuItem: NSMenuItem
    private let startMenuItem: NSMenuItem
    private let stopMenuItem: NSMenuItem
    private let restartMenuItem: NSMenuItem
    private let quitMenuItem: NSMenuItem

    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onRestart: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Status: Stopped", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false

        diskWarningMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        diskWarningMenuItem.isEnabled = false
        diskWarningMenuItem.isHidden = true

        startMenuItem = NSMenuItem(title: "Start", action: nil, keyEquivalent: "")
        stopMenuItem = NSMenuItem(title: "Stop", action: nil, keyEquivalent: "")
        restartMenuItem = NSMenuItem(title: "Restart", action: nil, keyEquivalent: "")
        quitMenuItem = NSMenuItem(title: "Quit", action: nil, keyEquivalent: "q")

        menu.addItem(statusMenuItem)
        menu.addItem(diskWarningMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(startMenuItem)
        menu.addItem(stopMenuItem)
        menu.addItem(restartMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitMenuItem)

        statusItem.menu = menu

        if let button = statusItem.button {
            button.title = "AppPod"
        }

        startMenuItem.target = self
        startMenuItem.action = #selector(startClicked)
        stopMenuItem.target = self
        stopMenuItem.action = #selector(stopClicked)
        restartMenuItem.target = self
        restartMenuItem.action = #selector(restartClicked)
        quitMenuItem.target = self
        quitMenuItem.action = #selector(quitClicked)

        updateForState(.stopped)
    }

    func updateForState(_ state: VMState) {
        switch state {
        case .stopped:
            statusMenuItem.title = "Status: Stopped"
            startMenuItem.isEnabled = true
            stopMenuItem.isEnabled = false
            restartMenuItem.isEnabled = false
            clearDiskWarning()
        case .validatingHost:
            statusMenuItem.title = "Status: Validating..."
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = false
            restartMenuItem.isEnabled = false
        case .preparingFirstLaunch:
            statusMenuItem.title = "Status: Preparing first launch..."
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = false
            restartMenuItem.isEnabled = false
        case .startingVM:
            statusMenuItem.title = "Status: Starting VM..."
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = true
            restartMenuItem.isEnabled = false
        case .waitingForHealth:
            statusMenuItem.title = "Status: Waiting for health..."
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = true
            restartMenuItem.isEnabled = false
        case .running:
            statusMenuItem.title = "Status: Running"
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = true
            restartMenuItem.isEnabled = true
        case .paused:
            statusMenuItem.title = "Status: Paused"
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = true
            restartMenuItem.isEnabled = false
        case .stopping:
            statusMenuItem.title = "Status: Stopping..."
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = false
            restartMenuItem.isEnabled = false
        case .destroying:
            statusMenuItem.title = "Status: Removing VM..."
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = false
            restartMenuItem.isEnabled = false
        case .error:
            statusMenuItem.title = "Status: Error"
            startMenuItem.isEnabled = true
            stopMenuItem.isEnabled = true
            restartMenuItem.isEnabled = true
        }

        if let button = statusItem.button {
            switch state {
            case .running:
                button.title = "▶ AppPod"
            case .paused:
                button.title = "⏸ AppPod"
            case .error:
                button.title = "⚠ AppPod"
            case .stopped:
                button.title = "AppPod"
            default:
                button.title = "⏳ AppPod"
            }
        }
    }

    func showDiskWarning(usedMB: Int, totalMB: Int) {
        let percent = totalMB > 0 ? Int(Double(usedMB) / Double(totalMB) * 100) : 0
        diskWarningMenuItem.title = "Disk: \(percent)% used (\(usedMB)/\(totalMB) MB)"
        diskWarningMenuItem.isHidden = false
    }

    private func clearDiskWarning() {
        diskWarningMenuItem.isHidden = true
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

    @objc private func quitClicked() {
        onQuit?()
    }
}
