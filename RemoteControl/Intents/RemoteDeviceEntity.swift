import AppIntents
import Foundation

/// A device that plays for this user, as Shortcuts and Siri offer it: "Living Room", with what it
/// plays underneath.
///
/// Identified by the device, not the session: Jellyfin opens a new session each time a client
/// reconnects, and a Shortcut keeps whatever id it was built with.
nonisolated struct RemoteDeviceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "intents.remote.device.type"
    static let defaultQuery = RemoteDeviceQuery()

    let id: String
    let name: String
    let playing: String?

    init(session: RemoteSession) {
        id = session.deviceKey
        name = session.deviceName
        playing = session.nowPlaying?.summary
    }

    var displayRepresentation: DisplayRepresentation {
        if let playing {
            DisplayRepresentation(title: "\(name)", subtitle: "\(playing)")
        } else {
            DisplayRepresentation(title: "\(name)")
        }
    }
}

nonisolated struct RemoteDeviceQuery: EntityQuery {
    init() {}

    func entities(for identifiers: [String]) async throws -> [RemoteDeviceEntity] {
        let devices = try await suggestedEntities()
        return devices.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [RemoteDeviceEntity] {
        guard let shared = SharedSession.read() else { return [] }
        return try await RemoteControlAPI(session: shared).controllableSessions().map(RemoteDeviceEntity.init)
    }
}
