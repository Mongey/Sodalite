import AppIntents
import SwiftUI
import WidgetKit

/// Play/pause in Control Center (and on the Lock Screen and Action button) for whichever device
/// played last.
struct RemotePlaybackControl: ControlWidget {
    static let kind = "de.superuser404.Sodalite.RemotePlayback"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { value in
            ControlWidgetToggle(isOn: value.isPlaying, action: SetRemotePlaybackIntent()) {
                Label {
                    Text(value.deviceName ?? String(localized: "control.remote.nothingPlaying"))
                } icon: {
                    Image(systemName: "play.tv")
                }
            } valueLabel: { isPlaying in
                Label(
                    isPlaying ? "control.remote.playing" : "control.remote.paused",
                    systemImage: isPlaying ? "pause.fill" : "play.fill"
                )
            }
        }
        .displayName("control.remote.name")
        .description("control.remote.description")
    }

    struct Value {
        let isPlaying: Bool
        let deviceName: String?
    }

    struct Provider: ControlValueProvider {
        var previewValue: Value {
            Value(isPlaying: true, deviceName: RemoteSession.placeholder.deviceName)
        }

        func currentValue() async throws -> Value {
            guard let shared = SharedSession.read(),
                  let sessions = try? await RemoteControlAPI(session: shared).controllableSessions(),
                  let session = PendingRemoteCommands.apply(to: sessions).first,
                  let playing = session.nowPlaying
            else { return Value(isPlaying: false, deviceName: nil) }
            return Value(isPlaying: !playing.isPaused, deviceName: session.deviceName)
        }
    }
}
