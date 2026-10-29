# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-10-29

### Added
- Native iOS application for iOS 14.0+ built with Swift & Theos.
- YouTube video and channel conversion into offline audio-only podcasts with background download queue.
- Channel Subscriptions with automatic new episode checking and notifications.
- Audio Player with playback speed control, lock screen / Control Center Now Playing integration, custom seek intervals, and L/R stereo audio balance slider.
- SponsorBlock integration for automated segment skipping (Sponsor, Intermission/Intro, Endcards, Outro, Self-promotion, Preview/Recap).
- User Snipper for custom manual skip regions per episode.
- WhisperX Speaker Diarization companion microservice for desktop/server (macOS, Linux, Windows) with FastAPI, PyTorch, and PyAnnote.
- Speaker-specific skips with interactive timeline segment tuning and live playback preview.
- Remote SSH management for starting, stopping, and checking WhisperX server status directly within iOS settings.
- Power-aware background sync daemon (`com.saihgupr.podcastthis`) with 2-hour interval, battery-state checks, and WiFi awareness.
- Action & Share extensions for one-tap episode queueing from Safari, YouTube, and other iOS apps.

