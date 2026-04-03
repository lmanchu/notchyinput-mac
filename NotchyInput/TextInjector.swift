import Cocoa
import Carbon.HIToolbox

/// Injects text into the active application via clipboard + CGEvent Cmd+V.
/// Uses CGEvent directly from this process (which has Accessibility permission).
enum TextInjector {
    static var targetApp: NSRunningApplication?

    static func saveTargetApp() {
        targetApp = NSWorkspace.shared.frontmostApplication
    }

    private static func log(_ msg: String) {
        let line = "\(Date()) [inject] \(msg)\n"
        let path = NSHomeDirectory() + "/notchyinput-app.log"
        if let data = line.data(using: .utf8) {
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
            }
        }
    }

    static func inject(_ text: String) {
        guard !text.isEmpty else { return }

        // 1. Set clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 2. Activate target app and wait for it to come to front
        if let app = targetApp {
            log("Activating: \(app.localizedName ?? "?") pid=\(app.processIdentifier)")
            app.activate()

            // Wait until the app is actually frontmost (up to 500ms)
            for _ in 0..<10 {
                usleep(50_000) // 50ms
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                    break
                }
            }
            log("Frontmost now: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        }

        // 3. Small extra delay for focus to fully settle
        usleep(100_000) // 100ms

        // 4. Check accessibility permission
        let trusted = AXIsProcessTrusted()
        log("AXIsProcessTrusted: \(trusted)")
        if !trusted {
            log("WARNING: No accessibility permission! CGEvent.post will silently fail.")
            // Prompt user for permission
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            return
        }

        // 5. Send Cmd+V via CGEvent
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: false) else {
            log("Failed to create CGEvent")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        usleep(10_000) // 10ms between down and up
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        log("CGEvent Cmd+V posted")
    }
}
