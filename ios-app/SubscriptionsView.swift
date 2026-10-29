import SwiftUI

struct SubscriptionsView: View {
    @ObservedObject var dataManager = DataManager.shared
    @ObservedObject var player = PodcastPlayer.shared
    @State private var subToDelete: Subscription? = nil
    @State private var confirmDeleteSub = false

    private var relativeLastSync: String {
        guard let date = dataManager.lastSyncDate else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                VStack(spacing: 0) {
                    ActiveDownloadsBanner()

                    if dataManager.subscriptions.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "bell.badge.slash")
                                .font(.system(size: 64))
                                .foregroundColor(.secondary)
                            Text("No Subscriptions")
                                .font(.title3).fontWeight(.bold)
                            Text("Subscribe to channels from search results to auto-download new episodes.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            Section(header: Text("Channels"), footer: syncFooterView) {
                                ForEach(dataManager.subscriptions) { sub in
                                    NavigationLink(destination: ChannelBrowserView(url: sub.channelUrl, initialTitle: sub.channelTitle)) {
                                        SubscriptionRow(sub: sub, dataManager: dataManager)
                                    }
                                    .contextMenu {
                                        Button {
                                            dataManager.scanForSubscription(sub)
                                        } label: {
                                            Label("Scan for New Episodes", systemImage: "arrow.triangle.2.circlepath")
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            subToDelete = sub
                                            confirmDeleteSub = true
                                        } label: {
                                            Label("Unsubscribe", systemImage: "bell.slash")
                                        }
                                    }
                                    .swipeActions(edge: .leading) {
                                        Button {
                                            dataManager.scanForSubscription(sub)
                                        } label: {
                                            Label("Scan", systemImage: "arrow.triangle.2.circlepath")
                                        }
                                        .tint(PodcastTheme.accent)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            subToDelete = sub
                                            confirmDeleteSub = true
                                        } label: {
                                            Label("Unsubscribe", systemImage: "bell.slash")
                                        }
                                    }
                                }
                            }
                        }
                        .listStyle(InsetGroupedListStyle())
                        .refreshable {
                            await dataManager.syncSubscriptionsAsync()
                            await dataManager.loadDataAsync()
                        }
                        .padding(.bottom, player.currentEpisode != nil ? 90 : 0)
                    }
                }
            }
            .navigationTitle("Subscriptions")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        dataManager.syncSubscriptions()
                    }) {
                        if dataManager.isSyncing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: PodcastTheme.accent))
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(PodcastTheme.accent)
                        }
                    }
                    .disabled(dataManager.isSyncing)
                }
            }
            .confirmationDialog(
                "Unsubscribe from \"\(subToDelete?.channelTitle ?? "")\"?",
                isPresented: $confirmDeleteSub,
                titleVisibility: .visible
            ) {
                Button("Unsubscribe", role: .destructive) {
                    if let sub = subToDelete {
                        dataManager.unsubscribe(channelId: sub.channelId)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This stops auto-downloading new episodes in the background.")
            }
        }
    }

    private var syncFooterView: some View {
        HStack {
            Spacer()
            if dataManager.isSyncing {
                Text("Checking for new episodes…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Last checked: \(relativeLastSync)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct SubscriptionRow: View {
    let sub: Subscription
    @ObservedObject var dataManager: DataManager
    @State private var artwork: UIImage? = nil

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(image: artwork, size: 48, isCircle: true)
                .cornerRadius(24)

            VStack(alignment: .leading, spacing: 4) {
                Text(sub.channelTitle)
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.primary)
                Text(sub.channelUrl)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .onAppear { loadArt() }
    }

    private func loadArt() {
        DispatchQueue.global(qos: .userInitiated).async {
            let img = dataManager.artworkImage(forSubscription: sub)
            DispatchQueue.main.async { artwork = img }
        }
    }
}
