import AppKit
import ContainerfyCore
import Foundation

// CLI vs GUI mode detection:
// If argv contains "pack", run CLI mode (no NSApplication).
// Otherwise, launch GUI as normal.

@main
enum ContainerfyApp {
    static func main() {
        // Disable stdout buffering so output is visible immediately,
        // even when piped through a shell script or captured.
        setbuf(stdout, nil)
        setbuf(stderr, nil)

        if CommandLine.arguments.count > 1 {
            switch CommandLine.arguments[1] {
            case "pack":
                let packArgs = Array(CommandLine.arguments.dropFirst(2))
                let command = PackCommand()
                let code = command.run(arguments: packArgs)
                exit(code)
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
    }
}
