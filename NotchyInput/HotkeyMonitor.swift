import Cocoa

/// Monitors global keyboard events for push-to-talk and click-toggle hotkeys.
/// Uses NSEvent global monitor — requires Accessibility permission.
final class HotkeyMonitor {
    enum Action {
        case pushToTalkDown
        case pushToTalkUp
        case togglePressed
    }

    // Key codes
    private let pttKeyCode: UInt16 = 61    // alt_r
    private let toggleKeyCode: UInt16 = 54 // cmd_r

    private var pttPressed = false
    private var togglePressed = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var callback: ((Action) -> Void)?

    private let logPath = NSHomeDirectory() + "/notchyinput-hotkey.log"

    private func log(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let fh = FileHandle(forWritingAtPath: logPath) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
    }

    func start(callback: @escaping (Action) -> Void) {
        self.callback = callback

        log("Starting hotkey monitor...")

        // Global monitor — fires when other apps are focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            self?.log("GLOBAL event type=\(event.type.rawValue) keyCode=\(event.keyCode)")
            self?.handleEvent(event)
        }

        // Local monitor — fires when this app is focused
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            self?.log("LOCAL event type=\(event.type.rawValue) keyCode=\(event.keyCode)")
            self?.handleEvent(event)
            return event
        }

        log("Monitor started. globalMonitor=\(globalMonitor != nil), localMonitor=\(localMonitor != nil)")
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    private func handleEvent(_ event: NSEvent) {
        let keyCode = event.keyCode

        if event.type == .flagsChanged {
            let flags = event.modifierFlags
            let rawFlags = flags.rawValue
            log("handleEvent keyCode=\(keyCode) rawFlags=\(rawFlags) option=\(flags.contains(.option)) cmd=\(flags.contains(.command)) pttPressed=\(pttPressed)")

            // alt_r (push-to-talk): press = start, release = stop
            if keyCode == pttKeyCode {
                let altDown = flags.contains(.option)
                if altDown && !pttPressed {
                    pttPressed = true
                    log(">>> PTT DOWN")
                    callback?(.pushToTalkDown)
                } else if !altDown && pttPressed {
                    pttPressed = false
                    log(">>> PTT UP")
                    callback?(.pushToTalkUp)
                }
            }

            // cmd_r (toggle): press = toggle
            if keyCode == toggleKeyCode {
                let cmdDown = flags.contains(.command)
                if cmdDown && !togglePressed {
                    togglePressed = true
                    log(">>> TOGGLE (cmd_r)")
                    callback?(.togglePressed)
                } else if !cmdDown && togglePressed {
                    togglePressed = false
                }
            }
        }
    }
}
