import SwiftUI

struct AddView: View {
    @ObservedObject var dataManager = DataManager.shared
    @State private var inputUrl: String = ""
    @FocusState private var fieldFocused: Bool
    @State private var selectedLogTab: Int = 0 // 0 = Daemon Log, 1 = Manual Downloads
    @State private var isLogsExpanded: Bool = false

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
                    .onTapGesture { fieldFocused = false }

                VStack(spacing: 0) {
                    // ── Static Top Input Card ──
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Add a YouTube Link", systemImage: "plus.circle.fill")
                            .font(.headline)
                            .foregroundColor(PodcastTheme.accent)

                        HStack {
                            Image(systemName: "link")
                                .foregroundColor(.secondary)
                            TextField("YouTube video or channel URL", text: $inputUrl)
                                .textInputAutocapitalization(.none)
                                .disableAutocorrection(true)
                                .keyboardType(.URL)
                                .submitLabel(.done)
                                .focused($fieldFocused)
                            
                            Button(action: {
                                if let data = UIPasteboard.general.data(forPasteboardType: "public.utf8-plain-text"),
                                   let str = String(data: data, encoding: .utf8) {
                                    inputUrl = str.trimmingCharacters(in: .whitespacesAndNewlines)
                                } else if let string = UIPasteboard.general.string {
                                    inputUrl = string.trimmingCharacters(in: .whitespacesAndNewlines)
                                } else if let url = UIPasteboard.general.url {
                                    inputUrl = url.absoluteString
                                }
                            }) {
                                Image(systemName: "doc.on.clipboard")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(12)
                        .background(Color(.tertiarySystemFill))
                        .cornerRadius(10)

                        // Action Buttons
                        HStack(spacing: 12) {
                            Button {
                                guard !inputUrl.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                                fieldFocused = false
                                dataManager.addDownload(url: inputUrl, isSubscribe: false)
                                inputUrl = ""
                            } label: {
                                Label("Download", systemImage: "arrow.down.circle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(dataManager.isDownloading || inputUrl.isEmpty ? Color(.systemFill) : PodcastTheme.accent)
                                    .foregroundColor(dataManager.isDownloading || inputUrl.isEmpty ? .secondary : .white)
                                    .cornerRadius(10)
                            }
                            .disabled(dataManager.isDownloading || inputUrl.isEmpty)
                            .buttonStyle(PlainButtonStyle())

                            NavigationLink(destination: ChannelBrowserView(url: inputUrl, initialTitle: "")) {
                                Label("Browse", systemImage: "magnifyingglass")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color(.systemFill).opacity(0.1))
                                    .foregroundColor(PodcastTheme.accent)
                                    .cornerRadius(10)
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(PodcastTheme.accent.opacity(0.3), lineWidth: 1))
                            }
                            .disabled(dataManager.isDownloading || inputUrl.isEmpty)
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                    // ── Scrollable Area for Status, Active Downloads, and Logs ──
                    ScrollView {
                        VStack(spacing: 16) {

                            // ── System & Subscription Sync Status Card ──
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 10) {
                                    ZStack {
                                        Circle()
                                            .fill(statusBackgroundColor)
                                            .frame(width: 32, height: 32)
                                        
                                        if dataManager.isSyncing {
                                            ProgressView()
                                                .progressViewStyle(CircularProgressViewStyle(tint: statusIconColor))
                                                .scaleEffect(0.75)
                                        } else {
                                            Image(systemName: statusIconName)
                                                .font(.system(size: 15, weight: .bold))
                                                .foregroundColor(statusIconColor)
                                        }
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(statusTitle)
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        Text(statusSubtitle)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }

                                    Spacer()

                                    Button(action: {
                                        dataManager.syncSubscriptions()
                                    }) {
                                        HStack(spacing: 4) {
                                            if dataManager.isSyncing {
                                                ProgressView()
                                                    .scaleEffect(0.7)
                                            } else {
                                                Image(systemName: "arrow.triangle.2.circlepath")
                                                    .font(.caption.weight(.semibold))
                                            }
                                            Text(dataManager.isSyncing ? "Checking…" : "Sync Now")
                                                .font(.caption.weight(.semibold))
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(dataManager.isSyncing ? Color(.systemFill) : PodcastTheme.accent.opacity(0.12))
                                        .foregroundColor(dataManager.isSyncing ? .secondary : PodcastTheme.accent)
                                        .cornerRadius(8)
                                    }
                                    .disabled(dataManager.isSyncing)
                                    .buttonStyle(PlainButtonStyle())
                                }

                                Divider()

                                HStack {
                                    Label("\(dataManager.subscriptions.count) Subscribed Channels", systemImage: "bell.fill")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("Last Check: \(relativeLastSync)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(16)
                            .background(Color(.secondarySystemGroupedBackground))
                            .cornerRadius(16)

                            // ── Active Downloads List or Initial Preparing Indicator ──
                            if !dataManager.activeDownloadsList.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        ProgressView()
                                            .scaleEffect(0.85)
                                            .padding(.trailing, 4)
                                        Text("Downloading (\(dataManager.activeDownloadsList.count))")
                                            .font(.headline)
                                        Spacer()
                                        Button("Cancel All") {
                                            dataManager.cancelAllDownloads()
                                        }
                                        .font(.subheadline)
                                        .foregroundColor(.red)
                                    }

                                    VStack(spacing: 12) {
                                        ForEach(dataManager.activeDownloadsList) { download in
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(download.title)
                                                    .font(.subheadline)
                                                    .fontWeight(.medium)
                                                    .lineLimit(1)
                                                
                                                Text(download.channel)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                                
                                                HStack {
                                                    ProgressView(value: min(max(download.progress, 0), 100), total: 100.0)
                                                        .progressViewStyle(LinearProgressViewStyle(tint: PodcastTheme.accent))
                                                    
                                                    Text("\(Int(download.progress))%")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                }
                                                
                                                HStack {
                                                    Text(download.status)
                                                        .font(.caption2)
                                                        .fontWeight(.semibold)
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
                                            .background(Color(.tertiarySystemFill))
                                            .cornerRadius(8)
                                        }
                                    }
                                }
                                .padding(16)
                                .background(Color(.secondarySystemGroupedBackground))
                                .cornerRadius(16)
                            } else if dataManager.isDownloading {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(spacing: 10) {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: PodcastTheme.accent))
                                            .scaleEffect(0.9)
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Starting Download…")
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundColor(.primary)
                                            Text("Fetching metadata & preparing stream...")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                    }
                                }
                                .padding(14)
                                .background(Color(.secondarySystemGroupedBackground))
                                .cornerRadius(14)
                            }

                            // ── Live Logs & Activity Feed (Hidden by default) ──
                            VStack(alignment: .leading, spacing: isLogsExpanded ? 12 : 0) {
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isLogsExpanded.toggle()
                                    }
                                }) {
                                    HStack {
                                        Label("Activity Logs", systemImage: "terminal.fill")
                                            .font(.headline)
                                            .foregroundColor(.primary)

                                        Spacer()

                                        HStack(spacing: 4) {
                                            Text(isLogsExpanded ? "Hide" : "Show")
                                                .font(.caption.weight(.medium))
                                            Image(systemName: isLogsExpanded ? "chevron.up" : "chevron.down")
                                                .font(.caption)
                                        }
                                        .foregroundColor(PodcastTheme.accent)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(PlainButtonStyle())

                                if isLogsExpanded {
                                    Picker("Log Source", selection: $selectedLogTab) {
                                        Text("Background Daemon").tag(0)
                                        Text("Manual Downloads").tag(1)
                                    }
                                    .pickerStyle(SegmentedPickerStyle())

                                    let currentLogText = selectedLogTab == 0 ? dataManager.daemonLogs : dataManager.downloadLogs

                                    if currentLogText.isEmpty {
                                        Text("No recent log activity.")
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .padding(.vertical, 8)
                                    } else {
                                        ScrollView {
                                            Text(currentLogText)
                                                .font(.system(.caption, design: .monospaced))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .foregroundColor(.secondary)
                                        }
                                        .frame(maxHeight: 220)
                                        .padding(8)
                                        .background(Color(.systemBackground).opacity(0.6))
                                        .cornerRadius(8)
                                    }

                                    if selectedLogTab == 1 && !dataManager.downloadLogs.isEmpty {
                                        HStack {
                                            Spacer()
                                            Button("Clear Log") {
                                                dataManager.downloadLogs = ""
                                            }
                                            .font(.caption)
                                            .foregroundColor(.red)
                                        }
                                    }
                                }
                            }
                            .padding(16)
                            .background(Color(.secondarySystemGroupedBackground))
                            .cornerRadius(16)

                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 80)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { fieldFocused = false }
                    }
                }
            }
            .navigationTitle("Add")
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("podcastthis_open_url"))) { notification in
                if let url = notification.userInfo?["url"] as? String {
                    inputUrl = url
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if inputUrl == url {
                            inputUrl = ""
                        }
                    }
                }
            }
        }
    }

    // MARK: - Status Card Computed Properties

    private var statusTitle: String {
        if dataManager.isSyncing {
            return "Checking Subscriptions…"
        } else if dataManager.isDownloading {
            return "Downloading Episode…"
        } else if dataManager.syncStatusPhase == "error" {
            return "Sync Error"
        } else {
            return "Subscriptions"
        }
    }

    private var statusSubtitle: String {
        if dataManager.isSyncing {
            return dataManager.syncStatusMessage.isEmpty ? "Checking channels for new uploads..." : dataManager.syncStatusMessage
        } else if dataManager.isDownloading {
            return "Active download in progress"
        } else if !dataManager.syncStatusMessage.isEmpty && dataManager.syncStatusMessage != "Idle" {
            return dataManager.syncStatusMessage
        } else {
            return "Auto-check runs every 30 minutes in background."
        }
    }

    private var statusIconName: String {
        if dataManager.isSyncing {
            return "arrow.triangle.2.circlepath"
        } else if dataManager.isDownloading {
            return "arrow.down.circle.fill"
        } else if dataManager.syncStatusPhase == "error" {
            return "exclamationmark.triangle.fill"
        } else {
            return "checkmark.circle.fill"
        }
    }

    private var statusIconColor: Color {
        if dataManager.isSyncing {
            return PodcastTheme.accent
        } else if dataManager.isDownloading {
            return PodcastTheme.accent
        } else if dataManager.syncStatusPhase == "error" {
            return .red
        } else {
            return .green
        }
    }

    private var statusBackgroundColor: Color {
        statusIconColor.opacity(0.15)
    }
}
