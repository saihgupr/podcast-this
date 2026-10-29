# PodcastThis

A YouTube-to-Podcast generator and native audio player for iOS. **PodcastThis** converts YouTube channels and individual videos into audio-only podcasts with embedded ID3 metadata, square-cropped album art, background auto-downloads, native iOS playback features, and AI-powered speaker-specific skipping.

---

## Screenshots

| Player | Library | Show Detail |
|---|---|---|
| <img src="assets/screenshots/player-2.jpg" width="250" alt="Full-screen player with speaker skip banner"> | <img src="assets/screenshots/library-2.jpg" width="250" alt="Library grid of subscribed shows"> | <img src="assets/screenshots/show-detail-2.jpg" width="250" alt="Show detail with episode list"> |

| Speaker Skips | Skip Tuning | Subscriptions |
|---|---|---|
| <img src="assets/screenshots/speaker-skips.png" width="250" alt="Detected speakers with per-speaker skip toggles"> | <img src="assets/screenshots/skip-tuning.png" width="250" alt="Trim silence and skip timing controls"> | <img src="assets/screenshots/subscriptions.jpg" width="250" alt="Channel subscriptions with auto-download sync"> |

---

## Features

- **Native iOS Playback:** Integrates with iOS `AVPlayer`, `MPNowPlayingInfoCenter`, and `MPRemoteCommandCenter` (Lock Screen, Control Center, CarPlay, Bluetooth).
- **Speaker-Specific Skips (WhisperX):** Uses computer-powered WhisperX and PyAnnote diarization to detect distinct speakers. Rename speakers, view speaking breakdown statistics, and toggle individual speakers to be automatically skipped during playback.
- **L/R Audio Balance Slider:** Real-time stereo panning (left to right) with constant-power audio processing (`MTAudioProcessingTap`). Features center-snapping, haptic feedback, and double-tap reset. Disabled by default, configurable in Settings.
- **Smart Playback:** Variable speed (0.75× – 2.0×), custom skip intervals, playback progress memory per episode, and optional unplayed-only autoplay.
- **SponsorBlock Integration:** Automatically strips ads, self-promotions, music intros/outros, and filler segments using crowdsourced segment data.
- **Custom User Skips (Snipper):** Manually mark custom start and end timestamps directly in the precision waveform Snipper editor.
- **Album Art & Metadata Tagging:** Downloads channel/video thumbnails, crops them to 1:1 square aspect ratio via `ffmpeg`, and embeds tags into the audio files (`.m4a`).
- **Subscriptions & Battery-Aware Background Daemon:** Subscribe to YouTube channels with automated checks every 2 hours via a native `launchd` daemon. Includes battery gating (<25% threshold check and charging detection) to preserve battery life.
- **iOS Share & Action Extensions:** Send YouTube links straight to PodcastThis from Safari, YouTube, or any app via the native iOS Share Sheet.
- **SSH Remote Triggers & CLI:** Trigger single downloads or syncs remotely from terminal using `podcastthis-add <url>` or `podcastthis-daemon`. Also start and stop the WhisperX server directly from the iOS app via SSH.

---

## App Settings

Available under **Settings**:
- **Autoplay Next Episode**: Automatically play the next episode upon completion.
- **Only Play Unplayed**: Skip already-completed episodes during autoplay.
- **Skip Interval**: Adjust forward/backward skip duration (5s – 60s).
- **L/R Audio Balance Slider**: Toggle the stereo balance slider on/off for the full player window (off by default).
- **SponsorBlock**: Enable/disable automatic segment skipping and customize removal categories.

| Playback & Battery | SponsorBlock |
|---|---|
| <img src="assets/screenshots/settings.png" width="300" alt="Playback, battery and audio balance settings"> | <img src="assets/screenshots/settings-sponsorblock.png" width="300" alt="SponsorBlock removal categories"> |
- **Custom User Skips**: Toggle automatic skipping for user-defined Snipper regions and speaker skips.
- **Computer WhisperX Server**: Configure your computer server URL (e.g., `http://192.168.1.100:8000`) with built-in connection testing and SSH remote management.

---

## Optional: WhisperX Speaker Diarization (Computer Setup)

<details>
<summary><b>Click to expand Computer setup instructions for Speaker-Specific Skips</b></summary>

<br>

PodcastThis includes a lightweight Python FastAPI microservice that runs locally on your computer (macOS, Linux, or Windows) to perform speech transcription and speaker diarization via WhisperX:

1. **Prerequisite**: Get a free [Hugging Face](https://huggingface.co) token and accept access terms on the required PyAnnote models:
   - [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) *(Community Model)*
   - [pyannote/speaker-diarization-3.1](https://huggingface.co/pyannote/speaker-diarization-3.1)
   - [pyannote/segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0)

2. **One-Command Setup**:
   ```bash
   cd services/whisperx-service
   chmod +x setup.sh
   ./setup.sh
   ```
   *The setup script will prompt you to enter your Hugging Face token (saved to `.env`) and display your computer's local IP address.*

3. **Start the Service**:
   ```bash
   ./start.sh
   ```
   *(Alternatively, configure SSH login in the iOS app to start and stop the service with a single tap.)*

4. **Connect from iPhone**:
   In **Settings → Computer WhisperX Server**, set your computer's IP (e.g. `http://192.168.1.100:8000`) and tap **Test** to confirm "Online".

<img src="assets/screenshots/whisperx-setup.png" width="300" alt="WhisperX server settings with connection test">

> [!NOTE]
> **First Run & Processing Times:** 
> - **Initial Run**: The very first time an episode is analyzed, WhisperX will download the AI models (~1 GB total), which adds a few minutes.
> - **Processing Speed**: Processing a full podcast (30–60 minutes) runs heavy AI diarization and speech alignment. The computer server continues processing in the background even if your phone's screen locks or times out, and automatically caches the completed timestamps.

</details>

---

## Background Daemon & Battery Management

The background sync daemon (`com.saihgupr.podcastthis`) runs on a 2-hour interval (`StartInterval = 7200`) and features built-in power awareness:
- **Battery Gating**: Background subscription scans are paused if battery level is below 25% and the device is not plugged into a charger.
- **Mid-Queue Protection**: Pauses ongoing downloads if battery drops below 20% while on battery power.
- **Manual Overrides**: In-app scans or manual CLI runs (`podcastthis-daemon --force`) bypass battery checks to allow immediate downloads anytime.

---

## Installation

Requires a jailbroken device on iOS 15 or later (rootless jailbreaks such as Dopamine supported).

1. Download the latest `com.saihgupr.podcastthis_*.deb` from the [releases page](https://github.com/saihgupr/podcast-this/releases).
2. Install it with your preferred method:
   - Open the `.deb` in Sileo or Zebra, or
   - Copy it to your device and run `dpkg -i <file>.deb` as root over SSH.
3. Dependencies (`python3`, `ffmpeg`) install automatically through your package manager.
4. Respring, then open PodcastThis from the Home Screen.

## Building from Source

Requires macOS or Linux with [Theos](https://theos.dev) installed:

```bash
git clone https://github.com/saihgupr/podcast-this.git
cd podcast-this
make package
```

The finished `.deb` will be in `packages/`. Install it as described above.

---

## Contributing

Contributions are welcome!

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/awesome-feature`)
3. Commit your changes and push to your fork
4. Open a Pull Request

## Support & Feedback

If you encounter any issues, bugs, or have feature requests, please [open an issue on GitHub](https://github.com/saihgupr/podcast-this/issues).

PodcastThis is open-source and free. If you find it useful, consider giving it a star on GitHub or making a donation to support development!

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/saihgupr)
