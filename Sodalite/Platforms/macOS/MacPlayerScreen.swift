import SwiftUI
import AppKit
import AetherEngine

/// The Mac's player: the engine's render surface with a pointer-and-keyboard transport over it.
///
/// Deliberately not a port of `PlayerOverlayView`. That overlay is display-only by construction
/// because `PlayerHostController` owns every press and moves a cursor through the controls for it,
/// which is what a remote needs and what a pointer makes pointless. Here the controls are ordinary
/// SwiftUI controls that handle their own clicks, and the keyboard reaches them through
/// `onKeyPress` rather than through a responder chain.
struct MacPlayerScreen: View {
    let viewModel: PlayerViewModel
    let theme: ResolvedAppearanceTheme
    let onDismiss: () -> Void

    /// The chrome hides itself while the pointer is still and comes back when it moves, so a window
    /// left alone is just the picture. Keyboard transport works either way.
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @FocusState private var hasKeyboardFocus: Bool

    private var titleLines: PlayerTitleLines { PlayerTitleLines(item: viewModel.item) }

    var body: some View {
        ZStack {
            Color.black
            AetherPlayerSurface(engine: viewModel.player)

            if viewModel.isLoading, viewModel.errorMessage == nil {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            if let message = viewModel.errorMessage {
                errorPanel(message: message)
            } else {
                chrome
                    .opacity(controlsVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: controlsVisible)
            }
        }
        .frame(minWidth: 720, minHeight: 405)
        .frame(idealWidth: 1280, idealHeight: 720)
        .preferredColorScheme(.dark)
        .tint(theme.palette.control.color)
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboardFocus)
        .onContinuousHover { phase in
            if case .active = phase { revealControls() }
        }
        .onKeyPress(keys: [.space, .leftArrow, .rightArrow, .escape, "f", "k"], action: handle)
        .task {
            hasKeyboardFocus = true
            PlayerModalPresence.claimPlayerActive()
            viewModel.beginPlayback()
            revealControls()
        }
        .onDisappear {
            hideTask?.cancel()
            viewModel.stopPlayback()
            PlayerModalPresence.releasePlayerActive()
        }
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleLines.header)
                        .font(.title2.weight(.semibold))
                    if let subtitle = titleLines.subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.title3)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(Text("common.back"))
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .background(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 160)
                    .allowsHitTesting(false)
            }

            Spacer(minLength: 0)

            transport
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .background(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 180)
                        .allowsHitTesting(false)
                }
        }
        .foregroundStyle(.white)
    }

    private var transport: some View {
        VStack(spacing: 8) {
            // Bound to the view model's own scrub state, so a drag reads the position it is dragging
            // to while the committed one keeps arriving from the engine behind it.
            Slider(
                value: Binding(
                    get: { Double(viewModel.displayedProgress) },
                    set: { viewModel.scrub(toFraction: Float($0)) }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing { viewModel.commitScrub() }
                    revealControls()
                }
            )

            HStack(spacing: 16) {
                Text(viewModel.isScrubbing ? viewModel.scrubTime : viewModel.currentTime)
                    .monospacedDigit()

                Spacer(minLength: 0)

                transportButton("gobackward.10") { skip(direction: -1) }
                transportButton(viewModel.isPlaying ? "pause.fill" : "play.fill", size: .title) {
                    viewModel.togglePlayPause()
                }
                transportButton("goforward.10") { skip(direction: 1) }

                Spacer(minLength: 0)

                transportButton("arrow.up.left.and.arrow.down.right", size: .body, action: toggleFullScreen)
                Text(viewModel.remainingTime)
                    .monospacedDigit()
            }
            .font(.callout)
        }
    }

    private func transportButton(
        _ systemImage: String,
        size: Font = .title3,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            revealControls()
        } label: {
            Image(systemName: systemImage)
                .font(size)
                .frame(width: 40, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func errorPanel(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: viewModel.errorIcon ?? "exclamationmark.triangle")
                .font(.system(size: 44))
            if let title = viewModel.errorTitle {
                Text(title).font(.title2.weight(.semibold))
            }
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            HStack(spacing: 12) {
                if viewModel.canRetryAfterOutage {
                    Button("player.error.retry") { viewModel.retryAfterOutage() }
                }
                Button("common.back", action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .foregroundStyle(.white)
        .padding(40)
    }

    // MARK: - Input

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .space:
            viewModel.togglePlayPause()
        case .leftArrow:
            skip(direction: -1)
        case .rightArrow:
            skip(direction: 1)
        case .escape:
            // Leave full screen first, the way QuickTime does: Escape in full screen means "give me
            // the window back", and only then "close the player".
            if isFullScreen {
                toggleFullScreen()
            } else {
                close()
            }
        default:
            switch press.characters {
            case "f": toggleFullScreen()
            case "k": viewModel.togglePlayPause()
            default: return .ignored
            }
        }
        revealControls()
        return .handled
    }

    /// A keyboard or a click asks for the jump and gets it now: unlike a remote there is no burst
    /// of presses to coalesce, so there is nothing to wait for.
    private func skip(direction: Int) {
        viewModel.seekJumpByConfiguredInterval(direction: direction)
        viewModel.commitScrub()
    }

    private func revealControls() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }

    private func close() {
        hideTask?.cancel()
        onDismiss()
    }

    // MARK: - Window

    /// The sheet's own window, which is not the app's key window while a menu or a panel is up.
    private var window: NSWindow? {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.isSheet }
    }

    private var isFullScreen: Bool {
        window?.styleMask.contains(.fullScreen) ?? false
    }

    private func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }
}
