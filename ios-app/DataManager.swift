import Foundation
import Combine
import UIKit
import AVFoundation



public class DataManager: ObservableObject {
    @Published public var shows: [PodcastShow] = []
    @Published public var subscriptions: [Subscription] = []
    @Published public var isDownloading: Bool = false
    @Published public var downloadLogs: String = ""
    @Published public var settings: AppSettings = AppSettings()
    @Published public var activeDownloads: Set<String> = []
    @Published public var downloadQueue: [String] = []
    @Published public var activeDownloadsList: [ActiveDownload] = []
    @Published public var isBulkQueueLoading: Bool = false
    @Published public var currentQueueUrl: String? = nil
    
    // Sync & Daemon Status
    @Published public var isSyncing: Bool = false
    @Published public var syncStatusMessage: String = "Idle"
    @Published public var syncStatusPhase: String = "idle"
    @Published public var currentSyncChannel: String = ""
    @Published public var lastSyncDate: Date? = nil
    @Published public var daemonLogs: String = ""

    private var signalSource: DispatchSourceSignal?
    private var progressTimer: Timer?
    private var diarizationTimer: Timer?
    
    #if os(iOS) && !targetEnvironment(simulator)
    private var activePid: pid_t? = nil
    private var activeSyncPid: pid_t? = nil
    #else
    private var activeProcess: Process? = nil
    private var activeSyncProcess: Process? = nil
    #endif

    private let progressSaveQueue = DispatchQueue(label: "com.saihgupr.podcastthis.progressSave", qos: .utility)
    public let baseDirectory: URL
    public let downloadsDirectory: URL
    public let stateFileURL: URL

    public static let shared = DataManager()

    private init() {
        #if targetEnvironment(simulator)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseDirectory = appSupport.appendingPathComponent("PodcastThis")
        #else
        if FileManager.default.fileExists(atPath: "/var/mobile/Library/Application Support") {
            baseDirectory = URL(fileURLWithPath: "/var/mobile/Library/Application Support/PodcastThis")
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            baseDirectory = appSupport.appendingPathComponent("PodcastThis")
        }
        #endif

        downloadsDirectory = baseDirectory.appendingPathComponent("downloads")
        stateFileURL = baseDirectory.appendingPathComponent("state.json")

        createDirectoriesIfNeeded()
        loadData()

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadData()
            self?.loadActiveDownloads()
            self?.loadSyncStatus()
            self?.loadDaemonLogs()
            self?.evaluateProgressTimer()
            self?.checkPendingShares()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.progressTimer?.invalidate()
            self?.progressTimer = nil
            self?.diarizationTimer?.invalidate()
            self?.diarizationTimer = nil
            if let isSync = self?.isSyncing, isSync {
                if let running = self?.isDaemonRunning(), !running {
                    self?.isSyncing = false
                    self?.syncStatusPhase = "idle"
                }
            }
        }

        #if os(iOS) && !targetEnvironment(simulator)
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            self?.loadData()
            self?.loadActiveDownloads()
            self?.loadSyncStatus()
            self?.loadDaemonLogs()
            self?.checkPendingShares()
        }
        source.resume()
        self.signalSource = source
        #endif

        loadActiveDownloads()
        loadSyncStatus()
        loadDaemonLogs()
        evaluateProgressTimer()
        checkPendingShares()
    }

    private func createDirectoriesIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true, attributes: nil)
            if !FileManager.default.fileExists(atPath: stateFileURL.path) {
                let initialState = AppState(subscriptions: [], playbackProgress: [:])
                let data = try JSONEncoder().encode(initialState)
                try data.write(to: stateFileURL)
            }
        } catch {
            print("[-] DataManager: Error creating directories: \(error)")
        }
    }

    public func loadDataAsync() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                self.loadDataSyncInternal()
                continuation.resume()
            }
        }
    }

    public func loadData() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.loadDataSyncInternal()
        }
    }

    private func loadDataSyncInternal() {
        let appState: AppState
        if let stateData = try? Data(contentsOf: stateFileURL),
           let decoded = try? JSONDecoder().decode(AppState.self, from: stateData) {
            appState = decoded
        } else {
            print("[-] DataManager: Warning: state.json missing or invalid, using fallback state")
            appState = AppState(subscriptions: [], playbackProgress: [:])
        }

        DispatchQueue.main.async {
            self.subscriptions = appState.subscriptions
            self.settings = appState.settings ?? AppSettings()
        }

        let supportedExtensions = Set(["m4a", "mp3", "m4b", "mp4", "aac", "flac", "wav", "opus", "ogg"])
        var foundFileURLs: [URL] = []

        if let enumerator = FileManager.default.enumerator(
            at: downloadsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                if supportedExtensions.contains(ext) && !fileURL.lastPathComponent.contains("_temp") {
                    foundFileURLs.append(fileURL)
                }
            }
        }

        var parsedEpisodes: [PodcastEpisode] = []
        var processedVideoIds = Set<String>()
        let downloadsPath = downloadsDirectory.path

        for fileURL in foundFileURLs {
            let fullPath = fileURL.path
            let relativeFilename: String
            if fullPath.hasPrefix(downloadsPath + "/") {
                relativeFilename = String(fullPath.dropFirst(downloadsPath.count + 1))
            } else {
                relativeFilename = fileURL.lastPathComponent
            }

            let videoId = fileURL.deletingPathExtension().lastPathComponent

            if processedVideoIds.contains(videoId) {
                continue
            }
            processedVideoIds.insert(videoId)

            if let progress = appState.playbackProgress[videoId] {
                let progressFileURL = downloadsDirectory.appendingPathComponent(progress.filename)
                let actualRelativeFilename: String
                if FileManager.default.fileExists(atPath: progressFileURL.path) {
                    actualRelativeFilename = progress.filename
                } else {
                    actualRelativeFilename = relativeFilename
                }

                let episode = PodcastEpisode(
                    videoId: videoId,
                    title: progress.title,
                    channel: progress.channel,
                    channelUrl: progress.channelUrl,
                    duration: progress.duration,
                    filename: actualRelativeFilename,
                    lastPosition: progress.lastPosition,
                    completed: progress.completed,
                    lastPlayed: progress.lastPlayed,
                    dateAdded: progress.dateAdded,
                    segments: progress.segments,
                    customSkips: progress.customSkips,
                    speakerDiarization: progress.speakerDiarization,
                    uploadDate: progress.uploadDate,
                    removeSilence: progress.removeSilence,
                    maxSilenceDuration: progress.maxSilenceDuration
                )
                parsedEpisodes.append(episode)
            } else {
                let dateString = (try? fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate?.description) ?? Date().description
                var title = videoId
                var channel = "Imported Feed"

                let parentFolder = fileURL.deletingLastPathComponent()
                if parentFolder.path != downloadsPath {
                    channel = parentFolder.lastPathComponent
                }

                let asset = AVURLAsset(url: fileURL)
                let cmDuration = asset.duration
                let duration: Double = (cmDuration.timescale > 0) ? Double(cmDuration.value) / Double(cmDuration.timescale) : 0.0

                for item in asset.commonMetadata {
                    guard let key = item.commonKey?.rawValue else { continue }
                    if key == AVMetadataKey.commonKeyTitle.rawValue, let str = item.stringValue, !str.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty {
                        title = str
                    } else if key == AVMetadataKey.commonKeyArtist.rawValue, let str = item.stringValue, !str.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty {
                        channel = str
                    } else if key == AVMetadataKey.commonKeyAlbumName.rawValue, let str = item.stringValue, !str.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty {
                        if channel == "Imported Feed" || parentFolder.path == downloadsPath {
                            channel = str
                        }
                    } else if key == AVMetadataKey.commonKeyArtwork.rawValue, let data = item.dataValue {
                        let artPath = downloadsDirectory.appendingPathComponent("\(videoId)_art.jpg")
                        if !FileManager.default.fileExists(atPath: artPath.path) {
                            try? data.write(to: artPath)
                        }
                    }
                }

                let episode = PodcastEpisode(
                    videoId: videoId,
                    title: title,
                    channel: channel,
                    channelUrl: "",
                    duration: duration,
                    filename: relativeFilename,
                    lastPosition: 0.0,
                    completed: false,
                    lastPlayed: nil,
                    dateAdded: dateString,
                    segments: nil,
                    customSkips: nil,
                    speakerDiarization: nil,
                    uploadDate: nil,
                    removeSilence: false,
                    maxSilenceDuration: 5.0
                )
                parsedEpisodes.append(episode)
            }
        }

        let grouped = Dictionary(grouping: parsedEpisodes, by: { $0.channel })

        let mappedShows: [PodcastShow] = grouped.map { channelName, episodes in
            let sortedEpisodes = episodes.sorted(by: { $0.dateAdded > $1.dateAdded })
            let artworkFilename: String? = sortedEpisodes.compactMap { ep -> String? in
                let artName = "\(ep.videoId)_art.jpg"
                if FileManager.default.fileExists(atPath: self.downloadsDirectory.appendingPathComponent(artName).path) {
                    return artName
                }
                let epURL = self.downloadsDirectory.appendingPathComponent(ep.filename)
                let folder = epURL.deletingLastPathComponent()
                if folder.path != downloadsPath {
                    let subArtPath = folder.appendingPathComponent(artName)
                    if FileManager.default.fileExists(atPath: subArtPath.path) {
                        return String(subArtPath.path.dropFirst(downloadsPath.count + 1))
                    }
                    for coverName in ["cover.jpg", "folder.jpg", "artwork.jpg", "album.jpg", "cover.png", "folder.png"] {
                        let coverURL = folder.appendingPathComponent(coverName)
                        if FileManager.default.fileExists(atPath: coverURL.path) {
                            return String(coverURL.path.dropFirst(downloadsPath.count + 1))
                        }
                    }
                }
                return nil
            }.first
            return PodcastShow(channelName: channelName, episodes: sortedEpisodes, artworkFilename: artworkFilename)
        }

        let savedOrder = appState.showOrder ?? []
        let orderMap = Dictionary(uniqueKeysWithValues: savedOrder.enumerated().map { ($1, $0) })
        let sortedShows = mappedShows.sorted { showA, showB in
            let orderA = orderMap[showA.channelName] ?? Int.max
            let orderB = orderMap[showB.channelName] ?? Int.max
            if orderA != orderB {
                return orderA < orderB
            }
            return showA.channelName.localizedCaseInsensitiveCompare(showB.channelName) == .orderedAscending
        }

        DispatchQueue.main.async {
            self.shows = sortedShows
        }
    }

    // MARK: - Show Reordering

    public func moveShow(fromOffsets source: IndexSet, toOffset destination: Int) {
        shows.move(fromOffsets: source, toOffset: destination)
        saveShowOrder()
    }

    public func moveShow(fromIndex: Int, toIndex: Int) {
        guard fromIndex != toIndex, shows.indices.contains(fromIndex), shows.indices.contains(toIndex) else { return }
        let show = shows.remove(at: fromIndex)
        shows.insert(show, at: toIndex)
        saveShowOrder()
    }

    public func saveShowOrder() {
        let order = shows.map { $0.channelName }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self,
                  let stateData = try? Data(contentsOf: self.stateFileURL),
                  var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }
            appState.showOrder = order
            if let encoded = try? JSONEncoder().encode(appState) {
                try? encoded.write(to: self.stateFileURL)
            }
        }
    }

    public func evaluateProgressTimer() {
        if settings.batterySaverEnabled {
            let shouldRun = isDownloading || isSyncing
            if shouldRun {
                if progressTimer == nil {
                    startProgressTimer()
                }
            } else {
                progressTimer?.invalidate()
                progressTimer = nil
            }
        } else {
            if progressTimer == nil {
                startProgressTimer()
            }
        }
    }

    public func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.loadActiveDownloads()
            self.loadSyncStatus()
            self.loadDaemonLogs()
            if self.settings.batterySaverEnabled && !self.isDownloading && !self.isSyncing {
                self.progressTimer?.invalidate()
                self.progressTimer = nil
            }
        }
    }

    public func loadActiveDownloads() {
        let fileURL = baseDirectory.appendingPathComponent("active_downloads.json")
        guard let data = try? Data(contentsOf: fileURL),
              let container = try? JSONDecoder().decode(ActiveDownloadsContainer.self, from: data) else {
            DispatchQueue.main.async {
                if self.activeDownloads.isEmpty {
                    if !self.activeDownloadsList.isEmpty {
                        self.activeDownloadsList = []
                    }
                    self.isDownloading = false
                }
            }
            return
        }
        
        let list = Array(container.activeDownloads.values).sorted(by: { $0.title < $1.title })
        DispatchQueue.main.async {
            if !list.isEmpty {
                self.activeDownloadsList = list
            } else if self.activeDownloads.isEmpty {
                self.activeDownloadsList = []
            }
            
            let anyActive = !self.activeDownloadsList.isEmpty || !self.activeDownloads.isEmpty || !self.downloadQueue.isEmpty
            self.isDownloading = anyActive
            self.evaluateProgressTimer()
        }
    }

    public func isDaemonRunning() -> Bool {
        let lockPath = baseDirectory.appendingPathComponent("daemon.lock").path
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o666)
        if fd < 0 { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    public func loadSyncStatus() {
        let fileURL = baseDirectory.appendingPathComponent("sync_status.json")
        guard let data = try? Data(contentsOf: fileURL),
              let status = try? JSONDecoder().decode(SyncStatus.self, from: data) else {
            return
        }
        
        DispatchQueue.main.async {
            self.syncStatusPhase = status.status
            self.syncStatusMessage = status.message
            self.currentSyncChannel = status.channelTitle ?? ""
            if let ts = status.timestamp {
                self.lastSyncDate = Date(timeIntervalSince1970: ts)
            }
            if let isSync = status.isSyncing, isSync {
                let running = self.isDaemonRunning()
                self.isSyncing = running
                if !running && status.status != "idle" {
                    self.syncStatusPhase = "idle"
                }
            } else {
                self.isSyncing = false
            }
            self.evaluateProgressTimer()
        }
    }

    public func loadDaemonLogs() {
        let logURL = baseDirectory.appendingPathComponent("daemon.log")
        guard let logData = try? Data(contentsOf: logURL),
              let logText = String(data: logData, encoding: .utf8) else {
            return
        }
        
        let lines = logText.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let recentLines = lines.suffix(40).joined(separator: "\n")
        
        DispatchQueue.main.async {
            if self.daemonLogs != recentLines {
                self.daemonLogs = recentLines
            }
        }
    }

    // MARK: - Manual Subscription Check

    public func syncSubscriptionsAsync() async {
        await withCheckedContinuation { continuation in
            self.syncSubscriptions {
                continuation.resume()
            }
        }
    }

    public func syncSubscriptions(completion: (() -> Void)? = nil) {
        if isSyncing && !isDaemonRunning() {
            self.isSyncing = false
        }
        guard !isSyncing else {
            completion?()
            return
        }
        
        DispatchQueue.main.async {
            self.isSyncing = true
            self.syncStatusPhase = "checking"
            self.syncStatusMessage = "Checking subscriptions..."
            self.downloadLogs += "\n[*] Manual subscription check started...\n"
        }
        
        DispatchQueue.global(qos: .background).async {
            let scriptPath = self.findExecutablePath("podcastthis-daemon") ?? "/var/jb/usr/local/bin/podcastthis-daemon"
            let result = self.executeScript(executable: scriptPath, arguments: ["--manual"])
            
            DispatchQueue.main.async {
                self.isSyncing = false
                if !result.output.isEmpty {
                    self.downloadLogs += result.output + "\n"
                }
                self.loadSyncStatus()
                self.loadData()
                self.loadDaemonLogs()
                self.loadActiveDownloads()
                completion?()
            }
        }
    }

    public func scanForNewEpisodesAsync(for show: PodcastShow) async {
        await withCheckedContinuation { continuation in
            self.scanForNewEpisodes(for: show) {
                continuation.resume()
            }
        }
    }

    public func scanForNewEpisodes(for show: PodcastShow, completion: (() -> Void)? = nil) {
        if isSyncing && !isDaemonRunning() {
            self.isSyncing = false
        }
        guard !isSyncing else {
            completion?()
            return
        }

        DispatchQueue.main.async {
            self.isSyncing = true
            self.syncStatusPhase = "checking"
            self.syncStatusMessage = "Scanning \(show.channelName)..."
            self.currentSyncChannel = show.channelName
            self.downloadLogs += "\n[*] Manual episode check started for '\(show.channelName)'...\n"
        }

        DispatchQueue.global(qos: .background).async {
            var channelUrlToScan = show.channelUrl

            // If channelUrl is not cached on show, try matching subscription or resolving via yt-dlp
            if channelUrlToScan == nil || channelUrlToScan?.isEmpty == true {
                if let sub = self.subscriptions.first(where: { $0.channelTitle == show.channelName }), !sub.channelUrl.isEmpty {
                    channelUrlToScan = sub.channelUrl
                } else if let firstEp = show.episodes.first, let ytDlpPath = self.findExecutablePath("yt-dlp") {
                    let videoUrl = "https://www.youtube.com/watch?v=\(firstEp.videoId)"
                    let args = ["--print", "channel_url", videoUrl]
                    if let resolvedUrl = self.runShellCommand(executable: ytDlpPath, arguments: args), resolvedUrl.starts(with: "http") {
                        let cleanUrl = resolvedUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                        channelUrlToScan = cleanUrl
                        self.updateChannelUrl(for: show, url: cleanUrl)
                    }
                }
            }

            let scriptPath = self.findExecutablePath("podcastthis-daemon") ?? "/var/jb/usr/local/bin/podcastthis-daemon"
            var args: [String] = []
            if let url = channelUrlToScan, !url.isEmpty {
                args = ["--channel", url, "--title", show.channelName]
            } else {
                args = ["--title", show.channelName]
            }

            let result = self.executeScript(executable: scriptPath, arguments: args)

            DispatchQueue.main.async {
                self.isSyncing = false
                if !result.output.isEmpty {
                    self.downloadLogs += result.output + "\n"
                }
                self.loadSyncStatus()
                self.loadData()
                self.loadDaemonLogs()
                self.loadActiveDownloads()
                completion?()
            }
        }
    }

    public func scanForSubscriptionAsync(_ sub: Subscription) async {
        await withCheckedContinuation { continuation in
            self.scanForSubscription(sub) {
                continuation.resume()
            }
        }
    }

    public func scanForSubscription(_ sub: Subscription, completion: (() -> Void)? = nil) {
        if isSyncing && !isDaemonRunning() {
            self.isSyncing = false
        }
        guard !isSyncing else {
            completion?()
            return
        }

        DispatchQueue.main.async {
            self.isSyncing = true
            self.syncStatusPhase = "checking"
            self.syncStatusMessage = "Scanning \(sub.channelTitle)..."
            self.currentSyncChannel = sub.channelTitle
            self.downloadLogs += "\n[*] Manual subscription check started for '\(sub.channelTitle)'...\n"
        }

        DispatchQueue.global(qos: .background).async {
            let scriptPath = self.findExecutablePath("podcastthis-daemon") ?? "/var/jb/usr/local/bin/podcastthis-daemon"
            let args = ["--channel", sub.channelUrl, "--title", sub.channelTitle]
            let result = self.executeScript(executable: scriptPath, arguments: args)

            DispatchQueue.main.async {
                self.isSyncing = false
                if !result.output.isEmpty {
                    self.downloadLogs += result.output + "\n"
                }
                self.loadSyncStatus()
                self.loadData()
                self.loadDaemonLogs()
                self.loadActiveDownloads()
                completion?()
            }
        }
    }


    // MARK: - Artwork helpers

    public func artworkImage(for episode: PodcastEpisode) -> UIImage? {
        let artPath = downloadsDirectory.appendingPathComponent("\(episode.videoId)_art.jpg")
        if let data = try? Data(contentsOf: artPath), let img = UIImage(data: data) { return img }

        let epURL = downloadsDirectory.appendingPathComponent(episode.filename)
        let folder = epURL.deletingLastPathComponent()
        if folder.path != downloadsDirectory.path {
            let subArtPath = folder.appendingPathComponent("\(episode.videoId)_art.jpg")
            if let data = try? Data(contentsOf: subArtPath), let img = UIImage(data: data) { return img }
            for coverName in ["cover.jpg", "folder.jpg", "artwork.jpg", "album.jpg", "cover.png", "folder.png"] {
                let coverURL = folder.appendingPathComponent(coverName)
                if let data = try? Data(contentsOf: coverURL), let img = UIImage(data: data) {
                    return img
                }
            }
        }

        if FileManager.default.fileExists(atPath: epURL.path) {
            let asset = AVURLAsset(url: epURL)
            for item in asset.commonMetadata {
                if item.commonKey?.rawValue == AVMetadataKey.commonKeyArtwork.rawValue,
                   let data = item.dataValue,
                   let img = UIImage(data: data) {
                    return img
                }
            }
        }
        return nil
    }

    private func getChannelId(for show: PodcastShow) -> String? {
        if let sub = subscriptions.first(where: { $0.channelTitle == show.channelName }) {
            return sub.channelId
        }
        for ep in show.episodes {
            let url = ep.channelUrl
            if !url.isEmpty {
                if url.contains("/channel/") {
                    return url.components(separatedBy: "/channel/").last
                } else if url.contains("/@") {
                    return url.components(separatedBy: "/@").last
                }
            }
        }
        return nil
    }

    public func artworkImage(for show: PodcastShow) -> UIImage? {
        if let channelId = getChannelId(for: show) {
            let channelArtPath = downloadsDirectory.appendingPathComponent("channel_\(channelId)_art.jpg")
            if let data = try? Data(contentsOf: channelArtPath), let img = UIImage(data: data) {
                return img
            }
        }
        if let fn = show.artworkFilename,
           let data = try? Data(contentsOf: downloadsDirectory.appendingPathComponent(fn)),
           let img = UIImage(data: data) { return img }
        if let first = show.episodes.first { return artworkImage(for: first) }
        return nil
    }

    public func artworkImage(forSubscription sub: Subscription) -> UIImage? {
        let channelId = sub.channelId.replacingOccurrences(of: "@", with: "")
        let channelArtPath = downloadsDirectory.appendingPathComponent("channel_\(channelId)_art.jpg")
        if let data = try? Data(contentsOf: channelArtPath), let img = UIImage(data: data) {
            return img
        }
        
        let urlClean = sub.channelUrl.components(separatedBy: "/channel/").last ?? sub.channelUrl.components(separatedBy: "/c/").last ?? sub.channelUrl.components(separatedBy: "/user/").last ?? ""
        let cleanUrlId = urlClean.replacingOccurrences(of: "@", with: "")
        let fallbackPath = downloadsDirectory.appendingPathComponent("channel_\(cleanUrlId)_art.jpg")
        if let data = try? Data(contentsOf: fallbackPath), let img = UIImage(data: data) {
            return img
        }
        
        return nil
    }

    // MARK: - Subscription helpers

    public func isSubscribed(to show: PodcastShow) -> Bool {
        subscriptions.contains(where: { $0.channelTitle == show.channelName })
    }

    public func saveSettings(_ settings: AppSettings) {
        self.settings = settings
        let fileURL = stateFileURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self,
                  let stateData = try? Data(contentsOf: fileURL),
                  var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }
            appState.settings = settings
            if let data = try? JSONEncoder().encode(appState) {
                try? data.write(to: fileURL)
                DispatchQueue.main.async {
                    self.evaluateProgressTimer()
                    PodcastPlayer.shared.invalidateSpeakerSkipCache()
                    PodcastPlayer.shared.updateSkipBoundaryObservers()
                }
            }
        }
    }

    private func findExecutablePath(_ name: String) -> String? {
        if name == "python3" {
            // Prioritize standard jailbreak system python /var/jb/usr/bin/python3
            for fullPath in ["/var/jb/usr/bin/python3", "/var/jb/usr/local/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3", "/var/jb/usr/bin/python3.11", "/var/jb/usr/bin/python3.10", "/var/jb/usr/local/bin/python3.12"] {
                if FileManager.default.fileExists(atPath: fullPath) {
                    return fullPath
                }
            }
        }
        let paths = ["/var/jb/usr/local/bin/", "/var/jb/usr/bin/", "/usr/local/bin/", "/usr/bin/"]
        for path in paths {
            let fullPath = path + name
            if FileManager.default.fileExists(atPath: fullPath) {
                return fullPath
            }
        }
        return nil
    }

    @discardableResult
    private func executeScript(
        executable: String,
        arguments: [String]
    ) -> (status: Int32, output: String) {
        #if os(iOS) && !targetEnvironment(simulator)
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "PodcastThisScript") {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        defer {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }

        var spawnExecutable = executable
        var spawnArgs = [executable] + arguments
        
        if let pythonPath = self.findExecutablePath("python3"), !executable.hasSuffix("python3") && !executable.hasSuffix("python3.12") {
            spawnExecutable = pythonPath
            spawnArgs = [pythonPath, executable] + arguments
        }
        
        var pipefd: [Int32] = [0, 0]
        guard pipe(&pipefd) == 0 else {
            return (-1, "[-] Error: Failed to create pipe\n")
        }
        
        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, pipefd[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, pipefd[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, pipefd[0])
        
        // Build robust environment matching SSH shell exactly
        var envDict = ProcessInfo.processInfo.environment
        envDict["PATH"] = "/var/jb/usr/local/bin:/var/jb/usr/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if FileManager.default.fileExists(atPath: "/var/jb/var/mobile") {
            envDict["HOME"] = "/var/jb/var/mobile"
        } else {
            envDict["HOME"] = "/var/mobile"
        }
        envDict["TMPDIR"] = "/tmp"
        envDict["PYTHONUNBUFFERED"] = "1"
        for cert in ["/var/jb/etc/ssl/cert.pem", "/var/jb/etc/ssl/certs/cacert.pem", "/etc/ssl/cert.pem"] {
            if FileManager.default.fileExists(atPath: cert) {
                envDict["SSL_CERT_FILE"] = cert
                break
            }
        }
        
        let envStrings = envDict.map { "\($0.key)=\($0.value)" }
        let cEnv = envStrings.map { strdup($0) } + [nil]
        let cArgs = spawnArgs.map { strdup($0) } + [nil]
        
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            for ptr in cArgs { if let p = ptr { free(p) } }
            for ptr in cEnv { if let p = ptr { free(p) } }
        }
        
        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, spawnExecutable, &fileActions, nil, cArgs, cEnv)
        
        // Close write-end in parent so reading reaches EOF
        close(pipefd[1])
        
        if spawnStatus != 0 {
            close(pipefd[0])
            let errMsg = "[-] Error: posix_spawn failed (\(spawnStatus)) for \(spawnExecutable)\n"
            return (spawnStatus, errMsg)
        }
        
        self.activePid = pid
        
        // Read all output to EOF from the read-end
        let fileHandle = FileHandle(fileDescriptor: pipefd[0], closeOnDealloc: true)
        let capturedData = fileHandle.readDataToEndOfFile()
        let capturedString = String(data: capturedData, encoding: .utf8) ?? ""
        
        var exitStatus: Int32 = 0
        waitpid(pid, &exitStatus, 0)
        self.activePid = nil
        
        return (exitStatus, capturedString)
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/python3")
        process.arguments = [executable] + arguments
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        self.activeProcess = process
        do {
            try process.run()
            process.waitUntilExit()
            self.activeProcess = nil
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        } catch {
            self.activeProcess = nil
            return (-1, "[-] Process error: \(error.localizedDescription)\n")
        }
        #endif
    }

    private func executeProcessDirect(
        executable: String,
        arguments: [String]
    ) -> (status: Int32, output: String) {
        #if os(iOS) && !targetEnvironment(simulator)
        var pipefd: [Int32] = [0, 0]
        guard pipe(&pipefd) == 0 else {
            return (-1, "[-] Error: Failed to create pipe\n")
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, pipefd[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, pipefd[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, pipefd[0])

        var envDict = ProcessInfo.processInfo.environment
        envDict["PATH"] = "/var/jb/usr/local/bin:/var/jb/usr/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if FileManager.default.fileExists(atPath: "/var/jb/var/mobile") {
            envDict["HOME"] = "/var/jb/var/mobile"
        } else {
            envDict["HOME"] = "/var/mobile"
        }

        let envStrings = envDict.map { "\($0.key)=\($0.value)" }
        let cEnv = envStrings.map { strdup($0) } + [nil]
        let cArgs = ([executable] + arguments).map { strdup($0) } + [nil]

        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            for ptr in cArgs { if let p = ptr { free(p) } }
            for ptr in cEnv { if let p = ptr { free(p) } }
        }

        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, executable, &fileActions, nil, cArgs, cEnv)
        close(pipefd[1])

        if spawnStatus != 0 {
            close(pipefd[0])
            return (spawnStatus, "[-] Error: posix_spawn failed (\(spawnStatus)) for \(executable)\n")
        }

        let fileHandle = FileHandle(fileDescriptor: pipefd[0], closeOnDealloc: true)
        let capturedData = fileHandle.readDataToEndOfFile()
        let capturedString = String(data: capturedData, encoding: .utf8) ?? ""

        var exitStatus: Int32 = 0
        waitpid(pid, &exitStatus, 0)
        return (exitStatus, capturedString)
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        } catch {
            return (-1, error.localizedDescription)
        }
        #endif
    }

    private func runShellCommand(executable: String, arguments: [String]) -> String? {
        let isYtDlp = executable.hasSuffix("yt-dlp")
        let maxAttempts = isYtDlp ? 3 : 1
        
        for attempt in 1...maxAttempts {
            let result = executeScript(executable: executable, arguments: arguments)
            let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.status == 0, !trimmed.isEmpty {
                return trimmed
            }
            if attempt < maxAttempts {
                Thread.sleep(forTimeInterval: 1.5)
            }
        }
        return nil
    }

    private func updateChannelUrl(for show: PodcastShow, url: String) {
        guard let stateData = try? Data(contentsOf: stateFileURL),
              var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }
              
        for epId in appState.playbackProgress.keys {
            if appState.playbackProgress[epId]?.channel == show.channelName {
                appState.playbackProgress[epId]?.channelUrl = url
            }
        }
        
        if let data = try? JSONEncoder().encode(appState) {
            try? data.write(to: stateFileURL)
            loadData()
        }
    }

    /// Subscribe to a show's channel. If channel URL is missing, we auto-resolve it using yt-dlp first.
    public func subscribe(to show: PodcastShow, progressCompletion: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) {
        if let url = show.channelUrl, !url.isEmpty {
            self.subscribeDirect(channelTitle: show.channelName, channelUrl: url)
            completion(true)
            return
        }
        
        guard let firstEpisode = show.episodes.first else {
            completion(false)
            return
        }
        
        progressCompletion("Resolving channel URL...")
        
        DispatchQueue.global(qos: .userInitiated).async {
            guard let ytDlpPath = self.findExecutablePath("yt-dlp") else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            let videoUrl = "https://www.youtube.com/watch?v=\(firstEpisode.videoId)"
            let args = ["--print", "channel_url", videoUrl]
            
            if let channelUrl = self.runShellCommand(executable: ytDlpPath, arguments: args),
               channelUrl.starts(with: "http") {
                self.updateChannelUrl(for: show, url: channelUrl)
                DispatchQueue.main.async {
                    self.subscribeDirect(channelTitle: show.channelName, channelUrl: channelUrl)
                    completion(true)
                }
            } else {
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    private func subscribeDirect(channelTitle: String, channelUrl: String) {
        var channelId = ""
        if channelUrl.contains("/channel/") {
            channelId = channelUrl.components(separatedBy: "/channel/").last ?? ""
        } else if channelUrl.contains("/c/") {
            channelId = channelUrl.components(separatedBy: "/c/").last ?? ""
        } else if channelUrl.contains("/user/") {
            channelId = channelUrl.components(separatedBy: "/user/").last ?? ""
        } else if channelUrl.contains("@") {
            channelId = channelUrl.components(separatedBy: "@").last ?? ""
        }
        
        if channelId.isEmpty {
            channelId = channelTitle.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
        }
        
        if let queryIndex = channelId.firstIndex(of: "?") {
            channelId = String(channelId[..<queryIndex])
        }
        channelId = channelId.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        guard let stateData = try? Data(contentsOf: stateFileURL),
              var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }
              
        if appState.subscriptions.contains(where: { $0.channelUrl == channelUrl || $0.channelId == channelId }) {
            return
        }
        
        let formatter = ISO8601DateFormatter()
        let dateString = formatter.string(from: Date())
        let newSub = Subscription(
            channelId: channelId,
            channelTitle: channelTitle,
            channelUrl: channelUrl,
            autoDownload: true,
            dateSubscribed: dateString,
            lastSeenVideoId: nil
        )
        appState.subscriptions.append(newSub)
        
        if let data = try? JSONEncoder().encode(appState) {
            try? data.write(to: stateFileURL)
            loadData()
        }
    }

    /// Remove subscription without touching downloaded episodes
    public func unsubscribe(from show: PodcastShow) {
        guard let stateData = try? Data(contentsOf: stateFileURL),
              var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }
        appState.subscriptions.removeAll {
            $0.channelTitle == show.channelName || ($0.channelUrl == show.channelUrl)
        }
        if let data = try? JSONEncoder().encode(appState) {
            try? data.write(to: stateFileURL)
            loadData()
        }
    }

    public func unsubscribe(channelId: String) {
        guard let stateData = try? Data(contentsOf: stateFileURL),
              var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }
        appState.subscriptions.removeAll { $0.channelId == channelId }
        if let data = try? JSONEncoder().encode(appState) {
            try? data.write(to: stateFileURL)
            loadData()
        }
    }

    // MARK: - Deletion

    /// Delete a single episode: removes all audio files, sidecar art, and state.json entry across root and subfolders
    public func deleteEpisode(_ episode: PodcastEpisode) {
        // Stop player if this is the current episode
        if PodcastPlayer.shared.currentEpisode?.videoId == episode.videoId {
            PodcastPlayer.shared.stop()
        }

        let epURL = downloadsDirectory.appendingPathComponent(episode.filename)
        let epFolder = epURL.deletingLastPathComponent()

        let filesToDelete = [
            epURL,
            downloadsDirectory.appendingPathComponent("\(episode.videoId).m4a"),
            downloadsDirectory.appendingPathComponent("\(episode.videoId)_art.jpg"),
            epFolder.appendingPathComponent("\(episode.videoId)_art.jpg")
        ]
        for url in filesToDelete {
            try? FileManager.default.removeItem(at: url)
        }

        // Clean up any remaining file matching videoId across downloadsDirectory
        if let enumerator = FileManager.default.enumerator(at: downloadsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                let name = fileURL.deletingPathExtension().lastPathComponent
                if name == episode.videoId || name == "\(episode.videoId)_art" {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }

        // Remove from state.json
        guard let stateData = try? Data(contentsOf: stateFileURL),
              var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }
        appState.playbackProgress.removeValue(forKey: episode.videoId)
        if let data = try? JSONEncoder().encode(appState) {
            try? data.write(to: stateFileURL)
        }
        loadData()
    }

    /// Delete all episodes in a show, remove channel directory and artwork, and clean matching subscriptions/state
    public func deleteShow(_ show: PodcastShow) {
        for episode in show.episodes {
            if PodcastPlayer.shared.currentEpisode?.videoId == episode.videoId {
                PodcastPlayer.shared.stop()
            }
            deleteEpisode(episode)
        }

        // Remove channel subfolder if it exists
        let channelFolder = downloadsDirectory.appendingPathComponent(show.channelName)
        if FileManager.default.fileExists(atPath: channelFolder.path) {
            try? FileManager.default.removeItem(at: channelFolder)
        }

        // Remove channel artwork if it exists
        if let channelId = getChannelId(for: show) {
            let channelArtPath = downloadsDirectory.appendingPathComponent("channel_\(channelId)_art.jpg")
            try? FileManager.default.removeItem(at: channelArtPath)
        }

        guard let stateData = try? Data(contentsOf: stateFileURL),
              var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }

        // Remove all progress entries matching episodes or channel name
        let videoIds = Set(show.episodes.map { $0.videoId })
        videoIds.forEach { appState.playbackProgress.removeValue(forKey: $0) }
        let residualKeys = appState.playbackProgress.filter { $0.value.channel == show.channelName }.map { $0.key }
        residualKeys.forEach { appState.playbackProgress.removeValue(forKey: $0) }

        appState.subscriptions.removeAll { $0.channelTitle == show.channelName }

        if let data = try? JSONEncoder().encode(appState) {
            try? data.write(to: stateFileURL)
        }
        loadData()
    }

    // MARK: - Progress update

    public func updateProgress(videoId: String, position: Double, completed: Bool) {
        let isoDate = ISO8601DateFormatter().string(from: Date())

        // 1. Synchronous in-memory update on main thread for UI & state consistency
        if Thread.isMainThread {
            self.applyInMemoryProgress(videoId: videoId, position: position, completed: completed, isoDate: isoDate)
        } else {
            DispatchQueue.main.async {
                self.applyInMemoryProgress(videoId: videoId, position: position, completed: completed, isoDate: isoDate)
            }
        }

        // 2. Offload JSON decoding, encoding, and atomic disk writes to background utility queue
        let targetURL = self.stateFileURL
        let inMemoryEp = (PodcastPlayer.shared.currentEpisode?.videoId == videoId ? PodcastPlayer.shared.currentEpisode : nil) ?? findEpisode(videoId: videoId)

        progressSaveQueue.async {
            guard let stateData = try? Data(contentsOf: targetURL),
                  var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }

            if var progress = appState.playbackProgress[videoId] {
                progress.lastPosition = position
                progress.completed = completed
                progress.lastPlayed = isoDate
                if let ep = inMemoryEp {
                    if let diar = ep.speakerDiarization {
                        progress.speakerDiarization = diar
                    }
                    progress.removeSilence = ep.removeSilence
                    progress.maxSilenceDuration = ep.maxSilenceDuration
                    if let skips = ep.customSkips {
                        progress.customSkips = skips
                    }
                    if let segs = ep.segments {
                        progress.segments = segs
                    }
                }
                appState.playbackProgress[videoId] = progress
            } else if let episode = inMemoryEp {
                appState.playbackProgress[videoId] = PodcastEpisodeProgress(
                    title: episode.title, channel: episode.channel, channelUrl: episode.channelUrl,
                    duration: episode.duration, filename: episode.filename,
                    lastPosition: position, completed: completed,
                    lastPlayed: isoDate, dateAdded: episode.dateAdded,
                    segments: episode.segments,
                    customSkips: episode.customSkips,
                    speakerDiarization: episode.speakerDiarization,
                    uploadDate: episode.uploadDate,
                    removeSilence: episode.removeSilence,
                    maxSilenceDuration: episode.maxSilenceDuration
                )
            }

            do {
                let data = try JSONEncoder().encode(appState)
                try data.write(to: targetURL, options: .atomic)
            } catch {
                print("[-] DataManager: Error saving playback progress: \(error)")
            }
        }
    }

    private func applyInMemoryProgress(videoId: String, position: Double, completed: Bool, isoDate: String) {
        for i in 0..<self.shows.count {
            if let epIdx = self.shows[i].episodes.firstIndex(where: { $0.videoId == videoId }) {
                self.shows[i].episodes[epIdx].lastPosition = position
                self.shows[i].episodes[epIdx].completed = completed
                self.shows[i].episodes[epIdx].lastPlayed = isoDate
                break
            }
        }
        if var current = PodcastPlayer.shared.currentEpisode, current.videoId == videoId {
            current.lastPosition = position
            current.completed = completed
            current.lastPlayed = isoDate
            PodcastPlayer.shared.currentEpisode = current
        }
    }

    public func setAllEpisodesPlayedState(for show: PodcastShow, completed: Bool) {
        guard let stateData = try? Data(contentsOf: stateFileURL),
              var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }

        let isoDate = ISO8601DateFormatter().string(from: Date())

        for episode in show.episodes {
            let position = completed ? episode.duration : 0.0
            if var progress = appState.playbackProgress[episode.videoId] {
                progress.lastPosition = position
                progress.completed = completed
                progress.lastPlayed = completed ? isoDate : nil
                appState.playbackProgress[episode.videoId] = progress
            } else {
                appState.playbackProgress[episode.videoId] = PodcastEpisodeProgress(
                    title: episode.title,
                    channel: episode.channel,
                    channelUrl: episode.channelUrl,
                    duration: episode.duration,
                    filename: episode.filename,
                    lastPosition: position,
                    completed: completed,
                    lastPlayed: completed ? isoDate : nil,
                    dateAdded: episode.dateAdded,
                    segments: episode.segments,
                    customSkips: episode.customSkips,
                    speakerDiarization: episode.speakerDiarization,
                    uploadDate: episode.uploadDate,
                    removeSilence: episode.removeSilence,
                    maxSilenceDuration: episode.maxSilenceDuration
                )
            }
        }

        do {
            let data = try JSONEncoder().encode(appState)
            try data.write(to: stateFileURL)
            loadData()
        } catch {
            print("[-] DataManager: Error setting played state: \(error)")
        }
    }

    public func findEpisode(videoId: String) -> PodcastEpisode? {
        for show in shows {
            if let ep = show.episodes.first(where: { $0.videoId == videoId }) { return ep }
        }
        return nil
    }

    public func extractCollaborations(from json: Any) -> [EpisodeMetadata] {
        var results: [EpisodeMetadata] = []
        var seenIds = Set<String>()
        
        func traverse(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                if let titleDict = dict["title"] as? [String: Any],
                   titleDict["simpleText"] as? String == "Collaborations" {
                    if let content = dict["content"] as? [String: Any],
                       let hList = content["horizontalListRenderer"] as? [String: Any],
                       let items = hList["items"] as? [[String: Any]] {
                        for item in items {
                            if let lockup = item["lockupViewModel"] as? [String: Any],
                               let vidId = lockup["contentId"] as? String,
                               !seenIds.contains(vidId) {
                                seenIds.insert(vidId)
                                var title = ""
                                if let meta = lockup["metadata"] as? [String: Any],
                                   let lockupMeta = meta["lockupMetadataViewModel"] as? [String: Any],
                                   let titleObj = lockupMeta["title"] as? [String: Any],
                                   let contentStr = titleObj["content"] as? String {
                                    title = contentStr
                                }
                                var duration: String? = nil
                                if let img = lockup["contentImage"] as? [String: Any],
                                   let overlays = img["overlays"] as? [[String: Any]] {
                                    for ov in overlays {
                                        if let b = ov["thumbnailBottomOverlayViewModel"] as? [String: Any],
                                           let badges = b["badges"] as? [[String: Any]] {
                                            for badge in badges {
                                                if let vm = badge["thumbnailBadgeViewModel"] as? [String: Any],
                                                   let t = vm["text"] as? String {
                                                    duration = t
                                                }
                                            }
                                        }
                                    }
                                }
                                results.append(EpisodeMetadata(
                                    id: vidId,
                                    title: title.isEmpty ? "Collaborative Video" : title,
                                    durationString: duration,
                                    url: "https://www.youtube.com/watch?v=\(vidId)"
                                ))
                            }
                        }
                    }
                }
                for (_, v) in dict {
                    traverse(v)
                }
            } else if let arr = obj as? [Any] {
                for v in arr {
                    traverse(v)
                }
            }
        }
        traverse(json)
        return results
    }

    // MARK: - Download

    public func fetchPlaylistMetadata(url: String, startIndex: Int = 1, limit: Int = 15, completion: @escaping ([EpisodeMetadata]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let ytDlpPath = self.findExecutablePath("yt-dlp") else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            
            var targetUrl = url
            var baseChannelUrl = url
            if url.contains("youtube.com/") || url.contains("youtu.be/") {
                if (url.contains("/@") || url.contains("/channel/") || url.contains("/c/") || url.contains("/user/")) {
                    var cleanedUrl = url
                    if cleanedUrl.hasSuffix("/") {
                        cleanedUrl.removeLast()
                    }
                    if cleanedUrl.hasSuffix("/videos") || cleanedUrl.hasSuffix("/shorts") || cleanedUrl.hasSuffix("/streams") {
                        if let lastSlash = cleanedUrl.lastIndex(of: "/") {
                            baseChannelUrl = String(cleanedUrl[..<lastSlash])
                        }
                    } else {
                        baseChannelUrl = cleanedUrl
                    }
                    if !cleanedUrl.contains("watch?") {
                        targetUrl = baseChannelUrl + "/videos"
                    }
                }
            }
            
            var collabEpisodes: [EpisodeMetadata] = []
            if startIndex == 1, let channelHomeUrl = URL(string: baseChannelUrl), (baseChannelUrl.contains("/@") || baseChannelUrl.contains("/channel/") || baseChannelUrl.contains("/c/") || baseChannelUrl.contains("/user/")) {
                var request = URLRequest(url: channelHomeUrl)
                request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
                let semaphore = DispatchSemaphore(value: 0)
                URLSession.shared.dataTask(with: request) { data, _, _ in
                    defer { semaphore.signal() }
                    guard let data = data, let html = String(data: data, encoding: .utf8) else { return }
                    if let startRange = html.range(of: "var ytInitialData = ") {
                        let afterStart = html[startRange.upperBound...]
                        if let endRange = afterStart.range(of: "};</script>") {
                            let jsonStr = String(afterStart[...endRange.lowerBound])
                            if let jsonData = jsonStr.data(using: .utf8),
                               let root = try? JSONSerialization.jsonObject(with: jsonData) {
                                collabEpisodes = self.extractCollaborations(from: root)
                            }
                        }
                    }
                }.resume()
                _ = semaphore.wait(timeout: .now() + 4.0)
            }
            
            let startStr = String(startIndex)
            let endStr = String(startIndex + limit - 1)
            let args = ["--flat-playlist", "--dump-json", "--playlist-start", startStr, "--playlist-end", endStr, targetUrl]
            
            guard let output = self.runShellCommand(executable: ytDlpPath, arguments: args) else {
                DispatchQueue.main.async { completion(collabEpisodes) }
                return
            }
            
            var episodes: [EpisodeMetadata] = []
            let lines = output.components(separatedBy: "\n")
            let decoder = JSONDecoder()
            for line in lines {
                guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if let data = line.data(using: .utf8),
                   let ep = try? decoder.decode(EpisodeMetadata.self, from: data) {
                    episodes.append(ep)
                }
            }
            
            if !collabEpisodes.isEmpty {
                let existingIds = Set(episodes.map { $0.id })
                let uniqueCollabs = collabEpisodes.filter { !existingIds.contains($0.id) }
                episodes = uniqueCollabs + episodes
            }
            
            DispatchQueue.main.async {
                completion(episodes)
            }
        }
    }

    private var lastProcessedShareUrl: String = ""
    private var lastProcessedShareTime: Date = .distantPast

    public func handleIncomingSharedUrl(_ rawUrl: String) {
        let trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Deduplicate requests for the same URL within 4 seconds
        if trimmed == lastProcessedShareUrl && Date().timeIntervalSince(lastProcessedShareTime) < 4.0 {
            return
        }
        lastProcessedShareUrl = trimmed
        lastProcessedShareTime = Date()

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("podcastthis_open_url"),
                object: nil,
                userInfo: ["url": trimmed]
            )
            self.addDownload(url: trimmed, isSubscribe: false)
        }
    }

    public func checkPendingShares() {
        let pendingFileURL = baseDirectory.appendingPathComponent("pending_shares.json")
        guard FileManager.default.fileExists(atPath: pendingFileURL.path),
              let data = try? Data(contentsOf: pendingFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = json["url"] as? String,
              !url.isEmpty else {
            return
        }
        
        let timestamp = json["timestamp"] as? TimeInterval ?? 0
        // Ignore stale shares older than 10 minutes
        if timestamp > 0 && (Date().timeIntervalSince1970 - timestamp) > 600 {
            try? FileManager.default.removeItem(at: pendingFileURL)
            return
        }
        
        // Remove file immediately to avoid double processing
        try? FileManager.default.removeItem(at: pendingFileURL)
        
        handleIncomingSharedUrl(url)
    }

    public func addDownload(url: String, isSubscribe: Bool = false, channel: String? = nil, channelUrl: String? = nil, completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            self.isDownloading = true
            self.activeDownloads.insert(url)
            self.downloadLogs += "\n[+] Queued: \(url)\n"
            
            // Immediate placeholder for instant UI feedback
            if self.activeDownloadsList.isEmpty {
                let placeholder = ActiveDownload(
                    videoId: url,
                    title: "Starting download…",
                    channel: channel ?? "Connecting to stream",
                    status: "Preparing",
                    progress: 0.0,
                    speed: "...",
                    eta: "--:--"
                )
                self.activeDownloadsList = [placeholder]
            }
        }

        DispatchQueue.global(qos: .background).async {
            let scriptPath = self.findExecutablePath("podcastthis-add") ?? "/var/jb/usr/local/bin/podcastthis-add"
            var arguments = [url]
            if isSubscribe { arguments.append("--subscribe") }
            if let ch = channel, !ch.isEmpty {
                arguments.append("--channel")
                arguments.append(ch)
            }
            if let chUrl = channelUrl, !chUrl.isEmpty {
                arguments.append("--channel-url")
                arguments.append(chUrl)
            }

            let result = self.executeScript(executable: scriptPath, arguments: arguments)

            DispatchQueue.main.async {
                if !result.output.isEmpty {
                    self.downloadLogs += result.output + "\n"
                }
                self.downloadLogs += "[+] Completed with exit code \(result.status)\n"
                self.activeDownloads.remove(url)
                self.loadActiveDownloads()
                self.loadData()
                completion?()
            }
        }
    }

    private func processNextQueueItem() {
        DispatchQueue.main.async {
            guard !self.downloadQueue.isEmpty else {
                self.currentQueueUrl = nil
                return
            }
            let nextUrl = self.downloadQueue.removeFirst()
            self.currentQueueUrl = nextUrl
            
            // Check if already downloaded
            let isAlreadyDownloaded = self.shows.contains { show in
                show.episodes.contains { $0.channelUrl == nextUrl || "https://www.youtube.com/watch?v=\($0.videoId)" == nextUrl }
            }
            if isAlreadyDownloaded {
                self.processNextQueueItem()
                return
            }
            
            self.addDownload(url: nextUrl) {
                self.processNextQueueItem()
            }
        }
    }

    public func startBulkDownload(channelUrl: String) {
        DispatchQueue.main.async {
            self.isBulkQueueLoading = true
            self.downloadLogs += "\n[+] Loading all episodes for bulk download...\n"
        }
        
        fetchPlaylistMetadata(url: channelUrl, startIndex: 1, limit: 1000) { fetchedEpisodes in
            DispatchQueue.main.async {
                self.isBulkQueueLoading = false
                guard !fetchedEpisodes.isEmpty else {
                    self.downloadLogs += "[-] Failed to fetch episode list for bulk download.\n"
                    return
                }
                
                let downloadedIds = Set(self.shows.flatMap { $0.episodes.map { $0.videoId } })
                
                var queuedCount = 0
                for ep in fetchedEpisodes {
                    let videoId: String
                    if let range = ep.url.range(of: "v=") {
                        videoId = String(ep.url[range.upperBound...]).components(separatedBy: "&").first ?? ""
                    } else {
                        videoId = ep.url.components(separatedBy: "/").last ?? ""
                    }
                    
                    if !downloadedIds.contains(videoId) && !self.downloadQueue.contains(ep.url) && self.currentQueueUrl != ep.url {
                        self.downloadQueue.append(ep.url)
                        queuedCount += 1
                    }
                }
                
                self.downloadLogs += "[+] Added \(queuedCount) new episodes to download queue.\n"
                
                if !self.isDownloading {
                    self.processNextQueueItem()
                }
            }
        }
    }

    public func cancelAllDownloads() {
        DispatchQueue.main.async {
            self.downloadQueue.removeAll()
            self.activeDownloads.removeAll()
            self.isDownloading = false
            self.isBulkQueueLoading = false
            self.currentQueueUrl = nil
            
            #if os(iOS) && !targetEnvironment(simulator)
            if let pid = self.activePid {
                kill(pid, SIGKILL)
                self.activePid = nil
            }
            #else
            if let process = self.activeProcess {
                process.terminate()
                self.activeProcess = nil
            }
            #endif
            
            // Clear active_downloads.json
            let fileURL = self.baseDirectory.appendingPathComponent("active_downloads.json")
            let emptyState = ["active_downloads": [String: ActiveDownload]()]
            if let emptyData = try? JSONEncoder().encode(emptyState) {
                try? emptyData.write(to: fileURL)
            }
            self.activeDownloadsList = []
            
            self.downloadLogs += "\n[!] Downloads cancelled by user.\n"
            self.loadData()
        }
    }

    // MARK: - Merging & Moving Shows / Episodes

    /// Moves a single episode to a target channel name.
    public func moveEpisode(_ episode: PodcastEpisode, toChannel targetChannelName: String) {
        guard let stateData = try? Data(contentsOf: stateFileURL),
              var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }

        let trimmedTarget = targetChannelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTarget.isEmpty, trimmedTarget != episode.channel else { return }

        let targetFolderURL = downloadsDirectory.appendingPathComponent(trimmedTarget)
        try? FileManager.default.createDirectory(at: targetFolderURL, withIntermediateDirectories: true, attributes: nil)

        var progress = appState.playbackProgress[episode.videoId] ?? PodcastEpisodeProgress(
            title: episode.title,
            channel: episode.channel,
            channelUrl: episode.channelUrl,
            duration: episode.duration,
            filename: episode.filename,
            lastPosition: episode.lastPosition,
            completed: episode.completed,
            lastPlayed: episode.lastPlayed,
            dateAdded: episode.dateAdded,
            segments: episode.segments,
            customSkips: episode.customSkips,
            speakerDiarization: episode.speakerDiarization,
            uploadDate: episode.uploadDate,
            removeSilence: episode.removeSilence,
            maxSilenceDuration: episode.maxSilenceDuration
        )

        progress.channel = trimmedTarget

        let currentFileURL = downloadsDirectory.appendingPathComponent(episode.filename)
        let lastComp = currentFileURL.lastPathComponent
        let newTargetFileURL = targetFolderURL.appendingPathComponent(lastComp)

        if FileManager.default.fileExists(atPath: currentFileURL.path) && currentFileURL.path != newTargetFileURL.path {
            try? FileManager.default.moveItem(at: currentFileURL, to: newTargetFileURL)
        }
        let relativePath = trimmedTarget + "/" + lastComp
        progress.filename = relativePath

        let rootArtURL = downloadsDirectory.appendingPathComponent("\(episode.videoId)_art.jpg")
        let oldFolderArtURL = currentFileURL.deletingLastPathComponent().appendingPathComponent("\(episode.videoId)_art.jpg")
        let newArtURL = targetFolderURL.appendingPathComponent("\(episode.videoId)_art.jpg")

        if FileManager.default.fileExists(atPath: rootArtURL.path) {
            try? FileManager.default.copyItem(at: rootArtURL, to: newArtURL)
        }
        if FileManager.default.fileExists(atPath: oldFolderArtURL.path) && oldFolderArtURL.path != newArtURL.path {
            if !FileManager.default.fileExists(atPath: newArtURL.path) {
                try? FileManager.default.moveItem(at: oldFolderArtURL, to: newArtURL)
            }
        }

        appState.playbackProgress[episode.videoId] = progress

        if let data = try? JSONEncoder().encode(appState) {
            try? data.write(to: stateFileURL)
        }
        loadData()
    }

    /// Merges all episodes from `sourceShow` into `targetChannelName`.
    public func mergeShow(_ sourceShow: PodcastShow, into targetChannelName: String) {
        guard let stateData = try? Data(contentsOf: stateFileURL),
              var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }

        let trimmedTarget = targetChannelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTarget.isEmpty, trimmedTarget != sourceShow.channelName else { return }

        let targetFolderURL = downloadsDirectory.appendingPathComponent(trimmedTarget)
        try? FileManager.default.createDirectory(at: targetFolderURL, withIntermediateDirectories: true, attributes: nil)

        for episode in sourceShow.episodes {
            var progress = appState.playbackProgress[episode.videoId] ?? PodcastEpisodeProgress(
                title: episode.title,
                channel: episode.channel,
                channelUrl: episode.channelUrl,
                duration: episode.duration,
                filename: episode.filename,
                lastPosition: episode.lastPosition,
                completed: episode.completed,
                lastPlayed: episode.lastPlayed,
                dateAdded: episode.dateAdded,
                segments: episode.segments,
                customSkips: episode.customSkips,
                speakerDiarization: episode.speakerDiarization,
                uploadDate: episode.uploadDate,
                removeSilence: episode.removeSilence,
                maxSilenceDuration: episode.maxSilenceDuration
            )

            progress.channel = trimmedTarget

            let currentFileURL = downloadsDirectory.appendingPathComponent(episode.filename)
            let lastComp = currentFileURL.lastPathComponent
            let newTargetFileURL = targetFolderURL.appendingPathComponent(lastComp)

            if FileManager.default.fileExists(atPath: currentFileURL.path) && currentFileURL.path != newTargetFileURL.path {
                try? FileManager.default.moveItem(at: currentFileURL, to: newTargetFileURL)
            }
            let relativePath = trimmedTarget + "/" + lastComp
            progress.filename = relativePath

            let rootArtURL = downloadsDirectory.appendingPathComponent("\(episode.videoId)_art.jpg")
            let oldFolderArtURL = currentFileURL.deletingLastPathComponent().appendingPathComponent("\(episode.videoId)_art.jpg")
            let newArtURL = targetFolderURL.appendingPathComponent("\(episode.videoId)_art.jpg")

            if FileManager.default.fileExists(atPath: rootArtURL.path) {
                try? FileManager.default.copyItem(at: rootArtURL, to: newArtURL)
            }
            if FileManager.default.fileExists(atPath: oldFolderArtURL.path) && oldFolderArtURL.path != newArtURL.path {
                if !FileManager.default.fileExists(atPath: newArtURL.path) {
                    try? FileManager.default.moveItem(at: oldFolderArtURL, to: newArtURL)
                }
            }

            appState.playbackProgress[episode.videoId] = progress
        }

        if let data = try? JSONEncoder().encode(appState) {
            try? data.write(to: stateFileURL)
        }
        loadData()
    }

    // MARK: - Custom User Skip Segments Management

    public func addCustomSkip(videoId: String, start: Double, end: Double, label: String = "Custom Skip") {
        guard let stateData = try? Data(contentsOf: stateFileURL),
              var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }

        let cleanStart = max(0, min(start, end))
        let cleanEnd = max(start, end)
        // Enforce minimum 0.2s duration — degenerate skips cause immediate re-trigger loops.
        guard cleanEnd - cleanStart >= 0.2 else { return }

        let newSkip = UserCustomSkip(start: cleanStart, end: cleanEnd, label: label.isEmpty ? "Custom Skip" : label, isEnabled: true)

        if var progress = appState.playbackProgress[videoId] {
            var skips = progress.customSkips ?? []
            skips.append(newSkip)
            skips.sort(by: { $0.start < $1.start })
            progress.customSkips = skips
            appState.playbackProgress[videoId] = progress
        } else if let episode = findEpisode(videoId: videoId) {
            var skips = episode.customSkips ?? []
            skips.append(newSkip)
            skips.sort(by: { $0.start < $1.start })
            appState.playbackProgress[videoId] = PodcastEpisodeProgress(
                title: episode.title,
                channel: episode.channel,
                channelUrl: episode.channelUrl,
                duration: episode.duration,
                filename: episode.filename,
                lastPosition: episode.lastPosition,
                completed: episode.completed,
                lastPlayed: episode.lastPlayed,
                dateAdded: episode.dateAdded,
                segments: episode.segments,
                customSkips: skips,
                speakerDiarization: episode.speakerDiarization,
                uploadDate: episode.uploadDate,
                removeSilence: episode.removeSilence,
                maxSilenceDuration: episode.maxSilenceDuration
            )
        }

        do {
            let data = try JSONEncoder().encode(appState)
            try data.write(to: stateFileURL)
            loadData()
            DispatchQueue.main.async {
                if var ep = PodcastPlayer.shared.currentEpisode, ep.videoId == videoId {
                    ep.customSkips = appState.playbackProgress[videoId]?.customSkips
                    PodcastPlayer.shared.currentEpisode = ep
                    PodcastPlayer.shared.updateSkipBoundaryObservers()
                }
            }
        } catch {
            print("[-] DataManager: Error adding custom skip: \(error)")
        }
    }

    public func updateCustomSkip(videoId: String, skip: UserCustomSkip) {
        guard let stateData = try? Data(contentsOf: stateFileURL),
              var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }

        if var progress = appState.playbackProgress[videoId], var skips = progress.customSkips {
            if let idx = skips.firstIndex(where: { $0.id == skip.id }) {
                skips[idx] = skip
                skips.sort(by: { $0.start < $1.start })
                progress.customSkips = skips
                appState.playbackProgress[videoId] = progress
            }
        }

        do {
            let data = try JSONEncoder().encode(appState)
            try data.write(to: stateFileURL)
            loadData()
            DispatchQueue.main.async {
                if var ep = PodcastPlayer.shared.currentEpisode, ep.videoId == videoId {
                    ep.customSkips = appState.playbackProgress[videoId]?.customSkips
                    PodcastPlayer.shared.currentEpisode = ep
                    PodcastPlayer.shared.updateSkipBoundaryObservers()
                }
            }
        } catch {
            print("[-] DataManager: Error updating custom skip: \(error)")
        }
    }

    public func deleteCustomSkip(videoId: String, skipId: String) {
        guard let stateData = try? Data(contentsOf: stateFileURL),
              var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }

        if var progress = appState.playbackProgress[videoId], var skips = progress.customSkips {
            skips.removeAll(where: { $0.id == skipId })
            progress.customSkips = skips
            appState.playbackProgress[videoId] = progress
        }

        do {
            let data = try JSONEncoder().encode(appState)
            try data.write(to: stateFileURL)
            loadData()
            DispatchQueue.main.async {
                if var ep = PodcastPlayer.shared.currentEpisode, ep.videoId == videoId {
                    ep.customSkips = appState.playbackProgress[videoId]?.customSkips
                    PodcastPlayer.shared.currentEpisode = ep
                    PodcastPlayer.shared.updateSkipBoundaryObservers()
                }
            }
        } catch {
            print("[-] DataManager: Error deleting custom skip: \(error)")
        }
    }

    public func toggleCustomSkip(videoId: String, skipId: String) {
        guard let stateData = try? Data(contentsOf: stateFileURL),
              var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }

        if var progress = appState.playbackProgress[videoId], var skips = progress.customSkips {
            if let idx = skips.firstIndex(where: { $0.id == skipId }) {
                skips[idx].isEnabled.toggle()
                progress.customSkips = skips
                appState.playbackProgress[videoId] = progress
            }
        }

        do {
            let data = try JSONEncoder().encode(appState)
            try data.write(to: stateFileURL)
            loadData()
            DispatchQueue.main.async {
                if var ep = PodcastPlayer.shared.currentEpisode, ep.videoId == videoId {
                    ep.customSkips = appState.playbackProgress[videoId]?.customSkips
                    PodcastPlayer.shared.currentEpisode = ep
                    PodcastPlayer.shared.updateSkipBoundaryObservers()
                }
            }
        } catch {
            print("[-] DataManager: Error toggling custom skip: \(error)")
        }
    }

    // MARK: - Speaker Diarization Management

    public func saveSpeakerDiarization(videoId: String, data diarizationData: SpeakerDiarizationData) {
        if var ep = PodcastPlayer.shared.currentEpisode, ep.videoId == videoId {
            ep.speakerDiarization = diarizationData
            PodcastPlayer.shared.currentEpisode = ep
            PodcastPlayer.shared.updateSkipBoundaryObservers()
        }

        for showIndex in shows.indices {
            if let epIndex = shows[showIndex].episodes.firstIndex(where: { $0.videoId == videoId }) {
                shows[showIndex].episodes[epIndex].speakerDiarization = diarizationData
            }
        }

        guard let stateData = try? Data(contentsOf: stateFileURL),
              var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }

        if var progress = appState.playbackProgress[videoId] {
            progress.speakerDiarization = diarizationData
            appState.playbackProgress[videoId] = progress
        } else if let episode = findEpisode(videoId: videoId) {
            let progress = PodcastEpisodeProgress(
                title: episode.title,
                channel: episode.channel,
                channelUrl: episode.channelUrl,
                duration: episode.duration,
                filename: episode.filename,
                lastPosition: episode.lastPosition,
                completed: episode.completed,
                lastPlayed: episode.lastPlayed,
                dateAdded: episode.dateAdded,
                segments: episode.segments,
                customSkips: episode.customSkips,
                speakerDiarization: diarizationData,
                uploadDate: episode.uploadDate,
                removeSilence: episode.removeSilence,
                maxSilenceDuration: episode.maxSilenceDuration
            )
            appState.playbackProgress[videoId] = progress
        }

        do {
            let data = try JSONEncoder().encode(appState)
            try data.write(to: stateFileURL)
            loadData()
            DispatchQueue.main.async {
                if var ep = PodcastPlayer.shared.currentEpisode, ep.videoId == videoId {
                    ep.speakerDiarization = diarizationData
                    PodcastPlayer.shared.currentEpisode = ep
                    PodcastPlayer.shared.updateSkipBoundaryObservers()
                }
            }
        } catch {
            print("[-] DataManager: Error saving speaker diarization: \(error)")
        }
    }

    // MARK: - SponsorBlock Rescan

    public func rescanSponsorBlockSegments(videoId: String, completion: @escaping (Result<Int, Error>) -> Void) {
        let categories = ["sponsor", "selfpromo", "interaction", "intro", "outro", "preview", "filler"]
        guard let categoriesJsonData = try? JSONSerialization.data(withJSONObject: categories),
              let categoriesJsonString = String(data: categoriesJsonData, encoding: .utf8),
              var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments") else {
            completion(.failure(NSError(domain: "PodcastThis", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid SponsorBlock URL request"])))
            return
        }

        components.queryItems = [
            URLQueryItem(name: "videoID", value: videoId),
            URLQueryItem(name: "categories", value: categoriesJsonString)
        ]

        guard let url = components.url else {
            completion(.failure(NSError(domain: "PodcastThis", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to construct URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8.0

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }

            guard let httpResp = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "PodcastThis", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])))
                }
                return
            }

            var parsedSegments: [PodcastEpisodeSegment] = []

            if httpResp.statusCode == 200, let data = data {
                if let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    for item in rawArray {
                        if let cat = item["category"] as? String,
                           let segRange = item["segment"] as? [Double], segRange.count >= 2 {
                            let start = segRange[0]
                            let end = segRange[1]
                            if end > start {
                                parsedSegments.append(PodcastEpisodeSegment(category: cat, start: start, end: end))
                            }
                        }
                    }
                }
            } else if httpResp.statusCode == 404 {
                // SponsorBlock returns 404 if no segments have been submitted, which is normal
                parsedSegments = []
            } else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "PodcastThis", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: "SponsorBlock server returned status \(httpResp.statusCode)"])))
                }
                return
            }

            // Save updated segments to state
            self.saveSponsorBlockSegments(videoId: videoId, segments: parsedSegments)

            DispatchQueue.main.async {
                completion(.success(parsedSegments.count))
            }
        }
        task.resume()
    }

    public func saveSponsorBlockSegments(videoId: String, segments: [PodcastEpisodeSegment]) {
        // 1. Synchronously update in-memory shows and player on the main thread for instant UI response
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            for showIndex in self.shows.indices {
                if let epIndex = self.shows[showIndex].episodes.firstIndex(where: { $0.videoId == videoId }) {
                    self.shows[showIndex].episodes[epIndex].segments = segments
                }
            }
            self.shows = self.shows

            if var ep = PodcastPlayer.shared.currentEpisode, ep.videoId == videoId {
                ep.segments = segments
                PodcastPlayer.shared.currentEpisode = ep
                PodcastPlayer.shared.updateSkipBoundaryObservers()
                PodcastPlayer.shared.evaluateSkipsNow()
            }
        }

        // 2. Offload disk save to progressSaveQueue to avoid thread contention
        let targetURL = self.stateFileURL
        let inMemoryEp = (PodcastPlayer.shared.currentEpisode?.videoId == videoId ? PodcastPlayer.shared.currentEpisode : nil) ?? findEpisode(videoId: videoId)

        progressSaveQueue.async {
            guard let stateData = try? Data(contentsOf: targetURL),
                  var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }

            if var progress = appState.playbackProgress[videoId] {
                progress.segments = segments
                appState.playbackProgress[videoId] = progress
            } else if let episode = inMemoryEp {
                let progress = PodcastEpisodeProgress(
                    title: episode.title,
                    channel: episode.channel,
                    channelUrl: episode.channelUrl,
                    duration: episode.duration,
                    filename: episode.filename,
                    lastPosition: episode.lastPosition,
                    completed: episode.completed,
                    lastPlayed: episode.lastPlayed,
                    dateAdded: episode.dateAdded,
                    segments: segments,
                    customSkips: episode.customSkips,
                    speakerDiarization: episode.speakerDiarization,
                    uploadDate: episode.uploadDate,
                    removeSilence: episode.removeSilence,
                    maxSilenceDuration: episode.maxSilenceDuration
                )
                appState.playbackProgress[videoId] = progress
            }

            do {
                let data = try JSONEncoder().encode(appState)
                try data.write(to: targetURL, options: .atomic)
            } catch {
                print("[-] DataManager: Error saving SponsorBlock segments: \(error)")
            }
        }
    }

    public func toggleSpeakerSkip(videoId: String, speakerId: String, explicitState: Bool? = nil) {
        var targetState: Bool = true

        // 1. Immediately update in-memory player state synchronously so lookups and seeks have zero delay
        if var ep = PodcastPlayer.shared.currentEpisode, ep.videoId == videoId, var diarization = ep.speakerDiarization {
            if let idx = diarization.speakers.firstIndex(where: { $0.id == speakerId }) {
                let nextVal = explicitState ?? !diarization.speakers[idx].isSkipped
                targetState = nextVal
                diarization.speakers[idx].isSkipped = nextVal
                ep.speakerDiarization = diarization
                PodcastPlayer.shared.currentEpisode = ep
                DispatchQueue.main.async {
                    PodcastPlayer.shared.updateSkipBoundaryObservers()
                    PodcastPlayer.shared.evaluateAutoSkipsImmediately()
                }
            }
        } else if let ep = findEpisode(videoId: videoId), let diarization = ep.speakerDiarization,
                  let spk = diarization.speakers.first(where: { $0.id == speakerId }) {
            targetState = explicitState ?? !spk.isSkipped
        }

        // 2. Immediately update in-memory shows state synchronously
        for showIndex in shows.indices {
            if let epIndex = shows[showIndex].episodes.firstIndex(where: { $0.videoId == videoId }),
               let diarization = shows[showIndex].episodes[epIndex].speakerDiarization,
               let spkIndex = diarization.speakers.firstIndex(where: { $0.id == speakerId }) {
                var updated = diarization
                updated.speakers[spkIndex].isSkipped = targetState
                shows[showIndex].episodes[epIndex].speakerDiarization = updated
            }
        }

        // 3. Persist to disk asynchronously on utility queue
        let targetStateToPersist = targetState
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self,
                  let stateData = try? Data(contentsOf: self.stateFileURL),
                  var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }

            if var progress = appState.playbackProgress[videoId],
               var diarization = progress.speakerDiarization,
               let idx = diarization.speakers.firstIndex(where: { $0.id == speakerId }) {
                diarization.speakers[idx].isSkipped = targetStateToPersist
                progress.speakerDiarization = diarization
                appState.playbackProgress[videoId] = progress

                do {
                    let data = try JSONEncoder().encode(appState)
                    try data.write(to: self.stateFileURL)
                } catch {
                    print("[-] DataManager: Error saving toggled speaker skip: \(error)")
                }
            }
        }
    }

    public func toggleSpeakerNonEnglish(videoId: String, speakerId: String, explicitState: Bool? = nil) {
        var targetState: Bool = true

        // 1. Immediately update in-memory player state synchronously
        if var ep = PodcastPlayer.shared.currentEpisode, ep.videoId == videoId, var diarization = ep.speakerDiarization {
            if let idx = diarization.speakers.firstIndex(where: { $0.id == speakerId }) {
                let nextVal = explicitState ?? !diarization.speakers[idx].isNonEnglish
                targetState = nextVal
                diarization.speakers[idx].isNonEnglish = nextVal
                ep.speakerDiarization = diarization
                PodcastPlayer.shared.currentEpisode = ep
                DispatchQueue.main.async {
                    PodcastPlayer.shared.updateSkipBoundaryObservers()
                    PodcastPlayer.shared.evaluateAutoSkipsImmediately()
                }
            }
        } else if let ep = findEpisode(videoId: videoId), let diarization = ep.speakerDiarization,
                  let spk = diarization.speakers.first(where: { $0.id == speakerId }) {
            targetState = explicitState ?? !spk.isNonEnglish
        }

        // 2. Immediately update in-memory shows state synchronously
        for showIndex in shows.indices {
            if let epIndex = shows[showIndex].episodes.firstIndex(where: { $0.videoId == videoId }),
               let diarization = shows[showIndex].episodes[epIndex].speakerDiarization,
               let spkIndex = diarization.speakers.firstIndex(where: { $0.id == speakerId }) {
                var updated = diarization
                updated.speakers[spkIndex].isNonEnglish = targetState
                shows[showIndex].episodes[epIndex].speakerDiarization = updated
            }
        }

        // 3. Persist to disk asynchronously on utility queue
        let targetNonEnglishToPersist = targetState
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self,
                  let stateData = try? Data(contentsOf: self.stateFileURL),
                  var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }

            if var progress = appState.playbackProgress[videoId],
               var diarization = progress.speakerDiarization,
               let idx = diarization.speakers.firstIndex(where: { $0.id == speakerId }) {
                diarization.speakers[idx].isNonEnglish = targetNonEnglishToPersist
                progress.speakerDiarization = diarization
                appState.playbackProgress[videoId] = progress

                do {
                    let data = try JSONEncoder().encode(appState)
                    try data.write(to: self.stateFileURL)
                } catch {
                    print("[-] DataManager: Error saving toggled speaker non-English flag: \(error)")
                }
            }
        }
    }

    public func toggleFilterEnglishOnly(videoId: String, explicitState: Bool? = nil) {
        var targetState: Bool = true

        // 1. Update in-memory player state synchronously
        if var ep = PodcastPlayer.shared.currentEpisode, ep.videoId == videoId, var diarization = ep.speakerDiarization {
            let nextVal = explicitState ?? !(diarization.filterEnglishOnly ?? false)
            targetState = nextVal
            diarization.filterEnglishOnly = nextVal
            ep.speakerDiarization = diarization
            PodcastPlayer.shared.currentEpisode = ep
            DispatchQueue.main.async {
                PodcastPlayer.shared.updateSkipBoundaryObservers()
                PodcastPlayer.shared.evaluateAutoSkipsImmediately()
            }
        } else if let ep = findEpisode(videoId: videoId), let diarization = ep.speakerDiarization {
            targetState = explicitState ?? !(diarization.filterEnglishOnly ?? false)
        }

        // 2. Update in-memory shows state synchronously
        for showIndex in shows.indices {
            if let epIndex = shows[showIndex].episodes.firstIndex(where: { $0.videoId == videoId }),
               let diarization = shows[showIndex].episodes[epIndex].speakerDiarization {
                var updated = diarization
                updated.filterEnglishOnly = targetState
                shows[showIndex].episodes[epIndex].speakerDiarization = updated
            }
        }

        // 3. Persist to disk asynchronously on utility queue
        let targetFilterEnglishOnlyToPersist = targetState
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self,
                  let stateData = try? Data(contentsOf: self.stateFileURL),
                  var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }

            if var progress = appState.playbackProgress[videoId],
               var diarization = progress.speakerDiarization {
                diarization.filterEnglishOnly = targetFilterEnglishOnlyToPersist
                progress.speakerDiarization = diarization
                appState.playbackProgress[videoId] = progress

                do {
                    let data = try JSONEncoder().encode(appState)
                    try data.write(to: self.stateFileURL)
                } catch {
                    print("[-] DataManager: Error saving toggled filterEnglishOnly: \(error)")
                }
            }
        }
    }

    public func renameSpeaker(videoId: String, speakerId: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 1. Immediately update in-memory player state
        if var ep = PodcastPlayer.shared.currentEpisode, ep.videoId == videoId, var diarization = ep.speakerDiarization {
            if let idx = diarization.speakers.firstIndex(where: { $0.id == speakerId }) {
                diarization.speakers[idx].name = trimmed
                ep.speakerDiarization = diarization
                PodcastPlayer.shared.currentEpisode = ep
            }
        }

        // 2. Immediately update in-memory shows state
        for showIndex in shows.indices {
            if let epIndex = shows[showIndex].episodes.firstIndex(where: { $0.videoId == videoId }),
               let diarization = shows[showIndex].episodes[epIndex].speakerDiarization,
               let spkIndex = diarization.speakers.firstIndex(where: { $0.id == speakerId }) {
                var updated = diarization
                updated.speakers[spkIndex].name = trimmed
                shows[showIndex].episodes[epIndex].speakerDiarization = updated
            }
        }

        // 3. Persist synchronously
        guard let stateData = try? Data(contentsOf: stateFileURL),
              var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }

        if var progress = appState.playbackProgress[videoId],
           var diarization = progress.speakerDiarization,
           let idx = diarization.speakers.firstIndex(where: { $0.id == speakerId }) {
            diarization.speakers[idx].name = trimmed
            progress.speakerDiarization = diarization
            appState.playbackProgress[videoId] = progress

            do {
                let data = try JSONEncoder().encode(appState)
                try data.write(to: stateFileURL)
            } catch {
                print("[-] DataManager: Error renaming speaker: \(error)")
            }
        }
    }

    public func clearSpeakerDiarization(videoId: String) {
        // Invalidate server cache if URL is configured (fire and forget)
        var baseUrl = settings.effectiveWhisperServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseUrl.hasSuffix("/") {
            baseUrl = String(baseUrl.dropLast())
        }
        if let url = URL(string: "\(baseUrl)/diarize/\(videoId)/cache") {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.timeoutInterval = 5.0
            URLSession.shared.dataTask(with: request).resume()
        }

        // 1. Immediately update in-memory player state
        if var ep = PodcastPlayer.shared.currentEpisode, ep.videoId == videoId {
            ep.speakerDiarization = nil
            PodcastPlayer.shared.currentEpisode = ep
            PodcastPlayer.shared.updateSkipBoundaryObservers()
        }

        // 2. Immediately update in-memory shows state
        for showIndex in shows.indices {
            if let epIndex = shows[showIndex].episodes.firstIndex(where: { $0.videoId == videoId }) {
                shows[showIndex].episodes[epIndex].speakerDiarization = nil
            }
        }

        // 3. Persist synchronously
        guard let stateData = try? Data(contentsOf: stateFileURL),
              var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }

        if var progress = appState.playbackProgress[videoId] {
            progress.speakerDiarization = nil
            appState.playbackProgress[videoId] = progress

            do {
                let data = try JSONEncoder().encode(appState)
                try data.write(to: stateFileURL)
            } catch {
                print("[-] DataManager: Error clearing speaker diarization: \(error)")
            }
        }
    }

    // MARK: - Silence Removal Management

    public func setSilenceRemoval(videoId: String, enabled: Bool, maxDuration: Double) {
        let clampedDuration = max(0.0, min(10.0, maxDuration))

        // 1. Synchronously update in-memory player state & immediately evaluate skips
        if var ep = PodcastPlayer.shared.currentEpisode, ep.videoId == videoId {
            ep.removeSilence = enabled
            ep.maxSilenceDuration = clampedDuration
            PodcastPlayer.shared.currentEpisode = ep
            PodcastPlayer.shared.updateSkipBoundaryObservers()
            PodcastPlayer.shared.evaluateAutoSkipsImmediately()
        }

        // 2. Synchronously update in-memory shows state
        for showIndex in shows.indices {
            if let epIndex = shows[showIndex].episodes.firstIndex(where: { $0.videoId == videoId }) {
                shows[showIndex].episodes[epIndex].removeSilence = enabled
                shows[showIndex].episodes[epIndex].maxSilenceDuration = clampedDuration
            }
        }

        // 3. Persist asynchronously on utility queue
        let targetEpisode = findEpisode(videoId: videoId)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self,
                  let stateData = try? Data(contentsOf: self.stateFileURL),
                  var appState = try? JSONDecoder().decode(AppState.self, from: stateData) else { return }

            if var progress = appState.playbackProgress[videoId] {
                progress.removeSilence = enabled
                progress.maxSilenceDuration = clampedDuration
                appState.playbackProgress[videoId] = progress
            } else if let episode = targetEpisode {
                let progress = PodcastEpisodeProgress(
                    title: episode.title,
                    channel: episode.channel,
                    channelUrl: episode.channelUrl,
                    duration: episode.duration,
                    filename: episode.filename,
                    lastPosition: episode.lastPosition,
                    completed: episode.completed,
                    lastPlayed: episode.lastPlayed,
                    dateAdded: episode.dateAdded,
                    segments: episode.segments,
                    customSkips: episode.customSkips,
                    speakerDiarization: episode.speakerDiarization,
                    uploadDate: episode.uploadDate,
                    removeSilence: enabled,
                    maxSilenceDuration: clampedDuration
                )
                appState.playbackProgress[videoId] = progress
            }

            do {
                let data = try JSONEncoder().encode(appState)
                try data.write(to: self.stateFileURL)
            } catch {
                print("[-] DataManager: Error saving silence removal setting: \(error)")
            }
        }
    }

    // MARK: - WhisperX Diarization & Remote Computer Control

    public func checkWhisperXHealth(completion: @escaping (Bool) -> Void) {
        var baseUrl = settings.effectiveWhisperServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseUrl.hasSuffix("/") {
            baseUrl = String(baseUrl.dropLast())
        }
        guard let url = URL(string: "\(baseUrl)/health") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3.0

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                DispatchQueue.main.async { completion(true) }
                return
            }

            // Fallback: If primary URL failed and computerSshHost is configured and different, test ssh host on port 8000
            if let self = self {
                let sshHost = self.settings.computerSshHost.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sshHost.isEmpty && !baseUrl.contains(sshHost) {
                    let fallbackUrlStr = "http://\(sshHost):8000/health"
                    if let fallbackUrl = URL(string: fallbackUrlStr) {
                        var fbRequest = URLRequest(url: fallbackUrl)
                        fbRequest.httpMethod = "GET"
                        fbRequest.timeoutInterval = 3.0
                        URLSession.shared.dataTask(with: fbRequest) { fbData, fbResp, _ in
                            if let fbHttpResp = fbResp as? HTTPURLResponse, fbHttpResp.statusCode == 200 {
                                DispatchQueue.main.async {
                                    var updatedSettings = self.settings
                                    updatedSettings.whisperServerUrl = "http://\(sshHost):8000"
                                    self.saveSettings(updatedSettings)
                                    completion(true)
                                }
                                return
                            }
                            DispatchQueue.main.async { completion(false) }
                        }.resume()
                        return
                    }
                }
            }

            DispatchQueue.main.async { completion(false) }
        }.resume()
    }

    public func executeSshCommand(
        remoteCommand: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let host = settings.computerSshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = settings.computerSshUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = settings.computerSshPort > 0 ? settings.computerSshPort : 22
        let password = settings.computerSshPassword
        let keyPath = settings.computerSshKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !host.isEmpty else {
            completion(.failure(NSError(domain: "PodcastThis", code: 400, userInfo: [NSLocalizedDescriptionKey: "Computer IP / Hostname is not configured in SSH Settings."])))
            return
        }

        let userHost = user.isEmpty ? host : "\(user)@\(host)"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var sshBinary = self.findExecutablePath("ssh") ?? "/var/jb/usr/bin/ssh"
            if !FileManager.default.fileExists(atPath: sshBinary) {
                if FileManager.default.fileExists(atPath: "/usr/bin/ssh") {
                    sshBinary = "/usr/bin/ssh"
                }
            }

            var baseSshArgs = [
                "-p", "\(port)",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "LogLevel=ERROR",
                "-o", "ConnectTimeout=5"
            ]

            if !keyPath.isEmpty && FileManager.default.fileExists(atPath: keyPath) {
                baseSshArgs.append(contentsOf: ["-i", keyPath])
            }

            var executableToSpawn = sshBinary
            var spawnArgs: [String] = []

            let sshpassBinary = self.findExecutablePath("sshpass") ?? "/var/jb/usr/bin/sshpass"
            let hasSshPass = FileManager.default.fileExists(atPath: sshpassBinary)

            if !password.isEmpty {
                if hasSshPass {
                    executableToSpawn = sshpassBinary
                    baseSshArgs.append(contentsOf: ["-o", "PreferredAuthentications=password,keyboard-interactive"])
                    spawnArgs = ["-p", password, sshBinary] + baseSshArgs + [userHost, remoteCommand]
                } else {
                    DispatchQueue.main.async {
                        completion(.failure(NSError(domain: "PodcastThis", code: 400, userInfo: [NSLocalizedDescriptionKey: "Password authentication requires the 'sshpass' package on your iOS device (install via Sileo/Zebra), or use SSH Key authentication."])))
                    }
                    return
                }
            } else {
                executableToSpawn = sshBinary
                spawnArgs = baseSshArgs + [userHost, remoteCommand]
            }

            let result = self.executeProcessDirect(executable: executableToSpawn, arguments: spawnArgs)
            DispatchQueue.main.async {
                if result.status == 0 {
                    completion(.success(result.output))
                } else {
                    let err = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    completion(.failure(NSError(domain: "PodcastThis", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? "SSH connection failed (code \(result.status)). Verify computer IP, port, and credentials." : err])))
                }
            }
        }
    }

    public func testSshConnection(completion: @escaping (Result<String, Error>) -> Void) {
        executeSshCommand(remoteCommand: "echo 'Connection successful: ' $(uname -a)") { result in
            completion(result)
        }
    }

    public func startRemoteWhisperXServer(
        progressHandler: @escaping (String) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let rawPath = settings.computerWhisperXPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = rawPath.isEmpty ? "~/podcast-this/services/whisperx-service" : rawPath

        // 1. Check if server is already online and responding first
        progressHandler("Checking service status...")
        checkWhisperXHealth { [weak self] isAlreadyOnline in
            if isAlreadyOnline {
                progressHandler("Service is online!")
                completion(.success(()))
                return
            }

            guard let self = self else { return }

            progressHandler("Sending start command to computer via SSH...")

            // Safely expand ~ to $HOME and quote path to handle spaces and shell escaping
            let sanitizedPath = path.hasPrefix("~/") ? "\"$HOME/" + path.dropFirst(2) + "\"" : "\"\(path)\""
            let startCmd = "cd \(sanitizedPath) && (nohup ./start.sh > /tmp/whisperx.log 2>&1 &)"

            self.executeSshCommand(remoteCommand: startCmd) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success:
                    progressHandler("Starting service, waiting for response...")
                    var attempts = 0
                    let maxAttempts = 15
                    Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { timer in
                        attempts += 1
                        self.checkWhisperXHealth { isOnline in
                            if isOnline {
                                timer.invalidate()
                                completion(.success(()))
                            } else if attempts >= maxAttempts {
                                timer.invalidate()
                                completion(.failure(NSError(domain: "PodcastThis", code: 504, userInfo: [NSLocalizedDescriptionKey: "Service was triggered over SSH, but did not respond on the configured port within \(Int(Double(maxAttempts) * 1.5)) seconds. Check \(path) logs."])))
                            }
                        }
                    }
                }
            }
        }
    }

    public func stopRemoteWhisperXServer(completion: @escaping (Result<Void, Error>) -> Void) {
        // 1. Try clean HTTP shutdown endpoint first
        var baseUrl = settings.effectiveWhisperServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseUrl.hasSuffix("/") {
            baseUrl = String(baseUrl.dropLast())
        }
        if let url = URL(string: "\(baseUrl)/shutdown") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 2.0
            URLSession.shared.dataTask(with: request).resume()
        }

        // 2. Also send pkill command over SSH if host is configured
        if !settings.computerSshHost.isEmpty {
            executeSshCommand(remoteCommand: "pkill -f 'python.*server.py' || true") { _ in
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            }
        } else {
            DispatchQueue.main.async {
                completion(.success(()))
            }
        }
    }

    public func fetchDiarizationStatus(
        videoId: String,
        completion: @escaping (Result<SpeakerDiarizationData?, Error>, String?) -> Void
    ) {
        var baseUrl = settings.effectiveWhisperServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseUrl.hasSuffix("/") {
            baseUrl = String(baseUrl.dropLast())
        }
        guard let url = URL(string: "\(baseUrl)/diarize/\(videoId)/status") else {
            completion(.failure(NSError(domain: "PodcastThis", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Computer WhisperX Server URL."])), nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6.0

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(error), nil)
                }
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String else {
                DispatchQueue.main.async {
                    completion(.success(nil), nil)
                }
                return
            }

            if status == "completed" {
                if let resultDict = json["result"],
                   let resultData = try? JSONSerialization.data(withJSONObject: resultDict),
                   let diarizationResult = try? JSONDecoder().decode(SpeakerDiarizationData.self, from: resultData) {
                    self.saveSpeakerDiarization(videoId: videoId, data: diarizationResult)
                    DispatchQueue.main.async {
                        completion(.success(diarizationResult), "Completed")
                    }
                    return
                }
            } else if status == "processing" {
                let step = (json["step"] as? String) ?? "Processing audio on computer..."
                DispatchQueue.main.async {
                    completion(.success(nil), step)
                }
                return
            } else if status == "failed" {
                let errMsg = (json["error"] as? String) ?? "Diarization failed on computer server."
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "PodcastThis", code: 500, userInfo: [NSLocalizedDescriptionKey: errMsg])), nil)
                }
                return
            }

            DispatchQueue.main.async {
                completion(.success(nil), nil)
            }
        }.resume()
    }

    // MARK: - Quick Analyze Speakers (All-in-One: Auto-start WhisperX & Diarize)

    public func quickAnalyzeSpeakers(
        episode: PodcastEpisode,
        force: Bool = false,
        progressHandler: @escaping (String) -> Void = { _ in },
        completion: @escaping (Result<SpeakerDiarizationData, Error>) -> Void
    ) {
        let fileURL = downloadsDirectory.appendingPathComponent(episode.filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            completion(.failure(NSError(domain: "PodcastThis", code: 404, userInfo: [NSLocalizedDescriptionKey: "Please download the episode first before running speaker analysis."])))
            return
        }

        progressHandler("Checking WhisperX server status...")
        checkWhisperXHealth { [weak self] isOnline in
            guard let self = self else { return }
            if isOnline {
                self.sendForDiarization(
                    episode: episode,
                    force: force,
                    detectLanguageOverride: false,
                    progressHandler: progressHandler,
                    completion: completion
                )
            } else {
                progressHandler("Server offline. Starting WhisperX server via SSH...")
                self.startRemoteWhisperXServer(
                    progressHandler: progressHandler
                ) { [weak self] startResult in
                    guard let self = self else { return }
                    switch startResult {
                    case .success:
                        self.sendForDiarization(
                            episode: episode,
                            force: force,
                            detectLanguageOverride: false,
                            progressHandler: progressHandler,
                            completion: completion
                        )
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    public func sendForDiarization(
        episode: PodcastEpisode,
        force: Bool = false,
        detectLanguageOverride: Bool? = nil,
        progressHandler: @escaping (String) -> Void,
        completion: @escaping (Result<SpeakerDiarizationData, Error>) -> Void
    ) {
        let fileURL = downloadsDirectory.appendingPathComponent(episode.filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            completion(.failure(NSError(domain: "PodcastThis", code: 404, userInfo: [NSLocalizedDescriptionKey: "Audio file not found on device."])))
            return
        }

        var baseUrl = settings.effectiveWhisperServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseUrl.hasSuffix("/") {
            baseUrl = String(baseUrl.dropLast())
        }
        guard let url = URL(string: "\(baseUrl)/diarize") else {
            completion(.failure(NSError(domain: "PodcastThis", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Computer WhisperX Server URL in Settings."])))
            return
        }

        if force {
            // When explicitly forced to re-analyze, bypass checking cached results and directly upload
            self.uploadAndProcessDiarization(episode: episode, fileURL: fileURL, url: url, force: true, detectLanguageOverride: detectLanguageOverride, progressHandler: progressHandler, completion: completion)
            return
        }

        // First check if computer server already has the cached result
        progressHandler("Checking server for cached analysis...")
        fetchDiarizationStatus(videoId: episode.videoId) { [weak self] result, step in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                if let data = data {
                    completion(.success(data))
                    return
                }
                if let step = step, !step.isEmpty {
                    // Already processing on server, start polling
                    self.startPollingDiarization(episode: episode, progressHandler: progressHandler, completion: completion)
                    return
                }
                // Not cached or processing, upload audio
                self.uploadAndProcessDiarization(episode: episode, fileURL: fileURL, url: url, force: false, detectLanguageOverride: detectLanguageOverride, progressHandler: progressHandler, completion: completion)
            case .failure(let err):
                // If initial connection test fails, fail immediately instead of attempting upload
                let nsErr = err as NSError
                if nsErr.domain == NSURLErrorDomain {
                    completion(.failure(NSError(domain: "PodcastThis", code: 503, userInfo: [NSLocalizedDescriptionKey: "Could not connect to WhisperX server at \(baseUrl). Please ensure the server is running on your computer and both devices are on the same network."])))
                    return
                }
                self.uploadAndProcessDiarization(episode: episode, fileURL: fileURL, url: url, force: false, detectLanguageOverride: detectLanguageOverride, progressHandler: progressHandler, completion: completion)
            }
        }
    }

    private func uploadAndProcessDiarization(
        episode: PodcastEpisode,
        fileURL: URL,
        url: URL,
        force: Bool = false,
        detectLanguageOverride: Bool? = nil,
        progressHandler: @escaping (String) -> Void,
        completion: @escaping (Result<SpeakerDiarizationData, Error>) -> Void
    ) {
        progressHandler("Preparing audio upload...")

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180.0

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"video_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(episode.videoId)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"title\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(episode.title)\r\n".data(using: .utf8)!)

        if force {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"force\"\r\n\r\n".data(using: .utf8)!)
            body.append("true\r\n".data(using: .utf8)!)
        }

        let shouldDetectLang = detectLanguageOverride ?? settings.detectLanguagesDuringDiarization
        let detectLang = shouldDetectLang ? "true" : "false"
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"detect_language\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(detectLang)\r\n".data(using: .utf8)!)

        let filename = fileURL.lastPathComponent
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)

        guard let audioData = try? Data(contentsOf: fileURL) else {
            completion(.failure(NSError(domain: "PodcastThis", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to read audio file data."])))
            return
        }

        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        progressHandler("Uploading audio to Computer (WhisperX)...")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180.0
        config.timeoutIntervalForResource = 3600.0
        let session = URLSession(configuration: config)

        let task = session.uploadTask(with: request, from: body) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "PodcastThis", code: 502, userInfo: [NSLocalizedDescriptionKey: "Failed to connect or upload audio to Computer WhisperX server: \(error.localizedDescription)"])))
                }
                return
            }

            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode >= 400 {
                let msg = data != nil ? (String(data: data!, encoding: .utf8) ?? "Server returned error \(httpResp.statusCode)") : "Server returned error \(httpResp.statusCode)"
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "PodcastThis", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])))
                }
                return
            }

            // Once uploaded or if upload response is received, start polling for status
            DispatchQueue.main.async {
                self.startPollingDiarization(episode: episode, progressHandler: progressHandler, completion: completion)
            }
        }

        task.resume()
    }

    public func startPollingDiarization(
        episode: PodcastEpisode,
        progressHandler: @escaping (String) -> Void,
        completion: @escaping (Result<SpeakerDiarizationData, Error>) -> Void
    ) {
        diarizationTimer?.invalidate()
        diarizationTimer = nil

        var attempts = 0
        var consecutiveErrors = 0
        let maxAttempts = 1800 // 1800 * 4s = 2 hours of active polling

        diarizationTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            attempts += 1

            self.fetchDiarizationStatus(videoId: episode.videoId) { result, step in
                switch result {
                case .success(let data):
                    consecutiveErrors = 0
                    if let data = data {
                        timer.invalidate()
                        if self.diarizationTimer === timer { self.diarizationTimer = nil }
                        completion(.success(data))
                    } else if let step = step {
                        progressHandler(step)
                    } else {
                        progressHandler("Processing audio on Computer (WhisperX)...")
                    }
                case .failure(let err):
                    consecutiveErrors += 1
                    // Transient connection timeouts are normal while the computer is heavily processing
                    progressHandler("Processing audio on Computer (WhisperX)...")

                    // After extended period of unreachable network (e.g. 45 consecutive attempts / 3 minutes), pause active polling and inform the user
                    if consecutiveErrors >= 45 {
                        timer.invalidate()
                        if self.diarizationTimer === timer { self.diarizationTimer = nil }
                        completion(.failure(NSError(domain: "PodcastThis", code: 503, userInfo: [NSLocalizedDescriptionKey: "AI Person Analysis is continuing in the background on your computer. Conversions take some time—once complete, opening this episode will automatically load the results."])))
                        return
                    }
                    if attempts >= maxAttempts {
                        timer.invalidate()
                        if self.diarizationTimer === timer { self.diarizationTimer = nil }
                        completion(.failure(NSError(domain: "PodcastThis", code: 504, userInfo: [NSLocalizedDescriptionKey: "AI Person Analysis is continuing in the background on your computer. Conversions take some time—once complete, opening this episode will automatically load the results."])))
                        return
                    }
                }

                if attempts >= maxAttempts {
                    timer.invalidate()
                    if self.diarizationTimer === timer { self.diarizationTimer = nil }
                    completion(.failure(NSError(domain: "PodcastThis", code: 504, userInfo: [NSLocalizedDescriptionKey: "AI Person Analysis is continuing in the background on your computer. Conversions take some time—once complete, opening this episode will automatically load the results."])))
                }
            }
        }
    }
}
