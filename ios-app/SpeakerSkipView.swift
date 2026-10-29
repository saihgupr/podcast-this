import SwiftUI

struct SpeakerSkipView: View {
    let episode: PodcastEpisode
    @ObservedObject var dataManager = DataManager.shared
    @ObservedObject var player = PodcastPlayer.shared
    @Environment(\.dismiss) var dismiss

    @State private var isAnalyzing = false
    @State private var statusMessage = ""
    @State private var errorMessage: String? = nil
    @State private var showingRenameAlert = false
    @State private var renamingSpeakerId: String? = nil
    @State private var renamingSpeakerName: String = ""
    @FocusState private var isRenameFieldFocused: Bool
    @State private var showingClearConfirmation = false
    @State private var showingReanalyzeConfirmation = false
    @State private var isServerOnline: Bool? = nil
    @State private var isSshActionActive = false
    @State private var sshActionStatus = ""
    @State private var showingSshSettings = false
    @State private var optimisticSpeakerSkips: [String: Bool] = [:]
    @State private var optimisticSpeakerNonEnglish: [String: Bool] = [:]
    @State private var localRemoveSilence: Bool? = nil
    @State private var localMaxSilenceDuration: Double? = nil
    @State private var localFilterEnglishOnly: Bool? = nil
    @State private var showingSegmentInspector = false

    private let purpleAccent = Color(red: 0.72, green: 0.35, blue: 0.98)
    private let tealAccent = Color(red: 0.18, green: 0.80, blue: 0.75)
    private let englishOnlyAccent = Color(red: 0.0, green: 0.55, blue: 1.0)
    private let enableTranscriptInspector = false // Set to true to re-enable the Transcript & Segment Inspector card

    private var currentEpisode: PodcastEpisode {
        for show in dataManager.shows {
            if let ep = show.episodes.first(where: { $0.videoId == episode.videoId }) {
                return ep
            }
        }
        if let current = player.currentEpisode, current.videoId == episode.videoId {
            return current
        }
        return episode
    }

    private var isSilenceRemovalEnabled: Bool {
        localRemoveSilence ?? currentEpisode.removeSilence
    }

    private var currentMaxSilenceDuration: Double {
        localMaxSilenceDuration ?? currentEpisode.maxSilenceDuration
    }

    private var silenceSkipRegions: [(start: Double, end: Double)] {
        guard isSilenceRemovalEnabled else { return [] }
        return player.getSilenceSkipIntervals()
    }

    private var currentDiarization: SpeakerDiarizationData? {
        currentEpisode.speakerDiarization
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    // Header Info
                    episodeHeaderCard

                    // Server Connection & Control Status
                    serverStatusBanner

                    if let diarization = currentDiarization, !diarization.speakers.isEmpty {
                        // Diarization Overview Stats
                        statsOverviewCard(diarization: diarization)

                        // Language Filtering Card (Only visible if language detection was run AND non-English content exists)
                        if diarization.detectedLanguages != nil && diarization.hasNonEnglishContent {
                            languageFilteringCard(diarization: diarization)
                        }

                        // Silence Removal Card
                        silenceRemovalCard

                        // Clip Padding & Timing Fine-Tuning Sliders
                        paddingControlsCard

                        // Speakers List
                        speakersSection(diarization: diarization)

                        // Transcript & Segment Inspector (temporarily hidden; set enableTranscriptInspector to true to re-enable)
                        if enableTranscriptInspector {
                            transcriptInspectorCard(diarization: diarization)
                        }

                        // Re-analyze & Clear Actions
                        managementActionsCard
                    } else {
                        // Unanalyzed State
                        unanalyzedCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Speaker Skips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(.headline.weight(.semibold))
                            .foregroundColor(PodcastTheme.accent)
                    }
                }
            }
            .sheet(isPresented: $showingSshSettings) {
                SSHComputerSettingsSheet(isPresented: $showingSshSettings)
            }
            .sheet(isPresented: $showingSegmentInspector) {
                if let diarization = currentDiarization {
                    SegmentInspectorSheet(diarization: diarization, episode: episode, isPresented: $showingSegmentInspector)
                }
            }
            .alert("Clear Speaker Analysis?", isPresented: $showingClearConfirmation) {
                Button("Clear", role: .destructive) {
                    dataManager.clearSpeakerDiarization(videoId: episode.videoId)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all detected speaker timestamps for this episode.")
            }
            .alert("Re-analyze Audio with WhisperX?", isPresented: $showingReanalyzeConfirmation) {
                Button("Re-analyze") {
                    triggerDiarization(force: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will upload the audio file to your computer and re-compute speaker segments.")
            }
            .onAppear {
                checkServerHealth()
                checkServerStatusOnAppear()
                syncSpeakerStates()
            }
            .onChange(of: currentDiarization) { _ in
                syncSpeakerStates()
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .overlay {
            renameSpeakerOverlay
        }
    }

    private func syncSpeakerStates() {
        if let diarization = currentDiarization {
            for speaker in diarization.speakers {
                optimisticSpeakerSkips[speaker.id] = speaker.isSkipped
                optimisticSpeakerNonEnglish[speaker.id] = speaker.isNonEnglish
            }
        } else {
            optimisticSpeakerSkips.removeAll()
            optimisticSpeakerNonEnglish.removeAll()
        }
    }

    private func checkServerHealth() {
        dataManager.checkWhisperXHealth { online in
            withAnimation(.easeInOut(duration: 0.2)) {
                self.isServerOnline = online
            }
        }
    }

    private func checkServerStatusOnAppear() {
        guard currentDiarization == nil || (currentDiarization?.speakers.isEmpty ?? true) else { return }
        dataManager.fetchDiarizationStatus(videoId: episode.videoId) { result, step in
            switch result {
            case .success(let data):
                if data != nil {
                    withAnimation {
                        isAnalyzing = false
                    }
                } else if let step = step {
                    isAnalyzing = true
                    statusMessage = step
                    dataManager.startPollingDiarization(
                        episode: episode,
                        progressHandler: { msg in
                            DispatchQueue.main.async {
                                self.statusMessage = msg
                            }
                        },
                        completion: { res in
                            DispatchQueue.main.async {
                                self.isAnalyzing = false
                                if case .success = res {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                }
                            }
                        }
                    )
                }
            case .failure:
                break
            }
        }
    }

    // MARK: - Server Status Banner

    private var serverStatusBanner: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isServerOnline == true ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isServerOnline == true ? .green : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isServerOnline == true ? Color.green : (isServerOnline == false ? Color.secondary : Color.orange))
                        .frame(width: 7, height: 7)

                    Text(isServerOnline == true ? "WhisperX Server Online" : (isServerOnline == false ? "WhisperX Server Offline" : "Checking Server..."))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(isServerOnline == true ? .primary : .secondary)
                }

                if isServerOnline == false {
                    Text(dataManager.settings.computerSshHost.isEmpty ? "Tap SSH to configure remote start" : "Ready to launch over SSH")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else if isServerOnline == true {
                    Text(dataManager.settings.effectiveWhisperServerUrl)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if isServerOnline == true {
                Button {
                    stopRemoteServer()
                } label: {
                    Text("Stop")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
                }
                .buttonStyle(SpringButtonStyle())
            } else {
                HStack(spacing: 8) {
                    if !dataManager.settings.computerSshHost.isEmpty {
                        Button {
                            startRemoteServer()
                        } label: {
                            if isSshActionActive {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.7)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                            } else {
                                Text("Start")
                                    .font(.caption.weight(.bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(purpleAccent))
                            }
                        }
                        .disabled(isSshActionActive)
                        .buttonStyle(SpringButtonStyle())
                    }

                    Button {
                        showingSshSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(purpleAccent)
                            .padding(7)
                            .background(Circle().fill(purpleAccent.opacity(0.12)))
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(PodcastTheme.cardBackground))
    }

    // MARK: - Header

    private var episodeHeaderCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(purpleAccent.opacity(0.14))
                Image(systemName: "person.2.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(purpleAccent)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(episode.title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text(episode.channel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(PodcastTheme.cardBackground))
    }

    // MARK: - Silence Removal Card

    private var silenceRemovalCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(tealAccent.opacity(0.15))
                    Image(systemName: isSilenceRemovalEnabled ? "waveform.badge.minus" : "waveform")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(tealAccent)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Trim Silence")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(silenceCardSubtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Instant-Response Silence Removal Switch with 54x44pt hit target
                Button {
                    let newVal = !isSilenceRemovalEnabled
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) {
                        localRemoveSilence = newVal
                    }
                    DispatchQueue.main.async {
                        dataManager.setSilenceRemoval(
                            videoId: episode.videoId,
                            enabled: newVal,
                            maxDuration: currentMaxSilenceDuration
                        )
                    }
                } label: {
                    ZStack {
                        Color.clear
                            .frame(width: 54, height: 44)

                        Capsule()
                            .fill(isSilenceRemovalEnabled ? tealAccent : Color(.systemGray4))
                            .frame(width: 51, height: 31)

                        Circle()
                            .fill(Color.white)
                            .frame(width: 27, height: 27)
                            .shadow(color: Color.black.opacity(0.18), radius: 2.5, x: 0, y: 1.5)
                            .offset(x: isSilenceRemovalEnabled ? 10 : -10)
                    }
                }
                .buttonStyle(PlainHitTargetButtonStyle())
                .contentShape(Rectangle())
            }

            if isSilenceRemovalEnabled {
                VStack(spacing: 12) {
                    Divider()
                        .padding(.vertical, 2)

                    // Readout & Current Setting Description
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ALLOWED PAUSE THRESHOLD")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.secondary)
                            Text(silenceThresholdDescription)
                                .font(.caption.weight(.medium))
                                .foregroundColor(.primary)
                        }
                        Spacer()
                        Text("\(Int(currentMaxSilenceDuration))s")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(tealAccent)
                    }

                    // Discrete 0-10s Slider
                    VStack(spacing: 4) {
                        Slider(
                            value: Binding(
                                get: { currentMaxSilenceDuration },
                                set: { val in
                                    let rounded = round(val)
                                    localMaxSilenceDuration = rounded
                                    DispatchQueue.main.async {
                                        dataManager.setSilenceRemoval(
                                            videoId: episode.videoId,
                                            enabled: true,
                                            maxDuration: rounded
                                        )
                                    }
                                }
                            ),
                            in: 0...10,
                            step: 1.0
                        )
                        .tint(tealAccent)

                        // Slider Tick Labels
                        HStack {
                            Group {
                                Text("0s (All)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("2s")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("4s")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            Group {
                                Text("6s")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("8s")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("10s")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // Total Trimmed Dead Air Stat (if diarization available)
                    if !silenceSkipRegions.isEmpty {
                        let totalTrimmed = silenceSkipRegions.reduce(0.0) { $0 + ($1.end - $1.start) }
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.caption.weight(.bold))
                                .foregroundColor(tealAccent)
                            Text("Trimming \(silenceSkipRegions.count) gaps (-\(formatDuration(totalTrimmed)) of dead air)")
                                .font(.caption.weight(.medium))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.top, 2)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(PodcastTheme.cardBackground))
    }

    private var silenceCardSubtitle: String {
        if !isSilenceRemovalEnabled {
            return "Automatically skip dead air between speech"
        }
        if currentMaxSilenceDuration == 0 {
            return "Trimming all pauses (0s max)"
        }
        return "Leaving up to \(Int(currentMaxSilenceDuration)).0s of natural pauses"
    }

    private var silenceThresholdDescription: String {
        if currentMaxSilenceDuration == 0 {
            return "Remove all silence (0s max pause)"
        } else if currentMaxSilenceDuration == 1.0 {
            return "Leave up to 1.0s of natural silence"
        } else {
            return "Leave up to \(Int(currentMaxSilenceDuration)).0s of silence"
        }
    }

    // MARK: - Unanalyzed State

    private var unanalyzedCard: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(PodcastTheme.accent.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "person.2.fill")
                    .font(.system(size: 30))
                    .foregroundColor(PodcastTheme.accent)
            }
            .padding(.top, 8)

            VStack(spacing: 6) {
                Text("No Speaker Analysis Yet")
                    .font(.title3.weight(.bold))

                Text("Send this episode to your computer running WhisperX to identify distinct speakers and automatically skip specific people during playback.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            if isAnalyzing {
                VStack(spacing: 14) {
                    HStack(spacing: 10) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: PodcastTheme.accent))
                            .scaleEffect(1.0)
                        Text(statusMessage.isEmpty ? "Analyzing audio on computer..." : statusMessage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(PodcastTheme.accent.opacity(0.1)))

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "clock.badge.checkmark")
                                .font(.subheadline)
                                .foregroundColor(purpleAccent)
                                .frame(width: 20)
                            Text("Full analysis takes time: a 90-minute podcast typically takes 1 to 1.5 hours to transcribe and separate all speakers.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }

                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "iphone.and.arrow.forward")
                                .font(.subheadline)
                                .foregroundColor(.green)
                                .frame(width: 20)
                            Text("You can tap Done, minimize the app, or listen to audio. Your computer will finish on its own and results will automatically appear when you return.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(PodcastTheme.cardBackground))
                }
                .padding(.vertical, 4)
            } else {
                Button {
                    triggerDiarization()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                        Text("Analyze Speakers with Computer (WhisperX)")
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(PodcastTheme.accent))
                }
                .buttonStyle(SpringButtonStyle())

                languageDetectionToggleCard
            }

            if let error = errorMessage {
                let isInfo = error.contains("background") || error.contains("continuing")
                HStack(spacing: 8) {
                    Image(systemName: isInfo ? "info.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(isInfo ? purpleAccent : .red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(isInfo ? .primary : .red)
                        .multilineTextAlignment(.leading)
                    Spacer()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(isInfo ? purpleAccent.opacity(0.12) : Color.red.opacity(0.12)))
            }

            VStack(spacing: 4) {
                Text("Computer Server: \(dataManager.settings.effectiveWhisperServerUrl)")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.8))
                Button {
                    showingSshSettings = true
                } label: {
                    Text("Configure SSH Remote Settings")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(purpleAccent)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16).fill(PodcastTheme.cardBackground))
    }

    // MARK: - Analyzed Overview

    private func statsOverviewCard(diarization: SpeakerDiarizationData) -> some View {
        let totalSpeakers = diarization.speakers.count
        let activeSkipsCount = diarization.speakers.filter { (optimisticSpeakerSkips[$0.id] ?? $0.isSkipped) }.count
        let totalSegments = diarization.segments.count

        return HStack(spacing: 12) {
            statBox(title: "SPEAKERS", value: "\(totalSpeakers)", color: purpleAccent)
            statBox(title: "SEGMENTS", value: "\(totalSegments)", color: .blue)
            statBox(title: "SKIPPED", value: "\(activeSkipsCount)", color: activeSkipsCount > 0 ? purpleAccent : .secondary)
        }
    }

    private func statBox(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(PodcastTheme.cardBackground))
    }

    // MARK: - Language Filtering Card (Glassmorphic)

    private func languageFilteringCard(diarization: SpeakerDiarizationData) -> some View {
        let isEnglishOnly = localFilterEnglishOnly ?? diarization.filterEnglishOnly ?? false
        let langSummary = languageBreakdownText(diarization: diarization)

        return VStack(spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(englishOnlyAccent.opacity(0.15))
                    Image(systemName: "globe.americas.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(englishOnlyAccent)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isEnglishOnly ? "English Only" : "Play English Only")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(isEnglishOnly ? "Skipping non-English audio segments" : "Automatically skip non-English audio segments")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Instant-Response English Only Switch with 54x44pt hit target
                Button {
                    let newVal = !isEnglishOnly
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) {
                        localFilterEnglishOnly = newVal
                    }
                    DispatchQueue.main.async {
                        dataManager.toggleFilterEnglishOnly(videoId: episode.videoId, explicitState: newVal)
                    }
                } label: {
                    ZStack {
                        Color.clear
                            .frame(width: 54, height: 44)

                        Capsule()
                            .fill(isEnglishOnly ? englishOnlyAccent : Color(.systemGray4))
                            .frame(width: 51, height: 31)

                        Circle()
                            .fill(Color.white)
                            .frame(width: 27, height: 27)
                            .shadow(color: Color.black.opacity(0.18), radius: 2.5, x: 0, y: 1.5)
                            .offset(x: isEnglishOnly ? 10 : -10)
                    }
                }
                .buttonStyle(PlainHitTargetButtonStyle())
                .contentShape(Rectangle())
            }

            if isEnglishOnly {
                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "slider.horizontal.below.rectangle")
                            .foregroundColor(englishOnlyAccent)
                        Text("LANGUAGE SKIP TIMING")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Language Skip Lead-In")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(String(format: "%.1f", dataManager.settings.languageSkipLeadIn))s earlier")
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundColor(englishOnlyAccent)
                        }

                        Slider(value: Binding(
                            get: { dataManager.settings.languageSkipLeadIn },
                            set: { newVal in
                                var newSettings = dataManager.settings
                                newSettings.languageSkipLeadIn = (newVal * 10).rounded() / 10
                                dataManager.saveSettings(newSettings)
                            }
                        ), in: 0.0...5.0, step: 0.1)
                        .tint(englishOnlyAccent)

                        Text("Cuts earlier before foreign language speech starts so you never hear opening words.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.8))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Language Skip Trailing")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(String(format: "%.1f", dataManager.settings.languageSkipTrail))s extra")
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundColor(englishOnlyAccent)
                        }

                        Slider(value: Binding(
                            get: { dataManager.settings.languageSkipTrail },
                            set: { newVal in
                                var newSettings = dataManager.settings
                                newSettings.languageSkipTrail = (newVal * 10).rounded() / 10
                                dataManager.saveSettings(newSettings)
                            }
                        ), in: 0.0...5.0, step: 0.1)
                        .tint(englishOnlyAccent)

                        Text("Extends skip past the end of foreign speech before resuming English.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                }
            }

            if !langSummary.isEmpty {
                Divider()

                HStack(spacing: 6) {
                    Image(systemName: "waveform.and.magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(englishOnlyAccent)
                    Text("Languages: \(langSummary)")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(PodcastTheme.cardBackground)
        )
    }

    private func languageBreakdownText(diarization: SpeakerDiarizationData) -> String {
        var durationByLang: [String: Double] = [:]
        for seg in diarization.segments {
            let lang = (seg.language ?? "en").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let dur = max(0.0, seg.end - seg.start)
            durationByLang[lang] = (durationByLang[lang] ?? 0.0) + dur
        }
        let total = durationByLang.values.reduce(0.0, +)
        guard total > 0 else {
            if let langs = diarization.detectedLanguages, !langs.isEmpty {
                return langs.map { displayName(for: $0) }.joined(separator: ", ")
            }
            return ""
        }

        let sorted = durationByLang.sorted { $0.value > $1.value }
        let parts = sorted.compactMap { (code, dur) -> String? in
            let pct = Int(round((dur / total) * 100))
            if pct < 1 && dur < 5.0 { return nil }
            return "\(displayName(for: code)) \(pct)%"
        }
        return parts.joined(separator: ", ")
    }

    private func displayName(for langCode: String) -> String {
        let code = langCode.lowercased()
        switch code {
        case "en": return "English"
        case "es": return "Spanish"
        case "fr": return "French"
        case "de": return "German"
        case "it": return "Italian"
        case "pt": return "Portuguese"
        case "ja": return "Japanese"
        case "zh": return "Chinese"
        case "ru": return "Russian"
        case "ar": return "Arabic"
        case "hi": return "Hindi"
        case "ko": return "Korean"
        case "nl": return "Dutch"
        case "pl": return "Polish"
        case "tr": return "Turkish"
        case "uk": return "Ukrainian"
        case "vi": return "Vietnamese"
        default:
            let locale = Locale(identifier: "en_US")
            return locale.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
        }
    }

    // MARK: - Skip Timing Padding Controls

    private var paddingControlsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "slider.horizontal.2.square.fill")
                    .foregroundColor(purpleAccent)
                Text("CLIP PADDING & TIMING")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Skip Start Buffer (Lead-In)")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(String(format: "%.1f", dataManager.settings.speakerSkipLeadIn))s earlier")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundColor(purpleAccent)
                }

                Slider(value: Binding(
                    get: { dataManager.settings.speakerSkipLeadIn },
                    set: { newVal in
                        var newSettings = dataManager.settings
                        newSettings.speakerSkipLeadIn = (newVal * 10).rounded() / 10
                        dataManager.saveSettings(newSettings)
                    }
                ), in: 0.0...5.0, step: 0.1)
                .tint(purpleAccent)

                Text("Cuts earlier before speech starts so you never hear opening words.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.8))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Skip End Buffer (Trailing)")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(String(format: "%.1f", dataManager.settings.speakerSkipTrail))s extra")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundColor(purpleAccent)
                }

                Slider(value: Binding(
                    get: { dataManager.settings.speakerSkipTrail },
                    set: { newVal in
                        var newSettings = dataManager.settings
                        newSettings.speakerSkipTrail = (newVal * 10).rounded() / 10
                        dataManager.saveSettings(newSettings)
                    }
                ), in: 0.0...5.0, step: 0.1)
                .tint(purpleAccent)

                Text("Extends skip past the end to remove trailing words or exhales.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.8))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(PodcastTheme.cardBackground))
    }

    // MARK: - Speakers Section

    private func speakersSection(diarization: SpeakerDiarizationData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DETECTED SPEAKERS (\(diarization.speakers.count))")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)

            ForEach(diarization.speakers) { speaker in
                speakerRow(speaker: speaker, totalDuration: episode.duration)
            }
        }
    }

    private func speakerRow(speaker: SpeakerProfile, totalDuration: Double) -> some View {
        let percentage = totalDuration > 0 ? (speaker.totalDuration / totalDuration) * 100 : 0
        let isSkipped = optimisticSpeakerSkips[speaker.id] ?? speaker.isSkipped
        let isSamplingThisSpeaker = player.isSamplingSpeaker && player.activeSamplingSpeakerId == speaker.id

        return HStack(spacing: 12) {
            // Tappable rename trigger (Avatar + Name + Talking sample text + Duration)
            Button {
                renamingSpeakerId = speaker.id
                renamingSpeakerName = speaker.name
                showingRenameAlert = true
            } label: {
                HStack(spacing: 12) {
                    // Speaker Avatar Icon
                    ZStack {
                        Circle()
                            .fill(isSkipped ? purpleAccent.opacity(0.22) : Color(.systemFill))
                            .frame(width: 42, height: 42)
                        Image(systemName: isSkipped ? "person.fill.xmark" : "person.fill")
                            .font(.system(size: 18))
                            .foregroundColor(isSkipped ? purpleAccent : .secondary)
                    }

                    // Name & Speaking Duration
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(speaker.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(isSkipped ? purpleAccent : .primary)

                            Image(systemName: "pencil")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        if let sampleText = speaker.sampleText, !sampleText.isEmpty {
                            Text("\"\(sampleText)\"")
                                .font(.caption2)
                                .italic()
                                .foregroundColor(.secondary.opacity(0.9))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }

                        HStack(spacing: 6) {
                            Text(formatDuration(speaker.totalDuration))
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)

                            Text("(\(Int(percentage))%)")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color(.tertiarySystemFill)))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(BorderlessButtonStyle())

            Spacer()

            // Voice Sample Audition Button (Isolated Speaker Sampling)
            if let diarization = currentDiarization, !diarization.segments.filter({ $0.speakerId == speaker.id }).isEmpty {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if isSamplingThisSpeaker {
                        player.stopSpeakerSampling()
                    } else {
                        player.startSpeakerSampling(
                            for: currentEpisode,
                            speakerId: speaker.id,
                            diarization: diarization,
                            maxSpeechDuration: 15.0
                        )
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: isSamplingThisSpeaker ? "stop.circle.fill" : "play.circle.fill")
                            .font(.caption)
                        Text(isSamplingThisSpeaker ? "Playing" : "Sample")
                            .font(.caption2.weight(.bold))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(isSamplingThisSpeaker ? purpleAccent : purpleAccent.opacity(0.14)))
                    .foregroundColor(isSamplingThisSpeaker ? .white : purpleAccent)
                }
                .buttonStyle(BorderlessButtonStyle())
            }

            // Instant-Response Speaker Skip Switch with 54x44pt hit target
            Button {
                let current = optimisticSpeakerSkips[speaker.id] ?? speaker.isSkipped
                let newVal = !current
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) {
                    optimisticSpeakerSkips[speaker.id] = newVal
                }
                DispatchQueue.main.async {
                    dataManager.toggleSpeakerSkip(videoId: episode.videoId, speakerId: speaker.id, explicitState: newVal)
                }
            } label: {
                ZStack {
                    // Expanded touch frame (54x44pt) ensuring comfortable touch target
                    Color.clear
                        .frame(width: 54, height: 44)

                    // iOS-native styled toggle track
                    Capsule()
                        .fill(isSkipped ? purpleAccent : Color(.systemGray4))
                        .frame(width: 51, height: 31)

                    // iOS-native styled sliding thumb with elevation shadow
                    Circle()
                        .fill(Color.white)
                        .frame(width: 27, height: 27)
                        .shadow(color: Color.black.opacity(0.18), radius: 2.5, x: 0, y: 1.5)
                        .offset(x: isSkipped ? 10 : -10)
                }
            }
            .buttonStyle(PlainHitTargetButtonStyle())
            .contentShape(Rectangle())
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(PodcastTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isSkipped ? purpleAccent.opacity(0.6) : Color.clear, lineWidth: 1.5)
                )
        )
    }

    // MARK: - Custom Speaker Rename Modal

    @ViewBuilder
    private var renameSpeakerOverlay: some View {
        if showingRenameAlert {
            ZStack {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isRenameFieldFocused = false
                            showingRenameAlert = false
                        }
                    }

                VStack(spacing: 16) {
                    VStack(spacing: 6) {
                        Text("Rename Speaker")
                            .font(.headline.weight(.bold))
                            .foregroundColor(.primary)

                        Text("Enter a custom name or role for this speaker.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    TextField("Speaker Name", text: $renamingSpeakerName)
                        .font(.body)
                        .focused($isRenameFieldFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(.secondarySystemBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(PodcastTheme.accent.opacity(0.4), lineWidth: 1)
                        )
                        .autocorrectionDisabled(true)

                    HStack(spacing: 12) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isRenameFieldFocused = false
                                showingRenameAlert = false
                            }
                        } label: {
                            Text("Cancel")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color(.secondarySystemBackground))
                                )
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(PlainButtonStyle())

                        Button {
                            if let spkId = renamingSpeakerId {
                                dataManager.renameSpeaker(videoId: episode.videoId, speakerId: spkId, newName: renamingSpeakerName)
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isRenameFieldFocused = false
                                showingRenameAlert = false
                            }
                        } label: {
                            Text("Save")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(PodcastTheme.accent)
                                )
                                .foregroundColor(.white)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(.systemBackground))
                        .shadow(color: Color.black.opacity(0.25), radius: 24, x: 0, y: 10)
                )
                .padding(.horizontal, 36)
            }
            .transition(.opacity)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isRenameFieldFocused = true
                }
            }
        }
    }

    // MARK: - Management Actions

    private var managementActionsCard: some View {
        VStack(spacing: 12) {
            if isAnalyzing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else {
                languageDetectionToggleCard

                HStack(spacing: 12) {
                    Button {
                        showingReanalyzeConfirmation = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text("Re-analyze Audio")
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(PodcastTheme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(PodcastTheme.accent.opacity(0.12)))
                    }
                    .buttonStyle(SpringButtonStyle())

                    Button {
                        showingClearConfirmation = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                            Text("Clear")
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.12)))
                    }
                    .buttonStyle(SpringButtonStyle())
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(PodcastTheme.cardBackground))
    }

    // MARK: - Remote SSH Server Actions

    private func startRemoteServer() {
        isSshActionActive = true
        sshActionStatus = "Starting..."
        errorMessage = nil

        dataManager.startRemoteWhisperXServer(
            progressHandler: { step in
                DispatchQueue.main.async {
                    self.sshActionStatus = step
                }
            },
            completion: { result in
                DispatchQueue.main.async {
                    self.isSshActionActive = false
                    switch result {
                    case .success:
                        self.isServerOnline = true
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    case .failure(let err):
                        self.errorMessage = err.localizedDescription
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                    }
                }
            }
        )
    }

    private func stopRemoteServer() {
        dataManager.stopRemoteWhisperXServer { result in
            DispatchQueue.main.async {
                self.isServerOnline = false
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }

    // MARK: - Diarization Action

    private func triggerDiarization(force: Bool = false) {
        isAnalyzing = true
        errorMessage = nil
        statusMessage = "Connecting to Computer WhisperX service..."

        dataManager.sendForDiarization(
            episode: episode,
            force: force,
            progressHandler: { msg in
                DispatchQueue.main.async {
                    self.statusMessage = msg
                }
            },
            completion: { result in
                DispatchQueue.main.async {
                    self.isAnalyzing = false
                    switch result {
                    case .success:
                        self.statusMessage = "Diarization complete!"
                        self.isServerOnline = true
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    case .failure(let err):
                        self.errorMessage = err.localizedDescription
                        self.checkServerHealth()
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                    }
                }
            }
        )
    }

    // MARK: - Helpers

    private func formatTimestamp(_ t: Double) -> String {
        guard t.isFinite && t >= 0 else { return "00:00.0" }
        let totalSeconds = Int(t)
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        let tenths = Int((t - Double(totalSeconds)) * 10)
        return String(format: "%02d:%02d.%d", m, s, tenths)
    }

    private func formatDuration(_ t: Double) -> String {
        guard t.isFinite && t >= 0 else { return "0s" }
        let totalSeconds = Int(t)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "%dh %02dm", h, m)
        } else if m > 0 {
            return String(format: "%dm %02ds", m, s)
        } else {
            return String(format: "%ds", s)
        }
    }

    // MARK: - Language Toggle & Transcript Inspector Cards

    private var languageDetectionToggleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { dataManager.settings.detectLanguagesDuringDiarization },
                set: { val in
                    var s = dataManager.settings
                    s.detectLanguagesDuringDiarization = val
                    dataManager.saveSettings(s)
                }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: "globe.badge.chevron.backward")
                        .foregroundColor(englishOnlyAccent)
                        .font(.system(size: 15, weight: .semibold))
                    Text("Detect Spoken Languages")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                }
            }
            .tint(englishOnlyAccent)

            Text("Scans audio for non-English speech. Keep off for fastest speaker analysis (~10x faster).")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground).opacity(0.7)))
    }

    private func transcriptInspectorCard(diarization: SpeakerDiarizationData) -> some View {
        let activeSeg = diarization.segments.first(where: { player.currentTime >= $0.start && player.currentTime < $0.end })
        let nonEnCount = diarization.segments.filter { ($0.language ?? "en").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "en" }.count

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "text.magnifyingglass")
                    .foregroundColor(PodcastTheme.accent)
                Text("TRANSCRIPT & SEGMENT INSPECTOR")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    showingSegmentInspector = true
                } label: {
                    HStack(spacing: 4) {
                        Text("View All (\(diarization.segments.count))")
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(PodcastTheme.accent)
                }
            }

            // Live active segment preview
            if let active = activeSeg {
                let spkName = diarization.speakers.first(where: { $0.id == active.speakerId })?.name ?? active.speakerId
                let lang = (active.language ?? "en").uppercased()
                let isNonEn = lang != "EN"

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)

                        Text("ACTIVE NOW: \(spkName)")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.primary)

                        Text("[\(lang)]")
                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(isNonEn ? Color.blue.opacity(0.2) : Color.green.opacity(0.2)))
                            .foregroundColor(isNonEn ? Color(red: 0.20, green: 0.65, blue: 1.0) : .green)

                        Spacer()

                        Text("\(formatTimestamp(active.start)) - \(formatTimestamp(active.end))")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                    }

                    let isNonEn = (active.language ?? "en").lowercased() != "en"
                    if let text = active.text, !text.isEmpty {
                        Text("\"\(text)\"")
                            .font(.caption)
                            .italic()
                            .foregroundColor(.primary.opacity(0.9))
                            .lineLimit(2)
                    } else if isNonEn {
                        Text("\"[\(lang) Speech]\"")
                            .font(.caption)
                            .italic()
                            .foregroundColor(.primary.opacity(0.9))
                            .lineLimit(2)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.12)))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.1")
                        .foregroundColor(.secondary)
                    Text("No speech segment at current playback (\(formatTimestamp(player.currentTime)))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(8)
            }

            // Inspector summary pill
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("\(diarization.segments.count)")
                        .font(.caption.weight(.bold))
                    Text("Total Segments")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if nonEnCount > 0 {
                    HStack(spacing: 4) {
                        Text("\(nonEnCount)")
                            .font(.caption.weight(.bold))
                            .foregroundColor(Color(red: 0.20, green: 0.65, blue: 1.0))
                        Text("Non-English")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button {
                    showingSegmentInspector = true
                } label: {
                    Text("Inspect Timeline")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(PodcastTheme.accent))
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(PodcastTheme.cardBackground))
    }
}

// MARK: - Transcript & Segment Inspector Sheet

struct SegmentInspectorSheet: View {
    let diarization: SpeakerDiarizationData
    let episode: PodcastEpisode
    @Binding var isPresented: Bool
    @ObservedObject var player = PodcastPlayer.shared
    @State private var searchText = ""
    @State private var filterNonEnglishOnly = false
    @State private var selectedSpeakerId: String? = nil

    private var filteredSegments: [SpeakerSegment] {
        var list = diarization.segments.sorted { $0.start < $1.start }
        if filterNonEnglishOnly {
            list = list.filter { ($0.language ?? "en").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "en" }
        }
        if let spkId = selectedSpeakerId {
            list = list.filter { $0.speakerId == spkId }
        }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let q = searchText.lowercased()
            list = list.filter { ($0.text ?? "").lowercased().contains(q) }
        }
        return list
    }

    private func speakerName(for id: String) -> String {
        diarization.speakers.first(where: { $0.id == id })?.name ?? id
    }

    private func formatTimestamp(_ t: Double) -> String {
        guard t.isFinite && t >= 0 else { return "00:00.0" }
        let totalSeconds = Int(t)
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        let tenths = Int((t - Double(totalSeconds)) * 10)
        return String(format: "%02d:%02d.%d", m, s, tenths)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Filters
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search spoken words...", text: $searchText)
                            .font(.subheadline)
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)

                    HStack(spacing: 8) {
                        Button {
                            filterNonEnglishOnly.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: filterNonEnglishOnly ? "checkmark.circle.fill" : "circle")
                                Text("Non-English Only")
                            }
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(filterNonEnglishOnly ? Color.blue.opacity(0.2) : Color(.systemGray6))
                            .foregroundColor(filterNonEnglishOnly ? .blue : .primary)
                            .cornerRadius(8)
                        }

                        if !diarization.speakers.isEmpty {
                            Menu {
                                Button("All Speakers") { selectedSpeakerId = nil }
                                ForEach(diarization.speakers) { spk in
                                    Button(spk.name) { selectedSpeakerId = spk.id }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(selectedSpeakerId == nil ? "All Speakers" : speakerName(for: selectedSpeakerId!))
                                    Image(systemName: "chevron.down")
                                }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(selectedSpeakerId != nil ? Color.purple.opacity(0.2) : Color(.systemGray6))
                                .foregroundColor(selectedSpeakerId != nil ? Color(red: 0.72, green: 0.35, blue: 0.98) : .primary)
                                .cornerRadius(8)
                            }
                        }

                        Spacer()

                        Text("\(filteredSegments.count) segments")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))

                // Segment List
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredSegments) { seg in
                            let isActive = player.currentTime >= seg.start && player.currentTime < seg.end
                            let lang = (seg.language ?? "en").uppercased()
                            let isNonEn = lang != "EN"

                            HStack(alignment: .top, spacing: 10) {
                                VStack(spacing: 8) {
                                    Button {
                                        player.seek(to: seg.start)
                                        if !player.isPlaying { player.resume() }
                                    } label: {
                                        Image(systemName: isActive && player.isPlaying ? "waveform.circle.fill" : "play.circle.fill")
                                            .font(.system(size: 24))
                                            .foregroundColor(isActive ? .green : (isNonEn ? .blue : .secondary))
                                    }
                                    .buttonStyle(PlainButtonStyle())

                                    Button {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        let target = max(0.0, seg.start - 3.0)
                                        player.seek(to: target)
                                        if !player.isPlaying { player.resume() }
                                    } label: {
                                        HStack(spacing: 2) {
                                            Image(systemName: "gobackward.minus")
                                                .font(.system(size: 8, weight: .bold))
                                            Text("-3s")
                                                .font(.system(size: 9, weight: .bold))
                                        }
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                                        .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                                .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(speakerName(for: seg.speakerId))
                                            .font(.caption.weight(.bold))
                                            .foregroundColor(.primary)

                                        Text("[\(lang)]")
                                            .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(RoundedRectangle(cornerRadius: 3).fill(isNonEn ? Color.blue.opacity(0.2) : Color.green.opacity(0.18)))
                                            .foregroundColor(isNonEn ? Color(red: 0.20, green: 0.65, blue: 1.0) : .green)

                                        Spacer()

                                        if isActive {
                                            Text("PLAYING")
                                                .font(.system(size: 9, weight: .black))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(Color.green))
                                                .foregroundColor(.white)
                                        }

                                        Text("\(formatTimestamp(seg.start)) - \(formatTimestamp(seg.end))")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundColor(.secondary)
                                    }

                                    let isSegNonEn = (seg.language ?? "en").lowercased() != "en"
                                    if let text = seg.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text(text)
                                            .font(.footnote)
                                            .foregroundColor(.primary)
                                            .multilineTextAlignment(.leading)
                                    } else if isSegNonEn {
                                        Text("[\(lang) Speech]")
                                            .font(.caption2)
                                            .italic()
                                            .foregroundColor(Color(red: 0.20, green: 0.65, blue: 1.0))
                                    } else {
                                        Text("(Acoustic speech turn - no words transcribed)")
                                            .font(.caption2)
                                            .italic()
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(isActive ? Color.green.opacity(0.1) : Color(.secondarySystemGroupedBackground))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(isActive ? Color.green.opacity(0.6) : (isNonEn ? Color.blue.opacity(0.3) : Color.clear), lineWidth: 1.5)
                                    )
                            )
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Transcript Inspector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
    }
}

// MARK: - SSH Computer Settings Sheet

struct SSHComputerSettingsSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var dataManager = DataManager.shared

    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var user: String = ""
    @State private var password: String = ""
    @State private var whisperXPath: String = ""
    @State private var whisperServerUrl: String = ""

    @State private var isTesting = false
    @State private var testResult: String? = nil
    @State private var isTestSuccess = false

    private let purpleAccent = Color(red: 0.72, green: 0.35, blue: 0.98)

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Computer SSH Host & Login"), footer: Text("Allows PodcastThis to start the WhisperX service on your computer over your local network.")) {
                    HStack {
                        Text("IP / Host")
                            .font(.subheadline)
                            .frame(width: 80, alignment: .leading)
                        TextField("192.168.1.100", text: $host)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.subheadline.monospaced())
                    }

                    HStack {
                        Text("Port")
                            .font(.subheadline)
                            .frame(width: 80, alignment: .leading)
                        TextField("22", text: $port)
                            .keyboardType(.numberPad)
                            .font(.subheadline.monospaced())
                    }

                    HStack {
                        Text("Username")
                            .font(.subheadline)
                            .frame(width: 80, alignment: .leading)
                        TextField("username", text: $user)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.subheadline)
                    }

                    HStack {
                        Text("Password")
                            .font(.subheadline)
                            .frame(width: 80, alignment: .leading)
                        SecureField("SSH password", text: $password)
                            .font(.subheadline)
                    }
                }

                Section(header: Text("Service Paths"), footer: Text("Location of whisperx-service directory and the HTTP endpoint.")) {
                    HStack {
                        Text("Path")
                            .font(.subheadline)
                            .frame(width: 80, alignment: .leading)
                        TextField("~/podcast-this/services/whisperx-service", text: $whisperXPath)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.caption.monospaced())

                        Button {
                            if let str = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
                                whisperXPath = str
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .font(.footnote)
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }

                    HStack {
                        Text("HTTP URL")
                            .font(.subheadline)
                            .frame(width: 80, alignment: .leading)
                        TextField("http://192.168.1.100:8000", text: $whisperServerUrl)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.caption.monospaced())
                    }
                }

                Section {
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .padding(.trailing, 6)
                                Text("Connecting...")
                            } else {
                                Image(systemName: "terminal.fill")
                                Text("Test SSH Connection")
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(purpleAccent)
                    }
                    .disabled(isTesting)

                    if let result = testResult {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: isTestSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundColor(isTestSuccess ? .green : .red)
                            Text(result)
                                .font(.caption)
                                .foregroundColor(isTestSuccess ? .primary : .red)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Computer SSH Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveAndDismiss()
                    }
                    .font(.headline.weight(.bold))
                    .foregroundColor(PodcastTheme.accent)
                }
            }
            .onAppear {
                loadCurrentSettings()
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func loadCurrentSettings() {
        let s = dataManager.settings
        host = s.computerSshHost
        port = "\(s.computerSshPort)"
        user = s.computerSshUser
        password = s.computerSshPassword
        whisperXPath = s.computerWhisperXPath.isEmpty ? "~/podcast-this/services/whisperx-service" : s.computerWhisperXPath
        let rawUrl = s.whisperServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if (rawUrl.isEmpty || rawUrl == "http://192.168.1.100:8000") && !s.computerSshHost.isEmpty {
            whisperServerUrl = "http://\(s.computerSshHost):8000"
        } else {
            whisperServerUrl = s.whisperServerUrl
        }
    }

    private func saveAndDismiss() {
        var s = dataManager.settings
        s.computerSshHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        s.computerSshPort = Int(port) ?? 22
        s.computerSshUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        s.computerSshPassword = password
        s.computerWhisperXPath = whisperXPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUrl = whisperServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.computerSshHost.isEmpty && (trimmedUrl.isEmpty || trimmedUrl == "http://192.168.1.100:8000") {
            s.whisperServerUrl = "http://\(s.computerSshHost):8000"
        } else if !trimmedUrl.isEmpty {
            s.whisperServerUrl = trimmedUrl
        } else if !s.computerSshHost.isEmpty {
            s.whisperServerUrl = "http://\(s.computerSshHost):8000"
        }
        dataManager.saveSettings(s)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isPresented = false
    }

    private func testConnection() {
        saveCurrentDraft()
        isTesting = true
        testResult = nil

        dataManager.testSshConnection { result in
            isTesting = false
            switch result {
            case .success(let output):
                isTestSuccess = true
                testResult = "SSH Connected! " + output.trimmingCharacters(in: .whitespacesAndNewlines)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .failure(let err):
                isTestSuccess = false
                testResult = err.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func saveCurrentDraft() {
        var s = dataManager.settings
        s.computerSshHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        s.computerSshPort = Int(port) ?? 22
        s.computerSshUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        s.computerSshPassword = password
        s.computerWhisperXPath = whisperXPath.trimmingCharacters(in: .whitespacesAndNewlines)
        dataManager.saveSettings(s)
    }
}

fileprivate struct PlainHitTargetButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
