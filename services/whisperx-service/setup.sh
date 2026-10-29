#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

echo "=== PodcastThis WhisperX Service Setup ==="

# Find suitable Python binary (WhisperX / CTranslate2 require Python <= 3.12)
PYTHON_BIN=""
for py in /opt/homebrew/bin/python3.11 /usr/local/bin/python3.12 /usr/local/bin/python3.11 python3.11 python3.12 python3.10 python3; do
    if command -v "$py" &> /dev/null; then
        PY_VER=$("$py" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        if [ "$PY_VER" = "3.10" ] || [ "$PY_VER" = "3.11" ] || [ "$PY_VER" = "3.12" ]; then
            PYTHON_BIN="$py"
            echo "[+] Found compatible Python $PY_VER at $PYTHON_BIN"
            break
        fi
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    echo "[-] Error: Python 3.10, 3.11, or 3.12 is required for WhisperX wheels."
    exit 1
fi

VENV_DIR="$DIR/venv"
rm -rf "$VENV_DIR"
echo "[+] Creating Python virtual environment in $VENV_DIR using $PYTHON_BIN..."
"$PYTHON_BIN" -m venv "$VENV_DIR"

echo "[+] Activating virtual environment..."
source "$VENV_DIR/bin/activate"

echo "[+] Installing dependencies..."
pip install --upgrade pip
pip install -r requirements.txt

echo ""
echo "=== Setup Complete! ==="

ENV_FILE="$DIR/.env"

# Prompt for HF token if not already saved in .env or environment
CURRENT_TOKEN=""
if [ -f "$ENV_FILE" ]; then
    CURRENT_TOKEN=$(grep -E "^HF_TOKEN=" "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
fi
if [ -z "$CURRENT_TOKEN" ] && [ -n "$HF_TOKEN" ]; then
    CURRENT_TOKEN="$HF_TOKEN"
fi

if [ -n "$CURRENT_TOKEN" ]; then
    echo "[+] Found existing Hugging Face Token: ${CURRENT_TOKEN:0:6}..."
    read -p "Press Enter to keep this token, or enter a new token: " NEW_TOKEN
    if [ -n "$NEW_TOKEN" ]; then
        echo "HF_TOKEN=\"$NEW_TOKEN\"" > "$ENV_FILE"
        echo "[+] Saved updated token to $ENV_FILE"
    fi
else
    echo "PyAnnote speaker diarization requires a free Hugging Face token."
    echo "1. Sign in or create an account at https://huggingface.co"
    echo "2. Accept terms on: https://huggingface.co/pyannote/speaker-diarization-3.1"
    echo "3. Generate a Read token at: https://huggingface.co/settings/tokens"
    echo ""
    read -p "Enter your Hugging Face Token (hf_...): " INPUT_TOKEN
    if [ -n "$INPUT_TOKEN" ]; then
        echo "HF_TOKEN=\"$INPUT_TOKEN\"" > "$ENV_FILE"
        echo "[+] Saved token to $ENV_FILE"
    else
        echo "[!] No token entered. You can add it later to $ENV_FILE or pass HF_TOKEN=..."
    fi
fi

echo ""
# Show local IP for convenience
LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
echo "[*] Your computer's local IP address is: $LOCAL_IP"
echo "[*] Set iOS App Settings -> Computer WhisperX Server to: http://$LOCAL_IP:8000"
echo ""

read -p "Start the WhisperX server now? (Y/n): " START_NOW
START_NOW=${START_NOW:-Y}
if [[ "$START_NOW" =~ ^[Yy]$ ]]; then
    echo "[+] Starting WhisperX Diarization Service on http://0.0.0.0:8000 ..."
    exec "$VENV_DIR/bin/python" server.py
else
    echo "You can start the server anytime by running:"
    echo "  cd $DIR && ./start.sh"
fi
