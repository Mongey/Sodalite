import Foundation

/// What the Up Next widget lists: Continue Watching first, then Next Up, one entry per show.
///
/// Built from the same `/Items/Resume` and `/Shows/NextUp` answers the Top Shelf reads, decoded into
/// the same `TopShelfItem`, so the two surfaces can never disagree about what is next.
nonisolated enum UpNextFeed {
    static let kind = "UpNext"

    /// One entry per show, because a widget row is a decision to make ("what do I watch?") and two
    /// rows of the same series answer it twice. A part-watched episode wins over the series' next
    /// one, which is why resume goes first; a movie is its own show.
    static func merge(resume: [TopShelfItem], nextUp: [TopShelfItem], limit: Int) -> [TopShelfItem] {
        var seen = Set<String>()
        return (resume + nextUp)
            .filter { seen.insert($0.seriesId ?? $0.id).inserted }
            .prefix(max(limit, 0))
            .map { $0 }
    }

    /// Where a part-watched item picks up, for a device told to play it. Nil starts it from the top.
    static func resumeTicks(of item: TopShelfItem) -> Int64? {
        guard let ticks = item.userData?.playbackPositionTicks, ticks > 0 else { return nil }
        return ticks
    }

    /// The link the app opens to start the item here. `DeepLinkRoute` parses it.
    static func playURL(itemID: String) -> URL? {
        URL(string: "sodalite://play/\(itemID)")
    }
}
