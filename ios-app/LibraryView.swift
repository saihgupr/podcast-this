import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Library Layout Mode

enum LibraryLayoutMode: String, CaseIterable {
    case grid2 = "grid2"
    case grid3 = "grid3"
    case list  = "list"

    var icon: String {
        switch self {
        case .grid2: return "square.grid.2x2"
        case .grid3: return "square.grid.3x3"
        case .list:  return "list.bullet"
        }
    }
    var label: String {
        switch self {
        case .grid2: return "2-Column Grid"
        case .grid3: return "3-Column Grid"
        case .list:  return "List"
        }
    }
}

// MARK: - Library (Shows Grid)

struct LibraryView: View {
    @ObservedObject var dataManager = DataManager.shared
    @ObservedObject var player = PodcastPlayer.shared
    @Binding var showFullPlayer: Bool
    @State private var showToDelete: PodcastShow? = nil
    @State private var confirmDeleteShow = false
    @State private var showToMerge: PodcastShow? = nil
    @State private var isReordering: Bool = false
    @State private var draggedShow: PodcastShow? = nil
    @AppStorage("libraryLayoutMode") private var layoutModeRaw: String = LibraryLayoutMode.grid2.rawValue
    @State private var navigationID = UUID()

    private var layoutMode: LibraryLayoutMode { LibraryLayoutMode(rawValue: layoutModeRaw) ?? .grid2 }

    private func gridColumns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    private func showContextMenu(for show: PodcastShow) -> some View {
        Group {
            Group {
                Button(role: .none) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isReordering = true
                    }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } label: {
                    Label("Edit / Reorder Shows", systemImage: "arrow.up.arrow.down")
                }
                Divider()
                Button(role: .none) {
                    dataManager.scanForNewEpisodes(for: show)
                } label: {
                    Label("Scan for New Episodes", systemImage: "arrow.triangle.2.circlepath")
                }
                Divider()
                Button(role: .none) {
                    let allPlayed = show.episodes.allSatisfy { $0.completed }
                    dataManager.setAllEpisodesPlayedState(for: show, completed: !allPlayed)
                } label: {
                    if show.episodes.allSatisfy({ $0.completed }) {
                        Label("Mark All as Unplayed", systemImage: "circle")
                    } else {
                        Label("Mark All as Played", systemImage: "checkmark.circle")
                    }
                }
                Divider()
                if dataManager.isSubscribed(to: show) {
                    Button(role: .none) {
                        dataManager.unsubscribe(from: show)
                    } label: {
                        Label("Unsubscribe", systemImage: "bell.slash")
                    }
                } else {
                    Button(role: .none) {
                        dataManager.subscribe(to: show, progressCompletion: { _ in }, completion: { _ in })
                    } label: {
                        Label("Subscribe", systemImage: "bell.fill")
                    }
                }
            }
            Group {
                Divider()
                Button(role: .none) {
                    showToMerge = show
                } label: {
                    Label("Merge Podcast...", systemImage: "arrow.triangle.merge")
                }
                Divider()
                Button(role: .destructive) {
                    showToDelete = show
                    confirmDeleteShow = true
                } label: {
                    Label("Delete Show", systemImage: "trash")
                }
            }
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                VStack(spacing: 0) {
                    ActiveDownloadsBanner()

                    if dataManager.shows.isEmpty {
                        ScrollView {
                            RefreshControlInstaller(onRefresh: {
                                await dataManager.loadDataAsync()
                            })
                            .frame(height: 1)

                            EmptyLibraryView()
                                .frame(maxWidth: .infinity, minHeight: 400)
                                .padding(.top, 60)
                        }
                    } else if layoutMode == .list {
                        List {
                            ForEach(dataManager.shows) { show in
                                if isReordering {
                                    ShowListRow(show: show)
                                        .wiggle(isWiggling: true, angle: (abs(show.channelName.hashValue) % 2 == 0) ? 1.2 : -1.2)
                                } else {
                                    NavigationLink(destination: ShowDetailView(show: show, showFullPlayer: $showFullPlayer)) {
                                        ShowListRow(show: show)
                                    }
                                    .contextMenu { showContextMenu(for: show) }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            showToDelete = show
                                            confirmDeleteShow = true
                                        } label: { Label("Delete", systemImage: "trash") }
                                    }
                                }
                            }
                            .onMove(perform: isReordering ? { source, dest in
                                withAnimation {
                                    dataManager.moveShow(fromOffsets: source, toOffset: dest)
                                }
                            } : nil)
                        }
                        .environment(\.editMode, isReordering ? .constant(.active) : .constant(.inactive))
                        .listStyle(PlainListStyle())
                        .padding(.bottom, player.currentEpisode != nil ? 90 : 0)
                        .refreshable {
                            guard !isReordering else { return }
                            await dataManager.syncSubscriptionsAsync()
                            await dataManager.loadDataAsync()
                        }
                    } else {
                        ScrollView {
                            RefreshControlInstaller(onRefresh: {
                                guard !isReordering else { return }
                                await dataManager.syncSubscriptionsAsync()
                                await dataManager.loadDataAsync()
                            })
                            .frame(height: 1)

                            LazyVGrid(
                                columns: gridColumns(layoutMode == .grid3 ? 3 : 2),
                                spacing: layoutMode == .grid3 ? 12 : 20
                            ) {
                                ForEach(dataManager.shows) { show in
                                    if isReordering {
                                        ShowCard(show: show, compact: layoutMode == .grid3)
                                            .wiggle(isWiggling: true, angle: (abs(show.channelName.hashValue) % 2 == 0) ? 1.5 : -1.5)
                                            .onDrag {
                                                self.draggedShow = show
                                                return NSItemProvider(object: show.channelName as NSString)
                                            }
                                            .onDrop(
                                                of: [UTType.text.identifier],
                                                delegate: ShowDropDelegate(targetShow: show, draggedShow: $draggedShow, dataManager: dataManager)
                                            )
                                    } else {
                                        NavigationLink(destination: ShowDetailView(show: show, showFullPlayer: $showFullPlayer)) {
                                            ShowCard(show: show, compact: layoutMode == .grid3)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .contextMenu { showContextMenu(for: show) }
                                    }
                                }
                            }
                            .padding(.horizontal, layoutMode == .grid3 ? 12 : 16)
                            .padding(.top, 8)
                            .padding(.bottom, player.currentEpisode != nil ? 90 : 20)
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !isReordering {
                        Menu {
                            ForEach(LibraryLayoutMode.allCases, id: \.rawValue) { mode in
                                Button {
                                    layoutModeRaw = mode.rawValue
                                } label: {
                                    Label(mode.label, systemImage: mode.icon)
                                }
                            }
                        } label: {
                            Image(systemName: layoutMode.icon)
                                .foregroundColor(PodcastTheme.accent)
                        }
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    if isReordering {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isReordering = false
                            }
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        } label: {
                            Text("Done")
                                .font(.headline.weight(.semibold))
                                .foregroundColor(PodcastTheme.accent)
                        }
                    } else {
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
            }
            .confirmationDialog(
                "Delete \"\(showToDelete?.channelName ?? "")\"?",
                isPresented: $confirmDeleteShow,
                titleVisibility: .visible
            ) {
                Button("Delete All Episodes", role: .destructive) {
                    if let show = showToDelete { dataManager.deleteShow(show) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes all downloaded episodes. Subscriptions will also be removed.")
            }
            .sheet(item: $showToMerge) { show in
                MergeShowSheet(sourceShow: show)
            }
        }
        .id(navigationID)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("popToLibraryRoot"))) { _ in
            navigationID = UUID()
        }
    }
}

/// Installs UIKit's native refresh control directly on SwiftUI's existing
/// scroll view, preserving the library grid's normal lazy rendering behavior.
private struct RefreshControlInstaller: UIViewRepresentable {
    let onRefresh: () async -> Void

    func makeCoordinator() -> RefreshControlCoordinator {
        RefreshControlCoordinator(onRefresh: onRefresh)
    }

    func makeUIView(context: Context) -> RefreshControlHostView {
        let view = RefreshControlHostView()
        view.refreshCoordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: RefreshControlHostView, context: Context) {
        context.coordinator.onRefresh = onRefresh
        view.refreshCoordinator = context.coordinator
        view.installRefreshControlWhenMounted()
    }
}

private final class RefreshControlCoordinator: NSObject {
    let refreshControl = UIRefreshControl()
    var onRefresh: () async -> Void
    private weak var installedScrollView: UIScrollView?
    private var isRefreshing = false

    init(onRefresh: @escaping () async -> Void) {
        self.onRefresh = onRefresh
        super.init()
        refreshControl.tintColor = UIColor(PodcastTheme.accent)
        refreshControl.addTarget(self, action: #selector(didPullToRefresh), for: .valueChanged)
    }

    func install(on scrollView: UIScrollView?) {
        guard let scrollView, installedScrollView !== scrollView else { return }
        if installedScrollView?.refreshControl === refreshControl {
            installedScrollView?.refreshControl = nil
        }
        scrollView.alwaysBounceVertical = true
        scrollView.refreshControl = refreshControl
        installedScrollView = scrollView
    }

    @objc private func didPullToRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.onRefresh()
            self.finishRefreshAfterPullEnds()
        }
    }

    private func finishRefreshAfterPullEnds() {
        guard installedScrollView?.isDragging != true else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.finishRefreshAfterPullEnds()
            }
            return
        }

        refreshControl.endRefreshing()
        isRefreshing = false
    }
}

private final class RefreshControlHostView: UIView {
    weak var refreshCoordinator: RefreshControlCoordinator?
    private var installScheduled = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        installRefreshControlWhenMounted()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        installRefreshControlWhenMounted()
    }

    func installRefreshControlWhenMounted() {
        guard !installScheduled else { return }
        installScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.installScheduled = false
            self.refreshCoordinator?.install(on: self.enclosingScrollView)
        }
    }

    private var enclosingScrollView: UIScrollView? {
        var view: UIView? = self
        while let currentView = view {
            if let scrollView = currentView as? UIScrollView {
                return scrollView
            }
            view = currentView.superview
        }
        return nil
    }
}

struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(PodcastTheme.accentGradient)
                    .frame(width: 100, height: 100)
                    .opacity(0.15)
                Image(systemName: "headphones")
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(PodcastTheme.accent)
            }
            Text("No Shows Yet")
                .font(.title2).fontWeight(.bold)
            Text("Use the Add tab to download a YouTube\nvideo or subscribe to a channel.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Show List Row (compact list layout)

struct ShowListRow: View {
    let show: PodcastShow
    @ObservedObject var dataManager = DataManager.shared
    @State private var artwork: UIImage? = nil

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(image: artwork, size: 56, isCircle: true)
                .cornerRadius(28)
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(show.channelName)
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("\(show.episodes.count) episode\(show.episodes.count == 1 ? "" : "s")")
                        .font(.caption).foregroundColor(.secondary)
                    if show.unplayedCount > 0 {
                        Text("\(show.unplayedCount) new")
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(PodcastTheme.accent)
                            .clipShape(Capsule())
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 6)
        .onAppear { loadArt() }
    }

    private func loadArt() {
        DispatchQueue.global(qos: .userInitiated).async {
            let img = DataManager.shared.artworkImage(for: show)
            DispatchQueue.main.async { artwork = img }
        }
    }
}

// MARK: - Show Card (Grid Cell)

struct ShowCard: View {
    let show: PodcastShow
    var compact: Bool = false
    @ObservedObject var dataManager = DataManager.shared
    @State private var artwork: UIImage? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            let artSize: CGFloat = compact ? 110 : 170
            let badgeSize: CGFloat = compact ? 22 : 30
            let badgeOffset: CGFloat = badgeSize * 0.2
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(image: artwork, size: artSize, isCircle: true)

                if show.unplayedCount > 0 {
                    ZStack {
                        Circle()
                            .fill(PodcastTheme.accent)
                            .frame(width: badgeSize, height: badgeSize)
                            .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 1)
                        Text("\(show.unplayedCount)")
                            .font(.system(size: badgeSize * 0.42, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .offset(x: -badgeOffset, y: -badgeOffset)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(show.channelName)
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("\(show.episodes.count) episode\(show.episodes.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .padding(.bottom, 4)
        .onAppear { loadArt() }
    }

    private func loadArt() {
        DispatchQueue.global(qos: .userInitiated).async {
            let img = DataManager.shared.artworkImage(for: show)
            DispatchQueue.main.async { artwork = img }
        }
    }
}

// MARK: - Show Detail (Episode List)

enum SortOrder: String, CaseIterable, Identifiable {
    case recentlyAdded = "Recently Added"
    case newestToOldest = "Newest to Oldest"
    case oldestToNewest = "Oldest to Newest"
    
    var id: String { self.rawValue }
}

struct ShowDetailView: View {
    let show: PodcastShow
    @Binding var showFullPlayer: Bool
    @ObservedObject var player = PodcastPlayer.shared
    @ObservedObject var dataManager = DataManager.shared
    @State private var headerArtwork: UIImage? = nil
    @State private var sortOrder: SortOrder = .recentlyAdded
    @State private var showChannelBrowser = false
    @State private var episodeToMove: PodcastEpisode? = nil
    @State private var isRefreshingThisShow = false
    @State private var rotationAngle: Double = 0.0
    @Environment(\.presentationMode) var presentationMode

    private var currentShow: PodcastShow {
        dataManager.shows.first(where: { $0.channelName == show.channelName }) ?? show
    }

    private var sortedEpisodes: [PodcastEpisode] {
        switch sortOrder {
        case .recentlyAdded:
            return currentShow.episodes.sorted { $0.dateAdded > $1.dateAdded }
        case .newestToOldest:
            return currentShow.episodes.sorted {
                let d1 = $0.uploadDate ?? $0.dateAdded
                let d2 = $1.uploadDate ?? $1.dateAdded
                return d1 > d2
            }
        case .oldestToNewest:
            return currentShow.episodes.sorted {
                let d1 = $0.uploadDate ?? $0.dateAdded
                let d2 = $1.uploadDate ?? $1.dateAdded
                return d1 < d2
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ActiveDownloadsBanner()

            List {
                Section {
                    VStack(spacing: 0) {
                        ShowHeaderView(show: currentShow, artwork: headerArtwork)
                            .padding(.bottom, 8)

                        // Play / Shuffle Buttons
                        HStack(spacing: 12) {
                            Button(action: {
                                var targetEpisode = sortedEpisodes.first
                                if dataManager.settings.onlyPlayUnplayed {
                                    if let firstUnplayed = sortedEpisodes.first(where: { !$0.completed }) {
                                        targetEpisode = firstUnplayed
                                    }
                                }
                                if let ep = targetEpisode {
                                    player.play(episode: ep)
                                }
                            }) {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text("Play")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(PodcastTheme.accent)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                            .buttonStyle(SpringButtonStyle())
                            
                            Button(action: {
                                var eligible = sortedEpisodes
                                if dataManager.settings.onlyPlayUnplayed {
                                    let unplayed = sortedEpisodes.filter { !$0.completed }
                                    if !unplayed.isEmpty {
                                        eligible = unplayed
                                    }
                                }
                                if let randomEp = eligible.randomElement() {
                                    player.play(episode: randomEp)
                                }
                            }) {
                                HStack {
                                    Image(systemName: "shuffle")
                                    Text("Shuffle")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(.secondarySystemGroupedBackground))
                                .foregroundColor(PodcastTheme.accent)
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(PodcastTheme.accent, lineWidth: 1.5)
                                )
                            }
                            .buttonStyle(SpringButtonStyle())
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                Section {
                    ForEach(sortedEpisodes) { episode in
                        EpisodeRow(
                            episode: episode,
                            isCurrent: player.currentEpisode?.videoId == episode.videoId,
                            showFullPlayer: $showFullPlayer,
                            onMove: { episodeToMove = episode }
                        )
                        .listRowInsets(EdgeInsets())
                    }
                }

                if let channelUrl = currentShow.channelUrl, !channelUrl.isEmpty {
                    Section {
                        Button {
                            showChannelBrowser = true
                        } label: {
                            HStack {
                                Image(systemName: "safari")
                                Text("Find More Episodes...")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(.secondarySystemGroupedBackground))
                            .foregroundColor(PodcastTheme.accent)
                            .cornerRadius(12)
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(SpringButtonStyle())
                        .sheet(isPresented: $showChannelBrowser) {
                            NavigationView {
                                ChannelBrowserView(url: channelUrl, initialTitle: currentShow.channelName)
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(PlainListStyle())
            .padding(.bottom, player.currentEpisode != nil ? 90 : 0)
            .refreshable {
                await dataManager.loadDataAsync()
            }
        }
        .sheet(item: $episodeToMove) { ep in
            MoveEpisodeSheet(episode: ep)
        }
        .navigationTitle(currentShow.channelName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        isRefreshingThisShow = true
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                            rotationAngle = 360
                        }
                        dataManager.scanForNewEpisodes(for: currentShow) {
                            withAnimation(.easeOut(duration: 0.3)) {
                                isRefreshingThisShow = false
                                rotationAngle = 0
                            }
                        }
                    } label: {
                        let isBusy = (dataManager.isSyncing && dataManager.currentSyncChannel == currentShow.channelName) || isRefreshingThisShow
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.body.weight(.semibold))
                            .foregroundColor(PodcastTheme.accent)
                            .rotationEffect(.degrees(isBusy ? rotationAngle : 0))
                            .scaleEffect(isBusy ? 1.15 : 1.0)
                    }
                    .buttonStyle(SpringButtonStyle())
                    .disabled(isRefreshingThisShow || (dataManager.isSyncing && dataManager.currentSyncChannel == currentShow.channelName))

                    Menu {
                        Picker("Sort By", selection: $sortOrder) {
                            ForEach(SortOrder.allCases) { order in
                                Text(order.rawValue).tag(order)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                            .foregroundColor(PodcastTheme.accent)
                            .font(.title3)
                    }
                }
            }
        }
        .onAppear { loadHeaderArt() }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    private func loadHeaderArt() {
        DispatchQueue.global(qos: .userInitiated).async {
            let img = DataManager.shared.artworkImage(for: show)
            DispatchQueue.main.async { headerArtwork = img }
        }
    }
}

// MARK: - Show Header with Subscribe Button

struct ShowHeaderView: View {
    let show: PodcastShow
    let artwork: UIImage?
    @ObservedObject var dataManager = DataManager.shared
    @State private var subscribing = false

    private var isSubscribed: Bool { dataManager.isSubscribed(to: show) }
    private var hasChannelUrl: Bool { !(show.channelUrl ?? "").isEmpty }

    var body: some View {
        VStack(spacing: 16) {
            ArtworkView(image: artwork, size: 140, isCircle: true)
                .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 6)

            VStack(spacing: 4) {
                Text(show.channelName)
                    .font(.title3).fontWeight(.bold)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Label("\(show.episodes.count) episode\(show.episodes.count == 1 ? "" : "s")", systemImage: "waveform")
                    if show.unplayedCount > 0 {
                        Label("\(show.unplayedCount) new", systemImage: "circle.fill")
                            .foregroundColor(PodcastTheme.accent)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            // Always show Subscribe / Unsubscribe button
            Button {
                if isSubscribed {
                    dataManager.unsubscribe(from: show)
                } else {
                    if hasChannelUrl {
                        dataManager.subscribe(to: show) { _ in } completion: { _ in }
                    } else {
                        subscribing = true
                        dataManager.subscribe(to: show) { progress in
                            // Handled progress
                        } completion: { success in
                            subscribing = false
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if subscribing {
                        ProgressView().scaleEffect(0.75)
                    } else {
                        Image(systemName: isSubscribed ? "bell.fill" : "bell")
                    }
                    Text(subscribing ? "Subscribing..." : (isSubscribed ? "Subscribed" : "Subscribe"))
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(isSubscribed ? PodcastTheme.accent : Color(.secondarySystemGroupedBackground))
                )
                .overlay(
                    Capsule().stroke(isSubscribed ? Color.clear : PodcastTheme.accent, lineWidth: 1.5)
                )
                .foregroundColor(isSubscribed ? .white : PodcastTheme.accent)
            }
            .buttonStyle(SpringButtonStyle())
            .disabled(subscribing)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
    }
}


// MARK: - Episode Row (swipe to delete)

struct EpisodeRow: View {
    let episode: PodcastEpisode
    let isCurrent: Bool
    @Binding var showFullPlayer: Bool
    var onMove: (() -> Void)? = nil
    @ObservedObject var player = PodcastPlayer.shared
    @State private var rowArtwork: UIImage? = nil
    @State private var isRescanningSponsorBlock = false
    @State private var isAnalyzingSpeakers = false
    @State private var rowAlertTitle: String = ""
    @State private var rowAlertMessage: String? = nil
    @State private var showRowAlert = false

    var body: some View {
        HStack(spacing: 12) {
            // Main content area - tapping plays and opens the player; "Open" in context menu opens without playing
            HStack(spacing: 12) {
                ArtworkView(image: rowArtwork, size: 56)
                    .cornerRadius(8)

                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.title)
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundColor(isCurrent ? PodcastTheme.accent : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Text(episode.formattedUploadDate ?? episode.formattedDateAdded)
                            .font(.caption).foregroundColor(.secondary)
                        Text("·").font(.caption).foregroundColor(.secondary)
                        HStack(alignment: .center, spacing: 7) {
                            Text(episode.formattedDuration)
                                .font(.caption).foregroundColor(.secondary)
                            if isAnalyzingSpeakers {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: PodcastTheme.speakerSkipPurple))
                                    .scaleEffect(0.55)
                                    .frame(width: 10, height: 10)
                            } else if episode.hasSpeakerAnalysis {
                                Image(systemName: "person.wave.2.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(PodcastTheme.speakerSkipPurple)
                                    .offset(y: -1.5)
                                    .accessibilityLabel("Speaker analysis available")
                            }
                        }
                    }

                    if episode.progressFraction > 0 && !episode.completed {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color(.systemFill)).frame(height: 3)
                                Capsule()
                                    .fill(PodcastTheme.accent)
                                    .frame(width: geo.size.width * episode.progressFraction, height: 3)
                            }
                        }
                        .frame(height: 3)
                    } else if episode.completed {
                        Label("Played", systemImage: "checkmark.circle.fill")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                player.play(episode: episode, autoPlay: true)
                showFullPlayer = true
            }

            Spacer()

            // Explicit Play/Pause Button
            Button(action: {
                if isCurrent {
                    player.togglePlay()
                } else {
                    player.play(episode: episode, autoPlay: true)
                }
            }) {
                Image(systemName: isCurrent && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(PodcastTheme.accent)
            }
            .buttonStyle(BorderlessButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        // ← Swipe left to delete episode
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                DataManager.shared.deleteEpisode(episode)
            } label: {
                Image(systemName: "trash")
            }
        }
        // → Swipe right to mark as played/unplayed
        .swipeActions(edge: .leading) {
            Button {
                if episode.completed {
                    DataManager.shared.updateProgress(videoId: episode.videoId, position: 0.0, completed: false)
                } else {
                    DataManager.shared.updateProgress(videoId: episode.videoId, position: episode.duration, completed: true)
                }
            } label: {
                Image(systemName: episode.completed ? "circle" : "checkmark.circle")
            }
            .tint(.green)
        }
        .contextMenu {
            Button {
                player.play(episode: episode, autoPlay: false)
                showFullPlayer = true
            } label: {
                Label("Open", systemImage: "arrow.up.right.and.arrow.down.left.rectangle")
            }
            Divider()
            if let onMove = onMove {
                Button {
                    onMove()
                } label: {
                    Label("Move Episode...", systemImage: "folder.badge.plus")
                }
                Divider()
            }
            Button {
                if episode.completed {
                    DataManager.shared.updateProgress(videoId: episode.videoId, position: 0.0, completed: false)
                } else {
                    DataManager.shared.updateProgress(videoId: episode.videoId, position: episode.duration, completed: true)
                }
            } label: {
                Label(episode.completed ? "Mark as Unplayed" : "Mark as Played", systemImage: episode.completed ? "circle" : "checkmark.circle")
            }
            Divider()
            Button {
                isRescanningSponsorBlock = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                DataManager.shared.rescanSponsorBlockSegments(videoId: episode.videoId) { result in
                    isRescanningSponsorBlock = false
                    switch result {
                    case .success(let count):
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        rowAlertTitle = "SponsorBlock"
                        if count == 0 {
                            rowAlertMessage = "No SponsorBlock segments found for this episode."
                        } else {
                            if !DataManager.shared.settings.sponsorBlockEnabled {
                                rowAlertMessage = "Updated! Found \(count) SponsorBlock segment\(count == 1 ? "" : "s"), but SponsorBlock is currently DISABLED in Settings.\n\nPlease enable SponsorBlock in Settings for segments to appear on the timeline and automatically skip."
                            } else {
                                rowAlertMessage = "Updated! Found \(count) SponsorBlock segment\(count == 1 ? "" : "s")."
                            }
                        }
                        showRowAlert = true
                    case .failure(let error):
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        rowAlertTitle = "SponsorBlock Error"
                        rowAlertMessage = "Failed to rescan SponsorBlock: \(error.localizedDescription)"
                        showRowAlert = true
                    }
                }
            } label: {
                Label("Rescan SponsorBlock", systemImage: "scissors")
            }
            .disabled(isRescanningSponsorBlock)

            Button {
                isAnalyzingSpeakers = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                let hasDiarization = episode.speakerDiarization != nil && !(episode.speakerDiarization?.speakers.isEmpty ?? true)
                DataManager.shared.quickAnalyzeSpeakers(episode: episode, force: hasDiarization) { _ in
                } completion: { result in
                    isAnalyzingSpeakers = false
                    switch result {
                    case .success(let diarization):
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        let count = diarization.speakers.count
                        rowAlertTitle = "Speaker Analysis"
                        rowAlertMessage = count == 0 ? "WhisperX analysis finished, but no distinct speakers were identified." : "WhisperX analysis complete! Identified \(count) speaker\(count == 1 ? "" : "s")."
                        showRowAlert = true
                    case .failure(let error):
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        rowAlertTitle = "Speaker Analysis Failed"
                        rowAlertMessage = error.localizedDescription
                        showRowAlert = true
                    }
                }
            } label: {
                Label(
                    isAnalyzingSpeakers ? "Analyzing Speakers..." : "Analyze Speakers",
                    systemImage: "person.wave.2.fill"
                )
            }
            .disabled(isAnalyzingSpeakers)

            Divider()
            Button(role: .destructive) {
                DataManager.shared.deleteEpisode(episode)
            } label: {
                Label("Delete Episode", systemImage: "trash")
            }
        }
        .alert(isPresented: $showRowAlert) {
            Alert(
                title: Text(rowAlertTitle),
                message: Text(rowAlertMessage ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear { loadArt() }
    }

    private func loadArt() {
        DispatchQueue.global(qos: .userInitiated).async {
            let img = DataManager.shared.artworkImage(for: episode)
            DispatchQueue.main.async { rowArtwork = img }
        }
    }
}

// MARK: - Reusable Artwork View

struct ArtworkView: View {
    let image: UIImage?
    let size: CGFloat
    var isCircle: Bool = false

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    PodcastTheme.accentGradient
                    Image(systemName: "waveform")
                        .font(.system(size: size * 0.33, weight: .light))
                        .foregroundColor(.white.opacity(0.85))
                }
            }
        }
        .frame(width: size, height: size)
        .cornerRadius(isCircle ? size / 2 : size * 0.12)
    }
}

// MARK: - Mini Player Bar

struct MiniPlayerBar: View {
    @ObservedObject var player = PodcastPlayer.shared
    @Binding var showFullPlayer: Bool
    @State private var artwork: UIImage? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Progress line
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color(.systemFill)).frame(height: 2)
                    Rectangle()
                        .fill(PodcastTheme.accent)
                        .frame(width: player.duration > 0 ? geo.size.width * (player.currentTime / player.duration) : 0, height: 2)
                }
            }
            .frame(height: 2)

            HStack(spacing: 12) {
                ArtworkView(image: artwork, size: 44)
                    .cornerRadius(8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentEpisode?.title ?? "")
                        .font(.subheadline).fontWeight(.semibold).lineLimit(1)
                    Text(player.currentEpisode?.channel ?? "")
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }

                Spacer()

                HStack(spacing: 20) {
                    Button { player.skipForward() } label: {
                        Image(systemName: "goforward.\(Int(DataManager.shared.settings.skipDuration))").font(.system(size: 20))
                    }
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 22))
                    }
                }
                .foregroundColor(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
        .onTapGesture { showFullPlayer = true }
        .onAppear { loadArt() }
        .onChange(of: player.currentEpisode) { _ in loadArt() }
    }

    private func loadArt() {
        guard let ep = player.currentEpisode else { artwork = nil; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let img = DataManager.shared.artworkImage(for: ep)
            DispatchQueue.main.async { artwork = img }
        }
    }
}

// MARK: - Merge Show Sheet

struct MergeShowSheet: View {
    let sourceShow: PodcastShow
    @ObservedObject var dataManager = DataManager.shared
    @Environment(\.dismiss) var dismiss

    @State private var selectedTargetChannel: String = ""
    @State private var customChannelName: String = ""
    @State private var isCreatingNewChannel: Bool = false
    @State private var showConfirmationAlert: Bool = false

    private var otherShows: [PodcastShow] {
        dataManager.shows.filter { $0.channelName != sourceShow.channelName }
    }

    private var effectiveTargetChannel: String {
        if isCreatingNewChannel {
            return customChannelName.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return selectedTargetChannel
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Source Podcast")) {
                    HStack(spacing: 12) {
                        ArtworkView(image: dataManager.artworkImage(for: sourceShow), size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sourceShow.channelName)
                                .font(.headline)
                            Text("\(sourceShow.episodes.count) episode\(sourceShow.episodes.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(
                    header: Text("Merge Into Podcast"),
                    footer: Text("All episodes from \"\(sourceShow.channelName)\" will be moved into the target podcast channel.")
                ) {
                    ForEach(otherShows) { show in
                        Button {
                            selectedTargetChannel = show.channelName
                            isCreatingNewChannel = false
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkView(image: dataManager.artworkImage(for: show), size: 36)
                                Text(show.channelName)
                                    .foregroundColor(.primary)
                                Spacer()
                                if !isCreatingNewChannel && selectedTargetChannel == show.channelName {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundColor(PodcastTheme.accent)
                                }
                            }
                        }
                    }

                    Button {
                        isCreatingNewChannel = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundColor(PodcastTheme.accent)
                            Text("Create New Channel...")
                                .foregroundColor(PodcastTheme.accent)
                                .fontWeight(.semibold)
                            Spacer()
                            if isCreatingNewChannel {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundColor(PodcastTheme.accent)
                            }
                        }
                    }

                    if isCreatingNewChannel {
                        TextField("New Channel Name", text: $customChannelName)
                            .autocapitalization(.words)
                    }
                }
            }
            .navigationTitle("Merge Podcast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Merge") {
                        if !effectiveTargetChannel.isEmpty && effectiveTargetChannel != sourceShow.channelName {
                            showConfirmationAlert = true
                        }
                    }
                    .disabled(effectiveTargetChannel.isEmpty || effectiveTargetChannel == sourceShow.channelName)
                }
            }
            .alert("Confirm Merge", isPresented: $showConfirmationAlert) {
                Button("Merge", role: .destructive) {
                    let target = effectiveTargetChannel
                    dataManager.mergeShow(sourceShow, into: target)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to move \(sourceShow.episodes.count) episode(s) from \"\(sourceShow.channelName)\" into \"\(effectiveTargetChannel)\"?")
            }
        }
    }
}

// MARK: - Move Episode Sheet

struct MoveEpisodeSheet: View {
    let episode: PodcastEpisode
    @ObservedObject var dataManager = DataManager.shared
    @Environment(\.dismiss) var dismiss

    @State private var selectedTargetChannel: String = ""
    @State private var customChannelName: String = ""
    @State private var isCreatingNewChannel: Bool = false

    private var otherShows: [PodcastShow] {
        dataManager.shows.filter { $0.channelName != episode.channel }
    }

    private var effectiveTargetChannel: String {
        if isCreatingNewChannel {
            return customChannelName.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return selectedTargetChannel
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Episode")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(episode.title)
                            .font(.headline)
                        Text("Current Channel: \(episode.channel)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text("Move To Podcast Channel")) {
                    ForEach(dataManager.shows) { show in
                        Button {
                            selectedTargetChannel = show.channelName
                            isCreatingNewChannel = false
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkView(image: dataManager.artworkImage(for: show), size: 36)
                                Text(show.channelName)
                                    .foregroundColor(.primary)
                                Spacer()
                                if !isCreatingNewChannel && selectedTargetChannel == show.channelName {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundColor(PodcastTheme.accent)
                                }
                            }
                        }
                    }

                    Button {
                        isCreatingNewChannel = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundColor(PodcastTheme.accent)
                            Text("Create New Channel...")
                                .foregroundColor(PodcastTheme.accent)
                                .fontWeight(.semibold)
                            Spacer()
                            if isCreatingNewChannel {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundColor(PodcastTheme.accent)
                            }
                        }
                    }

                    if isCreatingNewChannel {
                        TextField("New Channel Name", text: $customChannelName)
                            .autocapitalization(.words)
                    }
                }
            }
            .navigationTitle("Move Episode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        let target = effectiveTargetChannel
                        if !target.isEmpty && target != episode.channel {
                            dataManager.moveEpisode(episode, toChannel: target)
                            dismiss()
                        }
                    }
                    .disabled(effectiveTargetChannel.isEmpty || effectiveTargetChannel == episode.channel)
                }
            }
        }
    }
}

// MARK: - Active Downloads Banner Component

struct ActiveDownloadsBanner: View {
    @ObservedObject var dataManager = DataManager.shared

    var body: some View {
        if !dataManager.activeDownloadsList.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ProgressView()
                        .scaleEffect(0.85)
                    Text("Downloading (\(dataManager.activeDownloadsList.count))")
                        .font(.headline)
                        .foregroundColor(PodcastTheme.accent)
                    Spacer()
                }

                ForEach(dataManager.activeDownloadsList) { download in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(download.title)
                            .font(.subheadline)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        
                        Text(download.channel)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        
                        HStack(spacing: 8) {
                            ProgressView(value: min(max(download.progress, 0), 100), total: 100.0)
                                .progressViewStyle(LinearProgressViewStyle(tint: PodcastTheme.accent))
                            
                            Text("\(Int(download.progress))%")
                                .font(.caption)
                                .font(.caption.weight(.bold))
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Text(download.status)
                                .font(.caption2)
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(PodcastTheme.accent)
                            
                            Spacer()
                            
                            if download.status == "Downloading" && download.speed != "N/A" {
                                Text("\(download.speed) • ETA \(download.eta)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .cornerRadius(8)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }
}

// MARK: - Wiggle / Jiggle Mode Modifier

struct WiggleModifier: ViewModifier {
    let isWiggling: Bool
    let rotationAngle: Double
    @State private var isAnimating = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(Angle(degrees: isWiggling ? (isAnimating ? rotationAngle : -rotationAngle) : 0))
            .offset(
                x: isWiggling ? (isAnimating ? -0.8 : 0.8) : 0,
                y: isWiggling ? (isAnimating ? 0.8 : -0.8) : 0
            )
            .animation(
                isWiggling ? Animation.easeInOut(duration: 0.13).repeatForever(autoreverses: true) : .default,
                value: isAnimating
            )
            .onAppear {
                if isWiggling {
                    isAnimating = true
                }
            }
            .onChange(of: isWiggling) { newValue in
                isAnimating = newValue
            }
    }
}

extension View {
    func wiggle(isWiggling: Bool, angle: Double = 1.5) -> some View {
        modifier(WiggleModifier(isWiggling: isWiggling, rotationAngle: angle))
    }
}

// MARK: - Grid Show Drag & Drop Delegate

struct ShowDropDelegate: DropDelegate {
    let targetShow: PodcastShow
    @Binding var draggedShow: PodcastShow?
    let dataManager: DataManager

    func dropEntered(info: DropInfo) {
        guard let draggedShow = draggedShow,
              draggedShow.id != targetShow.id,
              let fromIndex = dataManager.shows.firstIndex(where: { $0.id == draggedShow.id }),
              let toIndex = dataManager.shows.firstIndex(where: { $0.id == targetShow.id }) else {
            return
        }

        withAnimation(.easeInOut(duration: 0.25)) {
            dataManager.moveShow(fromIndex: fromIndex, toIndex: toIndex)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedShow = nil
        return true
    }
}

