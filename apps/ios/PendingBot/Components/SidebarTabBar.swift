import SwiftUI

/// One of the four top-level tabs. Used by TabRoot to drive its
/// regular-size-class layout (where we replace the system bottom tab bar
/// with a `SidebarTabBar` rendered at the bottom of each tab's left
/// column — the WeChat / QQ iPad pattern).
enum TopTab: String, Hashable, CaseIterable {
    case message
    case friends
    case scroll
    case me

    var label: String {
        switch self {
        case .message: return "消息"
        case .friends: return "好友"
        case .scroll:  return "来信"
        case .me:      return "我"
        }
    }

    var systemImage: String {
        switch self {
        case .message: return "bubble.left"
        case .friends: return "person.2"
        case .scroll:  return "envelope.open"
        case .me:      return "person.crop.circle"
        }
    }
}

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
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 20, weight: .regular))
                            .overlay(alignment: .topTrailing) {
                                if tab == .message, unread.hasUnread {
                                    Circle()
                                        .fill(Theme.Palette.accent)
                                        .frame(width: 7, height: 7)
                                        .offset(x: 7, y: -2)
                                }
                            }
                        Text(tab.label)
                            .font(.system(size: 10, weight: .medium))
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
