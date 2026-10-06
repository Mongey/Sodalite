import Foundation

extension HomeViewModel {
    func setHeroEnabled(_ enabled: Bool) {
        guard enabled != heroEnabled else { return }
        heroEnabled = enabled
        reloadHero()
    }

    func reloadHero() {
        heroTask?.cancel()
        guard heroEnabled else {
            heroItems = []
            return
        }
        heroTask = Task { [weak self] in await self?.loadHero() }
    }

    /// How many titles the carousel pages through.
    static let heroLimit = 8

    /// The newest movies and shows across every source, keeping only the ones with a backdrop: a
    /// hero without art is a black slab. Its own query rather than the Recently Added row's, because
    /// that row may be switched off and asks for none of the overview, genre and rating fields the
    /// hero prints. A source that fails just contributes nothing; the rows report reachability.
    func loadHero() async {
        let query = ItemQuery(
            includeItemTypes: [.movie, .series],
            sortBy: "DateCreated",
            sortOrder: "Descending",
            limit: Self.heroLimit * 2,
            fields: JellyfinEndpoint.homeRowFields + ",Overview,Genres,OfficialRating,ProductionYear"
        )
        let perSource = await withTaskGroup(of: [JellyfinItem].self) { group in
            for source in sources {
                group.addTask {
                    let items = (try? await source.libraryService.getItems(userID: source.userID, query: query))?.items ?? []
                    return items.map { item in
                        var stamped = item
                        if stamped.serverID == nil { stamped.serverID = source.serverID }
                        return stamped
                    }
                }
            }
            var all: [[JellyfinItem]] = []
            for await items in group { all.append(items) }
            return all
        }
        guard !Task.isCancelled else { return }
        heroItems = Array(
            perSource.joined()
                .filter { !($0.backdropImageTags ?? []).isEmpty }
                // ISO 8601 strings sort chronologically as text.
                .sorted { ($0.dateCreated ?? "") > ($1.dateCreated ?? "") }
                .prefix(Self.heroLimit)
        )
    }

    func heroBackdropURL(for item: JellyfinItem) -> URL? {
        imageService.backdropURL(for: item, maxWidth: ImageWidth.fullBleed)
    }
}
