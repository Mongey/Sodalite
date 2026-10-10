import AppIntents
import Foundation

/// What a widget button runs: one playstate command to one session. Plain values as parameters, so
/// the intent can be built inline in a `Button(intent:)`.
struct RemoteCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "widget.remote.intent.title"
    /// Only meaningful with a session id the widget just read, so it stays out of Shortcuts.
    static let isDiscoverable = false

    @Parameter(title: "widget.remote.intent.session")
    var sessionID: String

    @Parameter(title: "widget.remote.intent.command")
    var commandName: String

    @Parameter(title: "widget.remote.intent.position")
    var seekTicks: Int

    init() {}

    init(sessionID: String, command: RemoteCommand) {
        self.sessionID = sessionID
        self.commandName = command.name
        self.seekTicks = Int(command.seekTicks)
    }

    func perform() async throws -> some IntentResult {
        guard let session = SharedSession.read(),
              let command = RemoteCommand(name: commandName, seekTicks: Int64(seekTicks))
        else { return .result() }
        PendingRemoteCommands.record(command, for: sessionID)
        do {
            try await WidgetRemoteAPI(session: session).send(command, to: sessionID)
        } catch {
            // The reload that follows has to show what the device is really doing.
            PendingRemoteCommands.forget(sessionID)
            throw error
        }
        return .result()
    }
}
