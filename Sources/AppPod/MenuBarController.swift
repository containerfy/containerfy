import AppKit

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let menu: NSMenu

    private let statusMenuItem: NSMenuItem
    private let startMenuItem: NSMenuItem
    private let stopMenuItem: NSMenuItem
    private let quitMenuItem: NSMenuItem

    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Status: Stopped", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false

        startMenuItem = NSMenuItem(title: "Start", action: nil, keyEquivalent: "")
        stopMenuItem = NSMenuItem(title: "Stop", action: nil, keyEquivalent: "")
        quitMenuItem = NSMenuItem(title: "Quit", action: nil, keyEquivalent: "q")

        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(startMenuItem)
        menu.addItem(stopMenuItem)
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
        case .validatingHost:
            statusMenuItem.title = "Status: Validating..."
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = false
        case .startingVM:
            statusMenuItem.title = "Status: Starting VM..."
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = true
        case .waitingForHealth:
            statusMenuItem.title = "Status: Waiting for health..."
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = true
        case .running:
            statusMenuItem.title = "Status: Running"
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = true
        case .stopping:
            statusMenuItem.title = "Status: Stopping..."
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = false
        case .error:
            statusMenuItem.title = "Status: Error"
            startMenuItem.isEnabled = true
            stopMenuItem.isEnabled = true
        }

        if let button = statusItem.button {
            switch state {
            case .running:
                button.title = "▶ AppPod"
            case .error:
                button.title = "⚠ AppPod"
            case .stopped:
                button.title = "AppPod"
            default:
                button.title = "⏳ AppPod"
            }
        }
    }

    @objc private func startClicked() {
        onStart?()
    }

    @objc private func stopClicked() {
        onStop?()
    }

    @objc private func quitClicked() {
        onQuit?()
    }
}
