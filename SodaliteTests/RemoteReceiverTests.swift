import Testing
import Foundation
@testable import Sodalite

/// Sodalite as a target for other clients' remote controls: what it reads off Jellyfin's socket,
/// how the socket's retries are paced, and where each command lands.
@Suite("Remote receiver: socket messages, lifecycle, routing")
@MainActor
struct RemoteReceiverTests {

    private func decode(_ json: String) -> JellyfinSocketMessage? {
        JellyfinSocketMessage.decode(Data(json.utf8))
    }

    // MARK: - Decoding

    @Test func keepAliveCarriesTheTimeout() {
        #expect(decode(#"{"MessageType":"ForceKeepAlive","Data":60}"#) == .forceKeepAlive(seconds: 60))
    }

    @Test func playstateCommandsDecode() {
        #expect(decode(#"{"MessageType":"Playstate","Data":{"Command":"Pause","ControllingUserId":"u1"}}"#) == .playstate(.pause))
        #expect(decode(#"{"MessageType":"Playstate","Data":{"Command":"Unpause"}}"#) == .playstate(.unpause))
        #expect(decode(#"{"MessageType":"Playstate","Data":{"Command":"PlayPause"}}"#) == .playstate(.playPause))
        #expect(decode(#"{"MessageType":"Playstate","Data":{"Command":"Stop"}}"#) == .playstate(.stop))
        #expect(decode(#"{"MessageType":"Playstate","Data":{"Command":"NextTrack"}}"#) == .playstate(.nextTrack))
        #expect(decode(#"{"MessageType":"Playstate","Data":{"Command":"PreviousTrack"}}"#) == .playstate(.previousTrack))
    }

    @Test func seekConvertsTicksToSeconds() {
        let message = decode(#"{"MessageType":"Playstate","Data":{"Command":"Seek","SeekPositionTicks":6000000000}}"#)
        #expect(message == .playstate(.seek(seconds: 600)))
    }

    @Test func seekWithoutAPositionIsDropped() {
        #expect(decode(#"{"MessageType":"Playstate","Data":{"Command":"Seek"}}"#) == nil)
    }

    @Test func playNowTakesTheFirstItem() {
        let message = decode("""
        {"MessageType":"Play","Data":{"ItemIds":["a","b"],"StartPositionTicks":100,"PlayCommand":"PlayNow","ControllingUserId":"u1"}}
        """)
        #expect(message == .play(SocketPlayRequest(itemID: "a", startPositionTicks: 100)))
    }

    @Test func queueingCommandsAreNotPlayRequests() {
        #expect(decode(#"{"MessageType":"Play","Data":{"ItemIds":["a"],"PlayCommand":"PlayNext"}}"#) == nil)
        #expect(decode(#"{"MessageType":"Play","Data":{"ItemIds":[],"PlayCommand":"PlayNow"}}"#) == nil)
    }

    @Test func generalCommandKeepsItsArguments() {
        let message = decode("""
        {"MessageType":"GeneralCommand","Data":{"Name":"DisplayContent","Arguments":{"ItemId":"x","ItemType":"Movie"}}}
        """)
        #expect(message == .generalCommand(SocketGeneralCommand(name: "DisplayContent", arguments: ["ItemId": "x", "ItemType": "Movie"])))
    }

    @Test func otherMessagesAreKeptByTypeAndGarbageIsDropped() {
        #expect(decode(#"{"MessageType":"LibraryChanged","Data":{"ItemsAdded":[]}}"#) == .other(type: "LibraryChanged"))
        #expect(decode(#"{"MessageType":"KeepAlive"}"#) == .other(type: "KeepAlive"))
        #expect(decode("not json") == nil)
    }

    @Test func capabilitiesEncodeTheServerNames() throws {
        let data = try JSONEncoder().encode(ClientCapabilities.receiver)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["SupportsMediaControl"] as? Bool == true)
        #expect(json["PlayableMediaTypes"] as? [String] == ["Video"])
        #expect(json["SupportedCommands"] as? [String] == ["Play", "PlayState", "DisplayContent"])
    }

    // MARK: - Socket URL and lifecycle

    @Test func socketURLFollowsTheServerScheme() {
        let plain = JellyfinSocketTarget(baseURL: URL(string: "http://beelink:8096")!, authorization: "", deviceID: "dev")
        #expect(plain.socketURL?.absoluteString == "ws://beelink:8096/socket?deviceId=dev")
        let proxied = JellyfinSocketTarget(baseURL: URL(string: "https://example.org/jellyfin/")!, authorization: "", deviceID: "dev")
        #expect(proxied.socketURL?.absoluteString == "wss://example.org/jellyfin/socket?deviceId=dev")
    }

    @Test func backoffDoublesUpToAMinute() {
        #expect(JellyfinSocketLifecycle.backoff(attempt: 0) == .seconds(1))
        #expect(JellyfinSocketLifecycle.backoff(attempt: 3) == .seconds(8))
        #expect(JellyfinSocketLifecycle.backoff(attempt: 6) == .seconds(60))
        #expect(JellyfinSocketLifecycle.backoff(attempt: 40) == .seconds(60))
    }

    @Test func dropsBeforeConnectingBackOffFurtherEachTime() {
        var lifecycle = JellyfinSocketLifecycle()
        #expect(lifecycle.didDrop() == .seconds(1))
        lifecycle.retry()
        #expect(lifecycle.phase == .connecting(attempt: 1))
        #expect(lifecycle.didDrop() == .seconds(2))
        lifecycle.retry()
        #expect(lifecycle.didDrop() == .seconds(4))
    }

    @Test func aConnectionResetsTheBackoff() {
        var lifecycle = JellyfinSocketLifecycle()
        lifecycle.didDrop()
        lifecycle.retry()
        lifecycle.didDrop()
        lifecycle.retry()
        lifecycle.didReceiveMessage()
        #expect(lifecycle.phase == .connected)
        #expect(lifecycle.didDrop() == .seconds(1))
    }

    @Test func retryOnlyLeavesTheWaitingPhase() {
        var lifecycle = JellyfinSocketLifecycle()
        lifecycle.didReceiveMessage()
        lifecycle.retry()
        #expect(lifecycle.phase == .connected)
    }

    // MARK: - Routing

    private final class FakeSurface: RemotePlaybackSurface {
        var calls: [String] = []
        func remotePause() { calls.append("pause") }
        func remoteUnpause() { calls.append("unpause") }
        func remoteTogglePlayPause() { calls.append("toggle") }
        func remoteSeek(toSeconds seconds: Double) { calls.append("seek \(Int(seconds))") }
        func remoteNextTrack() { calls.append("next") }
        func remotePreviousTrack() { calls.append("previous") }
    }

    private final class Recorder {
        var stops = 0
        var opened: [DeepLinkRoute] = []
    }

    private func router(surface: FakeSurface?, recorder: Recorder) -> RemoteCommandRouter {
        RemoteCommandRouter(
            surface: { surface },
            stopPlayer: { recorder.stops += 1 },
            open: { recorder.opened.append($0) }
        )
    }

    private static let itemID = "0123456789abcdef0123456789abcdef"

    @Test func playstateReachesThePlayer() {
        let surface = FakeSurface()
        let recorder = Recorder()
        let router = router(surface: surface, recorder: recorder)
        router.handle(.playstate(.pause))
        router.handle(.playstate(.unpause))
        router.handle(.playstate(.playPause))
        router.handle(.playstate(.seek(seconds: 90)))
        router.handle(.playstate(.nextTrack))
        router.handle(.playstate(.previousTrack))
        #expect(surface.calls == ["pause", "unpause", "toggle", "seek 90", "next", "previous"])
        #expect(recorder.stops == 0)
    }

    @Test func stopClosesThePlayerRatherThanCallingIt() {
        let surface = FakeSurface()
        let recorder = Recorder()
        router(surface: surface, recorder: recorder).handle(.playstate(.stop))
        #expect(recorder.stops == 1)
        #expect(surface.calls.isEmpty)
    }

    @Test func playstateWithNoPlayerOnScreenDoesNothing() {
        let recorder = Recorder()
        router(surface: nil, recorder: recorder).handle(.playstate(.pause))
        #expect(recorder.stops == 0)
        #expect(recorder.opened.isEmpty)
    }

    @Test func playOpensTheItemAndStartsIt() {
        let recorder = Recorder()
        router(surface: nil, recorder: recorder)
            .handle(.play(SocketPlayRequest(itemID: Self.itemID, startPositionTicks: nil)))
        #expect(recorder.opened == [DeepLinkRoute(itemID: Self.itemID, autoPlay: true)])
    }

    @Test func displayContentOpensTheItemWithoutPlaying() {
        let recorder = Recorder()
        router(surface: nil, recorder: recorder)
            .handle(.generalCommand(SocketGeneralCommand(name: "DisplayContent", arguments: ["ItemId": Self.itemID])))
        #expect(recorder.opened == [DeepLinkRoute(itemID: Self.itemID, autoPlay: false)])
    }

    /// The id ends up in a request path, so anything that is not a GUID is refused the way a
    /// malformed `sodalite://` link is.
    @Test func itemIDsThatAreNotGUIDsAreRefused() {
        let recorder = Recorder()
        let router = router(surface: nil, recorder: recorder)
        router.handle(.play(SocketPlayRequest(itemID: "../../System/Info", startPositionTicks: nil)))
        router.handle(.generalCommand(SocketGeneralCommand(name: "DisplayContent", arguments: ["ItemId": "nope"])))
        #expect(recorder.opened.isEmpty)
    }

    @Test func unsupportedGeneralCommandsAreIgnored() {
        let recorder = Recorder()
        router(surface: nil, recorder: recorder)
            .handle(.generalCommand(SocketGeneralCommand(name: "DisplayMessage", arguments: ["Text": "hi"])))
        #expect(recorder.opened.isEmpty)
        #expect(recorder.stops == 0)
    }

    @Test func theActiveSlotForgetsOnlyItsOwnPlayer() {
        let first = FakeSurface()
        let second = FakeSurface()
        ActiveRemotePlayback.register(first)
        ActiveRemotePlayback.register(second)
        ActiveRemotePlayback.unregister(first)
        #expect(ActiveRemotePlayback.current === second)
        ActiveRemotePlayback.unregister(second)
        #expect(ActiveRemotePlayback.current == nil)
    }
}
