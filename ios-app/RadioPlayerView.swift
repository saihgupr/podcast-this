import SwiftUI
import AVKit

// MARK: - Dedicated Live-Radio Player (sheet)

struct RadioPlayerView: View {
    @ObservedObject var radio = RadioPlayer.shared
    @Environment(\.dismiss) var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var sleepMinutes: Int? = nil
    @State private var levels: [CGFloat] = Array(repeating: 0.18, count: 28)
    @State private var visualTimer: Timer? = nil

    private let barCount = 28

    private var isLive: Bool { radio.liveState == .playingLive }
    private var isBuffering: Bool { radio.liveState == .buffering }
    private var isPausedBehind: Bool { radio.liveState == .pausedBehindLive }

    private var trackKey: String {
        "\(radio.liveNowPlayingTitle ?? "")|\(radio.liveNowPlayingSubtitle ?? "")"
    }

    private var trackTitle: String {
        if let title = radio.liveNowPlayingTitle, !title.isEmpty { return title }
        return streamHostFallback
    }

    private var trackSubtitle: String? {
        if let subtitle = radio.liveNowPlayingSubtitle, !subtitle.isEmpty { return subtitle }
        // Title slot already shows the host fallback; no subtitle to add then.
        if radio.liveNowPlayingTitle?.isEmpty ?? true { return nil }
        return streamHostFallback
    }

    private var streamHostFallback: String {
        if let urlString = radio.currentStation?.streamURL,
           let url = URL(string: urlString),
           let host = url.host, !host.isEmpty {
            return host
        }
        return radio.currentStation?.streamURL ?? "Live stream"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 18)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        centerpiece
                            .padding(.bottom, 22)

                        stationBlock
                            .padding(.bottom, 20)

                        statusBar
                            .padding(.bottom, 26)

                        transport
                            .padding(.bottom, 22)

                        utilityRow
                            .padding(.bottom, 36)
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { startVisualizer() }
        .onDisappear { visualTimer?.invalidate(); visualTimer = nil }
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(SpringButtonStyle())
                .accessibilityLabel("Close")

                Spacer()

                connectionBadge
            }

            Text("LIVE RADIO")
                .font(.caption).fontWeight(.bold)
                .kerning(2)
                .foregroundColor(.white.opacity(0.6))
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(badgeColor)
                .frame(width: 7, height: 7)
            Text(badgeText)
                .font(.caption2).fontWeight(.bold)
        }
        .foregroundColor(badgeColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private var badgeText: String {
        switch radio.liveState {
        case .idle: return "IDLE"
        case .buffering: return "BUFFERING"
        case .playingLive: return "CONNECTED"
        case .pausedBehindLive: return "PAUSED"
        case .error: return "ERROR"
        }
    }

    private var badgeColor: Color {
        switch radio.liveState {
        case .playingLive: return Color(red: 0.35, green: 0.85, blue: 0.45)
        case .buffering: return Color.orange
        case .error: return Color(red: 1.0, green: 0.35, blue: 0.35)
        case .pausedBehindLive, .idle: return Color.white.opacity(0.5)
        }
    }

    // MARK: - Centerpiece

    private var centerpiece: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 24)
                .fill(PodcastTheme.accentGradient)

            RoundedRectangle(cornerRadius: 24)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.25), .white.opacity(0.0)],
                        startPoint: .top, endPoint: .center
                    )
                )

            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)

            VStack(spacing: 14) {
                Spacer(minLength: 0)
                HStack(alignment: .center, spacing: 4) {
                    ForEach(0..<barCount, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(isLive ? 0.92 : 0.25))
                            .frame(width: 3, height: 8 + (levels[i] * 64))
                    }
                }
                .frame(height: 80)
                .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)

            livePill
                .padding(16)
        }
        .frame(height: 240)
        .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)
    }

    private var livePill: some View {
        HStack(spacing: 6) {
            if isBuffering {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(0.7)
            } else {
                RadioLiveDot(active: isLive)
            }
            Text(pillText)
                .font(.caption2).fontWeight(.black)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(pillBackground))
        .opacity(isLive || isBuffering ? 1.0 : 0.75)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pillAccessibilityLabel)
    }

    private var pillText: String {
        switch radio.liveState {
        case .playingLive: return "LIVE"
        case .buffering: return "BUFFERING"
        case .pausedBehindLive: return "PAUSED"
        case .error: return "ERROR"
        case .idle: return "IDLE"
        }
    }

    private var pillBackground: Color {
        isLive ? Color(red: 0.85, green: 0.10, blue: 0.15) : Color.black.opacity(0.55)
    }

    private var pillAccessibilityLabel: String {
        switch radio.liveState {
        case .playingLive: return "Live radio, playing"
        case .buffering: return "Live radio, buffering"
        case .pausedBehindLive: return "Live radio, paused"
        case .error(let message): return "Live radio error, \(message)"
        case .idle: return "Live radio, idle"
        }
    }

    // MARK: - Station + Track

    private var stationBlock: some View {
        VStack(spacing: 8) {
            Text(radio.currentStation?.name ?? "No Station")
                .font(.title2).fontWeight(.bold)
                .foregroundColor(.white)
                .lineLimit(1)

            VStack(spacing: 3) {
                Text(trackTitle)
                    .font(.headline).fontWeight(.semibold)
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let subtitle = trackSubtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(PodcastTheme.accent)
                        .lineLimit(1)
                }
            }
            .id(trackKey)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .animation(.easeInOut(duration: 0.25), value: trackKey)
            .onLongPressGesture { copyTrack() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Now playing, \(trackTitle)")
            .accessibilityHint("Long press to copy")

            if case .error(let message) = radio.liveState {
                Text(message)
                    .font(.caption)
                    .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.45))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func copyTrack() {
        let text = [radio.liveNowPlayingTitle, radio.liveNowPlayingSubtitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " - ")
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: - Live Status Bar (replaces scrubber)

    private var statusBar: some View {
        HStack {
            Text("Session \(formatSession(radio.listeningDuration))")
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
                .monospacedDigit()

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                radio.jumpToLive()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                        .font(.caption2.weight(.bold))
                    Text("Jump to Live")
                        .font(.caption).fontWeight(.bold)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(isPausedBehind ? PodcastTheme.accent : Color.white.opacity(0.12)))
                .foregroundColor(.white)
            }
            .buttonStyle(SpringButtonStyle())
            .disabled(!isPausedBehind)
            .opacity(isPausedBehind ? 1.0 : 0.55)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.12))
        )
    }

    private func formatSession(_ t: TimeInterval) -> String {
        guard t.isFinite && t >= 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Transport

    private var transport: some View {
        HStack {
            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                radio.previousStation()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(SpringButtonStyle())
            .accessibilityLabel("Previous station")
            .disabled(radio.currentStation == nil)

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                if let station = radio.currentStation {
                    radio.toggle(station: station)
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.85, green: 0.12, blue: 0.20))
                        .frame(width: 76, height: 76)
                        .shadow(color: Color(red: 0.85, green: 0.12, blue: 0.20).opacity(0.45), radius: 16, x: 0, y: 6)
                    if isBuffering {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: radio.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                            .offset(x: radio.isPlaying ? 0 : 2)
                    }
                }
            }
            .buttonStyle(SpringButtonStyle())
            .accessibilityLabel(radio.isPlaying ? "Pause" : "Play")
            .disabled(radio.currentStation == nil)

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                radio.nextStation()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(SpringButtonStyle())
            .accessibilityLabel("Next station")
            .disabled(radio.currentStation == nil)

            Spacer()
        }
    }

    // MARK: - Utility Row

    private var utilityRow: some View {
        HStack {
            AirPlayButton()
                .frame(width: 44, height: 44)
                .accessibilityLabel("AirPlay")

            Spacer()

            Menu {
                Button("Off") { setSleep(nil) }
                Button("15 minutes") { setSleep(15) }
                Button("30 minutes") { setSleep(30) }
                Button("60 minutes") { setSleep(60) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: sleepMinutes == nil ? "moon" : "moon.fill")
                        .font(.footnote.weight(.semibold))
                    Text(sleepMinutes == nil ? "Sleep" : "\(sleepMinutes!)m")
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.white.opacity(0.10)))
                .foregroundColor(.white)
            }
            .accessibilityLabel("Sleep timer")
        }
    }

    private func setSleep(_ minutes: Int?) {
        sleepMinutes = minutes
        radio.setSleepTimer(minutes: minutes)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Visualizer

    private func startVisualizer() {
        visualTimer?.invalidate()
        visualTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
            if radio.liveState == .playingLive, !reduceMotion {
                withAnimation(.easeInOut(duration: 0.3)) {
                    levels = levels.map { _ in CGFloat.random(in: 0.15...1.0) }
                }
            } else {
                withAnimation(.easeInOut(duration: 0.3)) {
                    levels = Array(repeating: 0.18, count: barCount)
                }
            }
        }
    }
}

// MARK: - AirPlay

private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.activeTintColor = UIColor(PodcastTheme.accent)
        picker.tintColor = UIColor.white.withAlphaComponent(0.85)
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Pulsing Red LIVE Dot (shared by rows + mini player)

struct RadioLiveDot: View {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 1.0, green: 0.23, blue: 0.23))
                .frame(width: 7, height: 7)
                .opacity(active ? 1.0 : 0.35)
            Circle()
                .fill(Color(red: 1.0, green: 0.23, blue: 0.23))
                .frame(width: 7, height: 7)
                .scaleEffect(pulse ? 2.2 : 1.0)
                .opacity(pulse ? 0.0 : (active ? 0.6 : 0.0))
        }
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}
