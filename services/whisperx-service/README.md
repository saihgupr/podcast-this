# PodcastThis WhisperX Speaker Diarization Service 🎙️

A local computer microservice that uses [WhisperX](https://github.com/m-bain/whisperX) and [PyAnnote Audio](https://github.com/pyannote/pyannote-audio) to perform speaker diarization on podcast audio files for **PodcastThis**.

---

## Features

- **Accurate Speaker Segmentation**: Automatically detects individual speakers (`SPEAKER_00`, `SPEAKER_01`, etc.) and assigns start/end timestamps.
- **REST API**: Simple `POST /diarize` endpoint accepting audio files (`.m4a`, `.mp3`, `.wav`) directly from the iOS app.
- **Remote Control via SSH**: Start and stop the server remotely from the iOS app with one tap.
- **Auto Merging**: Merges split adjacent utterances from the same speaker.
- **Cross-Platform Execution**: Optimized for Apple Silicon MPS, NVIDIA CUDA, and CPU execution.

---

## Setup & Prerequisites

1. **Hugging Face Token**:
   - PyAnnote models are gated on Hugging Face.
   - Create a free account on [huggingface.co](https://huggingface.co) and generate an access token.
   - Accept user conditions on:
     - [pyannote/speaker-diarization-3.1](https://huggingface.co/pyannote/speaker-diarization-3.1)
     - [pyannote/segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0)

2. **Install & Run**:
   ```bash
   cd services/whisperx-service
   chmod +x setup.sh
   ./setup.sh

   # Start the service
   export HF_TOKEN="hf_your_token_here"
   ./venv/bin/python server.py
   ```

3. **Configure in iOS App**:
   - In **Settings** inside PodcastThis on your iOS device, set **Computer WhisperX Server URL** to `http://<YOUR_COMPUTER_LOCAL_IP>:8000` (e.g. `http://192.168.1.100:8000`).

---

## Configuration Options

Set these in `.env` inside `services/whisperx-service/` or export them in your shell:

| Variable | Default | Description |
|---|---|---|
| `HF_TOKEN` | `None` | Hugging Face user access token for PyAnnote models. |
| `WHISPER_MODEL_NAME` | `small` | Whisper model architecture (`small`, `base`, `medium`, `large-v3`, etc.). |
| `PORT` | `8000` | Port for the FastAPI server. |
| `HOST` | `0.0.0.0` | Host interface to bind to. |
| `IDLE_TIMEOUT_MINUTES` | `30` | Minutes of inactivity before server shuts down automatically (set to `0` to disable). |

