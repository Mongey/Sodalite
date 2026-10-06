import SwiftUI
import AppKit

/// The one session the player window shows, handed over by whichever launcher started it.
///
/// A window scene cannot be given a view model directly (`openWindow` takes only a Codable value),
/// so the launchers park the session here and the scene reads it back. There is one player window,
/// not one per title: a second Play replaces what the window is showing rather than stacking a
/// second engine decoding beside the first.
@MainActor
@Observable
final class MacPlayerWindowSession {
    static let shared = MacPlayerWindowSession()
    static let windowID = "player"

    struct Entry {
        let viewModel: PlayerViewModel
        let theme: ResolvedAppearanceTheme
        /// Tells the launcher its player is gone, whichever way it went: Escape, the close button,
        /// or a newer session taking the window over.
        let onClose: () -> Void
    }

    private(set) var current: Entry?

    func show(_ entry: Entry) {
        let replaced = current
        current = entry
        replaced?.onClose()
    }

    /// Clears the window's session only if it is still this one, so a launcher tearing down late
    /// cannot close a player that a newer launcher has since put up.
    func end(_ viewModel: PlayerViewModel) {
        guard current?.viewModel === viewModel else { return }
        let ended = current
        current = nil
        ended?.onClose()
    }
}

/// The player window's scene. Not restored on relaunch: the session it would restore is gone.
struct MacPlayerWindowScene: Scene {
    var body: some Scene {
        Window("Player", id: MacPlayerWindowSession.windowID) {
            MacPlayerWindowContent()
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1280, height: 720)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
    }
}

private struct MacPlayerWindowContent: View {
    @Environment(\.dismissWindow) private var dismissWindow
    private let session = MacPlayerWindowSession.shared

    var body: some View {
        Group {
            if let entry = session.current {
                MacPlayerScreen(viewModel: entry.viewModel, theme: entry.theme) {
                    session.end(entry.viewModel)
                }
                // A replaced session is a new screen, so the old one's onDisappear stops its engine.
                .id(ObjectIdentifier(entry.viewModel))
                .navigationTitle(PlayerTitleLines(item: entry.viewModel.item).header)
            } else {
                Color.black
            }
        }
        .onChange(of: session.current == nil) { _, ended in
            if ended { dismissWindow(id: MacPlayerWindowSession.windowID) }
        }
        // The window's own close button: the session has to end with it, or the launcher would
        // still believe its player is up.
        .onDisappear {
            if let viewModel = session.current?.viewModel { session.end(viewModel) }
        }
    }
}

/// What both launchers do with the session they build: put it in the window, and take it back out
/// when their binding says the player is over.
struct MacPlayerWindowPresenter: ViewModifier {
    @Binding var session: PlayerViewModel?
    let theme: ResolvedAppearanceTheme
    let onClose: () -> Void

    @Environment(\.openWindow) private var openWindow
    /// The session this launcher put in the window, so dropping it ends that one and never a newer
    /// one another launcher has put up since.
    @State private var shown: PlayerViewModel?

    func body(content: Content) -> some View {
        content
            .onChange(of: session.map(ObjectIdentifier.init), initial: true) { _, _ in
                if let previous = shown, previous !== session {
                    MacPlayerWindowSession.shared.end(previous)
                }
                shown = session
                guard let viewModel = session else { return }
                MacPlayerWindowSession.shared.show(.init(viewModel: viewModel, theme: theme, onClose: onClose))
                openWindow(id: MacPlayerWindowSession.windowID)
            }
    }
}
