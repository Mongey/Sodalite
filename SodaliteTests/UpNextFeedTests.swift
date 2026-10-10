import Testing
import Foundation
@testable import Sodalite

/// The Up Next widget's list and its Play On request: what it shows, in which order, and what it
/// asks another device to play.
@Suite("Up Next: merge, play on")
struct UpNextFeedTests {

    private func item(_ id: String, series: String? = nil, positionTicks: Int64? = nil) -> TopShelfItem {
        TopShelfItem(
            id: id, name: id, type: series == nil ? .movie : .episode,
            seriesName: series, seriesId: series,
            parentIndexNumber: nil, indexNumber: nil,
            imageTags: nil, backdropImageTags: nil, parentBackdropImageTags: nil,
            parentThumbImageTag: nil, parentThumbItemId: nil,
            runTimeTicks: 100,
            userData: positionTicks.map { TopShelfUserData(playedPercentage: nil, playbackPositionTicks: $0) }
        )
    }

    // MARK: - Merge

    @Test func resumeComesFirstAndAShowAppearsOnce() {
        let resume = [item("ep-5", series: "severance", positionTicks: 40), item("arrival", positionTicks: 10)]
        let nextUp = [item("ep-6", series: "severance"), item("ep-1", series: "andor")]
        let merged = UpNextFeed.merge(resume: resume, nextUp: nextUp, limit: 10)
        #expect(merged.map(\.id) == ["ep-5", "arrival", "ep-1"])
    }

    @Test func twoEpisodesOfOneShowInResumeKeepTheFirst() {
        let resume = [item("ep-2", series: "dark"), item("ep-1", series: "dark")]
        #expect(UpNextFeed.merge(resume: resume, nextUp: [], limit: 10).map(\.id) == ["ep-2"])
    }

    @Test func theListIsCappedPerWidgetSize() {
        let nextUp = (0..<8).map { item("ep-\($0)", series: "show-\($0)") }
        #expect(UpNextFeed.merge(resume: [], nextUp: nextUp, limit: 3).map(\.id) == ["ep-0", "ep-1", "ep-2"])
        #expect(UpNextFeed.merge(resume: [], nextUp: nextUp, limit: 0).isEmpty)
    }

    @Test func onlyAPartWatchedItemResumes() {
        #expect(UpNextFeed.resumeTicks(of: item("a", positionTicks: 1_234)) == 1_234)
        #expect(UpNextFeed.resumeTicks(of: item("b", positionTicks: 0)) == nil)
        #expect(UpNextFeed.resumeTicks(of: item("c")) == nil)
    }

    @Test func aTapPlaysTheItemThroughTheAppsOwnDeepLink() throws {
        let url = try #require(UpNextFeed.playURL(itemID: "0123456789abcdef0123456789abcdef"))
        #expect(DeepLinkRoute.parse(url) == DeepLinkRoute(itemID: "0123456789abcdef0123456789abcdef", autoPlay: true))
    }

    // MARK: - Play on

    @Test func playNowNamesTheItemAndStartsAPartWatchedOneWhereItWasLeft() {
        let fresh = RemotePlayRequest(itemID: "ep-6", startPositionTicks: nil)
        #expect(fresh.path(sessionID: "abc") == "/Sessions/abc/Playing")
        #expect(fresh.queryItems == [
            URLQueryItem(name: "PlayCommand", value: "PlayNow"),
            URLQueryItem(name: "ItemIds", value: "ep-6"),
        ])
        #expect(RemotePlayRequest(itemID: "ep-6", startPositionTicks: 0).queryItems == fresh.queryItems)
        let resumed = RemotePlayRequest(itemID: "ep-5", startPositionTicks: 42)
        #expect(resumed.queryItems.last == URLQueryItem(name: "StartPositionTicks", value: "42"))
    }

    private static let sessions = """
    [
      {"Id":"atv-old","DeviceName":"Living Room","DeviceId":"atv-1","SupportsRemoteControl":true,
       "LastActivityDate":"2026-10-10T08:00:00.0000000Z","PlayableMediaTypes":["Audio","Video"]},
      {"Id":"atv-new","DeviceName":"Living Room","DeviceId":"atv-1","SupportsRemoteControl":true,
       "LastActivityDate":"2026-10-10T09:00:00.0000000Z","PlayableMediaTypes":["Audio","Video"]},
      {"Id":"speaker","DeviceName":"Kitchen","DeviceId":"speaker-1","SupportsRemoteControl":true,
       "LastActivityDate":"2026-10-10T09:30:00.0000000Z","PlayableMediaTypes":["Audio"]},
      {"Id":"web","DeviceName":"Firefox","DeviceId":"web-1","SupportsRemoteControl":true,
       "LastActivityDate":"2026-10-10T09:10:00.0000000Z",
       "NowPlayingItem":{"Id":"movie-1","Name":"Arrival"},"PlayState":{"IsPaused":true}},
      {"Id":"dlna","DeviceName":"Old TV","DeviceId":"dlna-1","SupportsRemoteControl":false,
       "LastActivityDate":"2026-10-10T09:50:00.0000000Z"},
      {"Id":"me","DeviceName":"Sodalite Remote","DeviceId":"own","SupportsRemoteControl":true,
       "LastActivityDate":"2026-10-10T09:59:00.0000000Z"}
    ]
    """

    private func targets() throws -> [RemoteSession] {
        let decoded = try JSONDecoder().decode([RemoteSession].self, from: Data(Self.sessions.utf8))
        return RemoteSession.playTargets(decoded, excludingDeviceID: "own")
    }

    @Test func playTargetsIncludeIdleAndPlayingVideoDevicesOncePerDevice() throws {
        // The Living Room's stale session drops out behind its newer one; the speaker cannot show
        // video, the DLNA renderer takes no commands, and this client is not a target.
        #expect(try targets().map(\.id) == ["web", "atv-new"])
    }

    @Test func aSavedDeviceResolvesToItsCurrentSession() throws {
        #expect(RemoteSession.target(in: try targets(), deviceKey: "atv-1")?.id == "atv-new")
        #expect(RemoteSession.target(in: try targets(), deviceKey: nil)?.id == "web")
        #expect(RemoteSession.target(in: try targets(), deviceKey: "speaker-1") == nil)
    }
}
