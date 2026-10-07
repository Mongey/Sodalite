import SwiftUI

extension FocusedValues {
    /// Pops the page on screen. Published by the visible pushed page, read by the Back command.
    @Entry var navigateBack: (() -> Void)?
}

extension View {
    /// Marks a pushed navigation page, so View > Back (Cmd-[) can pop it on the Mac.
    @ViewBuilder
    func pushedPage() -> some View {
        #if os(macOS)
        modifier(PushedPage())
        #else
        self
        #endif
    }
}

#if os(macOS)
/// Publishes `dismiss` only while this page is the one on screen and was actually pushed. Every page
/// under it stays mounted, so without the visibility gate the Back command could pop a page the
/// viewer is not looking at, and `isPresented` keeps a stack's root, which shares the same
/// modifiers, from offering to dismiss itself.
private struct PushedPage: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .focusedSceneValue(\.navigateBack, isPresented && isVisible ? { dismiss() } : nil)
    }
}

/// View > Back, Cmd-[, the shortcut every Mac browser and Finder uses to go back a page.
struct BackCommands: Commands {
    @FocusedValue(\.navigateBack) private var navigateBack

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            Button("common.back") { navigateBack?() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(navigateBack == nil)
            Divider()
        }
    }
}
#endif
