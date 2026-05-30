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


DEFAULT_MODEL_ID = "Qwen/Qwen3-ASR-0.6B"


def _estimate_download_bytes(model_id: str) -> int:
    """Rough download size for progress reporting. 1.7B is ~3x the 0.6B;
    4/5/6/8-bit quantized variants are smaller. Only affects the progress
    bar estimate, never correctness."""
    mid = model_id.lower()
    base = 3_400_000_000 if "1.7b" in mid else 1_200_000_000
    if "4bit" in mid:
        return int(base * 0.35)
    if "5bit" in mid:
        return int(base * 0.45)
    if "6bit" in mid:
        return int(base * 0.55)
    if "8bit" in mid:
        return int(base * 0.7)
    return base


def load_model():
    """Load Qwen3-ASR model with download progress reporting.

    Model is selected via the NOTCHY_ASR_MODEL env var (set by the Swift app's
    ASR Model menu); falls back to the 0.6B default when unset."""
    model_id = os.environ.get("NOTCHY_ASR_MODEL", "").strip() or DEFAULT_MODEL_ID
    short = model_id.split("/")[-1]

    # Check if model is already cached
    from huggingface_hub import snapshot_download, HfApi
    try:
        api = HfApi()
        cache_info = api.model_info(model_id, files_metadata=True)
        # Try to find in local cache
        from huggingface_hub import try_to_load_from_cache
        cached = try_to_load_from_cache(model_id, "config.json")
        if cached is not None:
            send({"status": "loading", "message": f"Loading {short} from cache...", "progress": 0.5})
        else:
            mb = _estimate_download_bytes(model_id) / 1_000_000
            send({"status": "loading", "message": f"Downloading {short} (~{mb:.0f}MB)...", "progress": 0.0})
            # Download with progress callback
            _download_with_progress(model_id)
    except Exception:
        send({"status": "loading", "message": f"Loading {short}...", "progress": 0.0})

    send({"status": "loading", "message": "Initializing ASR engine...", "progress": 0.9})

    import mlx_qwen3_asr
    model, config = mlx_qwen3_asr.load_model(model_id)
    return model, config


def _download_with_progress(model_id):
    """Download model files with progress reporting to Swift."""
    from huggingface_hub import snapshot_download
    import threading

    # Track progress by monitoring cache directory size
    total_size_estimate = _estimate_download_bytes(model_id)
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

    try:
        model, config = load_model()
    except Exception as e:
        import traceback
        tb = traceback.format_exc()
        sys.stderr.write(f"[asr_server] FATAL during load_model: {e}\n{tb}\n")
        sys.stderr.flush()
        send({"status": "fatal", "error": f"load_model failed: {e}"})
        sys.exit(2)

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

        # Health probe — lets Swift confirm model is still responsive.
        if request.get("ping"):
            import resource
            rss_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1_000_000
            send({"pong": True, "rss_mb": round(rss_mb, 1)})
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
    try:
        main()
    except Exception as e:
        import traceback
        sys.stderr.write(f"[asr_server] FATAL unhandled: {e}\n{traceback.format_exc()}\n")
        sys.stderr.flush()
        sys.exit(3)
