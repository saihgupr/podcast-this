import Foundation
import AVFoundation
import Combine
import MediaPlayer
import UIKit

enum RadioLiveState: Equatable {
    case idle
    case buffering
    case playingLive
    case pausedBehindLive
    case error(String)
}

class RadioPlayer: NSObject, ObservableObject {
    static let shared = RadioPlayer()

    // Legacy API (kept working; mirrored from liveState).
    @Published var currentStation: RadioStation?
    @Published var isPlaying: Bool = false
    @Published var isLoading: Bool = false

    // New live-radio API.
    @Published var liveState: RadioLiveState = .idle
    @Published var liveNowPlayingTitle: String?
    @Published var liveNowPlayingSubtitle: String?
    @Published var listeningDuration: TimeInterval = 0

    private var avPlayer: AVPlayer?
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var wasPlayingBeforeInterruption = false
    private var audioSessionActivated = false

    // ICY metadata (StreamTitle via AVPlayerItemMetadataOutput).
    private var metadataOutput: AVPlayerItemMetadataOutput?
    private var latestStreamTitleRaw: String?

    // Timers.
    private var listeningTimer: Timer?
    private var sleepTimer: Timer?
    private var sleepFadeTimer: Timer?

    private override init() {
        super.init()
        setupAudioSession()
        setupRemoteCommandCenter()
    }

    deinit {
        listeningTimer?.invalidate()
        sleepTimer?.invalidate()
        sleepFadeTimer?.invalidate()
    }

    // MARK: - Live State

    private func setLiveState(_ state: RadioLiveState) {
        liveState = state
        switch state {
        case .idle:
            isPlaying = false
            isLoading = false
        case .buffering:
            isPlaying = false
            isLoading = true
        case .playingLive:
            isPlaying = true
            isLoading = false
        case .pausedBehindLive:
            isPlaying = false
            isLoading = false
        case .error:
            isPlaying = false
            isLoading = false
        }
        if state == .playingLive {
            startListeningTimer()
        } else {
            stopListeningTimer()
        }
        updateNowPlayingPlaybackInfo(force: true)
    }

    // MARK: - Audio Session

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowAirPlay])

            NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: session)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleInterruption),
                name: AVAudioSession.interruptionNotification,
                object: session
            )

            NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: session)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleRouteChange),
                name: AVAudioSession.routeChangeNotification,
                object: session
            )
        } catch {
            print("[-] RadioPlayer: Failed to setup audio session: \(error)")
        }
    }

    private func activateAudioSessionIfNeeded() {
        guard !audioSessionActivated else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            audioSessionActivated = true
        } catch {
            print("[-] RadioPlayer: Failed to activate audio session: \(error)")
        }
    }

    private func deactivateAudioSession() {
        guard audioSessionActivated else { return }
        audioSessionActivated = false
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                print("[-] RadioPlayer: Failed to deactivate audio session: \(error)")
            }
        }
    }

    // MARK: - Playback API

    func play(station: RadioStation) {
        // Stop podcast playback first so streams never overlap.
        if PodcastPlayer.shared.isPlaying || PodcastPlayer.shared.currentEpisode != nil {
            PodcastPlayer.shared.stop()
        }

        // Same station already loaded — just resume.
        if currentStation?.id == station.id, avPlayer != nil {
            activateAudioSessionIfNeeded()
            avPlayer?.volume = 1.0
            avPlayer?.play()
            if avPlayer?.timeControlStatus == .playing {
                setLiveState(.playingLive)
            } else {
                setLiveState(.buffering)
            }
            refreshNowPlayingInfo()
            return
        }

        startStream(station: station, resetDuration: true)
    }

    func stop() {
        cancelSleepTimers(restoreVolume: false)
        tearDownCurrentPlayer()
        deactivateAudioSession()
        currentStation = nil
        liveNowPlayingTitle = nil
        liveNowPlayingSubtitle = nil
        latestStreamTitleRaw = nil
        listeningDuration = 0
        setLiveState(.idle)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func toggle(station: RadioStation) {
        if currentStation?.id == station.id, isPlaying || isLoading {
            stop()
        } else {
            play(station: station)
        }
    }

    func jumpToLive() {
        guard let station = currentStation, let player = avPlayer else { return }

        // Catch up to the live edge directly; rebuild the item if the
        // stream exposes no seekable range to jump within.
        if let item = player.currentItem, !item.seekableTimeRanges.isEmpty {
            activateAudioSessionIfNeeded()
            player.seek(to: .positiveInfinity)
            player.play()
            if player.timeControlStatus == .playing {
                setLiveState(.playingLive)
            } else {
                setLiveState(.buffering)
            }
            return
        }

        // Fallback: rebuild the live item and resume, preserving the session clock.
        startStream(station: station, resetDuration: false)
    }

    func nextStation() {
        let stations = RadioStore.shared.stations
        guard !stations.isEmpty else { return }
        if let current = currentStation,
           let index = stations.firstIndex(where: { $0.id == current.id }) {
            play(station: stations[(index + 1) % stations.count])
        } else {
            play(station: stations[0])
        }
    }

    func previousStation() {
        let stations = RadioStore.shared.stations
        guard !stations.isEmpty else { return }
        if let current = currentStation,
           let index = stations.firstIndex(where: { $0.id == current.id }) {
            play(station: stations[(index - 1 + stations.count) % stations.count])
        } else {
            play(station: stations[stations.count - 1])
        }
    }

    func setSleepTimer(minutes: Int?) {
        cancelSleepTimers(restoreVolume: true)
        guard let minutes = minutes, minutes > 0 else { return }
        sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            self?.beginSleepFadeAndStop()
        }
    }

    private func startStream(station: RadioStation, resetDuration: Bool) {
        // Stop podcast playback first so streams never overlap.
        if PodcastPlayer.shared.isPlaying || PodcastPlayer.shared.currentEpisode != nil {
            PodcastPlayer.shared.stop()
        }

        tearDownCurrentPlayer()

        guard let url = URL(string: station.streamURL) else {
            print("[-] RadioPlayer: Invalid stream URL: \(station.streamURL)")
            currentStation = station
            setLiveState(.error("Invalid stream URL"))
            return
        }

        activateAudioSessionIfNeeded()

        currentStation = station
        liveNowPlayingTitle = nil
        liveNowPlayingSubtitle = nil
        latestStreamTitleRaw = nil
        if resetDuration {
            listeningDuration = 0
        }
        setLiveState(.buffering)

        let item = AVPlayerItem(url: url)
        attachMetadataOutput(to: item)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.volume = 1.0
        avPlayer = newPlayer

        timeControlStatusObserver = newPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch player.timeControlStatus {
                case .playing:
                    if self.liveState != .playingLive {
                        self.setLiveState(.playingLive)
                    }
                case .paused:
                    // Only treat as paused-behind-live once we were actually live.
                    // (Initial .paused before first frames must stay .buffering.)
                    if self.liveState == .playingLive {
                        self.setLiveState(.pausedBehindLive)
                    }
                case .waitingToPlayAtSpecifiedRate:
                    if self.liveState == .playingLive || self.liveState == .pausedBehindLive {
                        self.setLiveState(.buffering)
                    }
                @unknown default:
                    break
                }
            }
        }

        newPlayer.play()
        setupNowPlayingInfo(for: station)
    }

    private func pause() {
        guard let player = avPlayer, isPlaying else { return }
        player.pause()
        setLiveState(.pausedBehindLive)
    }

    private func resume() {
        guard let player = avPlayer, !isPlaying else { return }
        activateAudioSessionIfNeeded()
        player.play()
        if player.timeControlStatus == .playing {
            setLiveState(.playingLive)
        } else {
            setLiveState(.buffering)
        }
    }

    private func tearDownCurrentPlayer() {
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
        detachMetadataOutput()
        stopListeningTimer()
        avPlayer?.pause()
        avPlayer = nil
        isPlaying = false
        isLoading = false
        wasPlayingBeforeInterruption = false
    }

    // MARK: - Listening Duration

    private func startListeningTimer() {
        guard listeningTimer == nil else { return }
        listeningTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.listeningDuration += 1
        }
    }

    private func stopListeningTimer() {
        listeningTimer?.invalidate()
        listeningTimer = nil
    }

    // MARK: - Sleep Timer

    private func cancelSleepTimers(restoreVolume: Bool) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepFadeTimer?.invalidate()
        sleepFadeTimer = nil
        if restoreVolume {
            avPlayer?.volume = 1.0
        }
    }

    private func beginSleepFadeAndStop() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        guard avPlayer != nil else {
            stop()
            return
        }
        sleepFadeTimer?.invalidate()
        var step = 0
        let totalSteps = 20
        let rawStart = avPlayer?.volume ?? 1.0
        let base: Float = rawStart > 0.01 ? rawStart : 1.0
        sleepFadeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            step += 1
            let progress = Float(step) / Float(totalSteps)
            self.avPlayer?.volume = max(0, base * (1 - progress))
            if step >= totalSteps {
                timer.invalidate()
                self.sleepFadeTimer = nil
                self.stop()
            }
        }
    }

    // MARK: - ICY Metadata

    private func attachMetadataOutput(to item: AVPlayerItem) {
        detachMetadataOutput()
        // identifiers:nil = all timed metadata (older SDKs lack the ICY
        // AVMetadataIdentifier constants, so match the raw value below).
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        output.setDelegate(self, queue: DispatchQueue.main)
        item.add(output)
        metadataOutput = output
    }

    private func detachMetadataOutput() {
        if let output = metadataOutput {
            avPlayer?.currentItem?.remove(output)
            output.setDelegate(nil, queue: nil)
            metadataOutput = nil
        }
    }

    private func parseStreamTitle(_ raw: String) -> (title: String?, subtitle: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }
        if let dash = trimmed.range(of: " - ") {
            let artist = String(trimmed[..<dash.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = String(trimmed[dash.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (title.isEmpty ? nil : title, artist.isEmpty ? nil : artist)
        }
        return (trimmed, nil)
    }

    // MARK: - Interruptions & Route Changes

    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        if type == .began {
            if isPlaying {
                wasPlayingBeforeInterruption = true
                pause()
            }
        } else if type == .ended {
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) && wasPlayingBeforeInterruption {
                    wasPlayingBeforeInterruption = false
                    resume()
                } else {
                    wasPlayingBeforeInterruption = false
                }
            } else {
                wasPlayingBeforeInterruption = false
            }
        }
    }

    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        if reason == .oldDeviceUnavailable {
            DispatchQueue.main.async {
                if self.isPlaying {
                    self.pause()
                }
            }
        }
    }

    // MARK: - Now Playing & Remote Commands

    private func setupNowPlayingInfo(for station: RadioStation) {
        refreshNowPlayingInfo()
    }

    private func refreshNowPlayingInfo() {
        guard let station = currentStation else { return }
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = station.name
        nowPlayingInfo[MPMediaItemPropertyArtist] = latestStreamTitleRaw ?? station.name
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = true
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func updateNowPlayingPlaybackInfo(force: Bool = false) {
        guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func setupRemoteCommandCenter() {
        DispatchQueue.main.async {
            UIApplication.shared.beginReceivingRemoteControlEvents()
        }

        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self, self.currentStation != nil else { return .commandFailed }
            self.resume()
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self, self.currentStation != nil else { return .commandFailed }
            self.pause()
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self, let station = self.currentStation else { return .commandFailed }
            self.toggle(station: station)
            return .success
        }

        commandCenter.stopCommand.isEnabled = true
        commandCenter.stopCommand.addTarget { [weak self] _ in
            guard let self = self, self.currentStation != nil else { return .commandFailed }
            self.stop()
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self, self.currentStation != nil else { return .commandFailed }
            self.nextStation()
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self, self.currentStation != nil else { return .commandFailed }
            self.previousStation()
            return .success
        }
    }
}

// MARK: - AVPlayerItemMetadataOutputPushDelegate (ICY StreamTitle)

extension RadioPlayer: AVPlayerItemMetadataOutputPushDelegate {
    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        // ICY carries the track as a raw "Artist - Title" StreamTitle string;
        // commonKeyTitle/Artist are unreliable here, so split it ourselves.
        // Runs on .main (see attachMetadataOutput), safe to publish directly.
        guard currentStation != nil else { return }
        for group in groups {
            for item in group.items {
                // Raw ICY identifier is "icy/StreamTitle"; match by suffix so this
                // compiles on SDKs without the AVMetadataIdentifier constant.
                let rawID = item.identifier?.rawValue ?? ""
                guard rawID.lowercased().contains("streamtitle") else { continue }
                guard let raw = item.stringValue ?? (item.value as? String) else { continue }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let parsed = parseStreamTitle(trimmed)
                if liveNowPlayingTitle != parsed.title || liveNowPlayingSubtitle != parsed.subtitle {
                    liveNowPlayingTitle = parsed.title
                    liveNowPlayingSubtitle = parsed.subtitle
                }
                if latestStreamTitleRaw != trimmed {
                    latestStreamTitleRaw = trimmed
                }
                refreshNowPlayingInfo()
            }
        }
    }
}
