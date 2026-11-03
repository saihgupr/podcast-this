import Foundation
import AVFoundation
import MediaPlayer
import UIKit

class RadioPlayer: NSObject, ObservableObject {
    static let shared = RadioPlayer()

    @Published var currentStation: RadioStation?
    @Published var isPlaying: Bool = false
    @Published var isLoading: Bool = false

    private var avPlayer: AVPlayer?
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var wasPlayingBeforeInterruption = false
    private var audioSessionActivated = false

    private override init() {
        super.init()
        setupAudioSession()
        setupRemoteCommandCenter()
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
        if currentStation?.id == station.id, let player = avPlayer {
            activateAudioSessionIfNeeded()
            player.play()
            isPlaying = true
            isLoading = false
            updateNowPlayingPlaybackInfo(force: true)
            return
        }

        tearDownCurrentPlayer()

        guard let url = URL(string: station.streamURL) else {
            print("[-] RadioPlayer: Invalid stream URL: \(station.streamURL)")
            return
        }

        activateAudioSessionIfNeeded()

        currentStation = station
        isLoading = true
        isPlaying = false

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        avPlayer = newPlayer

        timeControlStatusObserver = newPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch player.timeControlStatus {
                case .playing:
                    self.isPlaying = true
                    self.isLoading = false
                    self.updateNowPlayingPlaybackInfo(force: true)
                case .paused:
                    self.isPlaying = false
                    self.isLoading = false
                    self.updateNowPlayingPlaybackInfo(force: true)
                case .waitingToPlayAtSpecifiedRate:
                    self.isLoading = true
                @unknown default:
                    break
                }
            }
        }

        newPlayer.play()
        setupNowPlayingInfo(for: station)
    }

    func stop() {
        tearDownCurrentPlayer()
        deactivateAudioSession()
        currentStation = nil
        isPlaying = false
        isLoading = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func toggle(station: RadioStation) {
        if currentStation?.id == station.id, isPlaying || isLoading {
            stop()
        } else {
            play(station: station)
        }
    }

    private func pause() {
        guard let player = avPlayer, isPlaying else { return }
        player.pause()
        isPlaying = false
        updateNowPlayingPlaybackInfo(force: true)
    }

    private func resume() {
        guard let player = avPlayer, !isPlaying else { return }
        activateAudioSessionIfNeeded()
        player.play()
        isPlaying = true
        updateNowPlayingPlaybackInfo(force: true)
    }

    private func tearDownCurrentPlayer() {
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
        avPlayer?.pause()
        avPlayer = nil
        isPlaying = false
        isLoading = false
        wasPlayingBeforeInterruption = false
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
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = station.name
        nowPlayingInfo[MPMediaItemPropertyArtist] = station.name
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = true
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
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
    }
}
