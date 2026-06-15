import SwiftUI

// `TopTab` 已抽到跨平台文件 `Features/Root/TopTab.swift`(A5),供宽屏壳与
// iOS 侧栏共享。下面的 SidebarTabBar / topTabSelection 仍是 iOS-only。

/// Binding to the active top-level tab, threaded through environment so
/// the `SidebarTabBar` rendered inside each tab's sidebar can change
/// the selection without each tab knowing the parent's state shape.
private struct TopTabSelectionKey: EnvironmentKey {
    static let defaultValue: Binding<TopTab>? = nil
}
extension EnvironmentValues {
    var topTabSelection: Binding<TopTab>? {
        get { self[TopTabSelectionKey.self] }
        set { self[TopTabSelectionKey.self] = newValue }
    }
}

/// Horizontal strip of tab buttons sized to fit the bottom of a sidebar
/// column. Mirrors the iPhone tab bar's icon-on-top, label-below
/// arrangement — same visual vocabulary, just confined to the left
/// pane on iPad / Catalyst.
///
/// Sits flush against the bottom of its container; callers add it as
/// the last child of the sidebar's VStack.
struct SidebarTabBar: View {
    @Binding var selection: TopTab
    @EnvironmentObject private var unread: UnreadStore

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TopTab.allCases, id: \.self) { tab in
                Button {
                    if selection != tab { Haptics.tap() }
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        tab.symbol.image
                            .font(Theme.Fonts.glyph(size: 20, weight: .regular))
                            .overlay(alignment: .topTrailing) {
                                if tab == .message, unread.totalUnreadCount > 0 {
                                    Text(unread.totalUnreadCount > 99 ? "99+" : "\(unread.totalUnreadCount)")
                                        .font(Theme.Fonts.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .frame(minWidth: 17, minHeight: 17)
                                        .background(Capsule().fill(Color.red))
                                        .offset(x: 12, y: -8)
                                } else if tab == .envelope, unread.hasUnreadEnvelopes {
                                    // No count — just a small dot, matching
                                    // the message tab's visual placement.
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                        .overlay(
                                            Circle().strokeBorder(Theme.Palette.canvas, lineWidth: 1)
                                        )
                                        .offset(x: 6, y: -4)
                                }
                            }
                        Text(tab.label)
                            .font(Theme.Fonts.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(
                        selection == tab
                            ? Theme.Palette.accent
                            : Theme.Palette.inkMuted
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 4)
        .background(
            // Hairline divider above + canvas-tinted background so the
            // strip reads as chrome attached to the sidebar bottom,
            // not a floating row.
            ZStack(alignment: .top) {
                Theme.Palette.canvas
                Rectangle()
                    .fill(Theme.Palette.hairline)
                    .frame(height: 0.5)
            }
            .ignoresSafeArea(edges: .bottom)
        )
    }
}
