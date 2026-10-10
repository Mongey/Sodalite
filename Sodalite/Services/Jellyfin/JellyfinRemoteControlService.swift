import Foundation

/// Steering other devices that play for this user (Playing Elsewhere). A protocol of its own rather
/// than two more methods on the playback service, whose test doubles have no use for them.
protocol RemoteControlServiceProtocol {
    /// The active server's sessions worth offering controls for, most recently active first, with
    /// this device left out.
    func controllableSessions(userID: String) async throws -> [RemoteSession]
    func send(_ command: RemoteCommand, to sessionID: String) async throws
}

final class JellyfinRemoteControlService: RemoteControlServiceProtocol {
    let client: JellyfinClient

    init(client: JellyfinClient) {
        self.client = client
    }

    func controllableSessions(userID: String) async throws -> [RemoteSession] {
        let sessions = try await client.request(
            endpoint: JellyfinEndpoint.controllableSessions(userID: userID),
            responseType: [RemoteSession].self
        )
        return RemoteSession.controllable(sessions, excludingDeviceID: client.deviceID)
    }

    func send(_ command: RemoteCommand, to sessionID: String) async throws {
        try await client.request(
            endpoint: JellyfinEndpoint.remoteCommand(sessionID: sessionID, command: command)
        )
    }
}
