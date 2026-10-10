import Foundation

/// One entry of `GET /Sessions`, decoded for steering that device from here: who it is, what it
/// plays, and where playback stands.
///
/// Shared by the app and the widget extension, so it depends on Foundation alone. It is a separate
/// type from `JellyfinSessionInfo` on purpose: the tuner sweep asks one narrow question of the same
/// endpoint, and its decoder stays narrow.
nonisolated struct RemoteSession: Identifiable, Sendable, Equatable {
    let id: String
    let deviceID: String?
    let deviceName: String
    let client: String
    let lastActivity: Date?
    let supportsRemoteControl: Bool
    var nowPlaying: NowPlaying?

    nonisolated struct NowPlaying: Sendable, Equatable {
        let itemID: String
        let name: String
        let seriesName: String?
        let seasonNumber: Int?
        let episodeNumber: Int?
        /// The item whose Primary image stands for this one. An episode shows its series poster,
        /// because every control surface draws a poster-shaped tile and an episode's own Primary
        /// is a 16:9 still; anything else shows its own, and a track without one its album's.
        let imageItemID: String
        let imageTag: String?
        let runtimeTicks: Int64?
        var positionTicks: Int64
        var isPaused: Bool

        /// The series for an episode, the item's own name otherwise.
        var title: String { seriesName ?? name }

        /// "S1:E3 · Pilot" for an episode, nil for anything that is not one.
        var episodeLine: String? {
            guard seriesName != nil else { return nil }
            switch (seasonNumber, episodeNumber) {
            case let (season?, episode?):
                return "S\(season):E\(episode) · \(name)"
            default:
                return name
            }
        }

        var progress: Double? {
            guard let runtimeTicks, runtimeTicks > 0 else { return nil }
            return min(max(Double(positionTicks) / Double(runtimeTicks), 0), 1)
        }

        /// When the item started and when it ends, were it to play on uninterrupted from `date`.
        /// Handed to `ProgressView(timerInterval:)` and `Text(timerInterval:)`, which advance on their
        /// own, so a playing bar moves between polls (and on a widget, between timelines). Nil when
        /// the runtime is unknown, which leaves nothing to draw a bar against.
        func playbackInterval(asOf date: Date) -> ClosedRange<Date>? {
            guard let runtimeTicks, runtimeTicks > 0 else { return nil }
            let start = date.addingTimeInterval(-Double(positionTicks) / Double(RemoteSession.ticksPerSecond))
            return start...start.addingTimeInterval(Double(runtimeTicks) / Double(RemoteSession.ticksPerSecond))
        }

        /// Time left as "12:34" or "1:02:34", for a paused item, whose `Text(timerInterval:)` would
        /// keep counting.
        var remainingText: String? {
            guard let runtimeTicks, runtimeTicks > 0 else { return nil }
            let seconds = max(runtimeTicks - positionTicks, 0) / RemoteSession.ticksPerSecond
            let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
            return Duration.seconds(seconds).formatted(.time(pattern: pattern))
        }

        /// Where a relative skip lands, held inside the item. Without the upper bound a skip past
        /// the end asks the server for a position the player then has to reject.
        func seekTarget(bySeconds seconds: Int64) -> Int64 {
            let target = max(positionTicks + seconds * RemoteSession.ticksPerSecond, 0)
            guard let runtimeTicks, runtimeTicks > 0 else { return target }
            return min(target, runtimeTicks)
        }
    }

    static let ticksPerSecond: Int64 = 10_000_000
}

// MARK: - Listing

extension RemoteSession {
    static let listPath = "/Sessions"

    /// `ControllableByUserId` is the server's own answer to "may this user steer that session", so
    /// nothing here has to reproduce its rules. 960 seconds is the window jellyfin-web uses.
    static func listQuery(userID: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "ControllableByUserId", value: userID),
            URLQueryItem(name: "ActiveWithinSeconds", value: "960"),
        ]
    }

    /// The sessions worth offering controls for, most recently active first. A session that cannot
    /// take commands, or plays nothing, has no button that would do anything. Our own device is
    /// left out because it has its own player on screen.
    static func controllable(_ sessions: [RemoteSession], excludingDeviceID ownDeviceID: String?) -> [RemoteSession] {
        sessions
            .filter { $0.supportsRemoteControl && $0.nowPlaying != nil }
            .filter { ownDeviceID == nil || $0.deviceID != ownDeviceID }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    /// The state the session will report once the command has landed, so a control can show it
    /// without waiting a poll for the server to catch up. Nil for `stop`: the session stops
    /// playing and leaves the list.
    func applying(_ command: RemoteCommand) -> RemoteSession? {
        guard var playing = nowPlaying else { return self }
        switch command {
        case .stop:
            return nil
        case .pause:
            playing.isPaused = true
        case .unpause:
            playing.isPaused = false
        case .seek(let ticks):
            playing.positionTicks = ticks
        }
        var session = self
        session.nowPlaying = playing
        return session
    }
}

// MARK: - Commands

/// A playstate command for another session: `POST /Sessions/{id}/Playing/{command}`.
///
/// Pause and unpause rather than Jellyfin's PlayPause toggle. A control drawn from a state that is
/// a few seconds old (a widget always is) would otherwise flip the device the wrong way, and a
/// retried tap would flip it back. Naming the target state makes a repeat harmless.
nonisolated enum RemoteCommand: Sendable, Equatable {
    case pause
    case unpause
    case stop
    case seek(toTicks: Int64)

    var name: String {
        switch self {
        case .pause: "Pause"
        case .unpause: "Unpause"
        case .stop: "Stop"
        case .seek: "Seek"
        }
    }

    /// The inverse of `name` plus the seek target, for a caller that carries the command as plain
    /// values (an App Intent's parameters, a record in the app group).
    init?(name: String, seekTicks: Int64) {
        switch name {
        case "Pause": self = .pause
        case "Unpause": self = .unpause
        case "Stop": self = .stop
        case "Seek": self = .seek(toTicks: seekTicks)
        default: return nil
        }
    }

    var seekTicks: Int64 {
        if case .seek(let ticks) = self { ticks } else { 0 }
    }

    func path(sessionID: String) -> String {
        "/Sessions/\(sessionID)/Playing/\(name)"
    }

    var queryItems: [URLQueryItem]? {
        switch self {
        case .seek(let ticks):
            [URLQueryItem(name: "SeekPositionTicks", value: String(ticks))]
        default:
            nil
        }
    }
}

// MARK: - Decoding

extension RemoteSession: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case deviceID = "DeviceId"
        case deviceName = "DeviceName"
        case client = "Client"
        case lastActivity = "LastActivityDate"
        case supportsRemoteControl = "SupportsRemoteControl"
        case nowPlayingItem = "NowPlayingItem"
        case playState = "PlayState"
    }

    private enum ItemKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case seriesName = "SeriesName"
        case seriesID = "SeriesId"
        case seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case albumID = "AlbumId"
        case albumPrimaryImageTag = "AlbumPrimaryImageTag"
        case parentIndexNumber = "ParentIndexNumber"
        case indexNumber = "IndexNumber"
        case runTimeTicks = "RunTimeTicks"
        case imageTags = "ImageTags"
    }

    private enum ImageTagKeys: String, CodingKey {
        case primary = "Primary"
    }

    private enum PlayStateKeys: String, CodingKey {
        case positionTicks = "PositionTicks"
        case isPaused = "IsPaused"
    }

    /// Lenient past the id: a field this type cannot read costs that field, not the session, and a
    /// session whose item cannot be read is one with nothing playing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        deviceID = try? container.decodeIfPresent(String.self, forKey: .deviceID)
        deviceName = (try? container.decodeIfPresent(String.self, forKey: .deviceName)) ?? ""
        client = (try? container.decodeIfPresent(String.self, forKey: .client)) ?? ""
        lastActivity = (try? container.decodeIfPresent(String.self, forKey: .lastActivity))
            .flatMap(Self.parseDate)
        supportsRemoteControl = (try? container.decodeIfPresent(Bool.self, forKey: .supportsRemoteControl)) ?? false

        guard let item = try? container.nestedContainer(keyedBy: ItemKeys.self, forKey: .nowPlayingItem),
              let itemID = try? item.decode(String.self, forKey: .id)
        else {
            nowPlaying = nil
            return
        }
        let playState = try? container.nestedContainer(keyedBy: PlayStateKeys.self, forKey: .playState)
        let ownTag = (try? item.nestedContainer(keyedBy: ImageTagKeys.self, forKey: .imageTags))
            .flatMap { try? $0.decodeIfPresent(String.self, forKey: .primary) }
        let seriesID = try? item.decodeIfPresent(String.self, forKey: .seriesID)
        let seriesTag = try? item.decodeIfPresent(String.self, forKey: .seriesPrimaryImageTag)
        let albumID = try? item.decodeIfPresent(String.self, forKey: .albumID)
        let albumTag = try? item.decodeIfPresent(String.self, forKey: .albumPrimaryImageTag)

        let image: (id: String, tag: String?)
        if let seriesID, let seriesTag {
            image = (seriesID, seriesTag)
        } else if let ownTag {
            image = (itemID, ownTag)
        } else if let albumID, let albumTag {
            image = (albumID, albumTag)
        } else {
            image = (itemID, nil)
        }

        nowPlaying = NowPlaying(
            itemID: itemID,
            name: (try? item.decodeIfPresent(String.self, forKey: .name)) ?? "",
            seriesName: try? item.decodeIfPresent(String.self, forKey: .seriesName),
            seasonNumber: try? item.decodeIfPresent(Int.self, forKey: .parentIndexNumber),
            episodeNumber: try? item.decodeIfPresent(Int.self, forKey: .indexNumber),
            imageItemID: image.id,
            imageTag: image.tag,
            runtimeTicks: try? item.decodeIfPresent(Int64.self, forKey: .runTimeTicks),
            positionTicks: (try? playState?.decodeIfPresent(Int64.self, forKey: .positionTicks)) ?? 0,
            isPaused: (try? playState?.decodeIfPresent(Bool.self, forKey: .isPaused)) ?? false
        )
    }

    /// Jellyfin writes seven fractional digits ("2026-10-10T09:41:07.1234567Z"), which the ISO 8601
    /// parsers do not take. The fraction is dropped: ordering sessions by the second is enough.
    static func parseDate(_ string: String) -> Date? {
        var trimmed = string
        if let dot = trimmed.firstIndex(of: ".") {
            let fractionEnd = trimmed[dot...].dropFirst().firstIndex { !$0.isNumber } ?? trimmed.endIndex
            trimmed.removeSubrange(dot..<fractionEnd)
        }
        if !trimmed.hasSuffix("Z"), !trimmed.dropFirst(19).contains(where: { $0 == "+" || $0 == "-" }) {
            trimmed += "Z"
        }
        return try? Date(trimmed, strategy: .iso8601)
    }
}
