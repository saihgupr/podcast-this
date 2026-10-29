import SwiftUI

@main
struct PodcastThisApp: App {
    var body: some Scene {
        WindowGroup {
            MainTabView()
                .onOpenURL { url in
                    guard url.scheme == "podcastthis" else { return }
                    if url.host == "diarization-done",
                       let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                       let videoId = components.queryItems?.first(where: { $0.name == "video_id" })?.value {
                        DataManager.shared.fetchDiarizationStatus(videoId: videoId) { _, _ in }
                    }
                }
        }
    }
}

struct MainTabView: View {
    @ObservedObject var player = PodcastPlayer.shared
    @State private var showFullPlayer = false
    @State private var selectedTab = 0

    var body: some View {
        let tabBinding = Binding<Int>(
            get: { selectedTab },
            set: { newValue in
                if newValue == selectedTab {
                    if newValue == 0 {
                        NotificationCenter.default.post(name: NSNotification.Name("popToLibraryRoot"), object: nil)
                    }
                }
                selectedTab = newValue
            }
        )
        
        return ZStack(alignment: .bottom) {
            TabView(selection: tabBinding) {
                LibraryView(showFullPlayer: $showFullPlayer)
                    .tabItem {
                        Label("Library", systemImage: "books.vertical")
                    }
                    .tag(0)

                SubscriptionsView()
                    .tabItem {
                        Label("Subscriptions", systemImage: "bell.fill")
                    }
                    .tag(1)

                AddView()
                    .tabItem {
                        Label("Add", systemImage: "plus.circle")
                    }
                    .tag(2)

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .tag(3)
            }
            .accentColor(PodcastTheme.accent)

            // Sticky mini player sits above the tab bar
            if player.currentEpisode != nil {
                VStack(spacing: 0) {
                    MiniPlayerBar(showFullPlayer: $showFullPlayer)
                    // Spacer for the native tab bar height
                    Color.clear.frame(height: 49)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: player.currentEpisode != nil)
                // Stay pinned at bottom — never move up with keyboard
                .ignoresSafeArea(.keyboard)
            }
        }
        .sheet(isPresented: $showFullPlayer) {
            if #available(iOS 16.0, *) {
                FullPlayerView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            } else {
                FullPlayerView()
            }
        }
        .onOpenURL { incomingUrl in
            if let targetUrl = parseSharedUrl(from: incomingUrl) {
                selectedTab = 2
                DataManager.shared.handleIncomingSharedUrl(targetUrl)
            }
        }
    }

    private func parseSharedUrl(from url: URL) -> String? {
        let fullString = url.absoluteString
        
        // 1. Try URLComponents query items first
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems {
            if let target = queryItems.first(where: { $0.name.lowercased() == "url" || $0.name.lowercased() == "link" })?.value,
               !target.isEmpty {
                return target.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        // 2. Custom parsing for podcastthis:// schemes
        if fullString.hasPrefix("podcastthis://") {
            let rest = String(fullString.dropFirst("podcastthis://".count))
            if rest.hasPrefix("add?") || rest.hasPrefix("download?") || rest.hasPrefix("open?") {
                if let range = rest.range(of: "url=") {
                    let encoded = String(rest[range.upperBound...])
                    let decoded = encoded.removingPercentEncoding ?? encoded
                    return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let range = rest.range(of: "link=") {
                    let encoded = String(rest[range.upperBound...])
                    let decoded = encoded.removingPercentEncoding ?? encoded
                    return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if rest.hasPrefix("http://") || rest.hasPrefix("https://") {
                return (rest.removingPercentEncoding ?? rest).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if rest.hasPrefix("www.") || rest.hasPrefix("youtu.be/") || rest.hasPrefix("youtube.com/") {
                let clean = (rest.removingPercentEncoding ?? rest).trimmingCharacters(in: .whitespacesAndNewlines)
                return "https://" + clean
            }
        }
        return nil
    }
}

enum PodcastTheme {
    // Coral red matching iOS Podcasts app
    static let accent = Color(red: 0.94, green: 0.27, blue: 0.34)
    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.94, green: 0.27, blue: 0.34), Color(red: 0.75, green: 0.12, blue: 0.55)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let cardBackground = Color(.secondarySystemGroupedBackground)
    static let speakerSkipPurple = Color(red: 0.72, green: 0.35, blue: 0.98)
}
