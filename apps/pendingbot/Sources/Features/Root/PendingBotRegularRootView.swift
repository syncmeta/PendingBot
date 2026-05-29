#if os(iOS)
import SwiftUI

/// Regular-size PendingBot shell for iPad.
///
/// The Crew tab uses the shared SwiftUI big-screen surface; the other tabs
/// keep their native iPad views until their shared surfaces exist.
struct PendingBotRegularRootView: View {
    @Binding var selection: TopTab

    var body: some View {
        PendingBotBigScreenShellBridge(selection: $selection)
    }
}

private struct PendingBotBigScreenShellBridge: View {
    @Binding var selection: TopTab

    var body: some View {
        // Future shared-shell hook, after the Xcode project owns a local
        // package dependency:
        //
        // import PendingBotShared
        // PendingBotBigScreenAppView(...)
        currentIOSRegularTab
    }

    @ViewBuilder
    private var currentIOSRegularTab: some View {
        switch selection {
        case .message: MessageTabView()
        case .friends: FriendsTabView()
        // T4.6 multiplatform cutover: iPad/Mac share the same V2 Crew Tab as
        // iPhone (spec v2 §11.2 三端齐), retiring the codex-era big-screen
        // dashboard (PendingBotRegularCrewView + /v1/crew singular surface).
        case .crew: CrewTabV2View()
        case .envelope: EnvelopeTabView()
        case .me: MeTabView()
        }
    }
}
#endif
