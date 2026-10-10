import Testing
import Foundation
@testable import Sodalite

/// Playing Elsewhere and the iOS widget read `GET /Sessions` through `RemoteSession` and steer
/// through `RemoteCommand`; both clients share these two types, so this is where their contract
/// with the server is pinned.
@Suite("Remote sessions: decoding, filtering, commands")
struct RemoteSessionTests {

    /// Five sessions the way a 10.10 server answers: an episode playing on an Apple TV, a movie
    /// paused in a browser, a phone that is open but idle, a DLNA renderer that cannot take
    /// commands, and this device itself.
    private static let sample = """
    [
      {"Id":"atv","UserId":"u1","Client":"Sodalite","DeviceName":"Living Room","DeviceId":"atv-1",
       "LastActivityDate":"2026-10-10T09:41:07.1234567Z","SupportsRemoteControl":true,
       "PlayState":{"PositionTicks":6000000000,"CanSeek":true,"IsPaused":false,"IsMuted":false},
       "NowPlayingItem":{"Id":"ep-2","Name":"The Long Night","Type":"Episode","SeriesName":"Severance",
         "SeriesId":"series-1","SeriesPrimaryImageTag":"series-tag","ParentIndexNumber":2,"IndexNumber":3,
         "RunTimeTicks":36000000000,"ImageTags":{"Primary":"ep-tag"}}},
      {"Id":"web","Client":"Jellyfin Web","DeviceName":"Firefox","DeviceId":"web-1",
       "LastActivityDate":"2026-10-10T09:45:00.0000000Z","SupportsRemoteControl":true,
       "PlayState":{"PositionTicks":12000000000,"IsPaused":true},
       "NowPlayingItem":{"Id":"movie-1","Name":"Arrival","Type":"Movie","RunTimeTicks":69000000000,
         "ImageTags":{"Primary":"movie-tag"}}},
      {"Id":"phone","Client":"Jellyfin iOS","DeviceName":"iPhone","DeviceId":"phone-1",
       "LastActivityDate":"2026-10-10T09:50:00.0000000Z","SupportsRemoteControl":true,
       "PlayState":{"CanSeek":false,"IsPaused":false}},
      {"Id":"dlna","Client":"DLNA","DeviceName":"Old TV","DeviceId":"dlna-1",
       "LastActivityDate":"2026-10-10T09:55:00.0000000Z","SupportsRemoteControl":false,
       "PlayState":{"PositionTicks":1,"IsPaused":false},
       "NowPlayingItem":{"Id":"movie-2","Name":"Heat","RunTimeTicks":100}},
      {"Id":"me","Client":"Sodalite","DeviceName":"This iPad","DeviceId":"own-device",
       "LastActivityDate":"2026-10-10T09:59:00.0000000Z","SupportsRemoteControl":true,
       "PlayState":{"PositionTicks":1,"IsPaused":false},
       "NowPlayingItem":{"Id":"movie-3","Name":"Ronin","RunTimeTicks":100}}
    ]
    """

    private func decodedSample() throws -> [RemoteSession] {
        try JSONDecoder().decode([RemoteSession].self, from: Data(Self.sample.utf8))
    }

    @Test func aPlayingEpisodeDecodesWithItsSeriesAndItsPoster() throws {
        let atv = try #require(try decodedSample().first { $0.id == "atv" })
        #expect(atv.deviceName == "Living Room")
        #expect(atv.client == "Sodalite")
        #expect(atv.supportsRemoteControl)
        let playing = try #require(atv.nowPlaying)
        #expect(playing.itemID == "ep-2")
        #expect(playing.title == "Severance")
        #expect(playing.episodeLine == "S2:E3 · The Long Night")
        #expect(playing.imageItemID == "series-1")
        #expect(playing.imageTag == "series-tag")
        #expect(playing.positionTicks == 6_000_000_000)
        #expect(playing.runtimeTicks == 36_000_000_000)
        #expect(!playing.isPaused)
        #expect(playing.progress == 1.0 / 6.0)
    }

    @Test func aPausedMovieIsItsOwnTitleWithNoEpisodeLine() throws {
        let web = try #require(try decodedSample().first { $0.id == "web" }?.nowPlaying)
        #expect(web.title == "Arrival")
        #expect(web.episodeLine == nil)
        #expect(web.isPaused)
    }

    @Test func aMovieShowsItsOwnPosterAndATrackItsAlbum() throws {
        let web = try #require(try decodedSample().first { $0.id == "web" }?.nowPlaying)
        #expect(web.imageItemID == "movie-1")
        #expect(web.imageTag == "movie-tag")

        let json = """
        {"Id":"s","SupportsRemoteControl":true,
         "NowPlayingItem":{"Id":"track","Name":"Song","AlbumId":"album","AlbumPrimaryImageTag":"album-tag"}}
        """
        let session = try JSONDecoder().decode(RemoteSession.self, from: Data(json.utf8))
        #expect(session.nowPlaying?.imageItemID == "album")
        #expect(session.nowPlaying?.imageTag == "album-tag")
    }

    @Test func anIdleSessionDecodesWithNothingPlaying() throws {
        let phone = try #require(try decodedSample().first { $0.id == "phone" })
        #expect(phone.nowPlaying == nil)
    }

    @Test func jellyfinsSevenDigitFractionsStillParse() {
        let date = RemoteSession.parseDate("2026-10-10T09:41:07.1234567Z")
        #expect(date == Date(timeIntervalSince1970: 1_791_625_267))
    }

    // MARK: - Filter

    @Test func onlyControllablePlayingOtherDevicesSurviveNewestFirst() throws {
        let kept = RemoteSession.controllable(try decodedSample(), excludingDeviceID: "own-device")
        #expect(kept.map(\.id) == ["web", "atv"])
    }

    // MARK: - Commands

    @Test func commandsRouteToTheSessionsPlayingEndpoint() {
        #expect(RemoteCommand.pause.path(sessionID: "abc") == "/Sessions/abc/Playing/Pause")
        #expect(RemoteCommand.unpause.path(sessionID: "abc") == "/Sessions/abc/Playing/Unpause")
        #expect(RemoteCommand.stop.path(sessionID: "abc") == "/Sessions/abc/Playing/Stop")
        #expect(RemoteCommand.stop.queryItems == nil)
        let seek = RemoteCommand.seek(toTicks: 42)
        #expect(seek.path(sessionID: "abc") == "/Sessions/abc/Playing/Seek")
        #expect(seek.queryItems == [URLQueryItem(name: "SeekPositionTicks", value: "42")])
        for command in [RemoteCommand.pause, .unpause, .stop, .seek(toTicks: 42)] {
            #expect(RemoteCommand(name: command.name, seekTicks: command.seekTicks) == command)
        }
        #expect(RemoteCommand(name: "PlayPause", seekTicks: 0) == nil)
    }

    @Test func theAppsEndpointsCarryTheSharedShape() {
        let list = JellyfinEndpoint.controllableSessions(userID: "u1")
        #expect(list.path == "/Sessions")
        #expect(list.method == .get)
        #expect(list.queryItems == [
            URLQueryItem(name: "ControllableByUserId", value: "u1"),
            URLQueryItem(name: "ActiveWithinSeconds", value: "960"),
        ])
        let command = JellyfinEndpoint.remoteCommand(sessionID: "abc", command: .seek(toTicks: 7))
        #expect(command.path == "/Sessions/abc/Playing/Seek")
        #expect(command.method == .post)
        #expect(command.requiresAuth)
    }

    @Test func skipsStayInsideTheItem() throws {
        let playing = try #require(try decodedSample().first { $0.id == "atv" }?.nowPlaying)
        #expect(playing.seekTarget(bySeconds: -10) == 6_000_000_000 - 100_000_000)
        #expect(playing.seekTarget(bySeconds: -1_000) == 0)
        #expect(playing.seekTarget(bySeconds: 10_000) == 36_000_000_000)
    }

    @Test func aPlayingIntervalEndsAtTheRuntimeAndPausedTimeIsFormatted() throws {
        let playing = try #require(try decodedSample().first { $0.id == "atv" }?.nowPlaying)
        let now = Date(timeIntervalSince1970: 10_000)
        let interval = try #require(playing.playbackInterval(asOf: now))
        #expect(interval.lowerBound == now.addingTimeInterval(-600))
        #expect(interval.upperBound == now.addingTimeInterval(3_000))
        #expect(playing.remainingText == "50:00")
    }

    @Test func theExpectedStateFollowsEachCommand() throws {
        let atv = try #require(try decodedSample().first { $0.id == "atv" })
        #expect(atv.applying(.pause)?.nowPlaying?.isPaused == true)
        #expect(atv.applying(.pause)?.applying(.unpause)?.nowPlaying?.isPaused == false)
        #expect(atv.applying(.seek(toTicks: 5))?.nowPlaying?.positionTicks == 5)
        #expect(atv.applying(.stop) == nil)
    }
}
