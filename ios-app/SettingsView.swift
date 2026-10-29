import SwiftUI

struct SettingsView: View {
    @ObservedObject var dataManager = DataManager.shared
    @State private var ytDlpOK = false
    @State private var ffmpegOK = false
    @State private var isTestingServer = false
    @State private var serverTestStatus: String? = nil
    @State private var showingSshSettings = false

    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        
                        // Playback Settings
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Battery Saver Mode", systemImage: "battery.100.bolt")
                                    .font(.headline)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { dataManager.settings.batterySaverEnabled },
                                    set: { enabled in
                                        var newSettings = dataManager.settings
                                        newSettings.batterySaverEnabled = enabled
                                        dataManager.saveSettings(newSettings)
                                    }
                                ))
                                .labelsHidden()
                                .tint(PodcastTheme.accent)
                            }
                            
                            Text("Reduces battery drain by gating background polling to active transfers, caching skip calculations, and eliminating disk churn during playback.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, -4)
                            
                            Divider()
                                .padding(.vertical, 4)

                            HStack {
                                Label("Autoplay Next Episode", systemImage: "play.sequence.fill")
                                    .font(.headline)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { dataManager.settings.autoplayEnabled },
                                    set: { enabled in
                                        var newSettings = dataManager.settings
                                        newSettings.autoplayEnabled = enabled
                                        dataManager.saveSettings(newSettings)
                                    }
                                ))
                                .labelsHidden()
                                .tint(PodcastTheme.accent)
                            }
                            
                            Text("Automatically play the next episode when the current one finishes.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, -4)
                            
                            Divider()
                                .padding(.vertical, 4)

                            HStack {
                                Label("Only Play Unplayed", systemImage: "circle.badge.checkmark")
                                    .font(.headline)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { dataManager.settings.onlyPlayUnplayed },
                                    set: { enabled in
                                        var newSettings = dataManager.settings
                                        newSettings.onlyPlayUnplayed = enabled
                                        dataManager.saveSettings(newSettings)
                                    }
                                ))
                                .labelsHidden()
                                .tint(PodcastTheme.accent)
                            }
                            
                            Text("Skip or exclude episodes that have already been played all the way through.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, -4)

                            Divider()
                                .padding(.vertical, 4)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Label("Skip Interval: \(Int(dataManager.settings.skipDuration))s", systemImage: "clock.arrow.2.circlepath")
                                        .font(.headline)
                                    Spacer()
                                }
                                
                                Slider(value: Binding(
                                    get: { dataManager.settings.skipDuration },
                                    set: { newVal in
                                        let snapped = snapToStandardInterval(newVal)
                                        var newSettings = dataManager.settings
                                        newSettings.skipDuration = snapped
                                        dataManager.saveSettings(newSettings)
                                        PodcastPlayer.shared.setupRemoteCommandCenter()
                                    }
                                ), in: 5...60, step: 5)
                                .tint(PodcastTheme.accent)
                            }

                            Divider()
                                .padding(.vertical, 4)

                            HStack {
                                Label("L/R Audio Balance Slider", systemImage: "slider.horizontal.below.square.and.square.filled")
                                    .font(.headline)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { dataManager.settings.enableBalanceSlider },
                                    set: { enabled in
                                        var newSettings = dataManager.settings
                                        newSettings.enableBalanceSlider = enabled
                                        dataManager.saveSettings(newSettings)
                                    }
                                ))
                                .labelsHidden()
                                .tint(PodcastTheme.accent)
                            }
                            
                            Text("Show an audio balance slider on the full player window to fade audio between left and right speakers.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, -4)
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(16)
                        
                        // SponsorBlock Settings
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("SponsorBlock", systemImage: "scissors")
                                    .font(.headline)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { dataManager.settings.sponsorBlockEnabled },
                                    set: { enabled in
                                        var newSettings = dataManager.settings
                                        newSettings.sponsorBlockEnabled = enabled
                                        dataManager.saveSettings(newSettings)
                                    }
                                ))
                                .labelsHidden()
                                .tint(PodcastTheme.accent)
                            }
                            
                            Text("Automatically strip out ads, self-promotions, music outros, and filler segments from downloaded podcasts using crowdsourced data.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, -4)
                            
                            if dataManager.settings.sponsorBlockEnabled {
                                Divider()
                                    .padding(.vertical, 4)
                                
                                Text("Categories to Remove:")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(sponsorBlockCategoriesList, id: \.id) { category in
                                        HStack {
                                            Image(systemName: category.icon)
                                                .foregroundColor(category.color)
                                                .frame(width: 24)
                                            Text(category.name)
                                                .font(.subheadline)
                                            Spacer()
                                            Toggle("", isOn: Binding(
                                                get: { dataManager.settings.sponsorBlockCategories.contains(category.id) },
                                                set: { isSelected in
                                                    var newSettings = dataManager.settings
                                                    if isSelected {
                                                        if !newSettings.sponsorBlockCategories.contains(category.id) {
                                                            newSettings.sponsorBlockCategories.append(category.id)
                                                        }
                                                    } else {
                                                        newSettings.sponsorBlockCategories.removeAll { $0 == category.id }
                                                    }
                                                    dataManager.saveSettings(newSettings)
                                                }
                                            ))
                                            .labelsHidden()
                                            .tint(PodcastTheme.accent)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(16)

                        // Custom User Skips Settings
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Custom User Skips", systemImage: "scissors.badge.ellipsis")
                                    .font(.headline)
                                    .foregroundColor(PodcastTheme.accent)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { dataManager.settings.userSkipsEnabled },
                                    set: { enabled in
                                        var newSettings = dataManager.settings
                                        newSettings.userSkipsEnabled = enabled
                                        dataManager.saveSettings(newSettings)
                                    }
                                ))
                                .labelsHidden()
                                .tint(PodcastTheme.accent)
                            }
                            
                            Text("Automatically jump past custom marked skip sections (cut speakers, banter, rants) created in the player's Snipper editor.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, -4)
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(16)

                        // Computer WhisperX Diarization Server
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Computer WhisperX Server", systemImage: "desktopcomputer")
                                    .font(.headline)
                                Spacer()
                                if let status = serverTestStatus {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(status == "Online" ? Color.green : Color.red)
                                            .frame(width: 8, height: 8)
                                        Text(status)
                                            .font(.caption2.weight(.bold))
                                            .foregroundColor(status == "Online" ? .green : .red)
                                    }
                                }
                            }

                            Text("URL of your computer microservice for WhisperX speaker diarization.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, -4)

                            HStack(spacing: 8) {
                                TextField("http://192.168.1.100:8000", text: Binding(
                                    get: { dataManager.settings.whisperServerUrl },
                                    set: { newUrl in
                                        var newSettings = dataManager.settings
                                        newSettings.whisperServerUrl = newUrl
                                        dataManager.saveSettings(newSettings)
                                    }
                                ))
                                .font(.subheadline.monospaced())
                                .padding(10)
                                .background(Color(.tertiarySystemFill))
                                .cornerRadius(8)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)

                                Button {
                                    testServerConnection()
                                } label: {
                                    if isTestingServer {
                                        ProgressView()
                                            .padding(.horizontal, 10)
                                    } else {
                                        Text("Test")
                                            .font(.footnote.weight(.semibold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 10)
                                            .background(RoundedRectangle(cornerRadius: 8).fill(PodcastTheme.accent))
                                    }
                                }
                                .buttonStyle(SpringButtonStyle())
                            }

                            Divider()
                                .padding(.vertical, 4)

                            HStack {
                                Label("Detect Foreign Languages", systemImage: "globe.badge.chevron.backward")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { dataManager.settings.detectLanguagesDuringDiarization },
                                    set: { val in
                                        var s = dataManager.settings
                                        s.detectLanguagesDuringDiarization = val
                                        dataManager.saveSettings(s)
                                    }
                                ))
                                .labelsHidden()
                                .tint(PodcastTheme.accent)
                            }

                            Text("Scans audio for non-English speech during WhisperX diarization. Keep off for fastest analysis (~10x faster).")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(.top, -4)

                            Button {
                                showingSshSettings = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "terminal.fill")
                                    Text("Configure SSH Remote Start/Stop...")
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundColor(Color(red: 0.72, green: 0.35, blue: 0.98))
                            }
                            .padding(.top, 2)
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(16)

                        // System Dependencies
                        VStack(alignment: .leading, spacing: 12) {
                            Text("System Status")
                                .font(.headline)

                            HStack {
                                Image(systemName: ytDlpOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(ytDlpOK ? .green : .red)
                                Text("yt-dlp")
                                Spacer()
                                Text(ytDlpOK ? "Installed" : "Not Found")
                                    .font(.caption)
                                    .foregroundColor(ytDlpOK ? .green : .red)
                            }
                            Divider()
                            HStack {
                                Image(systemName: ffmpegOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(ffmpegOK ? .green : .red)
                                Text("ffmpeg")
                                Spacer()
                                Text(ffmpegOK ? "Installed" : "Not Found")
                                    .font(.caption)
                                    .foregroundColor(ffmpegOK ? .green : .red)
                            }
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(16)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 80)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingSshSettings) {
                SSHComputerSettingsSheet(isPresented: $showingSshSettings)
            }
            .onAppear { checkDeps() }
        }
    }

    private func checkDeps() {
        let fm = FileManager.default
        let paths = ["/usr/bin/", "/usr/local/bin/", "/var/jb/usr/bin/"]
        ytDlpOK = paths.contains { fm.fileExists(atPath: $0 + "yt-dlp") }
        ffmpegOK = paths.contains { fm.fileExists(atPath: $0 + "ffmpeg") }
    }

    private func snapToStandardInterval(_ value: Double) -> Double {
        let standardIntervals: [Double] = [5, 10, 15, 30, 45, 60]
        return standardIntervals.min(by: { abs($0 - value) < abs($1 - value) }) ?? 15
    }

    private func testServerConnection() {
        var baseUrl = dataManager.settings.effectiveWhisperServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseUrl.hasSuffix("/") {
            baseUrl = String(baseUrl.dropLast())
        }
        guard let url = URL(string: "\(baseUrl)/health") else {
            serverTestStatus = "Invalid URL"
            return
        }

        isTestingServer = true
        serverTestStatus = nil

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 4.0

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                self.isTestingServer = false
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    self.serverTestStatus = "Online"
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } else {
                    self.serverTestStatus = "Offline"
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }.resume()
    }
}

struct SponsorBlockCategoryInfo {
    let id: String
    let name: String
    let icon: String
    let color: Color
}

let sponsorBlockCategoriesList = [
    SponsorBlockCategoryInfo(id: "sponsor", name: "Sponsors & Ads", icon: "megaphone.fill", color: .orange),
    SponsorBlockCategoryInfo(id: "selfpromo", name: "Self Promotion / Paid Promo", icon: "shield.fill", color: .purple),
    SponsorBlockCategoryInfo(id: "interaction", name: "Interaction Reminders", icon: "hand.thumbsup.fill", color: .blue),
    SponsorBlockCategoryInfo(id: "intro", name: "Intros & Breaks", icon: "play.circle.fill", color: .green),
    SponsorBlockCategoryInfo(id: "outro", name: "Outros & Credits", icon: "stop.circle.fill", color: .red),
    SponsorBlockCategoryInfo(id: "preview", name: "Previews & Hooks", icon: "eye.fill", color: .cyan),
    SponsorBlockCategoryInfo(id: "filler", name: "Filler Tangents", icon: "bubble.right.fill", color: .gray)
]
