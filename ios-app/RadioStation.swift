import Foundation
import Combine

public struct RadioStation: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var streamURL: String

    public init(id: UUID = UUID(), name: String, streamURL: String) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
    }
}

public class RadioStore: ObservableObject {
    public static let shared = RadioStore()

    @Published public var stations: [RadioStation] = []
    @Published public var lastPlayedStationID: UUID? {
        didSet { saveLastPlayed() }
    }

    private let stationsKey = "radio_stations_v1"
    private let lastStationKey = "radio_last_station_v1"

    private init() {
        load()
        if stations.isEmpty {
            stations = [
                RadioStation(name: "ABC Jazz", streamURL: "https://abc.streamguys1.com/live/abcjazz/icecast.audio"),
                RadioStation(name: "Classical NEPM", streamURL: "https://nepr.iad.streamguys1.com/WFCR-HD.mp3")
            ]
            saveStations()
        }
    }

    public func addStation(name: String, url: String) {
        stations.append(RadioStation(name: name, streamURL: url))
        saveStations()
    }

    public func deleteStation(_ station: RadioStation) {
        stations.removeAll { $0.id == station.id }
        if lastPlayedStationID == station.id {
            lastPlayedStationID = nil
        }
        saveStations()
    }

    public func updateStation(_ station: RadioStation, name: String, url: String) {
        guard let index = stations.firstIndex(where: { $0.id == station.id }) else { return }
        stations[index].name = name
        stations[index].streamURL = url
        saveStations()
    }

    public func moveStation(from source: IndexSet, to destination: Int) {
        stations.move(fromOffsets: source, toOffset: destination)
        saveStations()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: stationsKey),
           let decoded = try? JSONDecoder().decode([RadioStation].self, from: data) {
            stations = decoded
        }
        if let uuidString = UserDefaults.standard.string(forKey: lastStationKey) {
            lastPlayedStationID = UUID(uuidString: uuidString)
        }
    }

    private func saveStations() {
        if let data = try? JSONEncoder().encode(stations) {
            UserDefaults.standard.set(data, forKey: stationsKey)
        }
    }

    private func saveLastPlayed() {
        if let id = lastPlayedStationID {
            UserDefaults.standard.set(id.uuidString, forKey: lastStationKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastStationKey)
        }
    }
}
