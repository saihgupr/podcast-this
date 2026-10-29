import SwiftUI
import AVFoundation

// MARK: - Full Screen Player

struct FullPlayerView: View {
    @ObservedObject var player = PodcastPlayer.shared
    @ObservedObject var dataManager = DataManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var artwork: UIImage? = nil
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    @State private var showSkipEditor = false
    @State private var showSpeakerSettings = false
    @State private var showSegmentInspector = false
    @State private var showDebugHUD = false
    private let enableDebugHUDButton = false // Set to true to re-enable the debug HUD toggle button in the player

    private var episodeSkips: [UserCustomSkip] {
        if let videoId = player.currentEpisode?.videoId {
            for show in dataManager.shows {
                if let ep = show.episodes.first(where: { $0.videoId == videoId }) {
                    return ep.customSkips ?? []
                }
            }
        }
        return player.currentEpisode?.customSkips ?? []
    }

    private var currentSpeakerDiarization: SpeakerDiarizationData? {
        if let videoId = player.currentEpisode?.videoId {
            for show in dataManager.shows {
                if let ep = show.episodes.first(where: { $0.videoId == videoId }) {
                    if let d = ep.speakerDiarization {
                        return d
                    }
                }
            }
        }
        return player.currentEpisode?.speakerDiarization
    }

    private var skippedSpeakerSegments: [SpeakerSegment] {
        return player.getMergedSpeakerSkipRegions()
    }

    private var isSilenceRemovalEnabled: Bool {
        if let videoId = player.currentEpisode?.videoId {
            for show in dataManager.shows {
                if let ep = show.episodes.first(where: { $0.videoId == videoId }) {
                    return ep.removeSilence
                }
            }
        }
        return player.currentEpisode?.removeSilence ?? false
    }

    private var silenceSkipRegions: [(start: Double, end: Double)] {
        guard isSilenceRemovalEnabled else { return [] }
        return player.getSilenceSkipIntervals()
    }

    // Compute sizes from actual screen width — no GeometryReader needed
    private let screenWidth = UIScreen.main.bounds.width
    private var artSize: CGFloat { screenWidth - 88 }
    private var scrubWidth: CGFloat { screenWidth - 56 }

    var displayTime: Double { isScrubbing ? scrubTime : player.currentTime }
    var remaining: Double { max(player.duration - displayTime, 0) }

    var body: some View {
        ZStack {
            // === Blurred Background — full screen ===
            artworkBackground

            // === Scrollable content column, pinned center ===
            VStack(spacing: 0) {
                handleBar
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        artworkCard
                            .padding(.top, 24)
                            .padding(.bottom, 28)

                        episodeInfo
                            .padding(.bottom, (currentSpeakerDiarization?.speakers.isEmpty == false) ? 14 : 24)

                        if let diarization = currentSpeakerDiarization, !diarization.speakers.isEmpty {
                            activeSpeakerBar(diarization: diarization)
                                .padding(.bottom, showDebugHUD ? 10 : 20)

                            if showDebugHUD {
                                playbackDebugHUD(diarization: diarization)
                                    .padding(.bottom, 20)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }

                        scrubBar
                            .padding(.bottom, 28)

                        mainControls
                            .padding(.bottom, 20)

                        secondaryControls
                            .padding(.bottom, DataManager.shared.settings.enableBalanceSlider ? 24 : 40)

                        if DataManager.shared.settings.enableBalanceSlider {
                            panBar
                                .padding(.bottom, 40)
                        }
                    }
                    .padding(.horizontal, 32)
                    .frame(width: screenWidth) // anchor everything to screen width
                }
            }
            .frame(width: screenWidth) // ensure VStack never exceeds screen width
        }
        .frame(width: screenWidth, alignment: .center)
        .interactiveDismissDisabled(false)
        .onAppear { loadArt() }
        .onChange(of: player.currentEpisode) { _ in loadArt() }
        .sheet(isPresented: $showSkipEditor) {
            if let ep = player.currentEpisode {
                SkipEditorView(episode: ep)
            }
        }
        .sheet(isPresented: $showSpeakerSettings) {
            if let ep = player.currentEpisode {
                SpeakerSkipView(episode: ep)
            }
        }
        .sheet(isPresented: $showSegmentInspector) {
            if let ep = player.currentEpisode, let diarization = currentSpeakerDiarization {
                SegmentInspectorSheet(diarization: diarization, episode: ep, isPresented: $showSegmentInspector)
            }
        }
    }

    // MARK: - Background

    private var artworkBackground: some View {
        ZStack {
            if let img = artwork {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: screenWidth, height: UIScreen.main.bounds.height)
                    .blur(radius: 55)
                    .opacity(0.45)
                    .clipped()
            }
            Color(.systemBackground)
                .opacity(artwork == nil ? 1.0 : 0.58)
        }
        .frame(width: screenWidth, height: UIScreen.main.bounds.height)
        .ignoresSafeArea()
    }

    // MARK: - Handle bar

    private var handleBar: some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 36, height: 5)
    }

    // MARK: - Artwork Card

    private var artworkCard: some View {
        Group {
            if let img = artwork {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: artSize, height: artSize)
                    .cornerRadius(artSize * 0.08)
                    .shadow(color: .black.opacity(0.35), radius: 22, x: 0, y: 10)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: artSize * 0.08)
                        .fill(PodcastTheme.accentGradient)
                    Image(systemName: "waveform")
                        .font(.system(size: artSize * 0.28, weight: .ultraLight))
                        .foregroundColor(.white.opacity(0.8))
                }
                .frame(width: artSize, height: artSize)
                .shadow(color: .black.opacity(0.3), radius: 22, x: 0, y: 10)
            }
        }
        .scaleEffect(player.isPlaying ? 1.0 : 0.88)
        .animation(.spring(response: 0.45, dampingFraction: 0.65), value: player.isPlaying)
    }

    // MARK: - Episode Info

    private var episodeInfo: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(player.currentEpisode?.title ?? "Not Playing")
                    .font(.title3).fontWeight(.bold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(player.currentEpisode?.channel ?? "")
                    .font(.subheadline)
                    .foregroundColor(PodcastTheme.accent)
                    .lineLimit(1)
            }
            .frame(minHeight: 74, alignment: .topLeading)

            Spacer()
        }
    }

    // MARK: - Scrub Bar (fixed width, no nested GeometryReader)

    private var scrubBar: some View {
        let progress = player.duration > 0 ? CGFloat(displayTime / player.duration) : 0
        return VStack(spacing: 8) {
            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color(.systemFill))
                    .frame(width: scrubWidth, height: 4)

                // Filled
                Capsule()
                    .fill(PodcastTheme.accent)
                    .frame(width: max(0, scrubWidth * progress), height: 4)

                // SponsorBlock Segments Overlay
                if dataManager.settings.sponsorBlockEnabled,
                   let segments = player.currentEpisode?.segments ?? (player.currentEpisode.flatMap { dataManager.findEpisode(videoId: $0.videoId)?.segments }),
                   player.duration > 0 {
                    ForEach(segments, id: \.self) { segment in
                        if dataManager.settings.sponsorBlockCategories.contains(segment.category) {
                            let startFrac = CGFloat(segment.start / player.duration)
                            let endFrac = CGFloat(segment.end / player.duration)
                            let w = max(2, scrubWidth * (endFrac - startFrac))
                            let off = scrubWidth * startFrac
                            
                            Rectangle()
                                .fill(categoryColor(for: segment.category))
                                .frame(width: w, height: 6)
                                .offset(x: off)
                        }
                    }
                }

                // Silence Removal Skips Overlay (Teal / Blue)
                if isSilenceRemovalEnabled, player.duration > 0 {
                    ForEach(silenceSkipRegions.indices, id: \.self) { idx in
                        let seg = silenceSkipRegions[idx]
                        let startFrac = CGFloat(seg.start / player.duration)
                        let endFrac = CGFloat(seg.end / player.duration)
                        let w = max(2, scrubWidth * (endFrac - startFrac))
                        let off = scrubWidth * startFrac

                        Rectangle()
                            .fill(Color(red: 0.18, green: 0.80, blue: 0.75).opacity(0.85))
                            .frame(width: w, height: 4)
                            .offset(x: off)
                    }
                }

                // Speaker-Specific Skips Overlay (Royal Purple) & English Only Skips (Electric Blue)
                if player.duration > 0 {
                    ForEach(skippedSpeakerSegments, id: \.self) { seg in
                        let startFrac = CGFloat(seg.start / player.duration)
                        let endFrac = CGFloat(seg.end / player.duration)
                        let w = max(3, scrubWidth * (endFrac - startFrac))
                        let off = scrubWidth * startFrac

                        let isSegNonEn = ((seg.language ?? "en").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "en")
                        let segColor = isSegNonEn ? Color(red: 0.20, green: 0.65, blue: 1.0) : Color(red: 0.72, green: 0.35, blue: 0.98)

                        Capsule()
                            .fill(segColor.opacity(0.95))
                            .frame(width: w, height: 6)
                            .offset(x: off)
                    }
                }

                // Custom User Skips Overlay (Vibrant Golden Amber)
                if dataManager.settings.userSkipsEnabled,
                   player.duration > 0 {
                    ForEach(episodeSkips) { skip in
                        let startFrac = CGFloat(skip.start / player.duration)
                        let endFrac = CGFloat(skip.end / player.duration)
                        let w = max(3, scrubWidth * (endFrac - startFrac))
                        let off = scrubWidth * startFrac

                        Capsule()
                            .fill(Color(red: 1.0, green: 0.72, blue: 0.0).opacity(skip.isEnabled ? 0.95 : 0.4))
                            .frame(width: w, height: 6)
                            .offset(x: off)
                    }
                }

                // Thumb
                Circle()
                    .fill(Color.primary)
                    .frame(width: 16, height: 16)
                    .shadow(radius: 2)
                    .offset(x: max(0, scrubWidth * progress - 8))
            }
            .frame(width: scrubWidth, height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        isScrubbing = true
                        let fraction = min(max(val.location.x / scrubWidth, 0), 1)
                        scrubTime = Double(fraction) * player.duration
                    }
                    .onEnded { _ in
                        player.seek(to: scrubTime)
                        isScrubbing = false
                    }
            )

            HStack {
                Text(formatTime(displayTime))
                Spacer()
                Text("-" + formatTime(remaining))
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .monospacedDigit()
            .frame(width: scrubWidth)
        }
    }

    // MARK: - Main Controls

    private var mainControls: some View {
        HStack {
            Group {
                Spacer()

                // Previous Button
                Button { player.playPreviousEpisode() } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(SpringButtonStyle())

                Spacer()

                // Skip Backward
                Button { player.skipBackward() } label: {
                    Image(systemName: "gobackward.\(Int(DataManager.shared.settings.skipDuration))")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(SpringButtonStyle())

                Spacer()
            }

            // Play/Pause
            Button { player.togglePlay() } label: {
                ZStack {
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 72, height: 72)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28))
                        .foregroundColor(Color(.systemBackground))
                        .offset(x: player.isPlaying ? 0 : 2)
                }
            }
            .buttonStyle(SpringButtonStyle())

            Group {
                Spacer()

                // Skip Forward
                Button { player.skipForward() } label: {
                    Image(systemName: "goforward.\(Int(DataManager.shared.settings.skipDuration))")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(SpringButtonStyle())

                Spacer()

                // Next Button
                Button { player.playNextEpisode(force: true) } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(SpringButtonStyle())

                Spacer()
            }
        }
    }

    // MARK: - Secondary Controls

    private var secondaryControls: some View {
        HStack(spacing: 16) {
            Spacer()

            // Scissors / Custom Skips Button
            Button {
                showSkipEditor = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "scissors")
                        .font(.footnote.weight(.semibold))
                    let skipCount = episodeSkips.count
                    if skipCount > 0 {
                        Text("\(skipCount)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(red: 1.0, green: 0.72, blue: 0.0)))
                            .foregroundColor(.black)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.primary.opacity(0.1)))
                .foregroundColor(.primary)
            }
            .buttonStyle(SpringButtonStyle())

            // Speaker Diarization Sheet Button
            if let diarization = currentSpeakerDiarization, !diarization.speakers.isEmpty {
                Button {
                    showSpeakerSettings = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.wave.2.fill")
                            .font(.footnote.weight(.semibold))
                        let skippedCount = diarization.speakers.filter { $0.isSkipped }.count
                        if skippedCount > 0 {
                            Text("\(skippedCount)")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color(red: 0.72, green: 0.35, blue: 0.98)))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .foregroundColor(diarization.speakers.contains(where: { $0.isSkipped }) ? Color(red: 0.72, green: 0.35, blue: 0.98) : .primary)
                }
                .buttonStyle(SpringButtonStyle())
            }

            // Playback Rate Menu
            Menu {
                Button("0.75×") { player.setPlaybackRate(0.75) }
                Button("1.0× (Normal)") { player.setPlaybackRate(1.0) }
                Button("1.25×") { player.setPlaybackRate(1.25) }
                Button("1.5×") { player.setPlaybackRate(1.5) }
                Button("2.0×") { player.setPlaybackRate(2.0) }
            } label: {
                Text(formatSpeed(player.playbackRate))
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .foregroundColor(.primary)
            }

            Spacer()
        }
    }

    // MARK: - L/R Audio Balance (Pan) Slider

    private var panBar: some View {
        // pan is -1.0 (Left) to 1.0 (Right)
        let panFraction = CGFloat((player.pan + 1.0) / 2.0)
        let centerOffset = scrubWidth / 2.0

        return VStack(spacing: 6) {
            ZStack(alignment: .leading) {
                // Background Track
                Capsule()
                    .fill(Color(.systemFill))
                    .frame(width: scrubWidth, height: 4)

                // Fill from Center to Thumb
                if player.pan < -0.01 {
                    let fillWidth = centerOffset - (scrubWidth * panFraction)
                    Capsule()
                        .fill(PodcastTheme.accent)
                        .frame(width: fillWidth, height: 4)
                        .offset(x: scrubWidth * panFraction)
                } else if player.pan > 0.01 {
                    let fillWidth = (scrubWidth * panFraction) - centerOffset
                    Capsule()
                        .fill(PodcastTheme.accent)
                        .frame(width: fillWidth, height: 4)
                        .offset(x: centerOffset)
                }

                // Center Indicator Tick
                Capsule()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 2, height: 8)
                    .offset(x: centerOffset - 1)

                // Thumb
                Circle()
                    .fill(PodcastTheme.accent)
                    .frame(width: 16, height: 16)
                    .shadow(radius: 2)
                    .offset(x: max(0, min(scrubWidth - 16, scrubWidth * panFraction - 8)))
            }
            .frame(width: scrubWidth, height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        let fraction = min(max(val.location.x / scrubWidth, 0), 1)
                        var newPan = Float(fraction * 2.0 - 1.0)

                        // Snap to center within 5% tolerance
                        if abs(newPan) < 0.05 {
                            if player.pan != 0.0 {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            newPan = 0.0
                        }
                        player.setPan(newPan)
                    }
            )
            .onTapGesture(count: 2) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                player.setPan(0.0)
            }

            HStack {
                Text("L")
                    .fontWeight(player.pan < -0.1 ? .bold : .regular)
                    .foregroundColor(player.pan < -0.1 ? PodcastTheme.accent : .secondary)
                Spacer()
                Text(formatPanText(player.pan))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text("R")
                    .fontWeight(player.pan > 0.1 ? .bold : .regular)
                    .foregroundColor(player.pan > 0.1 ? PodcastTheme.accent : .secondary)
            }
            .font(.caption)
            .monospacedDigit()
            .frame(width: scrubWidth)
        }
    }

    // MARK: - Active Speaker Pill / Skip Control

    private func activeSpeakerBar(diarization: SpeakerDiarizationData) -> some View {
        let skippedSpeakerSegments = player.getMergedSpeakerSkipRegions()
        let activeSpeakerSkipRegion = skippedSpeakerSegments.first { displayTime >= $0.start && displayTime < $0.end }
        let isInsideSpeakerSkip = activeSpeakerSkipRegion != nil

        let activeSegment = findActiveSegment(in: diarization, at: displayTime)
        let effectiveSegment = findEffectiveSegment(in: diarization, at: displayTime)
        let effectiveProfile = effectiveSegment.flatMap { findSpeakerProfile(for: $0.speakerId, in: diarization) }
            ?? (activeSpeakerSkipRegion.flatMap { findSpeakerProfile(for: $0.speakerId, in: diarization) })
            ?? (displayTime < (diarization.segments.first?.start ?? 0.0) ? diarization.speakers.first : nil)

        let isSpeakerMuted = effectiveProfile?.isSkipped == true

        let currentSegmentForLanguage = activeSegment ?? (
            effectiveSegment.flatMap { seg in
                (displayTime >= seg.start - 0.20 && displayTime <= seg.end + 0.20) ? seg : nil
            }
        ) ?? activeSpeakerSkipRegion
        let isSegmentNonEnglish = ((currentSegmentForLanguage?.language ?? "en").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "en")
        let isEnglishOnlyFiltered = (diarization.filterEnglishOnly ?? false) && (isSegmentNonEnglish || (isInsideSpeakerSkip && (activeSpeakerSkipRegion?.language ?? "en").lowercased() != "en"))

        let isSkipped = isInsideSpeakerSkip || (effectiveSegment != nil && isSpeakerMuted) || isEnglishOnlyFiltered
        let speakerName = effectiveProfile?.name ?? "Audio Interlude"

        let skipAccentColor: Color = isEnglishOnlyFiltered && !isSpeakerMuted
            ? Color(red: 0.20, green: 0.65, blue: 1.0)
            : Color(red: 0.72, green: 0.35, blue: 0.98)
        let subtitleText: String = {
            if isEnglishOnlyFiltered && !isSpeakerMuted { return "Skipping non-English audio" }
            if isSpeakerMuted { return "Auto-skipping speaker" }
            if activeSegment == nil { return "Pause / Interlude" }
            return "Active speaker"
        }()

        return HStack(spacing: 12) {
            // Speaker Info (Tapping opens Speaker Settings)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showSpeakerSettings = true
            } label: {
                HStack(spacing: 10) {
                    // Speaker Icon Badge
                    ZStack {
                        Circle()
                            .fill(isSkipped ? skipAccentColor.opacity(0.25) : Color.primary.opacity(0.08))
                            .frame(width: 32, height: 32)

                        Image(systemName: isSkipped ? (isEnglishOnlyFiltered && !isSpeakerMuted ? "globe.americas.fill" : "person.fill.xmark") : "person.wave.2.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(isSkipped ? skipAccentColor : PodcastTheme.accent)
                    }

                    // Speaker Name & Status Subtitle
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(speakerName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(1)

                            if isSpeakerMuted {
                                Text("SKIPPED")
                                    .font(.system(size: 9, weight: .black))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color(red: 0.72, green: 0.35, blue: 0.98)))
                                    .foregroundColor(.white)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }

                        Text(subtitleText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // Prominent Quick Skip Action Button (Always persistent)
            if let profile = effectiveProfile {
                Button {
                    skipActiveSpeaker(speaker: profile, segment: effectiveSegment)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isSkipped ? "forward.fill" : "person.fill.xmark")
                            .font(.system(size: 11, weight: .bold))
                        Text(isSkipped ? "Next" : "Skip")
                            .font(.caption.weight(.bold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(skipAccentColor)
                    )
                    .foregroundColor(.white)
                }
                .buttonStyle(SpringButtonStyle())
            }

            // Debug HUD Toggle Button (temporarily hidden; set enableDebugHUDButton to true to re-enable)
            if enableDebugHUDButton {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showDebugHUD.toggle()
                    }
                } label: {
                    Image(systemName: showDebugHUD ? "waveform.badge.magnifyingglass" : "ant")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(showDebugHUD ? PodcastTheme.accent : .secondary)
                        .padding(7)
                        .background(Circle().fill(showDebugHUD ? PodcastTheme.accent.opacity(0.18) : Color.primary.opacity(0.06)))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: scrubWidth)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemBackground).opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isSpeakerMuted ? Color(red: 0.72, green: 0.35, blue: 0.98).opacity(0.4) : Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }

    // MARK: - Playback Debug HUD

    private func playbackDebugHUD(diarization: SpeakerDiarizationData) -> some View {
        let skippedSpeakerSegments = player.getMergedSpeakerSkipRegions()
        let activeSpeakerSkipRegion = skippedSpeakerSegments.first { displayTime >= $0.start && displayTime < $0.end }
        let isInsideSpeakerSkip = activeSpeakerSkipRegion != nil

        let activeSegment = findActiveSegment(in: diarization, at: displayTime)
        let effectiveSegment = findEffectiveSegment(in: diarization, at: displayTime)
        let segment = activeSegment ?? effectiveSegment
        let profile = segment.flatMap { findSpeakerProfile(for: $0.speakerId, in: diarization) }
            ?? (activeSpeakerSkipRegion.flatMap { findSpeakerProfile(for: $0.speakerId, in: diarization) })

        let speakerDisplayName = profile?.name ?? (segment != nil ? segment!.speakerId : (activeSpeakerSkipRegion != nil ? activeSpeakerSkipRegion!.speakerId : "No Active Speaker"))
        let speakerId = segment?.speakerId ?? (activeSpeakerSkipRegion?.speakerId ?? "")

        let rawLang = (segment?.language ?? (activeSpeakerSkipRegion?.language ?? "en")).trimmingCharacters(in: .whitespacesAndNewlines)
        let langCode = rawLang.isEmpty ? "EN" : rawLang.uppercased()
        let isSpeakerMuted = profile?.isSkipped == true
        let isEnglishOnlyFiltered = (diarization.filterEnglishOnly ?? false) && (langCode != "EN" || ((activeSpeakerSkipRegion?.language ?? "en").lowercased() != "en"))

        // Check if playback position is in a silence removal skip
        let inSilenceSkip = silenceSkipRegions.contains { displayTime >= $0.start && displayTime < $0.end }
        // Check if in custom user skip
        let inCustomSkip = episodeSkips.contains { $0.isEnabled && displayTime >= $0.start && displayTime < $0.end }

        let actionStateText: String = {
            if isInsideSpeakerSkip {
                if isEnglishOnlyFiltered && !isSpeakerMuted { return "SKIPPED (Non-English)" }
                return "SKIPPED (Speaker)"
            }
            if isEnglishOnlyFiltered && !isSpeakerMuted { return "SKIPPED (Non-English)" }
            if isSpeakerMuted { return "SKIPPED (Speaker)" }
            if inSilenceSkip { return "SILENCE TRIMMED" }
            if inCustomSkip { return "SKIPPED (Custom)" }
            if activeSegment != nil { return "PLAYING" }
            return "PAUSE / INTERLUDE"
        }()

        let actionBadgeColor: Color = {
            if isInsideSpeakerSkip {
                if isEnglishOnlyFiltered && !isSpeakerMuted { return Color(red: 0.20, green: 0.65, blue: 1.0) }
                return Color(red: 0.72, green: 0.35, blue: 0.98)
            }
            if isEnglishOnlyFiltered && !isSpeakerMuted { return Color(red: 0.20, green: 0.65, blue: 1.0) }
            if isSpeakerMuted { return Color(red: 0.72, green: 0.35, blue: 0.98) }
            if inSilenceSkip { return Color(red: 0.18, green: 0.80, blue: 0.75) }
            if inCustomSkip { return Color(red: 1.0, green: 0.72, blue: 0.0) }
            if activeSegment != nil { return Color.green }
            return Color.secondary
        }()

        let timeRangeText: String = {
            if let skipRegion = activeSpeakerSkipRegion {
                let remaining = max(0, skipRegion.end - displayTime)
                return "\(formatDetailedTime(skipRegion.start)) - \(formatDetailedTime(skipRegion.end)) (\(String(format: "%.1fs left", remaining)))"
            }
            guard let seg = segment else { return "--:--.0 - --:--.0" }
            let remainingInSeg = max(0, seg.end - displayTime)
            return "\(formatDetailedTime(seg.start)) - \(formatDetailedTime(seg.end)) (\(String(format: "%.1fs left", remainingInSeg)))"
        }()

        let spokenText: String = {
            if activeSegment == nil && !isInsideSpeakerSkip {
                return "[Pause / Interlude]"
            }
            if let text = segment?.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if langCode != "EN" {
                return "[\(langCode) Speech]"
            }
            return "[Acoustic speech turn - no words]"
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("DEBUG HUD", systemImage: "waveform.badge.magnifyingglass")
                    .font(.system(size: 10, weight: .black))
                    .foregroundColor(PodcastTheme.accent)

                Spacer()

                Text(actionStateText)
                    .font(.system(size: 9, weight: .heavy))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(actionBadgeColor.opacity(0.2)))
                    .foregroundColor(actionBadgeColor)
            }

            HStack(spacing: 8) {
                Text("\(speakerDisplayName) (\(speakerId))")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.primary)

                if langCode != "EN" {
                    Text("NON-ENGLISH")
                        .font(.system(size: 9, weight: .black))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color(red: 0.20, green: 0.65, blue: 1.0)))
                        .foregroundColor(.white)
                }

                Text("[\(langCode)]")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(langCode == "EN" ? Color.green.opacity(0.18) : Color.blue.opacity(0.22)))
                    .foregroundColor(langCode == "EN" ? .green : Color(red: 0.20, green: 0.65, blue: 1.0))

                Spacer()

                Text(timeRangeText)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            Text("\"\(spokenText)\"")
                .font(.caption)
                .italic()
                .foregroundColor(.primary.opacity(0.9))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            // Rapid Testing Action Bar
            HStack(spacing: 8) {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if let seg = segment {
                        let target = max(0.0, seg.start - 3.0)
                        player.seek(to: target)
                        if !player.isPlaying { player.resume() }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gobackward.minus")
                            .font(.system(size: 10, weight: .bold))
                        Text("Jump -3s")
                            .font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .foregroundColor(.primary)
                }
                .buttonStyle(PlainButtonStyle())

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if let seg = segment {
                        player.toggleBoundaryLoop(start: seg.start, end: seg.end)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: player.isLoopingBoundary ? "repeat.circle.fill" : "repeat")
                            .font(.system(size: 10, weight: .bold))
                        Text(player.isLoopingBoundary ? "Looping" : "Loop 10s")
                            .font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(player.isLoopingBoundary ? Color.purple : Color.primary.opacity(0.1)))
                    .foregroundColor(player.isLoopingBoundary ? .white : .primary)
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showSegmentInspector = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 10, weight: .bold))
                        Text("Inspect")
                            .font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(PodcastTheme.accent.opacity(0.18)))
                    .foregroundColor(PodcastTheme.accent)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(width: scrubWidth)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemBackground).opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(actionBadgeColor.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private func formatDetailedTime(_ t: Double) -> String {
        guard t.isFinite && t >= 0 else { return "0:00.0" }
        let totalSeconds = Int(t)
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        let tenths = Int((t - Double(totalSeconds)) * 10)
        return String(format: "%d:%02d.%d", m, s, tenths)
    }

    // MARK: - Active Speaker Resolution Helpers

    private func findEffectiveSegment(in diarization: SpeakerDiarizationData, at time: Double) -> SpeakerSegment? {
        let segments = diarization.segments
        guard !segments.isEmpty else { return nil }

        // 1. Direct match or sub-second inter-word pause (< 0.8s)
        if let direct = findActiveSegment(in: diarization, at: time) {
            return direct
        }

        // 2. Stay consistent on the current speaker during conversational pauses up to 3.0s
        var lastPrecedingIdx: Int? = nil
        for (idx, seg) in segments.enumerated() {
            if seg.start <= time {
                lastPrecedingIdx = idx
            } else {
                break
            }
        }

        if let idx = lastPrecedingIdx {
            let seg = segments[idx]
            let isSkipped = (diarization.speakers.first { $0.id == seg.speakerId }?.isSkipped == true)
                || ((diarization.filterEnglishOnly ?? false) && (seg.language ?? "en").lowercased() != "en")
            if isSkipped && time > seg.end {
                // Do not latch onto skipped or non-English speech turns during an interlude
                if idx + 1 < segments.count && segments[idx + 1].start - time <= 1.5 {
                    return segments[idx + 1]
                }
                return nil
            }

            let maxPause = max(3.0, dataManager.settings.speakerSkipTrail + 1.0)
            if time <= seg.end + maxPause {
                return seg
            }
            // If upcoming segment is very near (< 1.5s), preview upcoming speaker
            if idx + 1 < segments.count && segments[idx + 1].start - time <= 1.5 {
                return segments[idx + 1]
            }
            return nil
        }

        // 3. Before first segment, only show if close (< 3.0s)
        if let first = segments.first, first.start - time <= 3.0 {
            return first
        }
        return nil
    }

    private func findActiveSegment(in diarization: SpeakerDiarizationData, at time: Double) -> SpeakerSegment? {
        let segments = diarization.segments
        guard !segments.isEmpty else { return nil }

        // 1. Direct hit in any speech segment
        for seg in segments {
            if time >= seg.start && time <= seg.end {
                return seg
            }
        }

        // 2. Inter-word pause (< 0.8s) within a speaker's conversational turn
        var precedingIdx: Int? = nil
        var succeedingIdx: Int? = nil
        for (idx, seg) in segments.enumerated() {
            if seg.end <= time {
                precedingIdx = idx
            } else if seg.start > time {
                succeedingIdx = idx
                break
            }
        }

        if let pIdx = precedingIdx {
            let prevSeg = segments[pIdx]
            let timeSinceEnd = time - prevSeg.end

            if let sIdx = succeedingIdx {
                let nextSeg = segments[sIdx]
                let timeUntilNext = nextSeg.start - time

                // Sub-second inter-word pause
                if timeSinceEnd < 0.8 || timeUntilNext < 0.3 {
                    if nextSeg.speakerId == prevSeg.speakerId {
                        return (timeSinceEnd <= timeUntilNext) ? prevSeg : nextSeg
                    } else if timeUntilNext < 0.3 {
                        return nextSeg
                    } else if timeSinceEnd < 0.8 {
                        return prevSeg
                    }
                }
            } else {
                if timeSinceEnd < 0.8 {
                    return prevSeg
                }
            }
        } else if let sIdx = succeedingIdx {
            let nextSeg = segments[sIdx]
            if nextSeg.start - time < 0.3 {
                return nextSeg
            }
        }

        return nil
    }

    private func findSpeakerProfile(for speakerId: String, in diarization: SpeakerDiarizationData) -> SpeakerProfile? {
        return diarization.speakers.first(where: { $0.id == speakerId })
    }

    private func skipActiveSpeaker(speaker: SpeakerProfile, segment: SpeakerSegment?) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        guard let ep = player.currentEpisode else { return }

        // 1. Persist speaker skip state in DataManager & synchronous player state
        if !speaker.isSkipped {
            dataManager.toggleSpeakerSkip(videoId: ep.videoId, speakerId: speaker.id, explicitState: true)
        }

        // 2. Resolve destination using the updated diarization regions
        let resolved = player.resolveSkipDestination(time: displayTime)
        let leadOut = max(0, dataManager.settings.speakerSkipTrail)

        var target: Double
        if resolved > displayTime + 0.05 {
            target = resolved
        } else if let seg = segment, seg.end > displayTime {
            target = player.resolveSkipDestination(time: seg.end + leadOut + 0.05)
        } else if let diar = currentSpeakerDiarization {
            // In a gap or untranscribed section: find next upcoming unskipped speaker turn
            let skippedIds = Set(diar.speakers.filter { $0.isSkipped }.map { $0.id })
            if let nextTurn = diar.segments.first(where: { $0.start > displayTime && !skippedIds.contains($0.speakerId) }) {
                target = max(displayTime + 0.05, nextTurn.start)
            } else if let nextSeg = diar.segments.first(where: { $0.start > displayTime }) {
                target = player.resolveSkipDestination(time: nextSeg.start)
            } else {
                target = min(displayTime + dataManager.settings.skipDuration, player.duration)
            }
        } else {
            target = min(displayTime + dataManager.settings.skipDuration, player.duration)
        }

        player.seek(to: target)
    }

    // MARK: - Helpers

    private func loadArt() {
        guard let ep = player.currentEpisode else { artwork = nil; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let img = DataManager.shared.artworkImage(for: ep)
            DispatchQueue.main.async { artwork = img }
        }
    }

    private func formatTime(_ t: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let m = Int(t) / 60; let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatSpeed(_ rate: Float) -> String {
        rate == 1.0 ? "1×" : String(format: "%.2g×", rate)
    }

    private func formatPanText(_ pan: Float) -> String {
        if abs(pan) < 0.01 { return "" }
        if pan < 0 {
            return String(format: "L %d%%", Int(abs(pan) * 100))
        } else {
            return String(format: "R %d%%", Int(pan * 100))
        }
    }

    private func categoryColor(for category: String) -> Color {
        switch category {
        case "sponsor": return .orange
        case "selfpromo": return .purple
        case "interaction": return .blue
        case "intro": return .green
        case "outro": return .red
        case "preview": return .init(red: 0.3, green: 0.8, blue: 0.9)
        case "filler": return .gray
        default: return .secondary
        }
    }
}

// MARK: - Spring Button Style

struct SpringButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
