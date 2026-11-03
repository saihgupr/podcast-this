import SwiftUI

struct RadioView: View {
    @ObservedObject var store = RadioStore.shared
    @ObservedObject var radio = RadioPlayer.shared
    @ObservedObject var podcastPlayer = PodcastPlayer.shared

    @State private var showingAddSheet = false
    @State private var editingStation: RadioStation? = nil
    @State private var stationToDelete: RadioStation? = nil
    @State private var confirmDelete = false
    @State private var stationName = ""
    @State private var stationURL = ""

    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                if store.stations.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "radio")
                            .font(.system(size: 64))
                            .foregroundColor(.secondary)
                        Text("No Radio Stations")
                            .font(.title3).fontWeight(.bold)
                        Text("Add a station to start listening to live streams.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Button {
                            resetSheetFields()
                            showingAddSheet = true
                        } label: {
                            Label("Add Station", systemImage: "plus.circle.fill")
                                .foregroundColor(PodcastTheme.accent)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.stations) { station in
                            RadioStationRow(
                                station: station,
                                isCurrent: radio.currentStation?.id == station.id,
                                isPlaying: radio.isPlaying,
                                isLoading: radio.isLoading
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                radio.toggle(station: station)
                            }
                            .contextMenu {
                                Button {
                                    startEditing(station)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    stationToDelete = station
                                    confirmDelete = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    stationToDelete = station
                                    confirmDelete = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete(perform: deleteStations)
                        .onMove(perform: store.moveStation)
                    }
                    .listStyle(InsetGroupedListStyle())
                    .padding(.bottom, (podcastPlayer.currentEpisode != nil || radio.currentStation != nil) ? 90 : 0)
                }
            }
            .navigationTitle("Radio")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !store.stations.isEmpty {
                        EditButton()
                            .foregroundColor(PodcastTheme.accent)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        resetSheetFields()
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundColor(PodcastTheme.accent)
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                stationFormSheet(title: "Add Station") {
                    store.addStation(name: stationName.trimmingCharacters(in: .whitespacesAndNewlines), url: stationURL.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            .sheet(item: $editingStation) { station in
                stationFormSheet(title: "Edit Station", station: station) {
                    store.updateStation(station, name: stationName.trimmingCharacters(in: .whitespacesAndNewlines), url: stationURL.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            .confirmationDialog(
                "Delete \"\(stationToDelete?.name ?? "")\"?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Station", role: .destructive) {
                    if let station = stationToDelete { deleteStation(station) }
                    stationToDelete = nil
                }
                Button("Cancel", role: .cancel) { stationToDelete = nil }
            } message: {
                Text("This removes the station from your Radio list. It does not affect downloads.")
            }
        }
    }

    // MARK: - Helpers

    private var isFormValid: Bool {
        let name = stationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = stationURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !urlString.isEmpty else { return false }
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return false }
        return true
    }

    private func resetSheetFields() {
        stationName = ""
        stationURL = ""
    }

    private func startEditing(_ station: RadioStation) {
        stationName = station.name
        stationURL = station.streamURL
        editingStation = station
    }

    private func deleteStation(_ station: RadioStation) {
        if radio.currentStation?.id == station.id {
            radio.stop()
        }
        store.deleteStation(station)
    }

    private func deleteStations(at offsets: IndexSet) {
        let toDelete = offsets.map { store.stations[$0] }
        if toDelete.count == 1, let station = toDelete.first {
            stationToDelete = station
            confirmDelete = true
            return
        }
        for station in toDelete {
            if radio.currentStation?.id == station.id { radio.stop() }
            store.deleteStation(station)
        }
    }

    private func stationFormSheet(title: String, station: RadioStation? = nil, onSave: @escaping () -> Void) -> some View {
        NavigationView {
            Form {
                Section(header: Text("Station")) {
                    TextField("Name", text: $stationName)
                        .autocapitalization(.words)
                    TextField("Stream URL", text: $stationURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                if let station {
                    Section {
                        Button(role: .destructive) {
                            editingStation = nil
                            stationToDelete = station
                            confirmDelete = true
                        } label: {
                            Label("Delete Station", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        showingAddSheet = false
                        editingStation = nil
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        onSave()
                        showingAddSheet = false
                        editingStation = nil
                    }
                    .font(.body.weight(.semibold))
                    .foregroundColor(PodcastTheme.accent)
                    .disabled(!isFormValid)
                }
            }
        }
    }
}

private struct RadioStationRow: View {
    let station: RadioStation
    let isCurrent: Bool
    let isPlaying: Bool
    let isLoading: Bool

    @ObservedObject var radio = RadioPlayer.shared

    private var showSpinner: Bool {
        isCurrent && isLoading
    }

    private var showPause: Bool {
        isCurrent && (isPlaying || isLoading)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(station.name)
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundColor(.primary)
                Text(station.streamURL)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if showSpinner {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: PodcastTheme.accent))
            } else {
                Button {
                    radio.toggle(station: station)
                } label: {
                    Image(systemName: showPause ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(PodcastTheme.accent)
                }
                .buttonStyle(BorderlessButtonStyle())
            }
        }
        .padding(.vertical, 4)
    }
}
