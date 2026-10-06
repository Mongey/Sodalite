import SwiftUI

/// The top of Home: the newest titles as a full-width banner that pages
/// by itself, the way the TV app opens. The art runs to the window's top edge under the toolbar; the title, a line of
/// facts, the overview and Play sit over a scrim at the bottom leading corner.
struct HomeHeroCarousel: View {
    let items: [JellyfinItem]
    let backdropURL: (JellyfinItem) -> URL?
    let onOpen: (JellyfinItem) -> Void
    let onPlay: (JellyfinItem) -> Void

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var index = 0
    /// The pointer is over the banner, or on tvOS focus is on its buttons; either way it holds still.
    @State private var isHovering = false
    #if os(tvOS)
    @FocusState private var buttonsFocused: Bool
    #endif
    /// How far below the window's top edge the banner starts: the toolbar's inset plus the stack
    /// spacing above it, and more while the page is pulled past its top. The art grows upward by
    /// exactly that. Measured in window space because every scroll-relative reading falls short:
    /// the top safe area is zero inside the scroll view, the content inset misses the spacing, and
    /// the `.scrollView` space starts below the inset, so it saw only the 8pt of spacing.
    @State private var topExtension: CGFloat = 0

    /// Long enough to read an overview, short enough that the banner visibly moves.
    private static let dwell: Duration = .seconds(8)

    private var isCompact: Bool { hSizeClass == .compact }

    private var titleSize: CGFloat {
        #if os(tvOS)
        64
        #else
        isCompact ? 28 : 40
        #endif
    }

    private var current: JellyfinItem? {
        items.indices.contains(index) ? items[index] : items.first
    }

    var body: some View {
        if let current {
            // The box is a placeholder sized off the window, and everything else is laid onto it, so
            // the art, the text and the pager all agree on one height. Built the other way round, the
            // filled backdrop picked the size and the clip cut the buttons and the dots off the bottom.
            Color.clear
                .containerRelativeFrame(.vertical) { height, _ in
                    isCompact ? max(320, height * 0.5) : max(440, height * 0.66)
                }
                .frame(maxWidth: .infinity)
                // Up under the transparent toolbar, the way the TV app's banner reaches the window's
                // top edge. Pinned to the bottom: `ignoresSafeArea` inside a scroll view let the art
                // hang below the banner as well.
                .background(alignment: .bottom) {
                    ZStack {
                        backdrop(for: current)
                        scrim
                    }
                    .padding(.top, -topExtension)
                }
                .onGeometryChange(for: CGFloat.self) { max(0, $0.frame(in: .global).minY) } action: {
                    topExtension = $0
                }
                                .overlay(alignment: .bottomLeading) {
                    details(for: current)
                        // Lined up with the rows' titles below it.
                        .padding(.leading, LayoutMetrics.current(hSizeClass).rowInset)
                        .padding(.trailing, isCompact ? LayoutMetrics.current(hSizeClass).rowInset : 160)
                        .padding(.bottom, 52)
                        .id(current.originKey)
                        .transition(.opacity)
                }
                .overlay(alignment: .bottom) {
                    pager.padding(.bottom, 20)
                }
                .overlay { arrows }
                #if os(tvOS)
                // Focus stands in for the pointer: a page change rebuilds the buttons, which would
                // throw focus off the one the viewer is on.
                .onChange(of: buttonsFocused) { _, focused in isHovering = focused }
                #else
                .contentShape(Rectangle())
                .onTapGesture { onOpen(current) }
                .onHover { isHovering = $0 }
                #endif
                #if os(iOS)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24).onEnded { drag in
                        guard abs(drag.translation.width) > abs(drag.translation.height),
                              abs(drag.translation.width) > 40 else { return }
                        step(drag.translation.width < 0 ? 1 : -1)
                    }
                )
                #endif
                .animation(.easeInOut(duration: 0.6), value: index)
                // Restarted by every page change, so a click on an arrow gets a full dwell before the
                // banner moves on by itself. Held while the pointer is over it, so nothing slides away
                // from under someone reading it.
                .task(id: "\(index)|\(isHovering)|\(items.count)") {
                    guard !isHovering, items.count > 1 else { return }
                    try? await Task.sleep(for: Self.dwell)
                    guard !Task.isCancelled else { return }
                    step(1)
                }
                .onChange(of: items.map(\.originKey)) { _, _ in index = 0 }
        }
    }

    // MARK: - Layers

    private func backdrop(for item: JellyfinItem) -> some View {
        AsyncCachedImage(url: backdropURL(item)) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Color.black
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .id(item.originKey)
        .transition(.opacity)
    }

    private var scrim: some View {
        ZStack {
            LinearGradient(
                stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.85), location: 1)],
                startPoint: .top, endPoint: .bottom
            )
            LinearGradient(
                stops: [.init(color: .black.opacity(0.6), location: 0), .init(color: .clear, location: 0.55)],
                startPoint: .leading, endPoint: .trailing
            )
        }
        .allowsHitTesting(false)
    }

    private func details(for item: JellyfinItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ContentLogoTitle(
                itemID: item.id,
                logo: .from(imageTags: item.imageTags, hasFullDetail: true)
            ) {
                Text(item.name)
                    .font(.system(size: titleSize, weight: .bold))
                    .lineLimit(2)
            }
            .frame(maxWidth: 420, maxHeight: 130, alignment: .bottomLeading)

            if let facts = facts(for: item) {
                Text(verbatim: facts)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            }

            if let overview = item.overview, !overview.isEmpty {
                Text(verbatim: overview)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
                    .frame(maxWidth: 520, alignment: .leading)
            }

            #if os(tvOS)
            // The system styles, because they carry the focus lift a remote needs to see where it is.
            HStack(spacing: 24) {
                Button { onPlay(item) } label: {
                    Label("detail.play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                Button { onOpen(item) } label: {
                    Image(systemName: "info")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(Text(verbatim: item.name))
            }
            .focused($buttonsFocused)
            .focusSection()
            .padding(.top, 8)
            #else
            HStack(spacing: 12) {
                Button {
                    onPlay(item)
                } label: {
                    Label("detail.play", systemImage: "play.fill")
                        .font(.headline)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .foregroundStyle(.black)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    onOpen(item)
                } label: {
                    Image(systemName: "info")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: item.name))
            }
            .padding(.top, 4)
            #endif
        }
        .foregroundStyle(.white)
        // The serverSession a combined Home's secondary title needs for its logo request.
        .environment(\.serverSession, item.serverID.map { dependencies.sessionRegistry.session(forServerID: $0) })
    }

    @ViewBuilder
    private var pager: some View {
        if items.count > 1 {
            HStack(spacing: 8) {
                ForEach(items.indices, id: \.self) { page in
                    Circle()
                        .fill(.white.opacity(page == index ? 1 : 0.4))
                        .frame(width: 7, height: 7)
                        .contentShape(Rectangle().inset(by: -4))
                        #if !os(tvOS)
                        .onTapGesture { index = page }
                        #endif
                }
            }
        }
    }

    @ViewBuilder
    private var arrows: some View {
        #if !os(tvOS)
        if items.count > 1 {
            HStack {
                arrow("chevron.left") { step(-1) }
                Spacer()
                arrow("chevron.right") { step(1) }
            }
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .opacity(isHovering ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: isHovering)
        }
        #endif
    }

    private func arrow(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 88)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        index = (index + delta + items.count) % items.count
    }

    /// "Movie · 2025 · Drama · Thriller · PG-13", with whatever the server knows.
    private func facts(for item: JellyfinItem) -> String? {
        var parts: [String] = []
        if let year = item.productionYear { parts.append(String(year)) }
        parts += (item.genres ?? []).prefix(2)
        if let rating = item.officialRating, !rating.isEmpty { parts.append(rating) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
