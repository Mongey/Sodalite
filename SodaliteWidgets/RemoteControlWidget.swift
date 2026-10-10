import AppIntents
import SwiftUI
import WidgetKit

/// What another device is playing for this user, with play/pause and stop on the Home Screen.
struct RemoteControlWidget: Widget {
    static let kind = "RemoteControl"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: RemoteControlProvider()) { entry in
            RemoteControlWidgetView(entry: entry)
        }
        .configurationDisplayName("widget.remote.name")
        .description("widget.remote.description")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct RemoteControlEntry: TimelineEntry {
    enum State {
        case signedOut
        case idle
        case playing(session: RemoteSession, nowPlaying: RemoteSession.NowPlaying, poster: CGImage?)
    }

    let date: Date
    let state: State
}

struct RemoteControlProvider: TimelineProvider {
    /// A timeline cannot follow a device in real time, and the bar already advances on its own, so
    /// a playing entry only has to be redrawn often enough to catch a change made elsewhere. An
    /// idle one waits longer: the app reloads the widget when it signs in or out.
    private static let playingRefresh: TimeInterval = 5 * 60
    private static let idleRefresh: TimeInterval = 30 * 60

    func placeholder(in context: Context) -> RemoteControlEntry {
        RemoteControlEntry(date: Date(), state: .playing(session: .placeholder, nowPlaying: .placeholder, poster: nil))
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (RemoteControlEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task { completion(await Self.load()) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<RemoteControlEntry>) -> Void) {
        Task {
            let entry = await Self.load()
            let wait: TimeInterval
            if case .playing = entry.state { wait = Self.playingRefresh } else { wait = Self.idleRefresh }
            completion(Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(wait))))
        }
    }

    private static func load() async -> RemoteControlEntry {
        let now = Date()
        guard let shared = SharedSession.read() else {
            return RemoteControlEntry(date: now, state: .signedOut)
        }
        let api = WidgetRemoteAPI(session: shared)
        guard let sessions = try? await api.controllableSessions(),
              let session = PendingRemoteCommands.apply(to: sessions, now: now).first,
              let playing = session.nowPlaying
        else {
            return RemoteControlEntry(date: now, state: .idle)
        }
        let poster = await api.poster(for: playing, maxPixelSize: 300)
        return RemoteControlEntry(date: now, state: .playing(session: session, nowPlaying: playing, poster: poster))
    }
}

struct RemoteControlWidgetView: View {
    let entry: RemoteControlEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(.background, for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        switch entry.state {
        case .signedOut:
            message("widget.remote.signedOut", systemImage: "person.crop.circle.badge.questionmark")
        case .idle:
            message("widget.remote.idle", systemImage: "play.tv")
        case let .playing(session, playing, poster):
            switch family {
            case .accessoryRectangular:
                rectangular(session: session, playing: playing)
            case .systemMedium:
                medium(session: session, playing: playing, poster: poster)
            default:
                small(session: session, playing: playing, poster: poster)
            }
        }
    }

    private func message(_ key: LocalizedStringKey, systemImage: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(key)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func small(session: RemoteSession, playing: RemoteSession.NowPlaying, poster: CGImage?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                posterView(poster, height: 58)
                Spacer(minLength: 4)
                VStack(spacing: 6) {
                    playPauseButton(session: session, playing: playing)
                    commandButton(session: session, command: .stop, key: "widget.remote.stop", systemImage: "stop.fill")
                }
            }
            Spacer(minLength: 0)
            Text(playing.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(session.deviceName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            progress(playing, showsTime: false)
        }
    }

    private func medium(session: RemoteSession, playing: RemoteSession.NowPlaying, poster: CGImage?) -> some View {
        HStack(spacing: 12) {
            posterView(poster, height: 130)
            VStack(alignment: .leading, spacing: 3) {
                Text(playing.title)
                    .font(.headline)
                    .lineLimit(1)
                if let episodeLine = playing.episodeLine {
                    Text(episodeLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(session.deviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                progress(playing, showsTime: true)
                HStack(spacing: 0) {
                    commandButton(session: session, command: .seek(toTicks: playing.seekTarget(bySeconds: -10)),
                                  key: "widget.remote.back10", systemImage: "gobackward.10")
                    Spacer(minLength: 0)
                    playPauseButton(session: session, playing: playing)
                    Spacer(minLength: 0)
                    commandButton(session: session, command: .seek(toTicks: playing.seekTarget(bySeconds: 10)),
                                  key: "widget.remote.forward10", systemImage: "goforward.10")
                    Spacer(minLength: 0)
                    commandButton(session: session, command: .stop, key: "widget.remote.stop", systemImage: "stop.fill")
                }
                .padding(.top, 4)
            }
        }
    }

    private func rectangular(session: RemoteSession, playing: RemoteSession.NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(playing.title)
                .font(.headline)
                .lineLimit(1)
            Text(session.deviceName)
                .font(.caption)
                .lineLimit(1)
            progress(playing, showsTime: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func posterView(_ poster: CGImage?, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        Group {
            if let poster {
                Image(decorative: poster, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "play.tv").foregroundStyle(.secondary))
            }
        }
        .frame(width: height * 2 / 3, height: height)
        .clipShape(shape)
    }

    /// Counts on by itself while the device plays; a paused item holds still.
    @ViewBuilder
    private func progress(_ playing: RemoteSession.NowPlaying, showsTime: Bool) -> some View {
        if let interval = playing.playbackInterval(asOf: entry.date) {
            HStack(spacing: 6) {
                if playing.isPaused {
                    ProgressView(value: playing.progress ?? 0)
                    if showsTime { Text(playing.remainingText ?? "") }
                } else {
                    ProgressView(timerInterval: interval, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    if showsTime {
                        Text(timerInterval: interval, countsDown: true)
                            .frame(maxWidth: 52, alignment: .trailing)
                    }
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .tint(.primary)
        }
    }

    private func playPauseButton(session: RemoteSession, playing: RemoteSession.NowPlaying) -> some View {
        playing.isPaused
            ? commandButton(session: session, command: .unpause, key: "widget.remote.play", systemImage: "play.fill")
            : commandButton(session: session, command: .pause, key: "widget.remote.pause", systemImage: "pause.fill")
    }

    private func commandButton(session: RemoteSession, command: RemoteCommand,
                               key: LocalizedStringKey, systemImage: String) -> some View {
        Button(intent: RemoteCommandIntent(sessionID: session.id, command: command)) {
            Label(key, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(.fill.secondary, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

extension RemoteSession {
    /// The widget gallery's sample. Never sent anywhere: the gallery renders the placeholder.
    static let placeholder = RemoteSession(
        id: "placeholder",
        deviceID: nil,
        deviceName: "Living Room",
        client: "Sodalite",
        lastActivity: nil,
        supportsRemoteControl: true,
        nowPlaying: .placeholder
    )
}

extension RemoteSession.NowPlaying {
    static let placeholder = RemoteSession.NowPlaying(
        itemID: "placeholder",
        name: "Episode",
        seriesName: nil,
        seasonNumber: nil,
        episodeNumber: nil,
        imageItemID: "placeholder",
        imageTag: nil,
        runtimeTicks: 60 * 60 * RemoteSession.ticksPerSecond,
        positionTicks: 20 * 60 * RemoteSession.ticksPerSecond,
        isPaused: false
    )
}

#Preview("Medium, playing", as: .systemMedium) {
    RemoteControlWidget()
} timeline: {
    RemoteControlEntry(date: .now, state: .playing(session: .placeholder, nowPlaying: .placeholder, poster: nil))
    RemoteControlEntry(date: .now, state: .idle)
    RemoteControlEntry(date: .now, state: .signedOut)
}

#Preview("Small, playing", as: .systemSmall) {
    RemoteControlWidget()
} timeline: {
    RemoteControlEntry(date: .now, state: .playing(session: .placeholder, nowPlaying: .placeholder, poster: nil))
}
