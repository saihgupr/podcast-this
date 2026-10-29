import Foundation

public struct EpisodeMetadata: Identifiable, Codable, Hashable {
    public var id: String
    public var title: String
    public var durationString: String?
    public var url: String
    
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case durationString = "duration_string"
        case url
    }

    public var formattedDuration: String? {
        guard let dStr = durationString else { return nil }
        if !dStr.contains(":"), let sec = Double(dStr) {
            let m = Int(sec) / 60
            let s = Int(sec) % 60
            return String(format: "%d:%02d", m, s)
        }
        return dStr
    }
}

public struct UserCustomSkip: Identifiable, Codable, Hashable {
    public var id: String
    public var start: Double
    public var end: Double
    public var label: String
    public var isEnabled: Bool
    public var dateCreated: String?

    enum CodingKeys: String, CodingKey {
        case id
        case start
        case end
        case label
        case isEnabled = "is_enabled"
        case dateCreated = "date_created"
    }

    public init(id: String = UUID().uuidString, start: Double, end: Double, label: String = "Custom Skip", isEnabled: Bool = true, dateCreated: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.label = label
        self.isEnabled = isEnabled
        self.dateCreated = dateCreated ?? ISO8601DateFormatter().string(from: Date())
    }

    public var formattedDuration: String {
        let diff = max(0, end - start)
        let m = Int(diff) / 60
        let s = Int(diff) % 60
        return String(format: "%d:%02d", m, s)
    }
}

public struct SkipInterval: Equatable, Hashable {
    public let start: Double
    public let end: Double
    
    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

public struct SpeakerProfile: Identifiable, Codable, Hashable {
    public var id: String
    public var name: String
    public var isSkipped: Bool
    public var totalDuration: Double
    public var sampleText: String?
    public var firstTimestamp: Double?
    public var isNonEnglish: Bool
    public var dominantLanguage: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case defaultName = "default_name"
        case isSkipped = "is_skipped"
        case totalDuration = "total_duration"
        case sampleText = "sample_text"
        case firstTimestamp = "first_timestamp"
        case isNonEnglish = "is_non_english"
        case dominantLanguage = "dominant_language"
    }

    public init(id: String, name: String, isSkipped: Bool = false, totalDuration: Double = 0.0, sampleText: String? = nil, firstTimestamp: Double? = nil, isNonEnglish: Bool = false, dominantLanguage: String? = nil) {
        self.id = id
        self.name = name
        self.isSkipped = isSkipped
        self.totalDuration = totalDuration
        self.sampleText = sampleText
        self.firstTimestamp = firstTimestamp
        self.isNonEnglish = isNonEnglish
        self.dominantLanguage = dominantLanguage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        if let customName = try? container.decodeIfPresent(String.self, forKey: .name) {
            name = customName
        } else if let defName = try? container.decodeIfPresent(String.self, forKey: .defaultName) {
            name = defName
        } else {
            name = id.hasPrefix("SPEAKER_") ? "Speaker \(id.replacingOccurrences(of: "SPEAKER_", with: ""))" : id
        }
        isSkipped = (try? container.decodeIfPresent(Bool.self, forKey: .isSkipped)) ?? false
        totalDuration = (try? container.decodeIfPresent(Double.self, forKey: .totalDuration)) ?? 0.0
        sampleText = try? container.decodeIfPresent(String.self, forKey: .sampleText)
        firstTimestamp = try? container.decodeIfPresent(Double.self, forKey: .firstTimestamp)
        isNonEnglish = (try? container.decodeIfPresent(Bool.self, forKey: .isNonEnglish)) ?? false
        dominantLanguage = try? container.decodeIfPresent(String.self, forKey: .dominantLanguage)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isSkipped, forKey: .isSkipped)
        try container.encode(totalDuration, forKey: .totalDuration)
        try container.encodeIfPresent(sampleText, forKey: .sampleText)
        try container.encodeIfPresent(firstTimestamp, forKey: .firstTimestamp)
        try container.encode(isNonEnglish, forKey: .isNonEnglish)
        try container.encodeIfPresent(dominantLanguage, forKey: .dominantLanguage)
    }
}

public struct SpeakerSegment: Identifiable, Codable, Hashable {
    public var id: String { "\(speakerId)_\(start)_\(end)" }
    public var speakerId: String
    public var start: Double
    public var end: Double
    public var language: String?
    public var text: String?

    enum CodingKeys: String, CodingKey {
        case speakerId = "speaker_id"
        case start
        case end
        case language
        case text
    }

    public init(speakerId: String, start: Double, end: Double, language: String? = "en", text: String? = nil) {
        self.speakerId = speakerId
        self.start = start
        self.end = end
        self.language = language
        self.text = text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speakerId = try container.decode(String.self, forKey: .speakerId)
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)
        language = (try? container.decodeIfPresent(String.self, forKey: .language)) ?? "en"
        text = try? container.decodeIfPresent(String.self, forKey: .text)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(speakerId, forKey: .speakerId)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(text, forKey: .text)
    }
}

public struct SpeakerDiarizationData: Codable, Hashable {
    public var videoId: String?
    public var speakers: [SpeakerProfile]
    public var segments: [SpeakerSegment]
    public var analyzedDate: String?
    public var detectedLanguages: [String]?
    public var filterEnglishOnly: Bool? = false

    enum CodingKeys: String, CodingKey {
        case videoId = "video_id"
        case speakers
        case segments
        case analyzedDate = "analyzed_date"
        case detectedLanguages = "detected_languages"
        case filterEnglishOnly = "filter_english_only"
    }

    public init(
        videoId: String? = nil,
        speakers: [SpeakerProfile] = [],
        segments: [SpeakerSegment] = [],
        analyzedDate: String? = nil,
        detectedLanguages: [String]? = nil,
        filterEnglishOnly: Bool? = false
    ) {
        self.videoId = videoId
        self.speakers = speakers
        self.segments = segments
        self.analyzedDate = analyzedDate
        self.detectedLanguages = detectedLanguages
        self.filterEnglishOnly = filterEnglishOnly
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        videoId = try? container.decodeIfPresent(String.self, forKey: .videoId)
        speakers = (try? container.decode([SpeakerProfile].self, forKey: .speakers)) ?? []
        segments = (try? container.decode([SpeakerSegment].self, forKey: .segments)) ?? []
        analyzedDate = try? container.decodeIfPresent(String.self, forKey: .analyzedDate)
        detectedLanguages = try? container.decodeIfPresent([String].self, forKey: .detectedLanguages)
        filterEnglishOnly = (try? container.decodeIfPresent(Bool.self, forKey: .filterEnglishOnly)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(videoId, forKey: .videoId)
        try container.encode(speakers, forKey: .speakers)
        try container.encode(segments, forKey: .segments)
        try container.encodeIfPresent(analyzedDate, forKey: .analyzedDate)
        try container.encodeIfPresent(detectedLanguages, forKey: .detectedLanguages)
        try container.encodeIfPresent(filterEnglishOnly, forKey: .filterEnglishOnly)
    }

    public var hasNonEnglishContent: Bool {
        if speakers.contains(where: { $0.isNonEnglish }) {
            return true
        }
        guard let langs = detectedLanguages, !langs.isEmpty else {
            return segments.contains { ($0.language ?? "en").lowercased() != "en" }
        }
        return langs.contains { $0.lowercased() != "en" }
    }
}

public struct PodcastEpisode: Identifiable, Codable, Hashable {
    public var id: String { videoId }
    public let videoId: String
    public let title: String
    public let channel: String
    public let channelUrl: String
    public let duration: Double
    public let filename: String
    public var lastPosition: Double
    public var completed: Bool
    public var lastPlayed: String?
    public var dateAdded: String
    public var segments: [PodcastEpisodeSegment]?
    public var customSkips: [UserCustomSkip]?
    public var speakerDiarization: SpeakerDiarizationData?
    public var uploadDate: String?
    public var removeSilence: Bool
    public var maxSilenceDuration: Double

    enum CodingKeys: String, CodingKey {
        case videoId = "video_id"
        case title
        case channel
        case channelUrl = "channel_url"
        case duration
        case filename
        case lastPosition = "last_position"
        case completed
        case lastPlayed = "last_played"
        case dateAdded = "date_added"
        case segments
        case customSkips = "custom_skips"
        case speakerDiarization = "speaker_diarization"
        case uploadDate = "upload_date"
        case removeSilence = "remove_silence"
        case maxSilenceDuration = "max_silence_duration"
    }

    public var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(lastPosition / duration, 1.0)
    }

    public var formattedDuration: String { formatTime(duration) }

    public var hasSpeakerAnalysis: Bool {
        guard let diarization = speakerDiarization else { return false }
        return diarization.analyzedDate != nil || !diarization.speakers.isEmpty || !diarization.segments.isEmpty
    }

    public var formattedDateAdded: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateAdded) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .none
            return display.string(from: date)
        }
        return dateAdded
    }

    public var formattedUploadDate: String? {
        guard let uploadDate = uploadDate, uploadDate.count == 8 else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        if let date = formatter.date(from: uploadDate) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .none
            return display.string(from: date)
        }
        return nil
    }

    public init(videoId: String, title: String, channel: String, channelUrl: String = "", duration: Double, filename: String, lastPosition: Double = 0.0, completed: Bool = false, lastPlayed: String? = nil, dateAdded: String, segments: [PodcastEpisodeSegment]? = nil, customSkips: [UserCustomSkip]? = nil, speakerDiarization: SpeakerDiarizationData? = nil, uploadDate: String? = nil, removeSilence: Bool = false, maxSilenceDuration: Double = 5.0) {
        self.videoId = videoId
        self.title = title
        self.channel = channel
        self.channelUrl = channelUrl
        self.duration = duration
        self.filename = filename
        self.lastPosition = lastPosition
        self.completed = completed
        self.lastPlayed = lastPlayed
        self.dateAdded = dateAdded
        self.segments = segments
        self.customSkips = customSkips
        self.speakerDiarization = speakerDiarization
        self.uploadDate = uploadDate
        self.removeSilence = removeSilence
        self.maxSilenceDuration = maxSilenceDuration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoId = try c.decode(String.self, forKey: .videoId)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Unknown Episode"
        channel = (try? c.decodeIfPresent(String.self, forKey: .channel)) ?? "Imported Feed"
        channelUrl = (try? c.decodeIfPresent(String.self, forKey: .channelUrl)) ?? ""
        duration = (try? c.decodeIfPresent(Double.self, forKey: .duration)) ?? 0.0
        filename = (try? c.decodeIfPresent(String.self, forKey: .filename)) ?? ""
        lastPosition = (try? c.decodeIfPresent(Double.self, forKey: .lastPosition)) ?? 0.0
        completed = (try? c.decodeIfPresent(Bool.self, forKey: .completed)) ?? false
        lastPlayed = try? c.decodeIfPresent(String.self, forKey: .lastPlayed)
        dateAdded = (try? c.decodeIfPresent(String.self, forKey: .dateAdded)) ?? ""
        segments = try? c.decodeIfPresent([PodcastEpisodeSegment].self, forKey: .segments)
        customSkips = try? c.decodeIfPresent([UserCustomSkip].self, forKey: .customSkips)
        speakerDiarization = try? c.decodeIfPresent(SpeakerDiarizationData.self, forKey: .speakerDiarization)
        uploadDate = try? c.decodeIfPresent(String.self, forKey: .uploadDate)
        removeSilence = (try? c.decodeIfPresent(Bool.self, forKey: .removeSilence)) ?? false
        maxSilenceDuration = (try? c.decodeIfPresent(Double.self, forKey: .maxSilenceDuration)) ?? 5.0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(videoId, forKey: .videoId)
        try c.encode(title, forKey: .title)
        try c.encode(channel, forKey: .channel)
        try c.encode(channelUrl, forKey: .channelUrl)
        try c.encode(duration, forKey: .duration)
        try c.encode(filename, forKey: .filename)
        try c.encode(lastPosition, forKey: .lastPosition)
        try c.encode(completed, forKey: .completed)
        try c.encodeIfPresent(lastPlayed, forKey: .lastPlayed)
        try c.encode(dateAdded, forKey: .dateAdded)
        try c.encodeIfPresent(segments, forKey: .segments)
        try c.encodeIfPresent(customSkips, forKey: .customSkips)
        try c.encodeIfPresent(speakerDiarization, forKey: .speakerDiarization)
        try c.encodeIfPresent(uploadDate, forKey: .uploadDate)
        try c.encode(removeSilence, forKey: .removeSilence)
        try c.encode(maxSilenceDuration, forKey: .maxSilenceDuration)
    }

    private func formatTime(_ t: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

public struct PodcastShow: Identifiable, Hashable {
    public var id: String { channelName }
    public let channelName: String
    public var episodes: [PodcastEpisode]
    public var artworkFilename: String?
    /// Channel URL derived from the first episode that has one
    public var channelUrl: String? {
        episodes.first(where: { !$0.channelUrl.isEmpty })?.channelUrl
    }

    public var unplayedCount: Int {
        episodes.filter { !$0.completed && $0.lastPosition == 0 }.count
    }
}

public struct Subscription: Identifiable, Codable, Hashable {
    public var id: String { channelId }
    public let channelId: String
    public let channelTitle: String
    public let channelUrl: String
    public var autoDownload: Bool
    public let dateSubscribed: String
    public var lastSeenVideoId: String?

    enum CodingKeys: String, CodingKey {
        case channelId = "channel_id"
        case channelTitle = "channel_title"
        case channelUrl = "channel_url"
        case autoDownload = "auto_download"
        case dateSubscribed = "date_subscribed"
        case lastSeenVideoId = "last_seen_video_id"
    }
}

public struct AppSettings: Codable, Hashable {
    public var sponsorBlockEnabled: Bool
    public var sponsorBlockCategories: [String]
    public var userSkipsEnabled: Bool
    public var autoplayEnabled: Bool
    public var onlyPlayUnplayed: Bool
    public var mixWithOthers: Bool
    public var skipDuration: Double
    public var enableBalanceSlider: Bool
    public var whisperServerUrl: String
    public var speakerSkipLeadIn: Double
    public var speakerSkipTrail: Double
    public var languageSkipLeadIn: Double
    public var languageSkipTrail: Double
    public var computerSshHost: String
    public var computerSshPort: Int
    public var computerSshUser: String
    public var computerSshPassword: String
    public var computerSshKeyPath: String
    public var computerWhisperXPath: String
    public var removeSilence: Bool
    public var maxSilenceDuration: Double
    public var detectLanguagesDuringDiarization: Bool
    public var batterySaverEnabled: Bool

    public var effectiveWhisperServerUrl: String {
        let trimmed = whisperServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = computerSshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.isEmpty && (trimmed.isEmpty || trimmed == "http://192.168.1.100:8000" || trimmed == "http://localhost:8000" || trimmed == "http://127.0.0.1:8000") {
            return "http://\(host):8000"
        }
        if !trimmed.isEmpty {
            return trimmed
        }
        if !host.isEmpty {
            return "http://\(host):8000"
        }
        return "http://127.0.0.1:8000"
    }

    enum CodingKeys: String, CodingKey {
        case sponsorBlockEnabled = "sponsorblock_enabled"
        case sponsorBlockCategories = "sponsorblock_categories"
        case userSkipsEnabled = "user_skips_enabled"
        case autoplayEnabled = "autoplay_enabled"
        case onlyPlayUnplayed = "only_play_unplayed"
        case mixWithOthers = "mix_with_others"
        case skipDuration = "skip_duration"
        case enableBalanceSlider = "enable_balance_slider"
        case whisperServerUrl = "whisper_server_url"
        case speakerSkipLeadIn = "speaker_skip_lead_in"
        case speakerSkipTrail = "speaker_skip_trail"
        case languageSkipLeadIn = "language_skip_lead_in"
        case languageSkipTrail = "language_skip_trail"
        case computerSshHost = "computer_ssh_host"
        case computerSshPort = "computer_ssh_port"
        case computerSshUser = "computer_ssh_user"
        case computerSshPassword = "computer_ssh_password"
        case computerSshKeyPath = "computer_ssh_key_path"
        case computerWhisperXPath = "computer_whisperx_path"
        case removeSilence = "remove_silence"
        case maxSilenceDuration = "max_silence_duration"
        case detectLanguagesDuringDiarization = "detect_languages_during_diarization"
        case batterySaverEnabled = "battery_saver_enabled"
    }

    public init(
        sponsorBlockEnabled: Bool = false,
        sponsorBlockCategories: [String] = ["sponsor", "selfpromo", "interaction", "intro", "outro", "preview", "filler"],
        userSkipsEnabled: Bool = true,
        autoplayEnabled: Bool = true,
        onlyPlayUnplayed: Bool = true,
        mixWithOthers: Bool = true,
        skipDuration: Double = 15.0,
        enableBalanceSlider: Bool = false,
        whisperServerUrl: String = "http://192.168.1.100:8000",
        speakerSkipLeadIn: Double = 1.0,
        speakerSkipTrail: Double = 0.5,
        languageSkipLeadIn: Double = 1.0,
        languageSkipTrail: Double = 0.5,
        computerSshHost: String = "",
        computerSshPort: Int = 22,
        computerSshUser: String = "",
        computerSshPassword: String = "",
        computerSshKeyPath: String = "",
        computerWhisperXPath: String = "",
        removeSilence: Bool = false,
        maxSilenceDuration: Double = 5.0,
        detectLanguagesDuringDiarization: Bool = false,
        batterySaverEnabled: Bool = true
    ) {
        self.sponsorBlockEnabled = sponsorBlockEnabled
        self.sponsorBlockCategories = sponsorBlockCategories
        self.userSkipsEnabled = userSkipsEnabled
        self.autoplayEnabled = autoplayEnabled
        self.onlyPlayUnplayed = onlyPlayUnplayed
        self.mixWithOthers = mixWithOthers
        self.skipDuration = skipDuration
        self.enableBalanceSlider = enableBalanceSlider
        self.whisperServerUrl = whisperServerUrl
        self.speakerSkipLeadIn = speakerSkipLeadIn
        self.speakerSkipTrail = speakerSkipTrail
        self.languageSkipLeadIn = languageSkipLeadIn
        self.languageSkipTrail = languageSkipTrail
        self.computerSshHost = computerSshHost
        self.computerSshPort = computerSshPort
        self.computerSshUser = computerSshUser
        self.computerSshPassword = computerSshPassword
        self.computerSshKeyPath = computerSshKeyPath
        self.computerWhisperXPath = computerWhisperXPath
        self.removeSilence = removeSilence
        self.maxSilenceDuration = maxSilenceDuration
        self.detectLanguagesDuringDiarization = detectLanguagesDuringDiarization
        self.batterySaverEnabled = batterySaverEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sponsorBlockEnabled = try container.decode(Bool.self, forKey: .sponsorBlockEnabled)
        sponsorBlockCategories = try container.decode([String].self, forKey: .sponsorBlockCategories)
        userSkipsEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .userSkipsEnabled)) ?? true
        autoplayEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .autoplayEnabled)) ?? true
        onlyPlayUnplayed = (try? container.decodeIfPresent(Bool.self, forKey: .onlyPlayUnplayed)) ?? true
        mixWithOthers = (try? container.decodeIfPresent(Bool.self, forKey: .mixWithOthers)) ?? true
        skipDuration = (try? container.decodeIfPresent(Double.self, forKey: .skipDuration)) ?? 15.0
        enableBalanceSlider = (try? container.decodeIfPresent(Bool.self, forKey: .enableBalanceSlider)) ?? false
        whisperServerUrl = (try? container.decodeIfPresent(String.self, forKey: .whisperServerUrl)) ?? "http://192.168.1.100:8000"
        speakerSkipLeadIn = (try? container.decodeIfPresent(Double.self, forKey: .speakerSkipLeadIn)) ?? 1.0
        speakerSkipTrail = (try? container.decodeIfPresent(Double.self, forKey: .speakerSkipTrail)) ?? 0.5
        languageSkipLeadIn = (try? container.decodeIfPresent(Double.self, forKey: .languageSkipLeadIn)) ?? 1.0
        languageSkipTrail = (try? container.decodeIfPresent(Double.self, forKey: .languageSkipTrail)) ?? 0.5
        computerSshHost = (try? container.decodeIfPresent(String.self, forKey: .computerSshHost)) ?? ""
        computerSshPort = (try? container.decodeIfPresent(Int.self, forKey: .computerSshPort)) ?? 22
        computerSshUser = (try? container.decodeIfPresent(String.self, forKey: .computerSshUser)) ?? ""
        computerSshPassword = (try? container.decodeIfPresent(String.self, forKey: .computerSshPassword)) ?? ""
        computerSshKeyPath = (try? container.decodeIfPresent(String.self, forKey: .computerSshKeyPath)) ?? ""
        computerWhisperXPath = (try? container.decodeIfPresent(String.self, forKey: .computerWhisperXPath)) ?? ""
        removeSilence = (try? container.decodeIfPresent(Bool.self, forKey: .removeSilence)) ?? false
        maxSilenceDuration = (try? container.decodeIfPresent(Double.self, forKey: .maxSilenceDuration)) ?? 5.0
        detectLanguagesDuringDiarization = (try? container.decodeIfPresent(Bool.self, forKey: .detectLanguagesDuringDiarization)) ?? false
        batterySaverEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .batterySaverEnabled)) ?? true
    }
}

public struct AppState: Codable {
    public var subscriptions: [Subscription]
    public var playbackProgress: [String: PodcastEpisodeProgress]
    public var settings: AppSettings?
    public var showOrder: [String]?

    enum CodingKeys: String, CodingKey {
        case subscriptions
        case playbackProgress = "playback_progress"
        case settings
        case showOrder = "show_order"
    }

    public init(subscriptions: [Subscription], playbackProgress: [String: PodcastEpisodeProgress], settings: AppSettings = AppSettings(), showOrder: [String]? = nil) {
        self.subscriptions = subscriptions
        self.playbackProgress = playbackProgress
        self.settings = settings
        self.showOrder = showOrder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subscriptions = (try? container.decode([Subscription].self, forKey: .subscriptions)) ?? []
        playbackProgress = (try? container.decode([String: PodcastEpisodeProgress].self, forKey: .playbackProgress)) ?? [:]
        settings = (try? container.decodeIfPresent(AppSettings.self, forKey: .settings)) ?? AppSettings()
        showOrder = try? container.decodeIfPresent([String].self, forKey: .showOrder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(subscriptions, forKey: .subscriptions)
        try container.encode(playbackProgress, forKey: .playbackProgress)
        try container.encodeIfPresent(settings, forKey: .settings)
        try container.encodeIfPresent(showOrder, forKey: .showOrder)
    }
}

public struct PodcastEpisodeProgress: Codable {
    public let title: String
    public var channel: String
    public var channelUrl: String
    public let duration: Double
    public var filename: String
    public var lastPosition: Double
    public var completed: Bool
    public var lastPlayed: String?
    public var dateAdded: String
    public var segments: [PodcastEpisodeSegment]?
    public var customSkips: [UserCustomSkip]?
    public var speakerDiarization: SpeakerDiarizationData?
    public var uploadDate: String?
    public var removeSilence: Bool
    public var maxSilenceDuration: Double

    enum CodingKeys: String, CodingKey {
        case title
        case channel
        case channelUrl = "channel_url"
        case duration
        case filename
        case lastPosition = "last_position"
        case position
        case completed
        case lastPlayed = "last_played"
        case dateAdded = "date_added"
        case segments
        case customSkips = "custom_skips"
        case speakerDiarization = "speaker_diarization"
        case uploadDate = "upload_date"
        case removeSilence = "remove_silence"
        case maxSilenceDuration = "max_silence_duration"
    }

    // Backwards-compatible decode: supports last_position, position, or defaults gracefully
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Unknown Episode"
        channel = (try? c.decodeIfPresent(String.self, forKey: .channel)) ?? "Imported Feed"
        channelUrl = (try? c.decodeIfPresent(String.self, forKey: .channelUrl)) ?? ""
        duration = (try? c.decodeIfPresent(Double.self, forKey: .duration)) ?? 0.0
        filename = (try? c.decodeIfPresent(String.self, forKey: .filename)) ?? ""
        if let lp = try? c.decodeIfPresent(Double.self, forKey: .lastPosition) {
            lastPosition = lp
        } else if let p = try? c.decodeIfPresent(Double.self, forKey: .position) {
            lastPosition = p
        } else {
            lastPosition = 0.0
        }
        completed = (try? c.decodeIfPresent(Bool.self, forKey: .completed)) ?? false
        lastPlayed = try? c.decodeIfPresent(String.self, forKey: .lastPlayed)
        dateAdded = (try? c.decodeIfPresent(String.self, forKey: .dateAdded)) ?? ""
        segments = try? c.decodeIfPresent([PodcastEpisodeSegment].self, forKey: .segments)
        customSkips = try? c.decodeIfPresent([UserCustomSkip].self, forKey: .customSkips)
        speakerDiarization = try? c.decodeIfPresent(SpeakerDiarizationData.self, forKey: .speakerDiarization)
        uploadDate = try? c.decodeIfPresent(String.self, forKey: .uploadDate)
        removeSilence = (try? c.decodeIfPresent(Bool.self, forKey: .removeSilence)) ?? false
        maxSilenceDuration = (try? c.decodeIfPresent(Double.self, forKey: .maxSilenceDuration)) ?? 5.0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(channel, forKey: .channel)
        try c.encode(channelUrl, forKey: .channelUrl)
        try c.encode(duration, forKey: .duration)
        try c.encode(filename, forKey: .filename)
        try c.encode(lastPosition, forKey: .lastPosition)
        try c.encode(completed, forKey: .completed)
        try c.encodeIfPresent(lastPlayed, forKey: .lastPlayed)
        try c.encode(dateAdded, forKey: .dateAdded)
        try c.encodeIfPresent(segments, forKey: .segments)
        try c.encodeIfPresent(customSkips, forKey: .customSkips)
        try c.encodeIfPresent(speakerDiarization, forKey: .speakerDiarization)
        try c.encodeIfPresent(uploadDate, forKey: .uploadDate)
        try c.encode(removeSilence, forKey: .removeSilence)
        try c.encode(maxSilenceDuration, forKey: .maxSilenceDuration)
    }

    public init(title: String, channel: String, channelUrl: String = "", duration: Double,
                filename: String, lastPosition: Double, completed: Bool,
                lastPlayed: String?, dateAdded: String, segments: [PodcastEpisodeSegment]? = nil,
                customSkips: [UserCustomSkip]? = nil,
                speakerDiarization: SpeakerDiarizationData? = nil,
                uploadDate: String? = nil,
                removeSilence: Bool = false,
                maxSilenceDuration: Double = 5.0) {
        self.title = title; self.channel = channel; self.channelUrl = channelUrl
        self.duration = duration; self.filename = filename
        self.lastPosition = lastPosition; self.completed = completed
        self.lastPlayed = lastPlayed; self.dateAdded = dateAdded
        self.segments = segments
        self.customSkips = customSkips
        self.speakerDiarization = speakerDiarization
        self.uploadDate = uploadDate
        self.removeSilence = removeSilence
        self.maxSilenceDuration = maxSilenceDuration
    }
}

public struct PodcastEpisodeSegment: Codable, Hashable {
    public let category: String
    public let start: Double
    public let end: Double

    public init(category: String, start: Double, end: Double) {
        self.category = category
        self.start = start
        self.end = end
    }
}

public struct ActiveDownload: Identifiable, Codable {
    public var id: String { videoId }
    public let videoId: String
    public let title: String
    public let channel: String
    public let status: String
    public let progress: Double
    public let speed: String
    public let eta: String
    
    enum CodingKeys: String, CodingKey {
        case videoId = "video_id"
        case title
        case channel
        case status
        case progress
        case speed
        case eta
    }
}

public struct ActiveDownloadsContainer: Codable {
    public let activeDownloads: [String: ActiveDownload]
    
    enum CodingKeys: String, CodingKey {
        case activeDownloads = "active_downloads"
    }
}

public struct SyncStatus: Codable {
    public let status: String
    public let message: String
    public let channelTitle: String?
    public let currentChannel: Int?
    public let totalChannels: Int?
    public let isSyncing: Bool?
    public let timestamp: Double?
    public let date: String?
    
    enum CodingKeys: String, CodingKey {
        case status
        case message
        case channelTitle = "channel_title"
        case currentChannel = "current_channel"
        case totalChannels = "total_channels"
        case isSyncing = "is_syncing"
        case timestamp
        case date
    }
}

