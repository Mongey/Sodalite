import AppIntents

/// Surfaces intents to Siri/Shortcuts; phrases matched from localized `AppShortcuts.xcstrings` per language.
/// Only `OpenSodaliteIntent` is exposed: tvOS Siri rejects non-system-schema custom intents at voice-invoke ("doesn't support this with Siri"), but "Open [App]" is system-blessed via LSOpenURL. `ContinueWatchingIntent` stays in the codebase for the Shortcuts app on iPhone/iPad/Mac where custom intents work.
struct SodaliteShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenSodaliteIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Launch \(.applicationName)",
                "Show \(.applicationName)",
            ],
            shortTitle: "Open",
            systemImageName: "play.tv"
        )
        // The remote-control actions run on iPhone, iPad and Mac. tvOS has no Shortcuts app, and
        // its Siri turns custom intents away (see above).
        #if !os(tvOS)
        AppShortcut(
            intent: PauseRemoteDeviceIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Pause \(\.$device) in \(.applicationName)",
                "Pause \(.applicationName) on \(\.$device)",
            ],
            shortTitle: "Pause",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ResumeRemoteDeviceIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Resume \(\.$device) in \(.applicationName)",
                "Resume \(.applicationName) on \(\.$device)",
            ],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: StopRemoteDeviceIntent(),
            phrases: [
                "Stop \(.applicationName)",
                "Stop \(\.$device) in \(.applicationName)",
                "Stop \(.applicationName) on \(\.$device)",
            ],
            shortTitle: "Stop",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: SkipRemoteDeviceIntent(),
            phrases: [
                "Skip ahead in \(.applicationName)",
                "Skip ahead on \(\.$device) in \(.applicationName)",
            ],
            shortTitle: "Skip",
            systemImageName: "goforward.30"
        )
        AppShortcut(
            intent: PlayUpNextOnDeviceIntent(),
            phrases: [
                "Play what's next in \(.applicationName)",
                "Play what's next on \(\.$device) in \(.applicationName)",
            ],
            shortTitle: "Play Next",
            systemImageName: "tv"
        )
        #endif
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}
