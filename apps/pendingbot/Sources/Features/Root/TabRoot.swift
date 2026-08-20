#if os(iOS)
import SwiftUI

/// Four-tab root: 消息 / 好友 / 来信 / 我.
///
/// 来信 (Envelopes) hosts a feed of articles each bot has written for
/// the user; new envelopes are triggered from each conversation's
/// settings sheet.
///
/// Two layouts driven by horizontal size class:
///   • compact (iPhone): system `TabView` with the bottom tab bar
///   • regular (iPad): the active tab is rendered
///     directly (no system tab bar), and each tab embeds a
///     `SidebarTabBar` at the bottom of its left column — the
///     WeChat / QQ iPad placement.
struct TabRoot: View {
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject private var unread: UnreadStore
    @Environment(\.useSidebarLayout) private var sidebarLayout
    /// App-level call ownership. The full-screen cover for in-call UI
    /// and the floating pill that takes its place when minimized both
    /// live here at the root, so the call survives the user switching
    /// tabs or popping the conversation off the nav stack.
    @Environment(CallCenter.self) private var callCenter
    /// Deep-link inbox. A /b/<slug> link flips us to the friends tab,
    /// which then presents the add-bot preview (it clears the slug).
    @State private var deepLink = DeepLinkStore.shared

    // Persisted across launches so reopening the app on iPad puts the
    // user back where they were. SceneStorage keeps it per-window which
    // matches Catalyst multi-window expectations.
    @SceneStorage("topTab") private var selectedRaw: String = TopTab.message.rawValue

    // Live selection source for the TabView. @State commits synchronously,
    // so the TabView never re-reads a stale value mid-transition — reading
    // @SceneStorage directly in the binding's getter caused a one-frame
    // flash back to the previous tab. Stays nil until the first switch so
    // the initial render still honours the persisted tab without a flash.
    @State private var liveTab: TopTab?
    /// Local presentation state for the active call cover. It mirrors
    /// `CallCenter` instead of deriving a custom Binding directly from
    /// the observable object, which avoids SwiftUI dropping presentation
    /// updates when the session is installed from a deeply nested view.
    @State private var isShowingCallCover = false

    private var selected: Binding<TopTab> {
        Binding(
            get: { liveTab ?? TopTab(rawValue: selectedRaw) ?? .message },
            set: { newValue in
                liveTab = newValue
                selectedRaw = newValue.rawValue
            }
        )
    }

    var body: some View {
        if store.current != nil {
            Group {
                if sidebarLayout {
                    // iPad regular 收敛到与 macOS @main 同一个三列壳。注入
                    // `selected` 作为外部 tab 绑定,壳跟着 TabRoot 的选择走 ——
                    // 下面的深链 onChange 改 `selected.wrappedValue` 时,壳的
                    // 侧栏与中/右栏会同步翻 tab。
                    WideRootView(externalTab: selected)
                } else {
                    compactBody
                }
            }
            .environment(\.api, APIClient())
            .environment(\.account, store.current)
            .environment(\.topTabSelection, selected)
            .safeAreaInset(edge: .bottom) {
                // Floating pill sits above whatever bottom chrome the
                // current layout puts on screen (TabBar on compact,
                // SidebarTabBar on regular). `safeAreaInset` keeps the
                // underlying scroll content aware of the pill's height
                // so the last list row isn't covered.
                CallFloatingPill(center: callCenter)
                    .animation(
                        .spring(response: 0.32, dampingFraction: 0.85),
                        value: callCenter.isMinimized,
                    )
                    .animation(
                        .spring(response: 0.32, dampingFraction: 0.85),
                        value: callCenter.voiceCall != nil,
                    )
                    .animation(
                        .spring(response: 0.32, dampingFraction: 0.85),
                        value: callCenter.groupCall != nil,
                    )
            }
            .fullScreenCover(isPresented: $isShowingCallCover, onDismiss: handleCallCoverDismiss) {
                callCover
            }
            .onChange(of: callCenter.hasActiveCall, initial: true) { _, _ in
                syncCallCoverPresentation()
            }
            .onChange(of: callCenter.isMinimized, initial: true) { _, _ in
                syncCallCoverPresentation()
            }
            .onChange(of: store.current) { _, _ in Haptics.tap() }
            // A bot-share link landed — make sure the friends tab is the
            // one on screen so it can present the add-bot preview. The
            // friends tab itself consumes (and clears) the pending token.
            .onChange(of: deepLink.pendingAddBotToken) { _, new in
                if new != nil { selected.wrappedValue = .friends }
            }
            // A group invite link (/g/<token>) landed — flip to the message
            // tab, which presents the join-group preview (decisions.md D2).
            .onChange(of: deepLink.pendingJoinGroupToken) { _, new in
                if new != nil { selected.wrappedValue = .message }
            }
        } else {
            // Defensive — RootView wouldn't have shown TabRoot otherwise.
            WelcomeView()
        }
    }

    // MARK: - Call cover bindings

    @ViewBuilder
    private var callCover: some View {
        if let session = callCenter.voiceCall {
            CallView(session: session)
        } else if let session = callCenter.groupCall {
            GroupCallView(session: session)
        }
    }

    private func syncCallCoverPresentation() {
        let shouldShow = callCenter.hasActiveCall && !callCenter.isMinimized
        if isShowingCallCover != shouldShow {
            isShowingCallCover = shouldShow
        }
    }

    private func handleCallCoverDismiss() {
        if callCenter.hasActiveCall && !callCenter.isMinimized {
            callCenter.minimize()
        }
        syncCallCoverPresentation()
    }

    // ── Compact (iPhone) ────────────────────────────────────────────────────

    private var compactBody: some View {
        // 消息 tab badge — the system draws it on the tab item itself, so
        // it sits in the right place and never bleeds onto pushed or
        // presented views the way a hand-positioned overlay did.
        TabView(selection: selected) {
            MessageTabView()
                .tabItem { tabItem(TopTab.message) }
                .badge(unread.totalUnreadCount)
                .tag(TopTab.message)

            FriendsTabView()
                .tabItem { tabItem(TopTab.friends) }
                .tag(TopTab.friends)

            CrewTabView()
                .tabItem { tabItem(TopTab.crew) }
                .tag(TopTab.crew)

            EnvelopeTabView()
                .tabItem { tabItem(TopTab.envelope) }
                // System tab badge doesn't have a dot-only variant — a
                // bullet glyph is the closest we get to "small red dot".
                .badge(unread.hasUnreadEnvelopes ? Text(verbatim: "●") : nil)
                .tag(TopTab.envelope)

            MeTabView()
                .tabItem { tabItem(TopTab.me) }
                .tag(TopTab.me)
        }
    }

    private func tabItem(_ tab: TopTab) -> some View {
        Label {
            Text(tab.label)
        } icon: {
            tab.symbol.image
        }
    }

}

// EnvironmentValues for \.api / \.account moved to AppEnvironment.swift
// (cross-platform — the keys must exist on macOS too).
#endif
