import Foundation

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

    init(onReady: @escaping () -> Void) {
        self.readyCallback = onReady
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
                print("[asr-stderr] \(msg)", terminator: "")
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
                        NSLog("[asr] Python ASR server ready")
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

        do {
            try proc.run()
            print("[asr] Started Python ASR server (pid: \(proc.processIdentifier))")
        } catch {
            print("[asr] Failed to start Python process: \(error)")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        isReady = false
    }

    /// Transcribe WAV audio data. Blocks until result returns.
    func transcribe(wavData: Data, language: String = "zh") -> String {
        guard isReady, let stdin = stdinPipe, let stdout = stdoutPipe else {
            print("[asr] Not ready")
            return ""
        }

        let base64 = wavData.base64EncodedString()
        let request: [String: Any] = ["audio": base64, "language": language]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: request),
              var jsonString = String(data: jsonData, encoding: .utf8) else { return "" }

        jsonString += "\n"

        // Temporarily replace readability handler to capture response synchronously
        let semaphore = DispatchSemaphore(value: 0)
        var result = ""

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
                }
            }
        }

        stdin.fileHandleForWriting.write(jsonString.data(using: .utf8)!)

        _ = semaphore.wait(timeout: .now() + 30) // 30s timeout
        return result
    }
}
