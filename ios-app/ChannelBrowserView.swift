import SwiftUI

struct ChannelBrowserView: View {
    let url: String
    let initialTitle: String
    
    @State private var episodes: [EpisodeMetadata] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var canLoadMore = true
    @ObservedObject var dataManager = DataManager.shared
    @ObservedObject var player = PodcastPlayer.shared
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            ActiveDownloadsBanner()

            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Fetching episodes...")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if episodes.isEmpty {
                Text("No episodes found or failed to load.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        if dataManager.isBulkQueueLoading {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .padding(.trailing, 8)
                                Text("Preparing downloads...")
                                    .font(.subheadline).fontWeight(.semibold)
                                    .foregroundColor(PodcastTheme.accent)
                                Spacer()
                            }
                            .padding(.vertical, 14)
                            .background(Color(.secondarySystemGroupedBackground))
                            .cornerRadius(12)
                            .padding(.horizontal, 16)
                        } else if !dataManager.downloadQueue.isEmpty || (dataManager.isDownloading && dataManager.currentQueueUrl != nil) {
                            HStack(spacing: 0) {
                                Spacer()
                                VStack(spacing: 2) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "arrow.down.circle")
                                        Text("Downloading Episodes")
                                            .fontWeight(.semibold)
                                    }
                                    .foregroundColor(PodcastTheme.accent)
                                    Text("\(dataManager.downloadQueue.count + 1) remaining")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(action: {
                                    dataManager.cancelAllDownloads()
                                }) {
                                    Text("Cancel")
                                        .font(.subheadline).fontWeight(.semibold)
                                        .foregroundColor(.red)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color(.systemRed).opacity(0.1))
                                        .cornerRadius(8)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .padding(.trailing, 16)
                            }
                            .padding(.vertical, 14)
                            .background(Color(.secondarySystemGroupedBackground))
                            .cornerRadius(12)
                            .padding(.horizontal, 16)
                        } else {
                            Button(action: {
                                dataManager.startBulkDownload(channelUrl: url)
                            }) {
                                HStack {
                                    Image(systemName: "arrow.down.circle.fill")
                                    Text("Download All Episodes")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color(.secondarySystemGroupedBackground))
                                .foregroundColor(PodcastTheme.accent)
                                .cornerRadius(12)
                                .padding(.horizontal, 16)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }

                    Section(header: Text("Recent Episodes")) {
                        ForEach(episodes) { ep in
                            ChannelEpisodeRow(ep: ep, channelTitle: initialTitle, channelUrl: url, dataManager: dataManager)
                                .onAppear {
                                    if ep.id == episodes.last?.id {
                                        loadMoreEpisodes()
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if dataManager.shows.contains(where: { show in show.episodes.contains { $0.videoId == ep.id } }) {
                                        Button(role: .destructive) {
                                            if let downloadedEp = dataManager.shows.flatMap({ $0.episodes }).first(where: { $0.videoId == ep.id }) {
                                                dataManager.deleteEpisode(downloadedEp)
                                            }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                        }
                        
                        if isLoadingMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .padding(.vertical, 8)
                                Spacer()
                            }
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())
                .padding(.bottom, player.currentEpisode != nil ? 90 : 0)
            }
        }
        .navigationTitle(initialTitle.isEmpty ? "Channel" : initialTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Close") {
                    dismiss()
                }
                .foregroundColor(PodcastTheme.accent)
            }
        }
        .onAppear {
            loadEpisodes()
        }
    }
    
    private func loadEpisodes() {
        guard episodes.isEmpty else { return }
        isLoading = true
        dataManager.fetchPlaylistMetadata(url: url) { fetchedEpisodes in
            self.episodes = fetchedEpisodes
            self.isLoading = false
            if fetchedEpisodes.count < 15 {
                self.canLoadMore = false
            }
        }
    }
    
    private func loadMoreEpisodes() {
        guard !isLoadingMore && canLoadMore else { return }
        isLoadingMore = true
        let nextStart = episodes.count + 1
        dataManager.fetchPlaylistMetadata(url: url, startIndex: nextStart) { fetchedEpisodes in
            if fetchedEpisodes.isEmpty {
                self.canLoadMore = false
            } else {
                self.episodes.append(contentsOf: fetchedEpisodes)
                if fetchedEpisodes.count < 15 {
                    self.canLoadMore = false
                }
            }
            self.isLoadingMore = false
        }
    }
}

struct ChannelEpisodeRow: View {
    let ep: EpisodeMetadata
    var channelTitle: String = ""
    var channelUrl: String = ""
    @ObservedObject var dataManager: DataManager
    
    private var activeDownload: ActiveDownload? {
        dataManager.activeDownloadsList.first(where: { $0.videoId == ep.id })
    }
    
    private var isDownloaded: Bool {
        dataManager.shows.contains { show in
            show.episodes.contains { $0.videoId == ep.id }
        }
    }
    
    private var isDownloading: Bool {
        activeDownload != nil || dataManager.activeDownloads.contains(ep.url)
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(ep.title)
                    .font(.subheadline)
                    .lineLimit(2)
                if let duration = ep.formattedDuration {
                    Text(duration)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            
            if let download = activeDownload {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: download.progress, total: 100.0)
                        .frame(width: 45)
                        .progressViewStyle(LinearProgressViewStyle(tint: PodcastTheme.accent))
                    Text("\(Int(download.progress))%")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            } else if isDownloading {
                ProgressView()
                    .frame(width: 24, height: 24)
            } else if isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Color(red: 0.18, green: 0.80, blue: 0.44))
                    .font(.title2)
            } else {
                Button(action: {
                    dataManager.addDownload(
                        url: ep.url,
                        isSubscribe: false,
                        channel: channelTitle.isEmpty ? nil : channelTitle,
                        channelUrl: channelUrl.isEmpty ? nil : channelUrl
                    )
                }) {
                    Image(systemName: "icloud.and.arrow.down")
                        .foregroundColor(PodcastTheme.accent)
                        .font(.title2)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.vertical, 6)
    }
}
