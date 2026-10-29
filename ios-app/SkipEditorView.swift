import SwiftUI
import AVFoundation

struct SkipEditorView: View {
    let episode: PodcastEpisode
    @ObservedObject var player = PodcastPlayer.shared
    @ObservedObject var dataManager = DataManager.shared
    @Environment(\.dismiss) var dismiss

    @State private var startTime: Double = 0
    @State private var endTime: Double = 0
    @State private var editingSkipId: String? = nil
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    @State private var feedbackText: String? = nil
    @State private var showSpeakerSkips = false

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
        currentEpisode.removeSilence
    }

    private var currentMaxSilenceDuration: Double {
        currentEpisode.maxSilenceDuration
    }

    private var silenceSkipRegions: [(start: Double, end: Double)] {
        guard isSilenceRemovalEnabled else { return [] }
        return player.getSilenceSkipIntervals()
    }

    private var currentEpisodeDiarization: SpeakerDiarizationData? {
        currentEpisode.speakerDiarization
    }

    private var skippedSpeakerSegments: [SpeakerSegment] {
        return player.getMergedSpeakerSkipRegions()
    }

    private var speakerSkipsSubtitle: String {
        if let diarization = currentEpisodeDiarization, !diarization.speakers.isEmpty {
            let total = diarization.speakers.count
            let skipped = diarization.speakers.filter { $0.isSkipped }.count
            return "\(total) detected (\(skipped) active)"
        }
        return "Analyze audio with Computer WhisperX"
    }

    private var currentSkips: [UserCustomSkip] {
        return currentEpisode.customSkips ?? []
    }

    private var displayTime: Double {
        isScrubbing ? scrubTime : player.currentTime
    }

    private var skipDuration: Double {
        max(0, endTime - startTime)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    // Header Info
                    episodeHeaderCard

                    // Speaker Skips Entry Card
                    speakerSkipsCard

                    // Precision Scrubber & Timeline
                    precisionScrubberCard

                    // Transport & Precision Step Buttons (-60s to +60s)
                    transportControlsCard

                    // Mark In / Mark Out Controls
                    markPointsCard

                    // Action Buttons (Audition & Save)
                    actionButtonsCard

                    // Saved Skips List for this Episode
                    savedSkipsSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Skip Segment Editor")
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
            .onAppear {
                initializeEditorTimes()
            }
            .sheet(isPresented: $showSpeakerSkips) {
                SpeakerSkipView(episode: episode)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: - Initializer Helper

    private func initializeEditorTimes() {
        let current = player.currentTime
        startTime = max(0, current - 5.0)
        endTime = min(player.duration, current + 25.0)
        if endTime <= startTime {
            endTime = min(player.duration, startTime + 30.0)
        }
    }

    // MARK: - Episode Header

    private var episodeHeaderCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(PodcastTheme.accent.opacity(0.12))
                Image(systemName: "scissors")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(PodcastTheme.accent)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(episode.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(episode.channel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(PodcastTheme.cardBackground))
    }

    private let purpleAccent = Color(red: 0.72, green: 0.35, blue: 0.98)
    private let tealAccent = Color(red: 0.18, green: 0.80, blue: 0.75)

    // MARK: - Speaker Skips Card

    private var speakerSkipsCard: some View {
        Button {
            showSpeakerSkips = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(purpleAccent.opacity(0.15))
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(purpleAccent)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Speaker-Specific Skips")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                        Spacer()
                        if let count = currentEpisodeDiarization?.speakers.filter({ $0.isSkipped }).count, count > 0 {
                            Text("\(count) skipped")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(purpleAccent.opacity(0.2)))
                                .foregroundColor(purpleAccent)
                        }
                    }
                    Text(speakerSkipsSubtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(PodcastTheme.cardBackground))
        }
        .buttonStyle(SpringButtonStyle())
    }

    // MARK: - Precision Scrubber & Timeline

    private var precisionScrubberCard: some View {
        VStack(spacing: 16) {
            // Big Digital Time Readout
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CURRENT PLAYHEAD")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                    Text(formatTime(displayTime))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.primary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("TOTAL DURATION")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                    Text(formatTime(player.duration))
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
            }

            // Interactive Scrubber Bar with Start & End Markers
            GeometryReader { geo in
                let width = geo.size.width
                let progress = player.duration > 0 ? CGFloat(displayTime / player.duration) : 0
                let startFrac = player.duration > 0 ? CGFloat(startTime / player.duration) : 0
                let endFrac = player.duration > 0 ? CGFloat(endTime / player.duration) : 0

                ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(Color(.systemFill))
                        .frame(height: 6)

                    // Silence Removal Skips (Teal/Mint)
                    ForEach(silenceSkipRegions.indices, id: \.self) { idx in
                        let seg = silenceSkipRegions[idx]
                        let sFrac = CGFloat(seg.start / player.duration)
                        let eFrac = CGFloat(seg.end / player.duration)
                        let segW = max(2, width * (eFrac - sFrac))
                        let segOff = width * sFrac
                        Rectangle()
                            .fill(tealAccent.opacity(0.85))
                            .frame(width: segW, height: 6)
                            .offset(x: segOff)
                    }

                    // Existing Saved Speaker Skips (Royal Purple) & English Only Skips (Light Blue)
                    ForEach(skippedSpeakerSegments, id: \.self) { seg in
                        let sFrac = CGFloat(seg.start / player.duration)
                        let eFrac = CGFloat(seg.end / player.duration)
                        let segW = max(2, width * (eFrac - sFrac))
                        let segOff = width * sFrac
                        let isNonEnglish = ((seg.language ?? "en").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "en")
                        let segColor = isNonEnglish ? Color(red: 0.20, green: 0.65, blue: 1.0) : purpleAccent
                        Rectangle()
                            .fill(segColor.opacity(0.9))
                            .frame(width: segW, height: 6)
                            .offset(x: segOff)
                    }

                    // Existing Saved Skips on Timeline
                    ForEach(currentSkips) { skip in
                        let sFrac = CGFloat(skip.start / player.duration)
                        let eFrac = CGFloat(skip.end / player.duration)
                        let segW = max(0, width * (eFrac - sFrac))
                        let segOff = width * sFrac
                        Rectangle()
                            .fill(Color(red: 1.0, green: 0.72, blue: 0.0).opacity(skip.isEnabled ? 0.45 : 0.2))
                            .frame(width: segW, height: 6)
                            .offset(x: segOff)
                    }

                    // Proposed Current Skip Segment Region
                    if endTime > startTime {
                        let segW = max(0, width * (endFrac - startFrac))
                        let segOff = width * startFrac
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(red: 1.0, green: 0.72, blue: 0.0).opacity(0.9))
                            .frame(width: segW, height: 8)
                            .offset(x: segOff)
                    }

                    // Start Marker Pin
                    Capsule()
                        .fill(Color.primary.opacity(0.7))
                        .frame(width: 2.5, height: 18)
                        .offset(x: max(0, min(width - 2.5, width * startFrac - 1.25)))

                    // End Marker Pin
                    Capsule()
                        .fill(Color.primary.opacity(0.7))
                        .frame(width: 2.5, height: 18)
                        .offset(x: max(0, min(width - 2.5, width * endFrac - 1.25)))

                    // Current Playhead Thumb
                    Circle()
                        .fill(Color.white)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)
                        .offset(x: max(0, min(width - 18, width * progress - 9)))
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            isScrubbing = true
                            let fraction = min(max(val.location.x / width, 0), 1)
                            scrubTime = Double(fraction) * player.duration
                        }
                        .onEnded { _ in
                            player.seek(to: scrubTime)
                            isScrubbing = false
                        }
                )
            }
            .frame(height: 24)

            // Timeline Legend / Sub-Labels
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.right.to.line")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.secondary)
                    Text("Start: \(formatTime(startTime))")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "arrow.left.to.line")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.secondary)
                    Text("End: \(formatTime(endTime))")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(PodcastTheme.cardBackground))
    }

    // MARK: - Transport & Precision Stepping

    private var transportControlsCard: some View {
        VStack(spacing: 12) {
            Text("PLAYHEAD SCRUBBING")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                // Backward jumps
                stepButton(label: "-60s", seconds: -60)
                stepButton(label: "-30s", seconds: -30)
                stepButton(label: "-10s", seconds: -10)
                stepButton(label: "-1s", seconds: -1)

                // Play / Pause in center
                Button {
                    player.togglePlay()
                } label: {
                    ZStack {
                        Circle()
                            .fill(PodcastTheme.accent)
                            .frame(width: 44, height: 44)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .offset(x: player.isPlaying ? 0 : 1.5)
                    }
                }
                .buttonStyle(SpringButtonStyle())

                // Forward jumps
                stepButton(label: "+1s", seconds: 1)
                stepButton(label: "+10s", seconds: 10)
                stepButton(label: "+30s", seconds: 30)
                stepButton(label: "+60s", seconds: 60)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(PodcastTheme.cardBackground))
    }

    private func stepButton(label: String, seconds: Double) -> some View {
        Button {
            let target = max(0, min(player.duration, player.currentTime + seconds))
            player.seek(to: target)
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemFill)))
        }
        .buttonStyle(SpringButtonStyle())
    }

    // MARK: - Mark In / Out Cards

    private var markPointsCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Mark Start Column
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        startTime = player.currentTime
                        if endTime <= startTime {
                            endTime = min(player.duration, startTime + 10.0)
                        }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.right.to.line")
                            Text("Mark Start")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemFill)))
                    }
                    .buttonStyle(SpringButtonStyle())

                    // Start time display + Steppers
                    HStack {
                        Button {
                            startTime = max(0, startTime - 1.0)
                        } label: {
                            Image(systemName: "minus")
                                .font(.caption.weight(.bold))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color(.systemFill)))
                                .foregroundColor(.primary)
                        }

                        Spacer()

                        Text(formatTime(startTime))
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.primary)

                        Spacer()

                        Button {
                            startTime = min(max(0, endTime - 1.0), startTime + 1.0)
                        } label: {
                            Image(systemName: "plus")
                                .font(.caption.weight(.bold))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color(.systemFill)))
                                .foregroundColor(.primary)
                        }
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemFill)))
                }
                .frame(maxWidth: .infinity)

                // Mark End Column
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        endTime = max(startTime + 1.0, player.currentTime)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.left.to.line")
                            Text("Mark End")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemFill)))
                    }
                    .buttonStyle(SpringButtonStyle())

                    // End time display + Steppers
                    HStack {
                        Button {
                            endTime = max(startTime + 1.0, endTime - 1.0)
                        } label: {
                            Image(systemName: "minus")
                                .font(.caption.weight(.bold))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color(.systemFill)))
                                .foregroundColor(.primary)
                        }

                        Spacer()

                        Text(formatTime(endTime))
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.primary)

                        Spacer()

                        Button {
                            endTime = min(player.duration, endTime + 1.0)
                        } label: {
                            Image(systemName: "plus")
                                .font(.caption.weight(.bold))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color(.systemFill)))
                                .foregroundColor(.primary)
                        }
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemFill)))
                }
                .frame(maxWidth: .infinity)
            }

            // Summary Duration Banner
            HStack {
                Image(systemName: "scissors")
                    .foregroundColor(Color(red: 1.0, green: 0.72, blue: 0.0))
                Text("Will skip: \(formatTime(startTime)) → \(formatTime(endTime))")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.primary)
                Spacer()
                Text("-\(formatDuration(skipDuration))")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(red: 1.0, green: 0.72, blue: 0.0).opacity(0.18)))
                    .foregroundColor(Color(red: 0.85, green: 0.55, blue: 0.0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemFill)))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(PodcastTheme.cardBackground))
    }

    // MARK: - Action Buttons (Test & Save)

    private var actionButtonsCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                // Test Cut (Audition)
                Button {
                    testAuditionCut()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "headphones")
                        Text("Audition Cut")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(PodcastTheme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(PodcastTheme.accent.opacity(0.12))
                    )
                }
                .buttonStyle(SpringButtonStyle())

                // Save Button
                Button {
                    saveCustomSkip()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: editingSkipId != nil ? "checkmark.circle.fill" : "plus.circle.fill")
                        Text(editingSkipId != nil ? "Update Skip" : "Save Skip")
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(PodcastTheme.accent)
                    )
                }
                .buttonStyle(SpringButtonStyle())
            }

            if let feedback = feedbackText {
                Text(feedback)
                    .font(.caption.weight(.medium))
                    .foregroundColor(PodcastTheme.accent)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(PodcastTheme.cardBackground))
    }

    // MARK: - Saved Skips Section

    private var savedSkipsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SAVED SKIPS FOR THIS EPISODE (\(currentSkips.count))")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                if editingSkipId != nil {
                    Button("Cancel Edit") {
                        editingSkipId = nil
                        initializeEditorTimes()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(PodcastTheme.accent)
                }
            }

            if currentSkips.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "scissors")
                        .font(.system(size: 26))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No custom skips saved yet.")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.secondary)
                    Text("Mark Start & End points above, then tap Save Skip.")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.8))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(RoundedRectangle(cornerRadius: 14).fill(PodcastTheme.cardBackground.opacity(0.6)))
            } else {
                ForEach(currentSkips) { skip in
                    savedSkipRow(skip: skip)
                }
            }
        }
    }

    private func savedSkipRow(skip: UserCustomSkip) -> some View {
        let isBeingEdited = (editingSkipId == skip.id)
        let diff = max(0, skip.end - skip.start)

        return HStack(spacing: 12) {
            // Accent bar
            Capsule()
                .fill(Color(red: 1.0, green: 0.72, blue: 0.0).opacity(skip.isEnabled ? 1.0 : 0.35))
                .frame(width: 3.5, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(formatTime(skip.start)) → \(formatTime(skip.end))")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundColor(skip.isEnabled ? .primary : .secondary)
                    Text("-\(formatDuration(diff))")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(red: 1.0, green: 0.72, blue: 0.0).opacity(0.18)))
                        .foregroundColor(Color(red: 0.85, green: 0.55, blue: 0.0))
                }
            }

            Spacer()

            // Seek button
            Button {
                player.seek(to: max(0, skip.start - 2.0))
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(PodcastTheme.accent)
            }
            .buttonStyle(SpringButtonStyle())

            // Edit button
            Button {
                loadSkipForEditing(skip)
            } label: {
                Image(systemName: isBeingEdited ? "pencil.circle.fill" : "pencil.circle")
                    .font(.system(size: 22))
                    .foregroundColor(isBeingEdited ? PodcastTheme.accent : .secondary)
            }
            .buttonStyle(SpringButtonStyle())

            // Enable / Disable Toggle
            Button {
                dataManager.toggleCustomSkip(videoId: episode.videoId, skipId: skip.id)
            } label: {
                Image(systemName: skip.isEnabled ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 18))
                    .foregroundColor(skip.isEnabled ? .primary : .secondary.opacity(0.4))
            }
            .buttonStyle(SpringButtonStyle())

            // Delete button
            Button {
                deleteSkip(skip)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(SpringButtonStyle())
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(PodcastTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isBeingEdited ? PodcastTheme.accent : Color.clear, lineWidth: 1.5)
                )
        )
    }

    // MARK: - Actions

    private func testAuditionCut() {
        guard endTime > startTime else { return }
        player.auditionSkip(start: startTime, end: endTime)
        withAnimation {
            feedbackText = "Auditioning cut from \(formatTime(max(0, startTime - 3.0)))"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation { feedbackText = nil }
        }
    }

    private func saveCustomSkip() {
        guard endTime > startTime else { return }

        if let skipId = editingSkipId {
            let updated = UserCustomSkip(
                id: skipId,
                start: startTime,
                end: endTime,
                label: "Custom Skip",
                isEnabled: true
            )
            dataManager.updateCustomSkip(videoId: episode.videoId, skip: updated)
            editingSkipId = nil
            withAnimation {
                feedbackText = "Updated skip segment!"
            }
        } else {
            dataManager.addCustomSkip(
                videoId: episode.videoId,
                start: startTime,
                end: endTime,
                label: "Custom Skip"
            )
            withAnimation {
                feedbackText = "Saved new skip segment!"
            }
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { feedbackText = nil }
        }
    }

    private func loadSkipForEditing(_ skip: UserCustomSkip) {
        editingSkipId = skip.id
        startTime = skip.start
        endTime = skip.end
        player.seek(to: max(0, skip.start - 2.0))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func deleteSkip(_ skip: UserCustomSkip) {
        if editingSkipId == skip.id {
            editingSkipId = nil
            initializeEditorTimes()
        }
        dataManager.deleteCustomSkip(videoId: episode.videoId, skipId: skip.id)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: - Formatters

    private func formatTime(_ t: Double) -> String {
        guard t.isFinite && t >= 0 else { return "0:00" }
        let totalSeconds = Int(t)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }

    private func formatDuration(_ t: Double) -> String {
        guard t.isFinite && t >= 0 else { return "0s" }
        let totalSeconds = Int(t)
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        if m > 0 {
            return String(format: "%dm %02ds", m, s)
        } else {
            return String(format: "%ds", s)
        }
    }
}
