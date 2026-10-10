import AppIntents
import Foundation
import WidgetKit

/// A device that can be told to play something, idle or not: what "Play on" offers, in the Up Next
/// widget's settings and in Shortcuts. Identified by device like `RemoteDeviceEntity`, and kept
/// apart from it because that one lists only devices that are playing, which is all Pause, Resume
/// and Stop can act on.
nonisolated struct PlaybackTargetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "intents.playOn.device.type"
    static let defaultQuery = PlaybackTargetQuery()

    let id: String
    let name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(session: RemoteSession) {
        self.init(id: session.deviceKey, name: session.deviceName)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

nonisolated struct PlaybackTargetQuery: EntityQuery {
    init() {}

    /// A device that has gone quiet still resolves, by the name it was last listed under, so a
    /// configured widget keeps its choice while the Apple TV sleeps; the server forgets a session
    /// after a quarter of an hour without activity. The send is what finds it missing.
    func entities(for identifiers: [String]) async throws -> [PlaybackTargetEntity] {
        try await KnownPlaybackTargets.resolve(identifiers).map { PlaybackTargetEntity(id: $0.key, name: $0.name) }
    }

    func suggestedEntities() async throws -> [PlaybackTargetEntity] {
        try await KnownPlaybackTargets.online().map { PlaybackTargetEntity(id: $0.key, name: $0.name) }
    }
}

/// The devices "Play on" can name, and the names they were last listed under, kept in the app group
/// so a saved choice still resolves while its device is not online to list itself. Read by
/// `PlaybackTargetQuery` for Shortcuts and by the Up Next widget's settings.
nonisolated enum KnownPlaybackTargets {
    struct Target: Sendable {
        let key: String
        let name: String
    }

    private static let defaultsKey = "playOn.knownDevices"

    static func online() async throws -> [Target] {
        guard let shared = SharedSession.read() else { return [] }
        let targets = try await RemoteControlAPI(session: shared).playTargets()
            .map { Target(key: $0.deviceKey, name: $0.deviceName) }
        remember(targets)
        return targets
    }

    static func resolve(_ keys: [String]) async throws -> [Target] {
        let online = (try? await online()) ?? []
        let known = names()
        return keys.compactMap { key in
            online.first { $0.key == key } ?? known[key].map { Target(key: key, name: $0) }
        }
    }

    private static func names() -> [String: String] {
        UserDefaults(suiteName: RemoteControlAppGroup.id)?.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    private static func remember(_ targets: [Target]) {
        guard !targets.isEmpty else { return }
        var names = names()
        for target in targets {
            names[target.key] = target.name
        }
        UserDefaults(suiteName: RemoteControlAppGroup.id)?.set(names, forKey: defaultsKey)
    }
}

/// The Up Next widget's TV button: one item, one device. Plain values so the widget can build it
/// inline; Shortcuts has `PlayUpNextOnDeviceIntent`.
struct PlayOnRemoteDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "intents.playOn.item.title"
    static let supportedModes: IntentModes = .background
    static let isDiscoverable = false

    @Parameter(title: "intents.playOn.item.item")
    var itemID: String

    @Parameter(title: "intents.playOn.device")
    var deviceKey: String

    @Parameter(title: "intents.playOn.item.position")
    var startTicks: Int

    init() {}

    init(itemID: String, deviceKey: String, startTicks: Int64?) {
        self.itemID = itemID
        self.deviceKey = deviceKey
        self.startTicks = Int(startTicks ?? 0)
    }

    func perform() async throws -> some IntentResult {
        try await PlayOnRunner.play(
            RemotePlayRequest(itemID: itemID, startPositionTicks: Int64(startTicks)),
            on: deviceKey
        )
        return .result()
    }
}

/// "Play the next thing on the Living Room": the top of Up Next, from where it was left.
struct PlayUpNextOnDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "intents.playOn.upNext.title"
    static let description = IntentDescription("intents.playOn.upNext.description")
    static let supportedModes: IntentModes = .background
    #if SODALITE_EXTENSION
    static let isDiscoverable = false
    #endif

    @Parameter(title: "intents.playOn.device")
    var device: PlaybackTargetEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("intents.playOn.upNext.summary \(\.$device)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let shared = SharedSession.read() else { throw PlayOnFailure.signedOut }
        guard let item = try await RemoteControlAPI(session: shared).upNext(limit: 1).first else {
            throw PlayOnFailure.nothingUpNext
        }
        let target = try await PlayOnRunner.play(
            RemotePlayRequest(itemID: item.id, startPositionTicks: UpNextFeed.resumeTicks(of: item)),
            on: device?.id
        )
        return .result(dialog: "intents.playOn.upNext.done \(item.topShelfTitle) \(target.deviceName)")
    }
}

nonisolated enum PlayOnRunner {
    /// Resolves the device to its session at the moment of sending, since the id a widget or a
    /// Shortcut stored is the device's and the session behind it changes on every reconnect. With
    /// no device named, the one active most recently. Returns the session it went to.
    @discardableResult
    static func play(_ request: RemotePlayRequest, on deviceKey: String?) async throws -> RemoteSession {
        guard let shared = SharedSession.read() else { throw PlayOnFailure.signedOut }
        let api = RemoteControlAPI(session: shared)
        guard let target = RemoteSession.target(in: try await api.playTargets(), deviceKey: deviceKey) else {
            throw PlayOnFailure.deviceUnavailable
        }
        try await api.play(request, on: target.id)
        // The Remote Control widget and the control pick the new session up on their next look.
        WidgetCenter.shared.reloadAllTimelines()
        return target
    }
}

nonisolated enum PlayOnFailure: Error, CustomLocalizedStringResourceConvertible {
    case signedOut
    case nothingUpNext
    case deviceUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "intents.remote.error.signedOut"
        case .nothingUpNext: "intents.playOn.error.nothingUpNext"
        case .deviceUnavailable: "intents.playOn.error.deviceUnavailable"
        }
    }
}
