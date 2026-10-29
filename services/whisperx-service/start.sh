#!/bin/bash
set -e

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:$HOME/.local/bin:$PATH"

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

if [ ! -d "$DIR/venv" ]; then
    echo "[-] Virtual environment not found. Please run ./setup.sh first."
    exit 1
fi

LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "localhost")
echo "=== PodcastThis WhisperX Diarization Service ==="
echo "[*] Server address: http://$LOCAL_IP:8000"
echo "[*] iOS App Settings URL: http://$LOCAL_IP:8000"
echo ""

# If already running and healthy, exit cleanly without crashing on port bind
if curl -s -f http://127.0.0.1:8000/health >/dev/null 2>&1; then
    echo "[*] PodcastThis WhisperX Diarization Service is already running and healthy on port 8000."
    exit 0
fi

# Clean up any stale/zombie process occupying port 8000 that is not responding to /health
STALE_PIDS=$(lsof -ti :8000 2>/dev/null || true)
if [ -n "$STALE_PIDS" ]; then
    echo "[!] Port 8000 is occupied but unresponsive. Cleaning up stale process(es): $STALE_PIDS"
    kill -9 $STALE_PIDS 2>/dev/null || true
    sleep 1
fi

exec "$DIR/venv/bin/python" "$DIR/server.py"

