# NotchyInput

Voice input for macOS that lives in your MacBook notch.

Push-to-talk with Right Alt, release to transcribe and paste. Uses [Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) running locally via MLX — no cloud, no API key, no subscription.

## Features

- **Push-to-talk** — Hold Right Alt to record, release to transcribe and paste
- **Click toggle** — Right Cmd to start/stop recording
- **Notch UI** — Recording indicator lives in the MacBook notch area
- **Local ASR** — Qwen3-ASR 0.6B via MLX, runs entirely on-device
- **Chinese → Traditional** — Automatic simplified-to-traditional Chinese conversion
- **Zero dependencies** — Native Swift app, no Electron, no browser

## Requirements

- macOS 13.0+
- Apple Silicon (M1/M2/M3/M4) — required for MLX
- ~1.8GB disk space for the ASR model (downloaded on first launch)

## Install

Download the latest `.dmg` from [Releases](https://github.com/lmanchu/notchyinput-mac/releases), open it, drag to Applications.

First launch:
1. Grant **Microphone** permission when prompted
2. Grant **Accessibility** permission (System Settings → Privacy & Security → Accessibility)
3. Wait for the ASR model to download (~1.8GB, one-time)

## Build from Source

```bash
git clone https://github.com/lmanchu/notchyinput-mac
cd notchyinput-mac

# Build
xcodebuild -project NotchyInput.xcodeproj -scheme NotchyInput -configuration Release build

# Set up Python ASR server
python3 -m venv venv
source venv/bin/activate
pip install -r asr/requirements.txt

# Run
open Build/Products/Release/NotchyInput.app
```

## Pack Release DMG

```bash
bash pack_release.sh
# Output: NotchyInput-Mac-1.0.0.dmg (~86MB)
# Includes embedded Python + MLX + Qwen3-ASR
```

## How It Works

```
Right Alt (hold) → Record audio → Release → Qwen3-ASR → Paste to active app
                                              ↑
                                    MLX on Apple Silicon
                                    16kHz mono, local inference
```

- **Swift app** handles UI (notch pill), audio recording (AVAudioEngine), hotkeys (NSEvent), and text injection (CGEvent Cmd+V)
- **Python subprocess** runs Qwen3-ASR via `mlx_qwen3_asr`, communicates over JSON lines on stdin/stdout
- Model downloads automatically from Hugging Face on first launch

## Credits

- Notch UI inspired by [adamlyttleapps/notchy](https://github.com/adamlyttleapps/notchy)
- ASR engine: [Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) via [mlx_qwen3_asr](https://pypi.org/project/mlx-qwen3-asr/)
- Voice input concept from [jfamily4tw/voicetype4tw-mac](https://github.com/jfamily4tw/voicetype4tw-mac)

## License

MIT
