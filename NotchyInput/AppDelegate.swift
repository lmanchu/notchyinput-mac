import AppKit
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var notchWindow: NotchWindow?
    private let hotkeyMonitor = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private var asrBridge: ASRBridge!
    private var isRecording = false
    private var isToggleMode = false
    private var asrReady = false

    private func log(_ msg: String) {
        #if DEBUG
        let line = "\(Date()) [app] \(msg)\n"
        let path = NSHomeDirectory() + "/notchyinput-app.log"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path) {
                if let fh = FileHandle(forWritingAtPath: path) {
                    fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[app] applicationDidFinishLaunching")
        TranscriptionPolish.Config.seedIfMissing()
        requestAccessibilityIfNeeded()
        setupStatusItem()
        setupNotchWindow()
        setupHotkey()
        setupRecorder()
        startASR()
        observeSleepWake()
        NSLog("[app] All setup complete")
    }

    // Sleep/wake breaks the stdin/stdout pipe to the Python sidecar without
    // killing the subprocess, so terminationHandler never fires. Respawn the
    // bridge on wake to recover.
    private func observeSleepWake() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(systemWillSleep),
                       name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(systemDidWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func systemWillSleep() {
        NSLog("[app] systemWillSleep — stopping ASR bridge")
        log("systemWillSleep")
        asrReady = false
        asrBridge?.stop()
    }

    @objc private func systemDidWake() {
        NSLog("[app] systemDidWake — restarting ASR bridge")
        log("systemDidWake")
        asrReady = false
        asrBridge?.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.asrBridge?.start()
        }
    }

    private func requestAccessibilityIfNeeded() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            log("Accessibility permission requested (not yet granted)")
        } else {
            log("Accessibility permission OK")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor.stop()
        recorder.stopEngine()
        asrBridge.stop()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "NotchyInput")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupNotchWindow() {
        notchWindow = NotchWindow { [weak self] in
            self?.toggleRecording()
        }
    }

    private func setupHotkey() {
        hotkeyMonitor.start { [weak self] action in
            DispatchQueue.main.async {
                switch action {
                case .pushToTalkDown:
                    self?.startRecording(toggle: false)
                case .pushToTalkUp:
                    self?.stopRecording()
                case .togglePressed:
                    self?.toggleRecording()
                }
            }
        }
    }

    private func setupRecorder() {
        recorder.levelCallback = { level in
            RecordingState.pushLevel(level)
        }
        recorder.startEngine()
    }

    private func startASR() {
        log("Starting ASR bridge...")
        asrBridge = ASRBridge { [weak self] in
            self?.asrReady = true
            self?.log("ASR READY!")
            // Update status item to indicate ready
            DispatchQueue.main.async {
                self?.statusItem.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "NotchyInput - Ready")
            }
        }
        asrBridge.start()
    }

    // MARK: - Recording control

    private func startRecording(toggle: Bool) {
        log("startRecording called. isRecording=\(isRecording) asrReady=\(asrReady)")
        guard !isRecording else { log("Already recording, skip"); return }
        guard asrReady else {
            log("ASR not ready, ignoring")
            return
        }
        TextInjector.saveTargetApp()
        isRecording = true
        isToggleMode = toggle
        RecordingState.recordingStart = Date()
        RecordingState.waveform = Array(repeating: 0, count: 30)
        RecordingState.current = .recording
        recorder.start()
        playSound("Tink") // subtle start sound
        log("Recording started (toggle: \(toggle))")
    }

    private func stopRecording() {
        log("stopRecording called. isRecording=\(isRecording)")
        guard isRecording else { log("Not recording, skip"); return }
        isRecording = false
        RecordingState.current = .processing
        log("Recording stopped, getting audio...")

        let wavData = recorder.stop()
        log("WAV data size: \(wavData.count) bytes")
        guard !wavData.isEmpty else {
            log("Empty audio, back to idle")
            RecordingState.current = .idle
            return
        }

        // Transcribe on background thread; then polish via LLM if enabled.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.log("Sending to ASR...")
            let raw = self.asrBridge.transcribe(wavData: wavData)
            self.log("ASR result: '\(raw)'")

            // Polish layer (no-op when disabled or on failure — returns raw)
            let final: String
            if raw.isEmpty {
                final = raw
            } else {
                final = TranscriptionPolish.polish(raw)
                if final != raw {
                    self.log("Polished: '\(final)'")
                }
            }

            DispatchQueue.main.async {
                if !final.isEmpty {
                    RecordingState.current = .done(text: final)
                    self.playSound("Pop") // done sound
                    TextInjector.inject(final)
                    self.log("Injected: \(final)")

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        RecordingState.current = .idle
                    }
                } else {
                    self.log("Empty transcription")
                    RecordingState.current = .idle
                }
            }
        }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording(toggle: true)
        }
    }

    // MARK: - Status item

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu()
        } else {
            toggleRecording()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let modelLabel = ASRModelRegistry.options.first { $0.id == ASRModelRegistry.currentID }?.label ?? "Qwen3-ASR"
        let statusText = asrReady ? "\(modelLabel) Ready" : "Loading \(modelLabel)..."
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(.separator())

        let pttItem = NSMenuItem(title: "Push-to-talk: Right Alt", action: nil, keyEquivalent: "")
        pttItem.isEnabled = false
        menu.addItem(pttItem)

        let toggleItem = NSMenuItem(title: "Toggle: Right Cmd", action: nil, keyEquivalent: "")
        toggleItem.isEnabled = false
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let polishCfg = TranscriptionPolish.Config.load()
        let polishStatus = polishCfg.enabled ? "Polish: \(polishCfg.model)" : "Polish: off"
        let polishItem = NSMenuItem(title: polishStatus, action: nil, keyEquivalent: "")
        polishItem.isEnabled = false
        menu.addItem(polishItem)

        let openConfigItem = NSMenuItem(title: "Open Polish Config...", action: #selector(openPolishConfig), keyEquivalent: ",")
        openConfigItem.target = self
        menu.addItem(openConfigItem)

        let openDictItem = NSMenuItem(title: "Open Dictionary...", action: #selector(openPolishDictionary), keyEquivalent: "")
        openDictItem.target = self
        menu.addItem(openDictItem)

        menu.addItem(.separator())

        // ASR model picker — switching writes UserDefaults and restarts the engine.
        let modelMenuItem = NSMenuItem(title: "ASR Model", action: nil, keyEquivalent: "")
        let modelSubmenu = NSMenu()
        let currentModelID = ASRModelRegistry.currentID
        for opt in ASRModelRegistry.options {
            let item = NSMenuItem(title: "\(opt.label)  —  \(opt.note)",
                                  action: #selector(selectASRModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = opt.id
            item.state = (opt.id == currentModelID) ? .on : .off
            modelSubmenu.addItem(item)
        }
        modelMenuItem.submenu = modelSubmenu
        menu.addItem(modelMenuItem)

        menu.addItem(.separator())

        let restartASRItem = NSMenuItem(title: "Restart ASR Engine", action: #selector(restartASR), keyEquivalent: "r")
        restartASRItem.target = self
        menu.addItem(restartASRItem)

        let restartAppItem = NSMenuItem(title: "Restart NotchyInput", action: #selector(restartApp), keyEquivalent: "R")
        restartAppItem.target = self
        menu.addItem(restartAppItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit NotchyInput", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        self.statusItem.menu = menu
        self.statusItem.button?.performClick(nil)
        self.statusItem.menu = nil
    }

    // MARK: - Preferences

    @objc private func openPolishConfig() {
        // Ensure file exists, then open in default editor
        _ = TranscriptionPolish.Config.load()
        NSWorkspace.shared.open(URL(fileURLWithPath: TranscriptionPolish.Config.configPath))
    }

    @objc private func openPolishDictionary() {
        _ = TranscriptionPolish.Config.load() // also seeds dictionary stub
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.notchyinput/dictionary.json"))
    }

    // MARK: - Model selection

    @objc private func selectASRModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if id == ASRModelRegistry.currentID {
            NSLog("[app] ASR model unchanged: %@", id)
            return
        }
        ASRModelRegistry.setCurrentID(id)
        NSLog("[app] ASR model switched to %@ — restarting engine", id)
        log("ASR model -> \(id)")
        restartASR()
    }

    // MARK: - Restart actions

    @objc private func restartASR() {
        NSLog("[app] manual ASR restart triggered from menu")
        log("manual restart ASR")
        asrReady = false
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "NotchyInput - Restarting")
        }
        asrBridge?.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.asrBridge?.start()
        }
    }

    @objc private func restartApp() {
        NSLog("[app] manual app restart triggered from menu")
        log("manual restart app")
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", bundlePath]
        do {
            try task.run()
        } catch {
            NSLog("[app] failed to relaunch: \(error)")
            return
        }
        // Give /usr/bin/open a moment to fork the new instance before we exit,
        // otherwise the parent's death can race the child's launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Sound

    private func playSound(_ name: String) {
        // Use built-in macOS system sounds
        NSSound(named: name)?.play()
    }
}
