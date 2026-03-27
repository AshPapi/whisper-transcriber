#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Starting Whisper Transcriber..."

# ── Start Python backend ──────────────────────────────────────────────────
echo "[1/2] Starting Python backend on port 8765..."
cd "$DIR/../python_backend"
uvicorn server:app --host 127.0.0.1 --port 8765 &
BACKEND_PID=$!
echo "  Backend PID: $BACKEND_PID"

sleep 2

# ── Start Flutter app ─────────────────────────────────────────────────────
echo "[2/2] Launching Flutter app..."
cd "$DIR/../flutter_ui"

RELEASE_BIN="build/linux/x64/release/bundle/whisper_transcriber"
if [ -f "$RELEASE_BIN" ]; then
    ./"$RELEASE_BIN" &
else
    echo "Flutter app not built. Running in debug mode..."
    flutter run -d linux &
fi

# Cleanup on exit
trap "kill $BACKEND_PID 2>/dev/null; exit" INT TERM EXIT
wait
