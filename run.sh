#!/bin/bash
# Launch NotchyInput — works on both Mac Studio and Lucy
# First run will download Qwen3-ASR model (~1.2GB)

DIR="$(cd "$(dirname "$0")" && pwd)"

# Check if app exists
if [ ! -d "$DIR/dist/NotchyInput.app" ]; then
    echo "ERROR: NotchyInput.app not found in dist/"
    echo "Build on Mac Studio first: xcodebuild -project NotchyInput.xcodeproj -scheme NotchyInput -configuration Release"
    exit 1
fi

# Activate venv if exists, otherwise create it
if [ ! -d "$DIR/venv" ]; then
    echo "Creating Python venv..."
    python3 -m venv "$DIR/venv"
    source "$DIR/venv/bin/activate"
    pip install -r "$DIR/asr/requirements.txt"
else
    source "$DIR/venv/bin/activate"
fi

echo "Starting NotchyInput..."
echo "  Right Alt = push-to-talk"
echo "  F13 = toggle recording"
echo "  Right-click menu bar icon for status"
open "$DIR/dist/NotchyInput.app"
