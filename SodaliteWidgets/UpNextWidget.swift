import AppIntents
import SwiftUI
import WidgetKit

/// What to watch next: Continue Watching, then Next Up. A tap plays it here; with a device chosen in
/// the widget's settings, a TV button beside each item plays it there instead.
struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: UpNextFeed.kind, intent: UpNextConfigurationIntent.self, provider: UpNextProvider()) { entry in
            UpNextWidgetView(entry: entry)
        }
        .configurationDisplayName("widget.upNext.name")
        .description("widget.upNext.description")
        .supportedFamilies(Self.families)
    }

    #if os(iOS)
    private static let families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular]
    #else
    private static let families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
    #endif
}

/// The widget's "Play on" choice, stored as the device key with the names offered alongside.
///
/// A plain value rather than `PlaybackTargetEntity`: WidgetKit has to rebuild a saved entity in the
/// extension before every timeline, and where that rebuild failed (measured in the simulator, where
/// the system could not read the extension's App Intents metadata) the widget silently lost its
/// device. A string comes back as it was saved.
struct UpNextConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "widget.upNext.configuration.title"
    static let description = IntentDescription("widget.upNext.configuration.description")

    @Parameter(title: "widget.upNext.configuration.playOn", optionsProvider: UpNextDeviceOptions())
    var playOn: String?
}

struct UpNextDeviceOptions: DynamicOptionsProvider {
    func results() async throws -> ItemCollection<String> {
        let targets = try await KnownPlaybackTargets.online()
        return ItemCollection(sections: [
            IntentItemSection(items: targets.map { IntentItem($0.key, title: "\($0.name)") }),
        ])
    }
}

struct UpNextEntry: TimelineEntry {
    enum State {
        case signedOut
        case empty
        case items([UpNextEntryItem])
    }

    let date: Date
    let state: State
    let playOn: KnownPlaybackTargets.Target?
}

struct UpNextEntryItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let progress: Double?
    let startTicks: Int64?
    let artwork: CGImage?

    var playURL: URL? { UpNextFeed.playURL(itemID: id) }
}

struct UpNextProvider: AppIntentTimelineProvider {
    /// Next Up moves when something is watched, and the app reloads the widget when that happens on
    /// this device. The schedule only has to catch what was watched somewhere else.
    private static let refresh: TimeInterval = 45 * 60

    func placeholder(in context: Context) -> UpNextEntry {
        UpNextEntry(date: Date(), state: .items(UpNextEntryItem.placeholders(count: Self.limit(for: context.family))), playOn: nil)
    }

    func snapshot(for configuration: UpNextConfigurationIntent, in context: Context) async -> UpNextEntry {
        if context.isPreview {
            return placeholder(in: context)
        }
        return await Self.load(family: context.family, playOnKey: configuration.playOn)
    }

    func timeline(for configuration: UpNextConfigurationIntent, in context: Context) async -> Timeline<UpNextEntry> {
        let entry = await Self.load(family: context.family, playOnKey: configuration.playOn)
        return Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(Self.refresh)))
    }

    static func limit(for family: WidgetFamily) -> Int {
        switch family {
        case .systemMedium: 3
        case .systemLarge: 5
        default: 1
        }
    }

    private static func load(family: WidgetFamily, playOnKey: String?) async -> UpNextEntry {
        let now = Date()
        guard let shared = SharedSession.read() else {
            return UpNextEntry(date: now, state: .signedOut, playOn: nil)
        }
        let playOn: KnownPlaybackTargets.Target?
        if let playOnKey {
            playOn = (try? await KnownPlaybackTargets.resolve([playOnKey]).first)
                ?? KnownPlaybackTargets.Target(key: playOnKey, name: "")
        } else {
            playOn = nil
        }
        let api = RemoteControlAPI(session: shared)
        guard let items = try? await api.upNext(limit: limit(for: family)), !items.isEmpty else {
            return UpNextEntry(date: now, state: .empty, playOn: playOn)
        }
        // The small widget's picture spans its width; a row's is a thumbnail.
        let pixels = family == .systemSmall ? 480 : 300
        let artworks = await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask { (index, await api.artwork(for: item, maxPixelSize: pixels)) }
            }
            var byIndex: [Int: CGImage] = [:]
            for await (index, image) in group {
                byIndex[index] = image
            }
            return byIndex
        }
        let entries = items.enumerated().map { index, item in
            UpNextEntryItem(item, artwork: artworks[index])
        }
        return UpNextEntry(date: now, state: .items(entries), playOn: playOn)
    }
}

extension UpNextEntryItem {
    init(_ item: TopShelfItem, artwork: CGImage?) {
        let isEpisode = item.type == .episode && item.seriesName != nil
        self.init(
            id: item.id,
            title: isEpisode ? item.seriesName ?? item.name : item.name,
            subtitle: isEpisode
                ? EpisodeMetadataFormatter.episodeLine(under: item.seriesName,
                                                       season: item.parentIndexNumber,
                                                       episode: item.indexNumber,
                                                       title: item.name)
                : nil,
            progress: item.topShelfProgress,
            startTicks: UpNextFeed.resumeTicks(of: item),
            artwork: artwork
        )
    }

    /// The gallery's sample. Never opened: the gallery renders the placeholder.
    static func placeholders(count: Int) -> [UpNextEntryItem] {
        (0..<count).map { index in
            UpNextEntryItem(
                id: "placeholder-\(index)",
                title: String(localized: "widget.upNext.placeholder.title"),
                subtitle: "S1, E\(index + 2)",
                progress: index == 0 ? 0.4 : nil,
                startTicks: nil,
                artwork: nil
            )
        }
    }
}

struct UpNextWidgetView: View {
    let entry: UpNextEntry

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
        case .empty:
            message("widget.upNext.empty", systemImage: "checkmark.circle")
        case .items(let items):
            switch family {
            case .accessoryRectangular:
                if let first = items.first { rectangular(first) }
            case .systemMedium, .systemLarge:
                list(items)
            default:
                if let first = items.first { small(first) }
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

    private func small(_ item: UpNextEntryItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            artwork(item.artwork)
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    playOnButton(item, compact: true)
                        .padding(4)
                }
            Spacer(minLength: 0)
            Text(item.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            progress(item)
        }
        .widgetURL(item.playURL)
    }

    private func list(_ items: [UpNextEntryItem]) -> some View {
        let thumbHeight: CGFloat = family == .systemLarge ? 52 : 36
        return VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 7) {
            if family == .systemLarge {
                Text("widget.upNext.name")
                    .font(.headline)
            }
            ForEach(items) { item in
                HStack(spacing: 10) {
                    if let url = item.playURL {
                        Link(destination: url) {
                            row(item, thumbHeight: thumbHeight)
                        }
                    } else {
                        row(item, thumbHeight: thumbHeight)
                    }
                    playOnButton(item, compact: family != .systemLarge)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ item: UpNextEntryItem, thumbHeight: CGFloat) -> some View {
        HStack(spacing: 10) {
            artwork(item.artwork)
                .frame(width: thumbHeight * 16 / 9, height: thumbHeight)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                progress(item)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private func rectangular(_ item: UpNextEntryItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .font(.headline)
                .lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .lineLimit(1)
            }
            progress(item)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(item.playURL)
    }

    @ViewBuilder
    private func artwork(_ image: CGImage?) -> some View {
        Group {
            if let image {
                // Desaturated so a tinted or accented widget keeps the picture's detail rather than
                // a flat block of the tint.
                Image(decorative: image, scale: 1)
                    .resizable()
                    .widgetAccentedRenderingMode(.accentedDesaturated)
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "play.tv").foregroundStyle(.secondary))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Only for a part-watched item; a fresh episode has nothing to show.
    @ViewBuilder
    private func progress(_ item: UpNextEntryItem) -> some View {
        if let fraction = item.progress, fraction > 0 {
            ProgressView(value: fraction)
                .tint(.primary)
        }
    }

    @ViewBuilder
    private func playOnButton(_ item: UpNextEntryItem, compact: Bool) -> some View {
        if let device = entry.playOn {
            Button(intent: PlayOnRemoteDeviceIntent(itemID: item.id, deviceKey: device.key, startTicks: item.startTicks)) {
                Label {
                    Text("widget.upNext.playOn \(device.name)")
                } icon: {
                    Image(systemName: "tv")
                }
                .labelStyle(.iconOnly)
                .font((compact ? Font.caption : Font.body).weight(.semibold))
                .frame(width: compact ? 28 : 34, height: compact ? 28 : 34)
                .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview("Medium", as: .systemMedium) {
    UpNextWidget()
} timeline: {
    UpNextEntry(date: .now, state: .items(UpNextEntryItem.placeholders(count: 3)), playOn: nil)
    UpNextEntry(date: .now, state: .items(UpNextEntryItem.placeholders(count: 3)),
                playOn: KnownPlaybackTargets.Target(key: "atv", name: "Living Room"))
    UpNextEntry(date: .now, state: .empty, playOn: nil)
}
