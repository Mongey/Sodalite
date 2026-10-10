import Foundation

/// What another client can do to the player on screen. Each call names the state it wants, so a
/// repeated command (a retried Pause, two remotes pressing at once) changes nothing the second time.
@MainActor
protocol RemotePlaybackSurface: AnyObject {
    func remotePause()
    func remoteUnpause()
    func remoteTogglePlayPause()
    func remoteSeek(toSeconds seconds: Double)
    func remoteNextTrack()
    func remotePreviousTrack()
}

/// The player session currently on screen, if any. The player registers itself when it starts and
/// clears the slot when it stops; weak so a torn-down player can never be steered.
@MainActor
enum ActiveRemotePlayback {
    static weak var current: (any RemotePlaybackSurface)?

    static func register(_ surface: any RemotePlaybackSurface) {
        current = surface
    }

    static func unregister(_ surface: any RemotePlaybackSurface) {
        if current === surface { current = nil }
    }
}

/// Turns socket messages into actions on the app. Opening an item goes through the same route as a
/// `sodalite://` link, so the profile checks and the teardown of a player already on screen live in
/// one place.
@MainActor
struct RemoteCommandRouter {
    let surface: () -> (any RemotePlaybackSurface)?
    let stopPlayer: () -> Void
    let open: (DeepLinkRoute) -> Void

    func handle(_ message: JellyfinSocketMessage) {
        switch message {
        case .playstate(let command):
            handle(command)
        case .play(let request):
            guard DeepLinkRoute.isItemID(request.itemID) else { return }
            open(DeepLinkRoute(itemID: request.itemID, autoPlay: true))
        case .generalCommand(let command):
            guard command.name == "DisplayContent",
                  let itemID = command.arguments["ItemId"], DeepLinkRoute.isItemID(itemID)
            else { return }
            open(DeepLinkRoute(itemID: itemID, autoPlay: false))
        case .forceKeepAlive, .other:
            return
        }
    }

    private func handle(_ command: SocketPlaystateCommand) {
        if command == .stop {
            stopPlayer()
            return
        }
        guard let surface = surface() else { return }
        switch command {
        case .pause: surface.remotePause()
        case .unpause: surface.remoteUnpause()
        case .playPause: surface.remoteTogglePlayPause()
        case .seek(let seconds): surface.remoteSeek(toSeconds: seconds)
        case .nextTrack: surface.remoteNextTrack()
        case .previousTrack: surface.remotePreviousTrack()
        case .stop: return
        }
    }
}
