# Changelog

All notable changes to NotchyInput will be documented here.

## [1.0.1] — 2026-05-15

### Added
- **Logo / brand identity** — V2 indigo "Speak. Type." design across AppIcon (10 sizes), 1280×640 README banner, `.icns`, and 3 SVG variants saved under `assets/logo/`.
- **Xcode asset catalog compilation** — `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon` set on target configs so future builds compile `Assets.xcassets` and embed the icon. Previous builds produced empty `Resources/` and fell back to generic icon.
- **LLM transcription polish layer** (`TranscriptionPolish.swift`) — post-ASR cleanup pass via any OpenAI-compatible chat completions endpoint. Internalizes nine prompt rules adapted from `nick1ee/ZeroType`: 晶晶體 (zh+en mixing) / 廢詞過濾 / 口誤修正 / 智慧標點 / 序數→條列 / 格式口令 / 字典優先 / 空白保護 / no-hallucination clause.
- **User-configurable polish** — config at `~/.notchyinput/config.json`, custom dictionary at `~/.notchyinput/dictionary.json`, both seeded with commented stubs on first launch. Default endpoint is OpenAI's public API; works with OpenRouter, Together, Ollama, LM Studio, or any compatible endpoint. Disabled by default — users opt in.
- **Status bar menu items** — "Polish: off/<model>" status row, "Open Polish Config..." (⌘,), "Open Dictionary...".
- **ASR state machine skeleton** (`ASRState.swift`) — actor-based state machine with explicit transitions, drop-in target for `ASRBridge`'s implicit `{isReady, isRestarting}` bag. Not wired yet.
- Network entitlement `com.apple.security.network.client` for outbound polish API calls.

### Fixed
- **Animations finally appear** — the SwiftUI tree inside the Dynamic Island was being **remounted on every state and hover change** because `NotchWindow` reassigned `NSHostingView.rootView` three times per update. SwiftUI saw a fresh root each time, so `withAnimation` / `.transition` / `@State`-driven effects were always reset. Introduced `RecordingViewModel: ObservableObject` as the SwiftUI-observable source of truth; `NSHostingView` is now initialized once and SwiftUI diffs in place via `@Published`.
- **Code signing + TCC stability** — `pack_release.sh` now signs bottom-up with Developer ID Application + hardened runtime + entitlements, so binary rebuilds don't drift the cdhash and orphan TCC permissions. Optional notarization step gated on `NOTARIZE_PROFILE` env var.
- **Hardened-runtime entitlements** added for future embedded-Python work: `allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation`, `allow-dyld-environment-variables`.
- **`pack_release.sh` configuration mismatch** — was looking for built artifact in Debug path despite building Release.

### Carried over from prior working tree
- ASR sidecar sleep/wake recovery (`NSWorkspace.willSleepNotification` / `didWakeNotification`).
- Health-ping watchdog (RSS threshold + 5s response timeout, restart on miss).
- Subprocess zombie defense (terminationHandler nilled before terminate to avoid late-signal respawn).

### Distribution
- **Notarized + stapled** by Apple notary service (submission `1d6e8091-…`, status Accepted ~90s after upload). `spctl -a -v` reports `accepted, source=Notarized Developer ID`. First-launch Gatekeeper warning is gone — DMG opens with a double-click on any Mac.

### Known limitations
- Apple Silicon only (mlx requirement). macOS 13.0+.
- `ASRState` actor exists but isn't wired into `ASRBridge` yet.

## [1.0.0] — 2026-04-17

Initial release.
