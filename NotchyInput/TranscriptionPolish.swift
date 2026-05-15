import Foundation

/// LLM-driven post-processing for raw ASR output.
/// Inspired by nick1ee/ZeroType's prompt-engineering core (the bit that's actually
/// valuable from that project — its app shell is Flutter and not portable).
///
/// Pipeline:  raw ASR text → polish() → cleaned text → TextInjector
///
/// Backend: CLIProxyAPI (default 127.0.0.1:8317), OpenAI-compatible.
/// Config:  ~/.notchyinput/config.json
/// Dict:    ~/.notchyinput/dictionary.json
///
/// Failure mode: any network/parse error returns the raw input unchanged.
/// We never block the user on polish — the raw transcription always wins as fallback.
enum TranscriptionPolish {

    // MARK: - Public entry

    /// Polishes raw ASR text. Synchronous (called from a background thread already).
    /// Returns raw text unchanged on any failure or when polish is disabled.
    static func polish(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }

        let cfg = Config.load()
        guard cfg.enabled else { return raw }

        // Try primary, then fallback.
        if let polished = callLLM(text: trimmed, model: cfg.model, cfg: cfg) {
            return polished
        }
        if let fallback = cfg.fallbackModel,
           let polished = callLLM(text: trimmed, model: fallback, cfg: cfg) {
            NSLog("[polish] primary failed, fallback succeeded with \(fallback)")
            return polished
        }
        NSLog("[polish] all models failed, returning raw")
        return raw
    }

    // MARK: - LLM call

    private static func callLLM(text: String, model: String, cfg: Config) -> String? {
        guard let url = URL(string: cfg.endpoint) else { return nil }

        let dictTerms = Dictionary.load()
        let prompt = buildPrompt(raw: text, dictionary: dictTerms)

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.2,
            "max_tokens": 1024,
            "stream": false
        ]

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = cfg.timeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cfg.apiKey.isEmpty {
            req.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = payload

        let semaphore = DispatchSemaphore(value: 0)
        var result: String?

        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                NSLog("[polish] %@ network error: %@", model, error.localizedDescription)
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data = data else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                NSLog("[polish] %@ HTTP %d", model, code)
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String
            else {
                NSLog("[polish] %@ unexpected response shape", model)
                return
            }
            let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                result = cleaned
            }
        }
        task.resume()

        let timedOut = semaphore.wait(timeout: .now() + cfg.timeoutSeconds + 1) == .timedOut
        if timedOut {
            task.cancel()
            NSLog("[polish] %@ timed out", model)
            return nil
        }
        return result
    }

    // MARK: - Prompt

    private static let systemPrompt = """
    你是繁體中文語音轉錄後處理引擎，專為台灣使用者設計。
    輸入是麥克風 ASR 的原始轉錄，輸出是清理後可直接貼上的文字。
    只輸出 polished 文字本身——不要解釋、不要加引號、不要任何 prefix 或 suffix。
    """

    private static func buildPrompt(raw: String, dictionary: [DictionaryEntry]) -> String {
        let dictBlock: String
        if dictionary.isEmpty {
            dictBlock = "（無自訂字典）"
        } else {
            dictBlock = dictionary.map { entry in
                let aliases = entry.aliases.joined(separator: "、")
                return "  - 「\(entry.term)」(可能被聽成：\(aliases))"
            }.joined(separator: "\n")
        }

        return """
        規則：
        1. 晶晶體支援：中英混用句保持自然，英文單字保留原文，不要翻譯成中文
        2. 過濾廢詞：「嗯」「啊」「呃」「喔」「那個」「然後」「基本上」「就是說」 一律刪除
        3. 口誤修正：偵測到「不對」「應該是」「我說錯了」「才對」「我的意思是」 → 砍掉前段錯誤，保留修正後內容
        4. 智慧標點：根據語意補逗號、句號；不要過度斷句、不要加問號驚嘆號除非語意明顯
        5. 條列轉換：偵測到「第一」「第二」「第三」或「首先」「然後」「最後」 → 轉成 「1. 」「2. 」格式並換行
        6. 格式口令：「空格」→ 空白；「底線」→ "_"；「驚嘆號」→ "!"；「冒號」→ ":"
        7. 字典優先：以下術語優先採用左側拼寫
        \(dictBlock)
        8. 空白保護：如果輸入只有雜訊或空白，輸出空字串
        9. 不要幻想：絕對不能加入輸入中沒有的內容；寧可保守也不要創造

        輸入：
        \(raw)
        """
    }

    // MARK: - Config

    struct Config {
        var enabled: Bool
        var endpoint: String
        var apiKey: String
        var model: String
        var fallbackModel: String?
        var timeoutSeconds: TimeInterval

        /// Disabled by default; users must edit ~/.notchyinput/config.json to enable.
        /// Default endpoint is OpenAI's public API; any OpenAI-compatible endpoint works
        /// (Anthropic via proxy, Together, OpenRouter, Ollama, vLLM, LM Studio, CLIProxyAPI, etc.)
        static let `default` = Config(
            enabled: false,
            endpoint: "https://api.openai.com/v1/chat/completions",
            apiKey: "",
            model: "gpt-4o-mini",
            fallbackModel: nil,
            timeoutSeconds: 10
        )

        static var configPath: String {
            NSHomeDirectory() + "/.notchyinput/config.json"
        }

        static func load() -> Config {
            seedIfMissing()
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let polish = json["polish"] as? [String: Any]
            else {
                return .default
            }
            var cfg = Config.default
            if let v = polish["enabled"] as? Bool { cfg.enabled = v }
            if let v = polish["endpoint"] as? String { cfg.endpoint = v }
            if let v = polish["api_key"] as? String { cfg.apiKey = v }
            if let v = polish["model"] as? String { cfg.model = v }
            if let v = polish["fallback_model"] as? String, !v.isEmpty { cfg.fallbackModel = v }
            if let v = polish["timeout_seconds"] as? Double { cfg.timeoutSeconds = v }
            return cfg
        }

        /// Writes a commented stub config + empty dictionary on first launch so users
        /// can find the file and edit it. Never overwrites existing config.
        static func seedIfMissing() {
            let dir = NSHomeDirectory() + "/.notchyinput"
            if !FileManager.default.fileExists(atPath: dir) {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            if !FileManager.default.fileExists(atPath: configPath) {
                let stub = """
                {
                  "_README": [
                    "Set polish.enabled to true and fill api_key to turn on LLM polish.",
                    "Default endpoint is OpenAI; any OpenAI-compatible endpoint works:",
                    "  - OpenAI:     https://api.openai.com/v1/chat/completions",
                    "  - OpenRouter: https://openrouter.ai/api/v1/chat/completions",
                    "  - Together:   https://api.together.xyz/v1/chat/completions",
                    "  - Ollama:     http://127.0.0.1:11434/v1/chat/completions   (model e.g. qwen2.5:7b)",
                    "  - LM Studio:  http://127.0.0.1:1234/v1/chat/completions",
                    "Models tested for Traditional Chinese polish:",
                    "  - gpt-4o-mini (cheap, fast, good)",
                    "  - claude-3-5-haiku (fast, decent zh-TW)",
                    "  - qwen2.5-72b-instruct via OpenRouter (best zh-TW)",
                    "fallback_model is optional; leave empty string for no fallback."
                  ],
                  "polish": {
                    "enabled": false,
                    "endpoint": "https://api.openai.com/v1/chat/completions",
                    "api_key": "",
                    "model": "gpt-4o-mini",
                    "fallback_model": "",
                    "timeout_seconds": 10
                  }
                }

                """
                try? stub.write(toFile: configPath, atomically: true, encoding: .utf8)
            }
            let dictPath = NSHomeDirectory() + "/.notchyinput/dictionary.json"
            if !FileManager.default.fileExists(atPath: dictPath) {
                let stub = """
                [
                  { "term": "NotchyInput", "aliases": ["notch input", "naughty input"] }
                ]

                """
                try? stub.write(toFile: dictPath, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Dictionary

    struct DictionaryEntry {
        let term: String
        let aliases: [String]
    }

    enum Dictionary {
        static func load() -> [DictionaryEntry] {
            let path = NSHomeDirectory() + "/.notchyinput/dictionary.json"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else {
                return []
            }
            return arr.compactMap { dict in
                guard let term = dict["term"] as? String else { return nil }
                let aliases = (dict["aliases"] as? [String]) ?? []
                return DictionaryEntry(term: term, aliases: aliases)
            }
        }
    }
}
