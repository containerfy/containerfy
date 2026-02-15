import AppKit
import Foundation

// CLI vs GUI mode detection:
// If argv contains "pack", run CLI mode (no NSApplication).
// Otherwise, launch GUI as normal.

if CommandLine.arguments.count > 1 {
    switch CommandLine.arguments[1] {
    case "pack":
        // CLI mode — run pack command and exit
        let packArgs = Array(CommandLine.arguments.dropFirst(2))
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await PackCommand.run(arguments: packArgs)
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    case "--help", "-h":
        print("Usage: containerfy <command> [flags]")
        print("")
        print("Commands:")
        print("  pack           Build a distributable .app bundle from a docker-compose.yml")
        print("")
        print("Run 'containerfy pack --help' for details.")
        print("")
        print("If no command is given, launches the GUI menu bar app.")
        exit(0)
    default:
        // Unknown command — fall through to GUI mode
        // (The binary may be launched by macOS with arguments like -NSDocumentRevisionsDebugMode)
        break
    }
}

// GUI mode — standard menu bar app
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Menu-bar only, no dock icon
app.run()
