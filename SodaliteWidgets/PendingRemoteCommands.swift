import Foundation

/// Commands the widget sent in the last few seconds, kept in the app group.
///
/// WidgetKit reloads the timeline as soon as a button's intent returns, which is usually before the
/// other device has reported its new state to the server. Without this the play button would flip
/// back to what it just changed and only correct itself on the next reload, minutes later.
nonisolated enum PendingRemoteCommands {
    private struct Record: Codable {
        let name: String
        let seekTicks: Int64
        let until: Date
    }

    private static let key = "widgets.pendingRemoteCommands"
    private static let window: TimeInterval = 8

    static func record(_ command: RemoteCommand, for sessionID: String, now: Date = Date()) {
        var records = load(now: now)
        records[sessionID] = Record(name: command.name, seekTicks: command.seekTicks, until: now.addingTimeInterval(window))
        save(records)
    }

    static func forget(_ sessionID: String) {
        var records = load(now: Date())
        records[sessionID] = nil
        save(records)
    }

    /// The sessions as they will be once the recent commands land: a stopped one gone, a paused
    /// one paused.
    static func apply(to sessions: [RemoteSession], now: Date = Date()) -> [RemoteSession] {
        let records = load(now: now)
        guard !records.isEmpty else { return sessions }
        return sessions.compactMap { session in
            guard let record = records[session.id],
                  let command = RemoteCommand(name: record.name, seekTicks: record.seekTicks)
            else { return session }
            return session.applying(command)
        }
    }

    private static func load(now: Date) -> [String: Record] {
        guard let data = UserDefaults(suiteName: WidgetAppGroup.id)?.data(forKey: key),
              let records = try? JSONDecoder().decode([String: Record].self, from: data)
        else { return [:] }
        return records.filter { $0.value.until > now }
    }

    private static func save(_ records: [String: Record]) {
        let defaults = UserDefaults(suiteName: WidgetAppGroup.id)
        if records.isEmpty {
            defaults?.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(records) {
            defaults?.set(data, forKey: key)
        }
    }
}
