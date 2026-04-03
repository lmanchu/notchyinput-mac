#!/usr/bin/env python3
"""
Qwen3-ASR server — long-running process communicating via JSON lines on stdin/stdout.

Protocol:
  Loading:       {"status": "loading", "message": "Downloading model...", "progress": 0.45}
  Ready signal:  {"status": "ready"}
  Request:       {"audio": "<base64 WAV>", "language": "zh"}
  Response:      {"text": "...", "elapsed": 1.23}
  Error:         {"error": "..."}
"""
import sys
import json
import time
import base64
import os
import numpy as np


def send(obj):
    """Send a JSON line to stdout (Swift reads this)."""
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def load_model():
    """Load Qwen3-ASR model with download progress reporting."""
    model_id = "Qwen/Qwen3-ASR-0.6B"

    # Check if model is already cached
    from huggingface_hub import snapshot_download, HfApi
    try:
        api = HfApi()
        cache_info = api.model_info(model_id, files_metadata=True)
        # Try to find in local cache
        from huggingface_hub import try_to_load_from_cache
        cached = try_to_load_from_cache(model_id, "config.json")
        if cached is not None:
            send({"status": "loading", "message": "Loading model from cache...", "progress": 0.5})
        else:
            send({"status": "loading", "message": "Downloading Qwen3-ASR model (~1.2GB)...", "progress": 0.0})
            # Download with progress callback
            _download_with_progress(model_id)
    except Exception:
        send({"status": "loading", "message": "Loading model...", "progress": 0.0})

    send({"status": "loading", "message": "Initializing ASR engine...", "progress": 0.9})

    import mlx_qwen3_asr
    model, config = mlx_qwen3_asr.load_model(model_id)
    return model, config


def _download_with_progress(model_id):
    """Download model files with progress reporting to Swift."""
    from huggingface_hub import snapshot_download
    import threading

    # Track progress by monitoring cache directory size
    total_size_estimate = 1_200_000_000  # ~1.2GB estimate
    cache_dir = os.path.expanduser("~/.cache/huggingface/hub")
    model_cache = os.path.join(cache_dir, f"models--{model_id.replace('/', '--')}")

    download_done = threading.Event()

    def progress_monitor():
        """Periodically check download size and report progress."""
        while not download_done.is_set():
            try:
                if os.path.exists(model_cache):
                    total = sum(
                        os.path.getsize(os.path.join(dp, f))
                        for dp, _, fns in os.walk(model_cache)
                        for f in fns
                    )
                    progress = min(total / total_size_estimate, 0.85)
                    mb_done = total / 1_000_000
                    send({
                        "status": "loading",
                        "message": f"Downloading model... {mb_done:.0f}MB",
                        "progress": round(progress, 2)
                    })
            except Exception:
                pass
            download_done.wait(timeout=2.0)

    monitor = threading.Thread(target=progress_monitor, daemon=True)
    monitor.start()

    try:
        snapshot_download(model_id, local_files_only=False)
    finally:
        download_done.set()
        monitor.join(timeout=3)


def transcribe(audio_bytes: bytes, model, language: str = "zh") -> str:
    """Transcribe WAV audio bytes to text."""
    import mlx_qwen3_asr
    import zhconv

    # Skip WAV header (44 bytes) if present
    if len(audio_bytes) > 44 and audio_bytes[:4] == b'RIFF':
        audio_np = np.frombuffer(audio_bytes[44:], dtype=np.int16).astype(np.float32) / 32768.0
    else:
        audio_np = np.frombuffer(audio_bytes, dtype=np.int16).astype(np.float32) / 32768.0

    if len(audio_np) < 1600:
        return ""

    result = mlx_qwen3_asr.transcribe(audio_np, model=model, language="zh")
    text = result.text.strip() if result and result.text else ""
    return zhconv.convert(text, "zh-tw") if text else ""


def main():
    send({"status": "loading", "message": "Starting ASR engine...", "progress": 0.0})

    model, config = load_model()

    # Signal ready
    send({"status": "ready"})

    # Main loop
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            request = json.loads(line)
        except json.JSONDecodeError as e:
            send({"error": f"Invalid JSON: {e}"})
            continue

        audio_b64 = request.get("audio", "")
        language = request.get("language", "zh")

        if not audio_b64:
            send({"error": "No audio data"})
            continue

        try:
            audio_bytes = base64.b64decode(audio_b64)
            start = time.time()
            text = transcribe(audio_bytes, model, language)
            elapsed = time.time() - start
            send({"text": text, "elapsed": round(elapsed, 3)})
        except Exception as e:
            sys.stderr.write(f"[asr_server] Error: {e}\n")
            sys.stderr.flush()
            send({"error": str(e)})


if __name__ == "__main__":
    main()
