import AppIntents
import Foundation
import WidgetKit

// The actions are compiled into the app and into each widget extension. The app's copy is the one
// Shortcuts and Siri list and run, in the app's process without bringing it forward; the
// extensions carry them for the widget buttons and the Control Center control, and hide their
// copies so no action shows up twice.

struct PauseRemoteDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "intents.remote.pause.title"
    static let description = IntentDescription("intents.remote.pause.description")
    static let supportedModes: IntentModes = .background
    #if SODALITE_EXTENSION
    static let isDiscoverable = false
    #endif

    @Parameter(title: "intents.remote.device")
    var device: RemoteDeviceEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("intents.remote.pause.summary \(\.$device)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = try await RemoteControlRunner.run(on: device) { _ in .pause }
        return .result(dialog: "intents.remote.pause.done \(session.deviceName)")
    }
}

struct ResumeRemoteDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "intents.remote.resume.title"
    static let description = IntentDescription("intents.remote.resume.description")
    static let supportedModes: IntentModes = .background
    #if SODALITE_EXTENSION
    static let isDiscoverable = false
    #endif

    @Parameter(title: "intents.remote.device")
    var device: RemoteDeviceEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("intents.remote.resume.summary \(\.$device)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = try await RemoteControlRunner.run(on: device) { _ in .unpause }
        return .result(dialog: "intents.remote.resume.done \(session.deviceName)")
    }
}

struct StopRemoteDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "intents.remote.stop.title"
    static let description = IntentDescription("intents.remote.stop.description")
    static let supportedModes: IntentModes = .background
    #if SODALITE_EXTENSION
    static let isDiscoverable = false
    #endif

    @Parameter(title: "intents.remote.device")
    var device: RemoteDeviceEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("intents.remote.stop.summary \(\.$device)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = try await RemoteControlRunner.run(on: device) { _ in .stop }
        return .result(dialog: "intents.remote.stop.done \(session.deviceName)")
    }
}

struct SkipRemoteDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "intents.remote.skip.title"
    static let description = IntentDescription("intents.remote.skip.description")
    static let supportedModes: IntentModes = .background
    #if SODALITE_EXTENSION
    static let isDiscoverable = false
    #endif

    /// Negative skips back.
    @Parameter(title: "intents.remote.skip.seconds", default: 30)
    var seconds: Int

    @Parameter(title: "intents.remote.device")
    var device: RemoteDeviceEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("intents.remote.skip.summary \(\.$device) \(\.$seconds)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let seconds = Int64(seconds)
        let session = try await RemoteControlRunner.run(on: device) { playing in
            .seek(toTicks: playing.seekTarget(bySeconds: seconds))
        }
        return .result(dialog: "intents.remote.skip.done \(session.deviceName)")
    }
}

/// The Control Center toggle's action: on resumes, off pauses, whichever device played last.
struct SetRemotePlaybackIntent: SetValueIntent {
    static let title: LocalizedStringResource = "intents.remote.toggle.title"
    static let supportedModes: IntentModes = .background
    /// Only the control sets a value; Shortcuts has Pause and Resume.
    static let isDiscoverable = false

    @Parameter(title: "intents.remote.toggle.value")
    var value: Bool

    func perform() async throws -> some IntentResult {
        let playing = value
        _ = try await RemoteControlRunner.run(on: nil) { _ in playing ? .unpause : .pause }
        return .result()
    }
}

/// What every action does: find the device, send it one command, and have the widgets and the
/// control redraw from the state it is about to report.
nonisolated enum RemoteControlRunner {
    /// Returns the session the command went to.
    @discardableResult
    static func run(
        on device: RemoteDeviceEntity?,
        _ command: (RemoteSession.NowPlaying) -> RemoteCommand
    ) async throws -> RemoteSession {
        guard let shared = SharedSession.read() else { throw RemoteControlFailure.signedOut }
        let api = RemoteControlAPI(session: shared)
        let sessions = try await api.controllableSessions()
        guard let session = RemoteSession.target(in: sessions, deviceKey: device?.id),
              let playing = session.nowPlaying
        else {
            throw device.map { RemoteControlFailure.notPlaying(deviceName: $0.name) } ?? .nothingPlaying
        }
        let sent = command(playing)
        PendingRemoteCommands.record(sent, for: session.id)
        do {
            try await api.send(sent, to: session.id)
        } catch {
            PendingRemoteCommands.forget(session.id)
            throw error
        }
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
        return session
    }
}

nonisolated enum RemoteControlFailure: Error, CustomLocalizedStringResourceConvertible {
    case signedOut
    case nothingPlaying
    case notPlaying(deviceName: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "intents.remote.error.signedOut"
        case .nothingPlaying: "intents.remote.error.nothingPlaying"
        case .notPlaying(let name): "intents.remote.error.notPlaying \(name)"
        }
    }
}
