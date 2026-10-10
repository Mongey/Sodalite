import SwiftUI
import WidgetKit

@main
struct SodaliteWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RemoteControlWidget()
        RemotePlaybackControl()
    }
}
