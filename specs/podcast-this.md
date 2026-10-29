# PodcastThis Specification

## Goal Description
PodcastThis is a YouTube-to-podcast generator for jailbroken iOS devices. It converts YouTube channels and videos into audio-only podcasts, embedding proper ID3 metadata and square-cropped album art. It allows users to listen offline, subscribe to channels for auto-downloads, save playback progress, and trigger downloads remotely from a Mac/PC via SSH.

---

## User Stories / Requirements

### 1. Podcast Vibe & Native Playback
- Audio-only playback with native iOS system media controls (Lock Screen, Control Center, CarPlay, and volume controls).
- Automatic resume capability: the app remembers the last playback position for each episode.
- Beautiful, clean, dark-mode SwiftUI player UI featuring large square album art, playback speed controls, skip-forward/backward buttons, and an optional real-time L/R audio balance slider with constant-power panning and center-snapping.

### 2. Audio Downloader & Metadata
- Fully on-device downloads using `yt-dlp` and `ffmpeg` running under a background daemon.
- Video and channel thumbnails are downloaded, center-cropped to a 1:1 square, and embedded as the album art in the audio file.
- Correct metadata tagging: video title as the episode title, channel name as the artist/album (podcast show name).

### 3. Remote Triggers (SSH CLI)
- A command-line script on the iPhone (`podcastthis-add <url>`) that can be invoked via SSH to trigger downloading a video or channel.
- Safe execution in the background so that closing the SSH terminal does not interrupt the download.

### 4. Channel Subscriptions & Auto-downloads
- Users can subscribe to YouTube channels.
- A LaunchDaemon checks subscribed channels periodically, downloading new uploads automatically in the background.

---

## Technical Design

### Directory Structure (iOS Filesystem)
All files are stored in a shared, non-sandboxed path:
`/var/mobile/Library/Application Support/PodcastThis/`
- `downloads/`: Directory containing all `.m4a` / `.mp3` audio files.
- `state.json`: Main database file for subscriptions, episode playback state, and library cache.
- `bin/`: CLI helpers and downloader scripts (`podcastthis-add`).

### Data Models (`state.json`)
```json
{
  "subscriptions": [
    {
      "channel_id": "UCxxxxxxxxxxxx",
      "channel_title": "Channel Name",
      "channel_url": "https://www.youtube.com/@ChannelName",
      "auto_download": true,
      "date_subscribed": "2026-07-10T12:00:00Z"
    }
  ],
  "playback_progress": {
    "video_id_12345": {
      "last_position": 142.5,
      "duration": 1200.0,
      "completed": false,
      "last_played": "2026-07-10T12:30:00Z"
    }
  }
}
```

### The Downloader Script (`podcastthis-add`)
Written in Python or Bash, located at `/usr/local/bin/podcastthis-add`:
1. Runs `yt-dlp` to download the best audio format (prefers `.m4a` format containing AAC audio).
2. Retrieves metadata and download thumbnail.
3. Center-crops the thumbnail to a 1:1 aspect ratio using `ffmpeg`.
4. Embeds the cropped artwork, title, artist, and description into the audio file metadata.
5. Saves the output to the `downloads/` directory and writes metadata updates to `state.json`.

### SwiftUI Application
1. **Views**:
   - **LibraryView**: Shows list of YouTube channels (Subscribed Shows).
   - **ShowDetailView**: Lists downloaded episodes of a specific channel.
   - **PlayerView**: High-fidelity custom media player.
   - **SettingsView**: Configure settings, view dependencies status (`yt-dlp`, `ffmpeg`).
2. **Architecture**:
   - Uses `AVPlayer` for streaming and offline file playback.
   - Uses `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` for lock screen and background controls.
   - Scans the `downloads/` directory to discover tracks dynamically, resolving metadata using file tagging or matching with `state.json`.

### LaunchDaemon (`com.saihgupr.podcastthis.plist`)
A daemon plist stored in `/Library/LaunchDaemons/` that triggers a python script every 1-2 hours to query subscribed feeds using `yt-dlp` and download new videos.

---

## Edge Case Handling
- **Network Interruptions**: The download daemon must handle internet dropouts gracefully, retrying failed downloads or resuming them.
- **YouTube Changes**: `yt-dlp` updates frequently; the app should provide an easy way to run `yt-dlp -U` or warn the user when downloads fail.
- **Low Disk Space**: The download script must verify available disk space before starting a download.
- **Playback Control Interruptions**: Handling audio interruptions (phone calls, maps directions, other audio apps playing) gracefully using `AVAudioSession`.
