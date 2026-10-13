import Foundation

/// Genre narrowing for the guide (Sodalite#182). Kept apart from `GuideFilter` because Jellyfin
/// cannot filter CHANNELS by genre: only `/LiveTv/Programs` takes `Genres`, so the matching channel
/// IDs are collected from a program query and the grid is narrowed client-side, like the search.
/// Being separate also keeps it out of the zap line-up, which `GuideFilter` feeds.
struct GuideGenreFilter: Equatable, Sendable {

    enum Scope: String, CaseIterable, Identifiable, Sendable {
        /// Channels whose CURRENT program matches, the same reading as the category chips.
        case now
        /// Channels with a match anywhere in the guide window, e.g. tonight's games.
        case guide

        var id: String { rawValue }
    }

    var genres: Set<String> = []
    var scope: Scope = .now

    var isActive: Bool { !genres.isEmpty }

    /// Case- and diacritic-insensitive, which is how Jellyfin matches the `Genres` parameter
    /// against its stored clean values, so a dimmed cell and the server's answer agree.
    func matches(_ program: JellyfinProgram) -> Bool {
        guard isActive else { return true }
        let wanted = Set(genres.map(\.guideFolded))
        return (program.genres ?? []).contains { wanted.contains($0.guideFolded) }
    }

    /// The `Genres` value: pipe-delimited, which Jellyfin reads as OR. Sorted so the same selection
    /// always produces the same request.
    var queryValue: String {
        genres.sorted().joined(separator: "|")
    }

    /// Distinct genre names across `programs`, first spelling wins, in the order a person reads a list.
    static func genreNames(in programs: [JellyfinProgram]) -> [String] {
        var seen: [String: String] = [:]
        for genre in programs.flatMap({ $0.genres ?? [] }) {
            let trimmed = genre.trimmingCharacters(in: .whitespacesAndNewlines)
            // A pipe would split the name in two on the way back to the server.
            guard !trimmed.isEmpty, !trimmed.contains("|") else { continue }
            let key = trimmed.guideFolded
            if seen[key] == nil { seen[key] = trimmed }
        }
        return seen.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Which programs a line-up-wide program query covers.
enum GuideProgramWindow: Equatable, Sendable {
    case airing
    case range(start: Date, end: Date)
}
