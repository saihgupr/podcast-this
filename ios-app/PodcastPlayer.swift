import Foundation
import AVFoundation
import MediaPlayer
import MediaToolbox
import UIKit

public class PodcastPlayer: NSObject, ObservableObject {
    @Published public var currentEpisode: PodcastEpisode?
    @Published public var isPlaying: Bool = false
    @Published public var currentTime: Double = 0.0
    @Published public var duration: Double = 0.0
    @Published public var playbackRate: Float = 1.0
    @Published public var pan: Float = 0.0
    @Published public var activeSamplingSpeakerId: String? = nil
    @Published public var isSamplingSpeaker: Bool = false
    @Published public var isLoopingBoundary: Bool = false
    public var boundaryLoopStart: Double = 0.0
    public var boundaryLoopEnd: Double = 0.0
    
    private var samplingSegments: [SpeakerSegment] = []
    private var samplingMaxDuration: Double = 15.0
    private var samplingAccumulatedSpeech: Double = 0.0
    private var samplingLastTime: Double? = nil
    
    private var avPlayer: AVPlayer?
    private var timeObserverToken: Any?
    private var boundaryObserverToken: Any?
    private var timeControlStatusObserver: NSKeyValueObservation?
    private let dataManager = DataManager.shared

    // Cached speaker skip calculation for battery conservation
    private var cachedSpeakerSkipRegions: [SpeakerSegment]? = nil
    private var cachedSpeakerSkipVideoId: String? = nil

    public func invalidateSpeakerSkipCache() {
        cachedSpeakerSkipRegions = nil
        cachedSpeakerSkipVideoId = nil
    }
    // Allocated once, lives for the app lifetime. Written on main thread, read
    // in the real-time audio tap callback — no allocations on the hot path.
    private let panValuePointer: UnsafeMutablePointer<Float> = {
        let ptr = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        ptr.initialize(to: 0.0)
        return ptr
    }()
    
    public static let shared = PodcastPlayer()
    
    private override init() {
        super.init()
        setupAudioSession()
        setupRemoteCommandCenter()
    }
    
    public func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            let options: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowAirPlay, .mixWithOthers]
            // Only reconfigure the category/options — do NOT call setActive(true) here.
            // Calling setActive(true) sends an interruption to other playing apps even
            // when .mixWithOthers is set. We activate once at first play, then let
            // AVPlayer manage the session thereafter.
            try session.setCategory(.playback, mode: .spokenAudio, options: options)
            
            // Register for interruption notifications (e.g. phone calls)
            NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: session)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleInterruption),
                name: AVAudioSession.interruptionNotification,
                object: session
            )

            // Register for route change notifications (e.g. Bluetooth / headphones disconnect)
            NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: session)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleRouteChange),
                name: AVAudioSession.routeChangeNotification,
                object: session
            )
        } catch {
            print("[-] PodcastPlayer: Failed to setup audio session: \(error)")
        }
    }
    
    private var audioSessionActivated = false
    public func activateAudioSessionIfNeeded() {
        guard !audioSessionActivated else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            audioSessionActivated = true
        } catch {
            print("[-] PodcastPlayer: Failed to activate audio session: \(error)")
        }
    }

    public func deactivateAudioSession() {
        guard audioSessionActivated else { return }
        audioSessionActivated = false
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                print("[-] PodcastPlayer: Failed to deactivate audio session: \(error)")
            }
        }
    }
    
    public func play(episode: PodcastEpisode, autoPlay: Bool = true) {
        // Ensure audio session is active
        activateAudioSessionIfNeeded()
        
        let isCompletedOrAtEnd = (episode.completed || episode.lastPosition >= (episode.duration - 3))

        // If this episode is already loaded, handle play/pause & replay if completed
        if currentEpisode?.videoId == episode.videoId {
            if !autoPlay {
                // If opening/loading without autoPlay and already loaded, leave current playback state as is
                return
            }
            let currentAtEnd = (currentEpisode?.completed == true || currentTime >= (duration - 3))
            if currentAtEnd {
                let startPos = resolveSkipDestination(time: 0.0)
                currentTime = startPos
                dataManager.updateProgress(videoId: episode.videoId, position: startPos, completed: false)
                if var ep = currentEpisode {
                    ep.completed = false
                    ep.lastPosition = startPos
                    currentEpisode = ep
                }
                
                avPlayer?.pause()
                let targetTime = CMTime(seconds: startPos, preferredTimescale: 600)
                avPlayer?.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    guard let self = self else { return }
                    self.avPlayer?.play()
                    self.avPlayer?.rate = self.playbackRate
                    self.isPlaying = true
                    self.updateNowPlayingPlaybackInfo()
                }
                return
            }
            togglePlay()
            return
        }
        
        // Save progress of the previous episode before switching
        saveCurrentProgress()
        
        // Stop current playback
        stop()
        invalidateSpeakerSkipCache()
        
        let freshEpisode = dataManager.findEpisode(videoId: episode.videoId) ?? episode
        currentEpisode = freshEpisode
        duration = freshEpisode.duration
        let initialPos = isCompletedOrAtEnd ? 0.0 : freshEpisode.lastPosition
        let resolvedStart = resolveSkipDestination(time: initialPos)
        currentTime = resolvedStart
        
        let fileURL = dataManager.downloadsDirectory.appendingPathComponent(freshEpisode.filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("[-] PodcastPlayer: Audio file does not exist: \(fileURL.path)")
            return
        }
        
        let asset = AVURLAsset(url: fileURL)
        let playerItem = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: playerItem)
        avPlayer = newPlayer
        applyAudioMix(to: playerItem, asset: asset)
        
        // KVO for timeControlStatus to keep isPlaying in sync with iOS state (Bluetooth disconnects, interruptions, etc.)
        timeControlStatusObserver = newPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch player.timeControlStatus {
                case .playing:
                    if !self.isPlaying {
                        self.isPlaying = true
                        self.activateAudioSessionIfNeeded()
                        self.updateNowPlayingPlaybackInfo(force: true)
                    }
                case .paused:
                    if self.isPlaying {
                        self.isPlaying = false
                        self.saveCurrentProgress()
                        self.updateNowPlayingPlaybackInfo(force: true)
                    }
                case .waitingToPlayAtSpecifiedRate:
                    // Waiting for audio route, buffering, or hardware spin-up.
                    // Do NOT treat as paused or stopped, and NEVER deactivate audio session.
                    break
                @unknown default:
                    break
                }
            }
        }
        
        // Add periodic time observer (100ms) - responsive polling for seamless skips
        let interval = CMTime(seconds: 0.10, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.currentTime = time.seconds
            self.updateNowPlayingPlaybackInfo()
            
            // Speaker sampling duration tracking
            if self.isSamplingSpeaker {
                if let last = self.samplingLastTime {
                    let delta = time.seconds - last
                    if delta > 0 && delta < 1.0 {
                        self.samplingAccumulatedSpeech += delta
                    }
                }
                self.samplingLastTime = time.seconds
                if self.samplingAccumulatedSpeech >= self.samplingMaxDuration {
                    self.stopSpeakerSampling()
                    return
                }
            }
            
            // Boundary looping check for instant skip transition audition
            if self.isLoopingBoundary && self.boundaryLoopEnd > self.boundaryLoopStart {
                if time.seconds >= self.boundaryLoopEnd {
                    self.seek(to: self.boundaryLoopStart)
                    return
                }
            }

            // Unified auto-skipping
            self.checkAutoSkips(time: time.seconds)
            
            // Auto save every 10 seconds or so
            if Int(self.currentTime) % 10 == 0 {
                self.saveCurrentProgress()
            }
        }
        
        // Setup hardware-level boundary time observers for exact timestamp triggers
        updateSkipBoundaryObservers()
        
        // Observe completion
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidPlayToEndTime),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )
        
        if isCompletedOrAtEnd {
            dataManager.updateProgress(videoId: freshEpisode.videoId, position: resolvedStart, completed: false)
            currentEpisode?.completed = false
            currentEpisode?.lastPosition = resolvedStart
            let targetTime = CMTime(seconds: resolvedStart, preferredTimescale: 600)
            newPlayer.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                guard let self = self else { return }
                if autoPlay {
                    newPlayer.play()
                    newPlayer.rate = self.playbackRate
                    self.isPlaying = true
                } else {
                    self.isPlaying = false
                }
                self.setupNowPlayingInfo(for: freshEpisode, fileURL: fileURL)
            }
        } else {
            if resolvedStart > 0 && resolvedStart < (freshEpisode.duration - 5) {
                let targetTime = CMTime(seconds: resolvedStart, preferredTimescale: 600)
                newPlayer.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    guard let self = self else { return }
                    if autoPlay {
                        newPlayer.play()
                        newPlayer.rate = self.playbackRate
                        self.isPlaying = true
                    } else {
                        self.isPlaying = false
                    }
                    self.setupNowPlayingInfo(for: freshEpisode, fileURL: fileURL)
                }
            } else {
                if autoPlay {
                    newPlayer.play()
                    newPlayer.rate = playbackRate
                    isPlaying = true
                } else {
                    isPlaying = false
                }
                setupNowPlayingInfo(for: freshEpisode, fileURL: fileURL)
            }
        }
    }
    
    public func togglePlay() {
        guard let avPlayer = avPlayer else { return }
        
        if isPlaying {
            if isSamplingSpeaker {
                stopSpeakerSampling()
                return
            }
            avPlayer.pause()
            isPlaying = false
            saveCurrentProgress()
        } else {
            activateAudioSessionIfNeeded()
            avPlayer.isMuted = false
            avPlayer.volume = 1.0
            avPlayer.play()
            avPlayer.rate = playbackRate
            isPlaying = true
        }
        updateNowPlayingPlaybackInfo(force: true)
    }

    public func resume() {
        guard let avPlayer = avPlayer, !isPlaying else { return }
        activateAudioSessionIfNeeded()
        avPlayer.isMuted = false
        avPlayer.volume = 1.0
        avPlayer.play()
        avPlayer.rate = playbackRate
        isPlaying = true
        updateNowPlayingPlaybackInfo(force: true)
    }
    
    public func pause() {
        guard let avPlayer = avPlayer, isPlaying else { return }
        if isSamplingSpeaker {
            stopSpeakerSampling()
            return
        }
        avPlayer.pause()
        isPlaying = false
        saveCurrentProgress()
        updateNowPlayingPlaybackInfo(force: true)
    }
    
    private func tearDownCurrentPlayer() {
        if isSamplingSpeaker {
            isSamplingSpeaker = false
            activeSamplingSpeakerId = nil
            samplingSegments = []
            samplingAccumulatedSpeech = 0.0
            samplingLastTime = nil
        }
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
        if let token = timeObserverToken {
            avPlayer?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let bToken = boundaryObserverToken {
            avPlayer?.removeTimeObserver(bToken)
            boundaryObserverToken = nil
        }
        if let currentItem = avPlayer?.currentItem {
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: currentItem)
        }
        avPlayer?.pause()
        avPlayer = nil
        isPlaying = false
        deactivateAudioSession()
        skipState = .idle
        recentSeekHistory = []
        consecutiveAutoSkipFailures = 0
    }

    public func stop() {
        tearDownCurrentPlayer()
        deactivateAudioSession()
        currentEpisode = nil
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    public func seek(to seconds: Double, snapToSkipEnd: Bool = true) {
        guard let avPlayer = avPlayer else { return }
        avPlayer.isMuted = false
        avPlayer.volume = 1.0
        skipState = .idle
        consecutiveAutoSkipFailures = 0
        var targetSeconds = seconds
        if snapToSkipEnd {
            targetSeconds = resolveSkipDestination(time: seconds)
            if targetSeconds > seconds {
                targetSeconds = min(targetSeconds + 0.05, duration > 0 ? duration : targetSeconds + 0.05)
            }
        }
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
        avPlayer.seek(to: targetTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            guard let self = self else { return }
            self.avPlayer?.volume = 1.0
            if finished {
                self.currentTime = targetSeconds
                self.updateNowPlayingPlaybackInfo()
                self.saveCurrentProgress()
                if self.isPlaying {
                    self.avPlayer?.rate = self.playbackRate
                }
            } else if let actualSec = self.avPlayer?.currentTime().seconds, actualSec.isFinite {
                self.currentTime = actualSec
            }
        }
    }
     public func skipForward() {
        guard avPlayer != nil else { return }
        let step = dataManager.settings.skipDuration
        let newTime = min(currentTime + step, duration)
        seek(to: newTime)
    }
    
    public func skipBackward() {
        guard avPlayer != nil else { return }
        let step = dataManager.settings.skipDuration
        let newTime = max(currentTime - step, 0.0)
        // Allow skipping backward into or before a skipped region without snapping forward
        seek(to: newTime, snapToSkipEnd: false)
    }

    public func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            avPlayer?.rate = rate
        }
        updateNowPlayingPlaybackInfo()
    }

    public func setPan(_ value: Float) {
        let clamped = max(-1.0, min(1.0, value))
        pan = clamped
        panValuePointer.pointee = clamped
    }

    // MARK: - Audio Pan via MTAudioProcessingTap

    private func applyAudioMix(to playerItem: AVPlayerItem, asset: AVURLAsset) {
        let tracks = asset.tracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return }

        let ptr = panValuePointer   // raw pointer — no Swift captures in callbacks

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(ptr),
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { _ in },
            prepare: nil,
            unprepare: nil,
            process: { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
                MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                                  flagsOut, nil, numberFramesOut)

                let storage = MTAudioProcessingTapGetStorage(tap)
                let abl = bufferListInOut

                let panVal = storage.assumingMemoryBound(to: Float.self).pointee
                guard panVal < -0.001 || panVal > 0.001 else { return }  // no-op at center

                // Mono fold-down constant-power pan:
                // When slider is moved from center, downmix stereo to mono so hard-panned
                // voices (e.g. host on L, guest on R) are preserved in both ears.
                let angle     = (panVal + 1.0) * Float.pi / 4.0
                let scale: Float = 1.41421356 // sqrt(2) to normalize constant-power loudness
                let leftGain  = cos(angle) * scale
                let rightGain = sin(angle) * scale

                let numBuffers = Int(abl.pointee.mNumberBuffers)

                if numBuffers == 1 {
                    // Interleaved stereo: L R L R ...
                    let buf = abl.pointee.mBuffers
                    guard let data = buf.mData else { return }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    let count = Int(buf.mDataByteSize) / 4  // Float = 4 bytes
                    var i = 0
                    while i + 1 < count {
                        let mono = (samples[i] + samples[i + 1]) * 0.5
                        let outL = mono * leftGain
                        let outR = mono * rightGain
                        samples[i]     = max(-1.0, min(1.0, outL))
                        samples[i + 1] = max(-1.0, min(1.0, outR))
                        i += 2
                    }
                } else if numBuffers >= 2 {
                    // Non-interleaved: buffer[0] = L, buffer[1] = R
                    let ablPtr = UnsafeMutableAudioBufferListPointer(abl)
                    if let lData = ablPtr[0].mData, let rData = ablPtr[1].mData {
                        let sL = lData.assumingMemoryBound(to: Float.self)
                        let sR = rData.assumingMemoryBound(to: Float.self)
                        let n = min(Int(ablPtr[0].mDataByteSize) / 4, Int(ablPtr[1].mDataByteSize) / 4)
                        var i = 0
                        while i < n {
                            let mono = (sL[i] + sR[i]) * 0.5
                            let outL = mono * leftGain
                            let outR = mono * rightGain
                            sL[i] = max(-1.0, min(1.0, outL))
                            sR[i] = max(-1.0, min(1.0, outR))
                            i += 1
                        }
                    }
                }
            }
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        guard status == noErr, let tapProcessor = tap else {
            print("[-] PodcastPlayer: MTAudioProcessingTapCreate failed: \(status)")
            return
        }

        let inputParams: [AVMutableAudioMixInputParameters] = tracks.map { track in
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = tapProcessor
            return params
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = inputParams
        playerItem.audioMix = audioMix
    }

    private func saveCurrentProgress() {
        guard let episode = currentEpisode else { return }
        let completed = currentTime >= (duration - 5.0)
        dataManager.updateProgress(videoId: episode.videoId, position: currentTime, completed: completed)
    }
    
    @objc private func playerItemDidPlayToEndTime(notification: Notification) {
        isPlaying = false
        currentTime = duration
        saveCurrentProgress()
        updateNowPlayingPlaybackInfo()
        
        playNextEpisode()
    }
    
    public func playNextEpisode(force: Bool = false) {
        if !force {
            guard dataManager.settings.autoplayEnabled else {
                print("[*] PodcastPlayer: Autoplay is disabled in settings.")
                return
            }
        }
        guard let current = currentEpisode else { return }
        
        // Find the show that has this episode
        guard let show = dataManager.shows.first(where: { show in
            show.episodes.contains { $0.videoId == current.videoId }
        }) else { return }
        
        // Sort episodes oldest to newest (chronological order)
        let sortedEps = show.episodes.sorted { ep1, ep2 in
            let date1 = ep1.uploadDate ?? ep1.dateAdded
            let date2 = ep2.uploadDate ?? ep2.dateAdded
            return date1 < date2
        }
        
        guard let currentIndex = sortedEps.firstIndex(where: { $0.videoId == current.videoId }) else { return }
        
        var nextEpisode: PodcastEpisode? = nil
        
        if dataManager.settings.onlyPlayUnplayed {
            // Find the first unplayed episode chronologically after the current one
            for i in (currentIndex + 1)..<sortedEps.count {
                if !sortedEps[i].completed {
                    nextEpisode = sortedEps[i]
                    break
                }
            }
            // Fallback: If no unplayed episodes remain chronologically after the current one,
            // play the immediate next episode (which is already played).
            if nextEpisode == nil {
                let nextIndex = currentIndex + 1
                if nextIndex < sortedEps.count {
                    nextEpisode = sortedEps[nextIndex]
                }
            }
        } else {
            let nextIndex = currentIndex + 1
            if nextIndex < sortedEps.count {
                nextEpisode = sortedEps[nextIndex]
            }
        }
        
        if let nextEpisode = nextEpisode {
            print("[+] PodcastPlayer: Autoplay playing next episode: \(nextEpisode.title)")
            DispatchQueue.main.async {
                self.play(episode: nextEpisode)
            }
        } else {
            print("[+] PodcastPlayer: End of feed reached or no more unplayed episodes.")
        }
    }

    public func playPreviousEpisode() {
        guard let current = currentEpisode else { return }
        
        // Find the show that has this episode
        guard let show = dataManager.shows.first(where: { show in
            show.episodes.contains { $0.videoId == current.videoId }
        }) else { return }
        
        // Sort episodes oldest to newest (chronological order)
        let sortedEps = show.episodes.sorted { ep1, ep2 in
            let date1 = ep1.uploadDate ?? ep1.dateAdded
            let date2 = ep2.uploadDate ?? ep2.dateAdded
            return date1 < date2
        }
        
        guard let currentIndex = sortedEps.firstIndex(where: { $0.videoId == current.videoId }) else { return }
        
        let prevIndex = currentIndex - 1
        if prevIndex >= 0 {
            let prevEpisode = sortedEps[prevIndex]
            print("[+] PodcastPlayer: Playing previous episode: \(prevEpisode.title)")
            DispatchQueue.main.async {
                self.play(episode: prevEpisode)
            }
        } else {
            print("[*] PodcastPlayer: First episode reached. Restarting current episode.")
            seek(to: 0.0)
        }
    }
    
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        if type == .began {
            if isPlaying {
                togglePlay()
            }
        } else if type == .ended {
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) && !isPlaying {
                    togglePlay()
                }
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
                    self.isPlaying = false
                    self.avPlayer?.pause()
                    self.saveCurrentProgress()
                    self.updateNowPlayingPlaybackInfo(force: true)
                }
            }
        }
    }
    
    // MARK: - Lock Screen & Control Center Controls
    
    public func setupRemoteCommandCenter() {
        // Needed for older UIKit remote-control event routing
        DispatchQueue.main.async {
            UIApplication.shared.beginReceivingRemoteControlEvents()
        }

        let commandCenter = MPRemoteCommandCenter.shared()

        // Toggle play/pause — this is what RemoteCompanion and headphone buttons send
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if !self.isPlaying {
                self.activateAudioSessionIfNeeded()
            }
            self.togglePlay()
            return .success
        }

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if !self.isPlaying {
                self.activateAudioSessionIfNeeded()
                self.togglePlay()
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.isPlaying {
                self.pause()
            }
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: dataManager.settings.skipDuration)]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            self?.skipForward()
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.playNextEpisode(force: true)
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.playPreviousEpisode()
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: dataManager.settings.skipDuration)]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skipBackward()
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.seek(to: positionEvent.positionTime)
            return .success
        }
    }
    
    private func setupNowPlayingInfo(for episode: PodcastEpisode, fileURL: URL) {
        var nowPlayingInfo = [String: Any]()
        
        nowPlayingInfo[MPMediaItemPropertyTitle] = episode.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = episode.channel
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = episode.channel
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = episode.duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = playbackRate
        
        // Extract embedded artwork from audio file
        let asset = AVAsset(url: fileURL)
        if let artworkItem = AVMetadataItem.metadataItems(from: asset.commonMetadata, withKey: AVMetadataKey.commonKeyArtwork, keySpace: AVMetadataKeySpace.common).first,
           let artworkData = artworkItem.value as? Data,
           let image = UIImage(data: artworkData) {
            
            let mediaArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = mediaArtwork
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    private var lastNowPlayingUpdateTime: Double = 0.0

    private func updateNowPlayingPlaybackInfo(force: Bool = false) {
        if !force && abs(currentTime - lastNowPlayingUpdateTime) < 1.0 {
            return
        }
        lastNowPlayingUpdateTime = currentTime
        guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    // MARK: - Unified Auto-Skipping Engine

    private var activeDiarization: SpeakerDiarizationData? {
        if let videoId = currentEpisode?.videoId {
            for show in dataManager.shows {
                if let ep = show.episodes.first(where: { $0.videoId == videoId }) {
                    if let d = ep.speakerDiarization {
                        return d
                    }
                }
            }
        }
        return currentEpisode?.speakerDiarization
    }

    /// Computes active speaker skip regions by applying user-defined lead-in and trail buffers,
    /// bridging empty pauses and absorbing short (<2.0s) interjections between turns of skipped speakers.
    /// When `diarization.filterEnglishOnly == true`, also treats non-English segments as skip regions.
    public func getMergedSpeakerSkipRegions() -> [SpeakerSegment] {
        if dataManager.settings.batterySaverEnabled,
           let epId = currentEpisode?.videoId,
           cachedSpeakerSkipVideoId == epId,
           let cached = cachedSpeakerSkipRegions {
            return cached
        }

        guard let diarization = activeDiarization else { return [] }
        let skippedIds = Set(diarization.speakers.filter { $0.isSkipped }.map { $0.id })
        let filterEnglish = diarization.filterEnglishOnly ?? false

        // Quick exit if no speaker is skipped and english-only filtering is not active
        if skippedIds.isEmpty && !filterEnglish {
            if dataManager.settings.batterySaverEnabled, let epId = currentEpisode?.videoId {
                cachedSpeakerSkipVideoId = epId
                cachedSpeakerSkipRegions = []
            }
            return []
        }

        let allSegments = diarization.segments.sorted { $0.start < $1.start }
        guard !allSegments.isEmpty else { return [] }

        func isSegmentSkipped(_ seg: SpeakerSegment) -> Bool {
            if skippedIds.contains(seg.speakerId) {
                return true
            }
            if filterEnglish {
                let lang = (seg.language ?? "en").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !lang.isEmpty && lang != "en" {
                    return true
                }
            }
            return false
        }

        let speakerLeadIn = max(0.0, dataManager.settings.speakerSkipLeadIn)
        let speakerTrail = max(0.0, dataManager.settings.speakerSkipTrail)
        let langLeadIn = max(0.0, dataManager.settings.languageSkipLeadIn)
        let langTrail = max(0.0, dataManager.settings.languageSkipTrail)

        func hasUpcomingSkippedSegment(fromIndex startIndex: Int) -> Bool {
            var unskippedDuration = 0.0
            for j in startIndex..<allSegments.count {
                let futureSeg = allSegments[j]
                if isSegmentSkipped(futureSeg) {
                    return unskippedDuration < 2.0
                }
                unskippedDuration += (futureSeg.end - futureSeg.start)
                if unskippedDuration >= 2.0 {
                    return false
                }
            }
            return false
        }

        var mergedRegions: [SpeakerSegment] = []
        var blockStart: Double? = nil
        var blockEnd: Double = 0.0
        var blockSpeakerId: String = ""
        var blockLanguage: String? = nil
        var blockHasNonEnglish: Bool = false

        for i in 0..<allSegments.count {
            let seg = allSegments[i]
            let isSkipped = isSegmentSkipped(seg)

            if isSkipped {
                let isNonEnTurn = filterEnglish && ((seg.language ?? "en").lowercased() != "en")
                if isNonEnTurn {
                    blockHasNonEnglish = true
                }
                let effectiveLeadIn = isNonEnTurn ? langLeadIn : speakerLeadIn
                let effectiveTrail = isNonEnTurn ? langTrail : speakerTrail

                if blockStart == nil {
                    // Start of a skipped block
                    var startWithLeadIn = max(0.0, seg.start - effectiveLeadIn)
                    if i > 0 {
                        let prevSeg = allSegments[i - 1]
                        if !isSegmentSkipped(prevSeg) {
                            // Non-English / skipped follows an unskipped English segment:
                            // Start the skip cleanly right after English ends (prevSeg.end + 0.02),
                            // or at (seg.start - effectiveLeadIn), whichever is later so we don't clip into English speech.
                            // If effectiveLeadIn pushes earlier than prevSeg.end + 0.02, clamp strictly to cleanBoundaryAfterEnglish.
                            let cleanBoundaryAfterEnglish = prevSeg.end + 0.02
                            startWithLeadIn = max(cleanBoundaryAfterEnglish, startWithLeadIn)
                        }
                    } else if isNonEnTurn {
                        // At episode start, lead-in can start right at 0.0
                        startWithLeadIn = max(0.0, seg.start - effectiveLeadIn)
                    }
                    blockStart = startWithLeadIn
                    blockSpeakerId = seg.speakerId
                    blockLanguage = seg.language
                } else if let l = seg.language, l.lowercased() != "en" {
                    blockLanguage = l
                }

                var endWithTrail = seg.end + effectiveTrail
                if i + 1 < allSegments.count {
                    let nextSeg = allSegments[i + 1]
                    let gap = nextSeg.start - seg.end
                    if isSegmentSkipped(nextSeg) {
                        // Bridge consecutive skipped segments
                        endWithTrail = max(endWithTrail, nextSeg.start)
                    } else if !isNonEnTurn && gap <= 2.0 && hasUpcomingSkippedSegment(fromIndex: i + 1) {
                        // Short pause before skipped speech continues (only for speaker mute, NOT non-English)
                        endWithTrail = max(endWithTrail, nextSeg.end)
                    } else if isNonEnTurn || blockHasNonEnglish {
                        // Non-English turn followed by English speech:
                        // Bridge the entire pause/interlude so neither Spanish leftovers nor the trailing interlude are heard.
                        // Stop cleanly 0.15s before the English speaker begins.
                        let cleanCutBeforeEnglish = max(seg.end + effectiveTrail, nextSeg.start - 0.15)
                        endWithTrail = min(nextSeg.start, max(endWithTrail, cleanCutBeforeEnglish))
                    } else {
                        // Unskipped speech following: stop cleanly before next speaker starts
                        endWithTrail = min(max(blockStart ?? seg.start, nextSeg.start), endWithTrail)
                    }
                }
                blockEnd = max(blockEnd, endWithTrail)
            } else {
                // Unskipped segment encountered: close block cleanly so English speech is never skipped
                if let start = blockStart {
                    let safeEnd = min(max(start, seg.start), blockEnd)
                    if safeEnd > start {
                        mergedRegions.append(SpeakerSegment(speakerId: blockSpeakerId, start: start, end: safeEnd, language: blockLanguage))
                    }
                    blockStart = nil
                    blockEnd = 0.0
                    blockLanguage = nil
                    blockHasNonEnglish = false
                }
            }
        }

        // Close final block if episode ends on skipped content
        if let start = blockStart {
            if blockEnd > start {
                mergedRegions.append(SpeakerSegment(speakerId: blockSpeakerId, start: start, end: blockEnd, language: blockLanguage))
            }
        }

        let finalRegions: [SpeakerSegment]
        if mergedRegions.count > 1 {
            var consolidated: [SpeakerSegment] = []
            var currentRegion = mergedRegions[0]

            for k in 1..<mergedRegions.count {
                let nextRegion = mergedRegions[k]
                let pauseDuration = nextRegion.start - currentRegion.end

                let hasUnskippedSpeechInBetween = allSegments.contains { s in
                    !isSegmentSkipped(s) && (s.end > currentRegion.end && s.start < nextRegion.start)
                }

                if pauseDuration <= 2.5 && !hasUnskippedSpeechInBetween {
                    currentRegion.end = max(currentRegion.end, nextRegion.end)
                } else {
                    consolidated.append(currentRegion)
                    currentRegion = nextRegion
                }
            }
            consolidated.append(currentRegion)
            finalRegions = consolidated
        } else {
            finalRegions = mergedRegions
        }

        if dataManager.settings.batterySaverEnabled, let epId = currentEpisode?.videoId {
            cachedSpeakerSkipVideoId = epId
            cachedSpeakerSkipRegions = finalRegions
        }

        return finalRegions
    }

    /// Returns calculated silence skip intervals for non-speech gaps exceeding maxSilenceDuration
    public func getSilenceSkipIntervals() -> [(start: Double, end: Double)] {
        guard let ep = currentEpisode, ep.removeSilence,
              let diarization = ep.speakerDiarization, !diarization.segments.isEmpty else {
            return []
        }

        let maxPause = max(0.0, ep.maxSilenceDuration)
        let totalDuration = duration > 0 ? duration : (ep.duration > 0 ? ep.duration : 0.0)

        // Filter and sort all audio segments
        let rawSpeech = diarization.segments
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }

        guard !rawSpeech.isEmpty else { return [] }

        // Consolidate overlapping / continuous speech segments
        var speechBlocks: [(start: Double, end: Double)] = []
        var curBlockStart = rawSpeech[0].start
        var curBlockEnd = rawSpeech[0].end

        for i in 1..<rawSpeech.count {
            let nextStart = rawSpeech[i].start
            let nextEnd = rawSpeech[i].end

            if nextStart <= curBlockEnd + 0.01 {
                curBlockEnd = max(curBlockEnd, nextEnd)
            } else {
                speechBlocks.append((start: curBlockStart, end: curBlockEnd))
                curBlockStart = nextStart
                curBlockEnd = nextEnd
            }
        }
        speechBlocks.append((start: curBlockStart, end: curBlockEnd))

        var silenceSkips: [(start: Double, end: Double)] = []

        // 1. Initial silence before first speech block
        if speechBlocks[0].start > 0 {
            let gap = speechBlocks[0].start
            if gap > maxPause {
                let skipStart = maxPause
                let skipEnd = speechBlocks[0].start
                if skipEnd > skipStart {
                    silenceSkips.append((start: skipStart, end: skipEnd))
                }
            }
        }

        // 2. Silence gaps between speech blocks
        for i in 0..<(speechBlocks.count - 1) {
            let gapStart = speechBlocks[i].end
            let gapEnd = speechBlocks[i + 1].start
            let gapDur = gapEnd - gapStart
            if gapDur > maxPause {
                let skipStart = gapStart + maxPause
                let skipEnd = gapEnd
                if skipEnd > skipStart {
                    silenceSkips.append((start: skipStart, end: skipEnd))
                }
            }
        }

        // 3. Trailing silence after last speech block
        if totalDuration > speechBlocks.last!.end {
            let gapStart = speechBlocks.last!.end
            let gapEnd = totalDuration
            let gapDur = gapEnd - gapStart
            if gapDur > maxPause {
                let skipStart = gapStart + maxPause
                let skipEnd = gapEnd
                if skipEnd > skipStart {
                    silenceSkips.append((start: skipStart, end: skipEnd))
                }
            }
        }

        return silenceSkips
    }

    /// Returns all unified active skip intervals sorted chronologically and merged.
    public func getAllActiveSkipIntervals() -> [(start: Double, end: Double)] {
        if isSamplingSpeaker, !samplingSegments.isEmpty {
            var intervals: [(start: Double, end: Double)] = []
            let totalDur = duration > 0 ? duration : (currentEpisode?.duration ?? 0.0)
            var cursor = 0.0
            for seg in samplingSegments {
                if seg.start > cursor {
                    intervals.append((start: cursor, end: seg.start))
                }
                cursor = max(cursor, seg.end)
            }
            if totalDur > cursor {
                intervals.append((start: cursor, end: totalDur))
            }
            return intervals
        }

        var intervals: [(start: Double, end: Double)] = []

        // 1. Speaker Skips (merged continuous regions)
        for seg in getMergedSpeakerSkipRegions() {
            if seg.end > seg.start {
                intervals.append((start: seg.start, end: seg.end))
            }
        }

        // 2. User Custom Skips
        if dataManager.settings.userSkipsEnabled, let skips = currentEpisode?.customSkips {
            for skip in skips where skip.isEnabled && skip.end > skip.start {
                intervals.append((start: skip.start, end: skip.end))
            }
        }

        // 3. SponsorBlock Skips
        if dataManager.settings.sponsorBlockEnabled, let segments = currentEpisode?.segments {
            for seg in segments where dataManager.settings.sponsorBlockCategories.contains(seg.category) && seg.end > seg.start {
                intervals.append((start: seg.start, end: seg.end))
            }
        }

        // 4. Silence Removal Skips
        for skip in getSilenceSkipIntervals() {
            intervals.append((start: skip.start, end: skip.end))
        }

        guard !intervals.isEmpty else { return [] }

        let sorted = intervals.sorted { $0.start < $1.start }
        var merged: [(start: Double, end: Double)] = []
        var curStart = sorted[0].start
        var curEnd = sorted[0].end

        for i in 1..<sorted.count {
            let nextStart = sorted[i].start
            let nextEnd = sorted[i].end

            if nextStart <= curEnd + 0.05 {
                curEnd = max(curEnd, nextEnd)
            } else {
                merged.append((start: curStart, end: curEnd))
                curStart = nextStart
                curEnd = nextEnd
            }
        }
        merged.append((start: curStart, end: curEnd))
        return merged
    }

    /// Dynamically updates AVPlayer boundary time observers for exact hardware-level skip triggering
    public func updateSkipBoundaryObservers() {
        invalidateSpeakerSkipCache()
        if let bToken = boundaryObserverToken {
            avPlayer?.removeTimeObserver(bToken)
            boundaryObserverToken = nil
        }
        guard let avPlayer = avPlayer else { return }

        // Only register macroscopic skips (Speaker Skips, User Skips, SponsorBlock, or Sampling Skips) for hardware boundary triggers.
        // Silence trimming generates hundreds of micro-intervals which are evaluated seamlessly by the periodic time observer.
        var intervals: [(start: Double, end: Double)] = []
        if isSamplingSpeaker, !samplingSegments.isEmpty {
            intervals = getAllActiveSkipIntervals()
        } else {
            for seg in getMergedSpeakerSkipRegions() {
                if seg.end > seg.start { intervals.append((start: seg.start, end: seg.end)) }
            }
            if dataManager.settings.userSkipsEnabled, let skips = currentEpisode?.customSkips {
                for skip in skips where skip.isEnabled && skip.end > skip.start {
                    intervals.append((start: skip.start, end: skip.end))
                }
            }
            if dataManager.settings.sponsorBlockEnabled, let segments = currentEpisode?.segments {
                for seg in segments where dataManager.settings.sponsorBlockCategories.contains(seg.category) && seg.end > seg.start {
                    intervals.append((start: seg.start, end: seg.end))
                }
            }
        }

        guard !intervals.isEmpty else { return }

        let boundaryTimes = intervals.compactMap { interval -> NSValue? in
            // Trigger 120ms before interval start for hardware decode mute lookahead
            let triggerSec = max(0.0, interval.start - 0.12)
            guard triggerSec.isFinite else { return nil }
            let cm = CMTime(seconds: triggerSec, preferredTimescale: 600)
            return NSValue(time: cm)
        }

        guard !boundaryTimes.isEmpty else { return }

        boundaryObserverToken = avPlayer.addBoundaryTimeObserver(forTimes: boundaryTimes, queue: .main) { [weak self] in
            guard let self = self else { return }
            let exactTime = self.avPlayer?.currentTime().seconds ?? self.currentTime
            self.checkAutoSkips(time: exactTime, isBoundaryTrigger: true)
        }
    }

    /// Resolves any timestamp to a valid playable position outside of all active skips.
    /// If `time` falls inside any active skip region, returns the end timestamp.
    public func resolveSkipDestination(time: Double) -> Double {
        var resolvedTime = time
        let intervals = getAllActiveSkipIntervals()
        var changed = true
        var iterations = 0

        while changed && iterations < 15 {
            changed = false
            iterations += 1
            for interval in intervals {
                if resolvedTime >= interval.start && resolvedTime < interval.end {
                    resolvedTime = interval.end
                    changed = true
                } else if interval.start > resolvedTime && (interval.start - resolvedTime) <= 0.30 {
                    // Pre-roll bridge: avoid landing in a micro-gap (<= 0.30s) right before another skipped segment
                    resolvedTime = interval.end
                    changed = true
                }
            }
        }

        return min(resolvedTime, duration > 0 ? duration : resolvedTime)
    }

    // MARK: - Skip State Machine

    /// Explicit three-state machine that replaces the old `isAutoSkipping` boolean.
    ///
    /// - `.idle`        Normal playback; skip evaluation is active.
    /// - `.seeking`     A seek has been dispatched. Both the 250ms periodic tick and
    ///                  boundary callbacks are silenced until `avPlayer.currentTime()`
    ///                  strictly exceeds `minPlayableTime`.
    /// - `.coolingDown` Post-seek silence window (or oscillation-breaker holdoff).
    ///                  Skip evaluation resumes only after `until` wall-clock time.
    private enum SkipState: Equatable {
        case idle
        case seeking(target: Double, minPlayableTime: Double, initiatedAt: CFAbsoluteTime)
        case coolingDown(until: CFAbsoluteTime)

        static func == (lhs: SkipState, rhs: SkipState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.seeking, .seeking): return true
            case (.coolingDown, .coolingDown): return true
            default: return false
            }
        }
    }

    private var skipState: SkipState = .idle
    /// Sliding ring buffer of recent seek targets (max 4) for oscillation detection.
    private var recentSeekHistory: [(target: Double, time: CFAbsoluteTime)] = []
    private var consecutiveAutoSkipFailures: Int = 0

    public func evaluateSkipsNow() {
        let exactTime = avPlayer?.currentTime().seconds ?? currentTime
        checkAutoSkips(time: exactTime)
    }

    private func checkAutoSkips(time: Double, isBoundaryTrigger: Bool = false) {
        guard let avPlayer = avPlayer else { return }

        let now = CFAbsoluteTimeGetCurrent()

        // ── State Machine Gate ────────────────────────────────────────────────
        switch skipState {
        case .seeking(_, let minPlayableTime, let initiatedAt):
            let intervals = getAllActiveSkipIntervals()
            let isInsideOrNearSkip = intervals.contains {
                (time >= $0.start && time < $0.end) || ($0.start > time && ($0.start - time) <= 0.30)
            }

            // Safety timeout: never let seeking state lock skipping for more than 0.8s of wall-clock time
            if now - initiatedAt > 0.8 {
                if !isInsideOrNearSkip {
                    avPlayer.isMuted = false
                    avPlayer.volume = 1.0
                }
                skipState = .idle
                break
            }
            // Still waiting for the seek to land; ignore ticks until we're clear.
            if time < minPlayableTime || isInsideOrNearSkip {
                return
            }
            // Advanced past minPlayableTime and safely clear of upcoming skip turns!
            avPlayer.isMuted = false
            avPlayer.volume = 1.0
            skipState = .coolingDown(until: now + 0.10)
            return

        case .coolingDown(let until):
            if now < until && !isBoundaryTrigger { return }
            skipState = .idle

        case .idle:
            break
        }

        // ── Interval Resolution ───────────────────────────────────────────────
        let intervals = getAllActiveSkipIntervals()
        guard !intervals.isEmpty else { return }

        var skipEnd: Double? = nil

        if isBoundaryTrigger {
            // Boundary observer fired at or 50ms before the skip start — match the interval.
            if let match = intervals.first(where: {
                (time >= $0.start - 0.20 && time < $0.end) || abs($0.start - time) <= 0.25
            }) {
                // Deadband: don't trigger if less than 0.04s remains in the skip region
                guard (match.end - time) >= 0.04 else { return }
                // Pre-roll mute guard: immediately mute before any audio rendering lag
                avPlayer.isMuted = true
                skipEnd = match.end
            }
        }

        if skipEnd == nil {
            // Periodic tick path — use a rate-aware lookahead window.
            let lookaheadWindow = max(0.12, Double(playbackRate) * 0.16)
            let lookaheadTime = time + lookaheadWindow

            let destCurrent = resolveSkipDestination(time: time)
            let destLookahead = resolveSkipDestination(time: lookaheadTime)

            if destCurrent > (time + 0.04) {
                // Current position is inside a skip region.
                avPlayer.isMuted = true
                skipEnd = destCurrent
            } else if destLookahead > (lookaheadTime + 0.04) {
                // Pre-roll Mute Guard: Just ahead of a skip region — engage mute BEFORE reaching non-English audio!
                avPlayer.isMuted = true
                skipEnd = destLookahead
            }
        }

        guard let resolvedEnd = skipEnd else {
            // Only unmute if idle and not approaching any upcoming skip within 0.30s
            if case .idle = skipState {
                let isApproachingSkip = intervals.contains {
                    (time >= $0.start && time < $0.end) || ($0.start > time && ($0.start - time) <= 0.30)
                }
                if !isApproachingSkip && avPlayer.isMuted {
                    avPlayer.isMuted = false
                    avPlayer.volume = 1.0
                }
            }
            return
        }

        // ── Oscillation Breaker ───────────────────────────────────────────────
        // Maintain a sliding ring buffer of the last 4 seek targets.
        // If we're trying to seek to the same ±0.15s region more than twice
        // within 1.0s, we're bouncing — forcefully break out.
        recentSeekHistory.append((target: resolvedEnd, time: now))
        // Trim entries older than 1.0s
        recentSeekHistory = recentSeekHistory.filter { now - $0.time <= 1.0 }
        if recentSeekHistory.count > 4 { recentSeekHistory.removeFirst() }

        let nearMatches = recentSeekHistory.filter { abs($0.target - resolvedEnd) < 0.15 }
        if nearMatches.count >= 3 {
            // Oscillation detected: jump hard past the stuck region.
            let breakTarget = min(resolvedEnd + 0.25, duration > 0 ? duration : resolvedEnd + 0.25)
            print("[!] PodcastPlayer: Oscillation breaker fired — jumping \(String(format: "%.2f", breakTarget))s past stuck region at \(String(format: "%.2f", resolvedEnd))s")
            recentSeekHistory = []  // clear history so we don't loop on the breaker itself
            consecutiveAutoSkipFailures = 0
            skipState = .coolingDown(until: now + 1.5)

            avPlayer.isMuted = true
            let breakTime = CMTime(seconds: breakTarget, preferredTimescale: 600)
            avPlayer.seek(to: breakTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, avPlayer] _ in
                avPlayer.isMuted = false
                avPlayer.volume = 1.0
                guard let self = self else { return }
                self.currentTime = breakTarget
                self.updateNowPlayingPlaybackInfo(force: true)
                if self.isPlaying { self.avPlayer?.rate = self.playbackRate }
            }
            return
        }

        // ── Execute Skip ──────────────────────────────────────────────────────
        // Land +0.08s past the skip end to clear the lookahead window even at 2× rate,
        // then resolve through resolveSkipDestination to prevent landing in any micro-gap <= 0.30s.
        let rawTarget = min(resolvedEnd + 0.08, duration > 0 ? duration : resolvedEnd + 0.08)
        let safeTarget = resolveSkipDestination(time: rawTarget)
        let minPlayableTime = resolvedEnd + 0.04   // lookahead window gate
        print("[+] PodcastPlayer: Auto-skip from \(String(format: "%.2f", time))s → \(String(format: "%.2f", safeTarget))s (skip end: \(String(format: "%.2f", resolvedEnd))s)")

        skipState = .seeking(target: safeTarget, minPlayableTime: minPlayableTime, initiatedAt: now)

        // Hardware-level instant mute guard to silence audio buffer during seek transit
        avPlayer.isMuted = true

        // Use zero tolerance for precision. Fall back to small tolerance after repeated
        // background-mode failures where iOS coalesces zero-tolerance seeks.
        let tolerance: CMTime = (consecutiveAutoSkipFailures > 1)
            ? CMTime(seconds: 0.03, preferredTimescale: 600)
            : .zero

        avPlayer.seek(to: CMTime(seconds: safeTarget, preferredTimescale: 600),
                      toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self, avPlayer] finished in
            guard let self = self else { return }

            if finished {
                self.consecutiveAutoSkipFailures = 0
                self.currentTime = safeTarget
                self.updateNowPlayingPlaybackInfo(force: true)
                self.saveCurrentProgress()
                if self.isPlaying { self.avPlayer?.rate = self.playbackRate }

                // Strict Post-Seek Unmute Guard: Keep audio muted if current playhead is still near the skip boundary
                // or if it landed within 0.30s of another non-English / skipped turn.
                let currentSec = self.avPlayer?.currentTime().seconds ?? safeTarget
                let activeIntervals = self.getAllActiveSkipIntervals()
                let isNearOrInsideSkip = activeIntervals.contains {
                    (currentSec >= $0.start && currentSec < $0.end) ||
                    ($0.start > currentSec && ($0.start - currentSec) <= 0.30)
                }

                if currentSec >= minPlayableTime && !isNearOrInsideSkip {
                    avPlayer.isMuted = false
                    avPlayer.volume = 1.0
                    self.skipState = .coolingDown(until: CFAbsoluteTimeGetCurrent() + 0.12)
                } else if isNearOrInsideSkip {
                    // Audio landed in/near another skip turn! Maintain mute and immediately extend skip.
                    let extendedDest = self.resolveSkipDestination(time: currentSec + 0.35)
                    print("[*] PodcastPlayer: Post-seek landed at \(String(format: "%.2f", currentSec))s within 0.30s of skip; extending to \(String(format: "%.2f", extendedDest))s with mute guard maintained")
                    avPlayer.isMuted = true
                    let nextTime = CMTime(seconds: extendedDest, preferredTimescale: 600)
                    avPlayer.seek(to: nextTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, avPlayer] nextFinished in
                        guard let self = self else { return }
                        if nextFinished {
                            let endSec = self.avPlayer?.currentTime().seconds ?? extendedDest
                            self.currentTime = endSec
                            let stillNear = self.getAllActiveSkipIntervals().contains {
                                (endSec >= $0.start && endSec < $0.end) || ($0.start > endSec && ($0.start - endSec) <= 0.30)
                            }
                            if !stillNear {
                                avPlayer.isMuted = false
                                avPlayer.volume = 1.0
                                self.skipState = .coolingDown(until: CFAbsoluteTimeGetCurrent() + 0.12)
                            }
                        }
                    }
                } else {
                    // Stay muted in .seeking state until periodic tick confirms playhead >= minPlayableTime
                    print("[*] PodcastPlayer: Post-seek landed at \(String(format: "%.2f", currentSec))s < minPlayableTime \(String(format: "%.2f", minPlayableTime))s; maintaining mute guard")
                }
            } else {
                // Seek was cancelled (background/low-power runloop stall).
                self.consecutiveAutoSkipFailures += 1
                print("[!] PodcastPlayer: Auto-skip seek cancelled (finished: false, failures: \(self.consecutiveAutoSkipFailures))")

                let actualSec = self.avPlayer?.currentTime().seconds ?? safeTarget
                if actualSec.isFinite { self.currentTime = actualSec }

                // Always restore audio — never leave the player muted after a failed seek.
                // This is the root cause of the locked-screen silence bug.
                avPlayer.isMuted = false
                avPlayer.volume = 1.0

                // If the playhead hasn't cleared minPlayableTime yet (typical background coalesce),
                // keep .seeking so the state-machine gate in the next 0.25s tick prevents an
                // immediate re-trigger stutter loop. Flip to .idle only when we're safely past
                // the skip boundary and the next tick can evaluate fresh.
                if actualSec.isFinite && actualSec >= minPlayableTime {
                    self.skipState = .idle
                }
                // else: leave skipState as .seeking — the 0.8s safety timeout will clear it.
            }
        }
    }

    /// Seeks to `start - 2.0s` and begins playback so the user can hear the
    /// skip fire naturally during audition. The state machine handles the skip
    /// cleanly without oscillation.
    public func auditionSkip(start: Double, end: Double) {
        guard end > start else { return }
        let preRoll = max(0, start - 2.0)
        seek(to: preRoll)
        if !isPlaying {
            resume()
        }
    }

    /// Loops continuous 10-second window across a skip boundary for rapid audition
    public func startBoundaryLoop(start: Double, end: Double) {
        isLoopingBoundary = true
        boundaryLoopStart = max(0.0, start - 3.0)
        boundaryLoopEnd = end + 1.5
        seek(to: boundaryLoopStart)
        if !isPlaying { resume() }
    }

    public func stopBoundaryLoop() {
        isLoopingBoundary = false
    }

    public func toggleBoundaryLoop(start: Double, end: Double) {
        if isLoopingBoundary {
            stopBoundaryLoop()
        } else {
            startBoundaryLoop(start: start, end: end)
        }
    }

    /// Immediately tests whether the current playback position falls within a skip interval
    /// and performs a jump if necessary (e.g. when toggling Trim Silence mid-playback).
    public func evaluateAutoSkipsImmediately() {
        guard let avPlayer = avPlayer, isPlaying else { return }
        let time = avPlayer.currentTime().seconds
        guard time.isFinite else { return }
        let dest = resolveSkipDestination(time: time)
        if dest > (time + 0.04) {
            avPlayer.isMuted = true
        }
        self.checkAutoSkips(time: time)
    }

    /// Auditions only the selected speaker's voice clips by skipping all other speakers and audio.
    public func startSpeakerSampling(
        for episode: PodcastEpisode,
        speakerId: String,
        diarization: SpeakerDiarizationData,
        maxSpeechDuration: Double = 15.0
    ) {
        let speakerSegments = diarization.segments
            .filter { $0.speakerId == speakerId && $0.end > $0.start }
            .sorted { $0.start < $1.start }

        guard let first = speakerSegments.first else { return }

        // If user taps the active sampling speaker button again, stop audition
        if isSamplingSpeaker && activeSamplingSpeakerId == speakerId {
            stopSpeakerSampling()
            return
        }

        isSamplingSpeaker = true
        activeSamplingSpeakerId = speakerId
        samplingSegments = speakerSegments
        samplingMaxDuration = maxSpeechDuration
        samplingAccumulatedSpeech = 0.0
        samplingLastTime = first.start

        if currentEpisode?.videoId == episode.videoId && avPlayer != nil {
            updateSkipBoundaryObservers()
            seek(to: first.start)
            if !isPlaying {
                resume()
            }
        } else {
            play(episode: episode)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self = self, self.isSamplingSpeaker, self.activeSamplingSpeakerId == speakerId else { return }
                self.updateSkipBoundaryObservers()
                self.seek(to: first.start)
                if !self.isPlaying {
                    self.resume()
                }
            }
        }
    }

    /// Stops speaker sampling audition mode cleanly and restores standard playback state.
    public func stopSpeakerSampling() {
        guard isSamplingSpeaker || activeSamplingSpeakerId != nil else { return }
        isSamplingSpeaker = false
        activeSamplingSpeakerId = nil
        samplingSegments = []
        samplingAccumulatedSpeech = 0.0
        samplingLastTime = nil
        pause()
        updateSkipBoundaryObservers()
    }
}
