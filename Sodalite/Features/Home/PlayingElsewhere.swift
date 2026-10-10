import SwiftUI

/// What the user's other devices are playing, and the controls to steer them, at the top of Home.
///
/// Not a `HomeRowType`: the section exists only while something plays somewhere else, so there is
/// nothing to order or switch off in Customize Home, and it never joins Home's cached feed.
@MainActor
@Observable
final class PlayingElsewhereModel {
    private(set) var sessions: [RemoteSession] = []
    /// When `sessions` was fetched. The playing bars count on from here, so it moves with the data
    /// rather than with every render.
    private(set) var fetchedAt = Date()

    private let service: RemoteControlServiceProtocol
    private let userID: String

    /// Commands sent in the last few seconds. A device reports its new state on its own schedule,
    /// so a poll that lands first would otherwise snap the button back to what it just changed.
    private var pending: [String: (command: RemoteCommand, until: Date)] = [:]

    static let pollInterval: Duration = .seconds(5)
    private static let pendingWindow: TimeInterval = 6

    init(service: RemoteControlServiceProtocol, userID: String) {
        self.service = service
        self.userID = userID
    }

    /// Runs for as long as the calling `.task` does, which is as long as Home is on screen.
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    func refresh() async {
        do {
            let fresh = try await service.controllableSessions(userID: userID)
            fetchedAt = Date()
            sessions = expected(from: fresh)
        } catch is CancellationError {
            return
        } catch {
            // A server without remote control, or one that is unreachable, simply has no section.
            sessions = []
        }
    }

    func send(_ command: RemoteCommand, to session: RemoteSession) async {
        pending[session.id] = (command, Date().addingTimeInterval(Self.pendingWindow))
        apply(command, to: session.id)
        do {
            try await service.send(command, to: session.id)
        } catch {
            pending[session.id] = nil
            await refresh()
        }
    }

    private func apply(_ command: RemoteCommand, to sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if let updated = sessions[index].applying(command) {
            sessions[index] = updated
        } else {
            sessions.remove(at: index)
        }
    }

    private func expected(from fresh: [RemoteSession]) -> [RemoteSession] {
        let now = Date()
        pending = pending.filter { $0.value.until > now }
        return fresh.compactMap { session in
            guard let command = pending[session.id]?.command else { return session }
            return session.applying(command)
        }
    }
}

struct PlayingElsewhereSection: View {
    let model: PlayingElsewhereModel
    let imageURL: (RemoteSession.NowPlaying) -> URL?

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.shellPaysLeadingInset) private var shellPaysLeading
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    private var leadingInset: CGFloat {
        shellPaysLeading ? metrics.rowLeading(shellPaysLeading: true) : metrics.rowInset
    }

    var body: some View {
        if !model.sessions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("home.playingElsewhere.title")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .padding(.leading, leadingInset)
                    .padding(.trailing, metrics.rowInset)

                RowScrollView(leading: leadingInset, trailing: metrics.rowInset,
                              vertical: metrics.rowVerticalPadding) {
                    LazyHStack(spacing: metrics.itemSpacing) {
                        ForEach(model.sessions) { session in
                            if let playing = session.nowPlaying {
                                RemoteSessionCard(
                                    session: session,
                                    playing: playing,
                                    fetchedAt: model.fetchedAt,
                                    imageURL: imageURL(playing),
                                    metrics: metrics,
                                    send: { command in Task { await model.send(command, to: session) } }
                                )
                            }
                        }
                    }
                }
                .focusSectionCompat()
            }
        }
    }
}

private struct RemoteSessionCard: View {
    let session: RemoteSession
    let playing: RemoteSession.NowPlaying
    let fetchedAt: Date
    let imageURL: URL?
    let metrics: LayoutMetrics
    let send: (RemoteCommand) -> Void

    private var artworkSize: CGSize {
        CGSize(width: metrics.listPosterSize.width, height: metrics.listPosterSize.height)
    }

    var body: some View {
        HStack(alignment: .top, spacing: metrics.itemSpacing * 0.75) {
            AsyncCachedImage(url: imageURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "play.tv").foregroundStyle(.secondary))
            }
            .frame(width: artworkSize.width, height: artworkSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                Text(playing.title)
                    .font(metrics.listTitleFont.weight(.semibold))
                    .lineLimit(1)
                if let episodeLine = playing.episodeLine {
                    Text(episodeLine)
                        .font(metrics.listOverviewFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Label(session.deviceName, systemImage: "tv.and.mediabox")
                    .font(metrics.listOverviewFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                progress
                controls
            }
        }
        .padding(metrics.itemSpacing * 0.6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Two landscape cards wide, but never wider than the row can show whole: on a phone the
        // card fills the row instead of running off its trailing edge.
        .containerRelativeFrame(.horizontal) { length, _ in
            min(length - metrics.rowInset * 2, metrics.landscapeSize.width * 1.9)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var progress: some View {
        if let interval = playing.playbackInterval(asOf: fetchedAt) {
            HStack(spacing: 8) {
                if playing.isPaused {
                    ProgressView(value: playing.progress ?? 0)
                    Text(playing.remainingText ?? "")
                } else {
                    ProgressView(timerInterval: interval, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    Text(timerInterval: interval, countsDown: true)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .tint(.primary)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            control("home.playingElsewhere.back10", systemImage: "gobackward.10") {
                send(.seek(toTicks: playing.seekTarget(bySeconds: -10)))
            }
            if playing.isPaused {
                control("home.playingElsewhere.play", systemImage: "play.fill") { send(.unpause) }
            } else {
                control("home.playingElsewhere.pause", systemImage: "pause.fill") { send(.pause) }
            }
            control("home.playingElsewhere.forward10", systemImage: "goforward.10") {
                send(.seek(toTicks: playing.seekTarget(bySeconds: 10)))
            }
            control("home.playingElsewhere.stop", systemImage: "stop.fill") { send(.stop) }
        }
        .padding(.top, 4)
    }

    private func control(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
    }
}
