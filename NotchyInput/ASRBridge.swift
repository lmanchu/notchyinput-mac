import Foundation

extension ISO8601DateFormatter {
    static let diag = ISO8601DateFormatter()
}

/// Append-only diagnostic black box. Writes to ~/.notchyinput/diagnostics.log
/// in ALL build configs (unlike the `#if DEBUG` NSLog paths), so a random
/// failure leaves a forensic trail we can read after the fact instead of
/// forcing a blind restart. Self-rotates at 2 MB.
enum DiagnosticsLog {
    private static let queue = DispatchQueue(label: "notchy.diag")
    private static let maxBytes = 2_000_000

    private static var dir: String { NSHomeDirectory() + "/.notchyinput" }
    private static var path: String { dir + "/diagnostics.log" }

    /// `fields` uses KeyValuePairs so the log column order is stable/readable.
    static func log(_ category: String, _ event: String, _ fields: KeyValuePairs<String, Any> = [:]) {
        let ts = ISO8601DateFormatter.diag.string(from: Date())
        var line = "\(ts) \(category) \(event)"
        for (k, v) in fields { line += " \(k)=\(v)" }
        line += "\n"
        queue.async {
            let fm = FileManager.default
            if !fm.fileExists(atPath: dir) {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            rotateIfNeeded(fm)
            guard let data = line.data(using: .utf8) else { return }
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
            } else {
                fm.createFile(atPath: path, contents: data)
            }
        }
    }

    private static func rotateIfNeeded(_ fm: FileManager) {
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size > maxBytes else { return }
        let rotated = path + ".1"
        try? fm.removeItem(atPath: rotated)
        try? fm.moveItem(atPath: path, toPath: rotated)
    }
}

/// A selectable ASR model. `id` is the Hugging Face repo passed to the Python
/// sidecar via the NOTCHY_ASR_MODEL env var.
struct ASRModelOption {
    let id: String
    let label: String
    let note: String
}

/// Single source of truth for the ASR model list and the user's choice.
/// Only models verified to load with mlx_qwen3_asr 0.3.2 are listed —
/// mlx-community quantized variants (4/5/6/8-bit) fail with "Missing parameters"
/// because their quant format differs from what load_models expects, so they
/// are deliberately excluded.
enum ASRModelRegistry {
    static let userDefaultsKey = "asrModelID"

    static let options: [ASRModelOption] = [
        ASRModelOption(id: "Qwen/Qwen3-ASR-0.6B",
                       label: "Qwen3-ASR-0.6B",
                       note: "fast · ~1.8 GB RAM"),
        ASRModelOption(id: "Qwen/Qwen3-ASR-1.7B",
                       label: "Qwen3-ASR-1.7B",
                       note: "accurate · ~4.9 GB RAM · 3.4 GB first download"),
    ]

    /// Currently selected model id (falls back to the first/default option).
    static var currentID: String {
        let stored = UserDefaults.standard.string(forKey: userDefaultsKey)
        if let stored, options.contains(where: { $0.id == stored }) {
            return stored
        }
        return options[0].id
    }

    static func setCurrentID(_ id: String) {
        UserDefaults.standard.set(id, forKey: userDefaultsKey)
    }
}

/// Bridges Swift to the Python Qwen3-ASR server via a long-running subprocess.
/// Protocol: JSON lines over stdin/stdout.
/// Swift → Python: {"audio": "<base64 WAV>", "language": "zh"}
/// Python → Swift: {"text": "...", "elapsed": 1.23}
final class ASRBridge {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var isReady = false
    private let readyCallback: () -> Void
    private let restartQueue = DispatchQueue(label: "asr.restart")
    private var isRestarting = false
    private var healthTimer: Timer?

    // Black-box forensics: timestamps so a snapshot can record how long ago the
    // model was last healthy / last produced a real transcription.
    private var spawnAt: Date?
    private var lastReadyAt: Date?
    private var lastTxnOkAt: Date?
    private var readyWatchdog: Timer?

    /// If the sidecar hasn't signaled ready within this many seconds of spawn,
    /// treat it as a stuck load and restart — closes the pre-ready blind spot
    /// where the health timer (which only starts after ready) never runs.
    private let readyTimeoutSec: TimeInterval = 90

    init(onReady: @escaping () -> Void) {
        self.readyCallback = onReady
    }

    /// Subprocess alive AND model loaded.
    private var isHealthy: Bool {
        return isReady && (process?.isRunning ?? false)
    }

    // MARK: – Periodic health check

    private func startHealthTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.healthTimer?.invalidate()
            self?.healthTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.performHealthCheck()
            }
        }
    }

    private func stopHealthTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.healthTimer?.invalidate()
            self?.healthTimer = nil
        }
    }

    // MARK: – Black-box snapshot & ready watchdog

    /// Dump the full failure context to the diagnostics log BEFORE we restart,
    /// so an auto-recovered failure still leaves forensic evidence.
    private func diagSnapshot(_ trigger: String, rss: Double = -1) {
        let now = Date()
        DiagnosticsLog.log("asr", "snapshot", [
            "trigger": trigger,
            "pid": process?.processIdentifier ?? -1,
            "rss_mb": rss,
            "running": process?.isRunning ?? false,
            "isReady": isReady,
            "sinceReady_s": lastReadyAt.map { Int(now.timeIntervalSince($0)) } ?? -1,
            "sinceTxnOk_s": lastTxnOkAt.map { Int(now.timeIntervalSince($0)) } ?? -1,
            "uptime_s": spawnAt.map { Int(now.timeIntervalSince($0)) } ?? -1
        ])
    }

    private func startReadyWatchdog() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.readyWatchdog?.invalidate()
            self.readyWatchdog = Timer.scheduledTimer(withTimeInterval: self.readyTimeoutSec, repeats: false) { [weak self] _ in
                guard let self = self, !self.isReady else { return }
                NSLog("[asr] ready-timeout — sidecar never signaled ready, restarting")
                self.diagSnapshot("ready-timeout")
                self.process?.terminate()  // terminationHandler → scheduleRestart
            }
        }
    }

    private func stopReadyWatchdog() {
        DispatchQueue.main.async { [weak self] in
            self?.readyWatchdog?.invalidate()
            self?.readyWatchdog = nil
        }
    }

    /// Sends {"ping":true} and expects {"pong":true,"rss_mb":...} within 5 s.
    /// Restarts if no response or RSS is below threshold.
    private func performHealthCheck() {
        guard isHealthy, let stdin = stdinPipe, let stdout = stdoutPipe else { return }

        guard let pingData = "{\"ping\":true}\n".data(using: .utf8) else { return }

        let semaphore = DispatchSemaphore(value: 0)
        var rssMB: Double = 0
        var modelOk = false

        let prev = stdout.fileHandleForReading.readabilityHandler
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let line = String(data: data, encoding: .utf8),
                  let jsonData = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else { return }
            if dict["pong"] as? Bool == true {
                rssMB = dict["rss_mb"] as? Double ?? 0
                modelOk = dict["model_ok"] as? Bool ?? false
                semaphore.signal()
            }
        }

        do {
            try stdin.fileHandleForWriting.write(contentsOf: pingData)
        } catch {
            NSLog("[asr] health-ping write failed: %@", String(describing: error))
            stdout.fileHandleForReading.readabilityHandler = prev
            scheduleRestart(reason: "health-ping write failure")
            return
        }

        // The probe runs a real (tiny) inference, so allow longer than a bare
        // ping — a paged-out model may take a few seconds to fault back in.
        let timedOut = semaphore.wait(timeout: .now() + 10) == .timedOut
        stdout.fileHandleForReading.readabilityHandler = prev

        if timedOut {
            NSLog("[asr] health probe timeout — model stuck, restarting")
            diagSnapshot("health-probe-timeout", rss: rssMB)
            process?.terminate()
            return
        }
        // Health = the model could actually run inference. RSS is NOT used to
        // decide life/death (MLX frees memory after inference; a healthy idle
        // model sits at ~180 MB), only recorded for forensics.
        if !modelOk {
            NSLog("[asr] health probe: model_ok=false — inference failed, restarting")
            diagSnapshot("health-probe-failed", rss: rssMB)
            process?.terminate()
            return
        }
        DiagnosticsLog.log("asr", "health", ["rss_mb": rssMB, "model_ok": true])
        NSLog("[asr] health probe OK — model_ok, RSS %.0f MB", rssMB)
    }

    func start() {
        let appBundle = Bundle.main.bundlePath
        let resourcesDir = appBundle + "/Contents/Resources"

        // Look for asr_server.py: embedded in bundle first, then dev paths
        let possibleScripts = [
            resourcesDir + "/asr/asr_server.py",
            (appBundle as NSString).deletingLastPathComponent + "/asr/asr_server.py",
            NSHomeDirectory() + "/Dropbox/Dev/notchyinput-mac/asr/asr_server.py"
        ]

        guard let scriptPath = possibleScripts.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            NSLog("[asr] ERROR: asr_server.py not found")
            return
        }

        // Find python3: embedded in bundle first, then venv, then system
        let embeddedPython = resourcesDir + "/python/bin/python3"
        let projectDir = (scriptPath as NSString).deletingLastPathComponent + "/.."
        let venvPython = projectDir + "/venv/bin/python3"
        let pythonCandidates = [
            embeddedPython,
            venvPython,
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        let pythonPath = pythonCandidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/python3"
        NSLog("[asr] Using python: %@", pythonPath)
        NSLog("[asr] Using script: %@", scriptPath)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = ["-u", scriptPath]

        // Set PYTHONPATH: embedded site-packages in bundle takes priority
        var env = ProcessInfo.processInfo.environment
        var pythonPaths: [String] = []

        // Embedded site-packages (from pack_release.sh)
        let embeddedSitePackages = resourcesDir + "/python/lib/python3.12/site-packages"
        if FileManager.default.fileExists(atPath: embeddedSitePackages) {
            pythonPaths.append(embeddedSitePackages)
        }
        // Also check adjacent site-packages (legacy)
        let adjacentSitePackages = (scriptPath as NSString).deletingLastPathComponent + "/site-packages"
        if FileManager.default.fileExists(atPath: adjacentSitePackages) {
            pythonPaths.append(adjacentSitePackages)
        }
        if !pythonPaths.isEmpty {
            let existing = env["PYTHONPATH"] ?? ""
            let joined = pythonPaths.joined(separator: ":")
            env["PYTHONPATH"] = existing.isEmpty ? joined : "\(joined):\(existing)"
        }

        // Set PYTHONHOME for embedded Python so it finds stdlib
        let embeddedHome = resourcesDir + "/python"
        if FileManager.default.fileExists(atPath: embeddedHome + "/lib/python3.12") {
            env["PYTHONHOME"] = embeddedHome
        }

        // Tell the Python sidecar which Qwen3-ASR model to load.
        env["NOTCHY_ASR_MODEL"] = ASRModelRegistry.currentID
        NSLog("[asr] Using model: %@", ASRModelRegistry.currentID)

        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let msg = String(data: data, encoding: .utf8) {
                // Land the sidecar's stderr (load failures, tracebacks) in the
                // black box — Release builds have no console, so this was lost.
                let trimmed = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { DiagnosticsLog.log("asr-stderr", trimmed) }
            }
        }

        stdinPipe = stdin
        stdoutPipe = stdout
        process = proc

        // Read stdout asynchronously for ready/loading signals
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

            for jsonLine in line.components(separatedBy: "\n") {
                guard let jsonData = jsonLine.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }

                if let status = dict["status"] as? String {
                    if status == "ready" {
                        self?.isReady = true
                        self?.lastReadyAt = Date()
                        NSLog("[asr] Python ASR server ready")
                        DiagnosticsLog.log("asr", "ready", [
                            "uptime_s": self?.spawnAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
                        ])
                        self?.stopReadyWatchdog()
                        self?.startHealthTimer()
                        DispatchQueue.main.async {
                            RecordingState.current = .idle
                            self?.readyCallback()
                        }
                    } else if status == "loading" {
                        let message = dict["message"] as? String ?? "Loading..."
                        let progress = dict["progress"] as? Float ?? 0
                        NSLog("[asr] Loading: %@ (%.0f%%)", message, progress * 100)
                        DispatchQueue.main.async {
                            RecordingState.current = .loading(message: message, progress: progress)
                        }
                    }
                }
            }
        }

        // Detect subprocess death and auto-respawn so a silent crash
        // doesn't leave Swift writing into a dead pipe (the 21-hour zombie bug).
        proc.terminationHandler = { [weak self] p in
            NSLog("[asr] Python subprocess died: pid=%d status=%d reason=%d",
                  p.processIdentifier, p.terminationStatus, p.terminationReason.rawValue)
            DiagnosticsLog.log("asr", "died", [
                "pid": p.processIdentifier,
                "status": p.terminationStatus,
                "reason": p.terminationReason.rawValue
            ])
            guard let self = self else { return }
            self.isReady = false
            self.scheduleRestart(reason: "subprocess exit")
        }

        do {
            try proc.run()
            spawnAt = Date()
            print("[asr] Started Python ASR server (pid: \(proc.processIdentifier))")
            DiagnosticsLog.log("asr", "spawn", [
                "pid": proc.processIdentifier,
                "model": ASRModelRegistry.currentID
            ])
            startReadyWatchdog()
        } catch {
            print("[asr] Failed to start Python process: \(error)")
            DiagnosticsLog.log("asr", "spawn-failed", ["error": String(describing: error)])
        }
    }

    /// Debounced restart — safe to call from terminationHandler or transcribe timeout.
    private func scheduleRestart(reason: String) {
        restartQueue.async { [weak self] in
            guard let self = self else { return }
            if self.isRestarting { return }
            self.isRestarting = true
            NSLog("[asr] Scheduling restart (reason: %@)", reason)
            DiagnosticsLog.log("asr", "restart", ["reason": reason])
            self.stopHealthTimer()
            self.stopReadyWatchdog()
            self.isReady = false
            self.process = nil
            self.stdinPipe = nil
            self.stdoutPipe = nil
            DispatchQueue.main.async {
                self.start()
                self.restartQueue.async { self.isRestarting = false }
            }
        }
    }

    func stop() {
        stopHealthTimer()
        stopReadyWatchdog()
        // Clear terminationHandler first — otherwise when the subprocess actually
        // exits (possibly minutes later, e.g. after macOS sleep delivers the queued
        // signal), the handler fires scheduleRestart() and spawns an extra sidecar
        // we no longer track. That's how 7 zombie sidecars accumulated over a week.
        if let proc = process {
            proc.terminationHandler = nil
            proc.terminate()
            // Best-effort wait, then SIGKILL escalation so subprocess can't linger
            // suspended through sleep and respawn-race on wake.
            let deadline = Date().addingTimeInterval(2)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        isReady = false
    }

    /// Transcribe WAV audio data. Blocks until result returns.
    func transcribe(wavData: Data, language: String = "zh") -> String {
        guard isHealthy, let stdin = stdinPipe, let stdout = stdoutPipe else {
            NSLog("[asr] Not healthy (isReady=%@ running=%@) — scheduling restart",
                  isReady ? "true" : "false",
                  (process?.isRunning ?? false) ? "true" : "false")
            scheduleRestart(reason: "transcribe on unhealthy bridge")
            return ""
        }

        let base64 = wavData.base64EncodedString()
        let request: [String: Any] = ["audio": base64, "language": language]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: request),
              var jsonString = String(data: jsonData, encoding: .utf8) else { return "" }

        jsonString += "\n"

        // Temporarily replace readability handler to capture response synchronously.
        // Handles both success {"text":...} and failure {"error":...} — either signals
        // the semaphore so we never wait the full 30s on a known error.
        let semaphore = DispatchSemaphore(value: 0)
        var result = ""
        var errorResponse: String?

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

            for jsonLine in line.components(separatedBy: "\n") {
                guard let jsonData = jsonLine.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }

                if let text = dict["text"] as? String {
                    result = text
                    if let elapsed = dict["elapsed"] as? Double {
                        print("[asr] Transcribed in \(String(format: "%.2f", elapsed))s: \(text)")
                    }
                    semaphore.signal()
                } else if let err = dict["error"] as? String {
                    errorResponse = err
                    NSLog("[asr] Transcription error from server: %@", err)
                    semaphore.signal()
                }
            }
        }

        // Writing to a closed pipe raises SIGPIPE by default on macOS.
        // Guard with a running check and wrap write to avoid app crash.
        guard process?.isRunning == true else {
            scheduleRestart(reason: "process died before write")
            return ""
        }
        do {
            try stdin.fileHandleForWriting.write(contentsOf: jsonString.data(using: .utf8)!)
        } catch {
            NSLog("[asr] Write to stdin failed: %@", String(describing: error))
            scheduleRestart(reason: "stdin write failure")
            return ""
        }

        let timeoutResult = semaphore.wait(timeout: .now() + 30)
        if timeoutResult == .timedOut {
            DiagnosticsLog.log("txn", "timeout", ["running": process?.isRunning ?? false])
            NSLog("[asr] Transcribe timed out after 30s — checking subprocess health")
            if !(process?.isRunning ?? false) {
                scheduleRestart(reason: "timeout with dead subprocess")
            } else {
                // Process alive but model stuck — still respawn to recover.
                NSLog("[asr] Subprocess alive but unresponsive; forcing restart")
                process?.terminate()
                // terminationHandler will call scheduleRestart()
            }
            return ""
        }
        if let err = errorResponse {
            NSLog("[asr] Returning empty result due to error: %@", err)
            DiagnosticsLog.log("txn", "error", ["msg": err])
            return ""
        }
        if !result.isEmpty { lastTxnOkAt = Date() }
        DiagnosticsLog.log("txn", result.isEmpty ? "empty" : "ok")
        return result
    }
}
