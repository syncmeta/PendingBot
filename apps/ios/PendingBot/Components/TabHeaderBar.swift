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

/// "+" icon inside a native-iOS "white glass" capsule — same idiom Apple
/// uses for nav-bar action chips on translucent chrome (Maps, Photos).
/// Used as the trailing item in the message + friends tab headers.
struct CirclePlusButton: View {
    var size: CGFloat = 32
    var body: some View {
        CircleGlassChip(systemImage: "plus", size: size)
    }
}

/// Sibling to CirclePlusButton — same glass capsule, three-dot glyph.
/// Used in the messages header for the "more actions" menu.
struct CircleEllipsisButton: View {
    var size: CGFloat = 32
    var body: some View {
        CircleGlassChip(systemImage: "ellipsis", size: size)
    }
}

private struct CircleGlassChip: View {
    let systemImage: String
    let size: CGFloat
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.Palette.accent)
            .frame(width: size, height: size)
            .background(Circle().fill(.ultraThinMaterial))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
    }
}
