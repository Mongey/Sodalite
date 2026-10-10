import Foundation

/// What the remote-control socket's task is keyed on. Any change ends the current run and, when
/// `shouldConnect` still holds, starts a new one against whatever the active client points at now.
struct RemoteReceiverKey: Equatable {
    let serverID: String?
    let userID: String?
    let shouldConnect: Bool
    /// Bumped when the server becomes reachable again, which can also mean a different address.
    let contentReload: Int
}

extension DependencyContainer {
    /// Holds this device open to other clients' remote controls for as long as the calling task
    /// runs. Returns at once when there is no signed-in session to connect as.
    func runRemoteReceiver(appState: AppState) async {
        guard let baseURL = jellyfinClient.baseURL, jellyfinClient.accessToken != nil else { return }
        let target = JellyfinSocketTarget(
            baseURL: baseURL,
            authorization: jellyfinClient.buildAuthHeader(),
            deviceID: jellyfinClient.deviceID
        )
        let router = RemoteCommandRouter(
            surface: { ActiveRemotePlayback.current },
            stopPlayer: {
                guard ActiveRemotePlayback.current != nil || PlayerModalPresence.isPlayerActive else { return }
                PlayerModalDismisser.dismissActive(logPrefix: "[RemoteReceiver]")
                appState.requestPlayerDismissal &+= 1
            },
            open: { appState.open($0) }
        )
        let client = jellyfinClient
        let socket = JellyfinSocket(
            target: target,
            postCapabilities: {
                try? await client.request(endpoint: JellyfinEndpoint.sessionCapabilities(.receiver))
            },
            onMessage: { router.handle($0) }
        )
        await socket.run()
    }
}
