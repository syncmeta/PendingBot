import SwiftUI

/// One row at the top of every top-level tab — left-aligned serif title +
/// optional leading action chip + right-aligned trailing content (typically
/// a "+" or "…" button). Replaces the system nav bar at the tab root so the
/// title and the action sit on the SAME row at the SAME height.
///
/// Use:
/// ```swift
/// TabHeaderBar(title: "消息") {
///     Button { … } label: { Image(systemName: "plus") }
/// }
/// // or with a leading chip too:
/// TabHeaderBar(title: "消息",
///              leading: { CirclePlusButton() },
///              trailing: { CircleEllipsisButton() })
/// ```
struct TabHeaderBar<Leading: View, Trailing: View>: View {
    let title: String
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: String,
        @ViewBuilder leading: @escaping () -> Leading = { EmptyView() },
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(Theme.Fonts.serif(size: 17, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            leading()
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 0)
            trailing()
                .foregroundStyle(Theme.Palette.ink)
        }
        .frame(minHeight: 36)
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}

extension TabHeaderBar where Leading == EmptyView {
    /// Trailing-only convenience — preserves the original two-arg call site.
    init(
        title: String,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.leading = { EmptyView() }
        self.trailing = trailing
    }
}

/// Plain SF Symbol icon used as a tab-header trailing action. Mirrors
/// Apple's own list headers (Mail, Messages, Reminders) — bare glyph in
/// the accent tint, no capsule chip behind it. The 36×36 frame keeps the
/// hit target HIG-compliant even though the glyph itself is smaller.
struct HeaderActionIcon: View {
    let systemImage: String
    var size: CGFloat = 36
    var glyphPointSize: CGFloat = 19
    var glyphWeight: Font.Weight = .regular
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: glyphPointSize, weight: glyphWeight))
            .foregroundStyle(Theme.Palette.accent)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
    }
}

/// "+" trailing action — bare SF Symbol, no chip.
struct CirclePlusButton: View {
    var size: CGFloat = 36
    var body: some View {
        HeaderActionIcon(systemImage: "plus", size: size)
    }
}

/// Three-dot "more actions" trailing action.
struct CircleEllipsisButton: View {
    var size: CGFloat = 36
    var body: some View {
        HeaderActionIcon(systemImage: "ellipsis", size: size)
    }
}

/// Compose glyph (`square.and.pencil`) — Apple's "new" idiom in
/// Messages / Mail. Used in the messages header to start a fresh chat.
struct CircleComposeButton: View {
    var size: CGFloat = 36
    var body: some View {
        HeaderActionIcon(systemImage: "square.and.pencil", size: size)
    }
}

/// Wraps a left + right header action into a single visually-grouped
/// pill — used in the messages tab to merge the compose + "+" pair so
/// they read as one control instead of two floating icons. iOS 26+ gets
/// the system Liquid Glass material via `.glassEffect`; older systems
/// fall back to a flat muted-surface capsule with a hairline divider
/// between the two buttons.
struct GroupedHeaderControls<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 0) {
            leading()
            Rectangle()
                .fill(Theme.Palette.ink.opacity(0.10))
                .frame(width: 0.5, height: 18)
            trailing()
        }
        .groupedHeaderBackground()
    }
}

private extension View {
    @ViewBuilder
    func groupedHeaderBackground() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self.background(Capsule(style: .continuous).fill(Theme.Palette.surfaceMuted))
        }
    }
}

// MARK: - Plus-button popover menu

/// One row in a `PlusActionPopover`.
struct PlusActionItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let action: () -> Void
}

/// Tab-header "+" trigger that opens a narrow popover instead of the
/// default `Menu`. The native menu's row spacing is too tight for
/// thumb taps on these short option lists, so we render our own with
/// a fixed (smaller) width and roomier vertical spacing.
struct PlusActionPopover: View {
    let items: [PlusActionItem]
    var size: CGFloat = 36
    var width: CGFloat = 168

    @State private var isPresented = false

    var body: some View {
        Button {
            Haptics.tap()
            isPresented = true
        } label: {
            CirclePlusButton(size: size)
        }
        .buttonStyle(.plain)
        .popover(
            isPresented: $isPresented,
            attachmentAnchor: .point(.bottom),
            arrowEdge: .top
        ) {
            VStack(spacing: 4) {
                ForEach(items) { item in
                    Button {
                        isPresented = false
                        Haptics.tap()
                        item.action()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.systemImage)
                                .font(.system(size: 15, weight: .regular))
                                .frame(width: 22, alignment: .center)
                            Text(item.title)
                                .font(.system(size: 15))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(Theme.Palette.ink)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
            .frame(width: width)
            .presentationCompactAdaptation(.popover)
        }
    }
}
