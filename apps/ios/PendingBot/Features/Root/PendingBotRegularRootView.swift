import SwiftUI

/// Regular-size PendingBot shell for iPad.
///
/// `apps/shared/PendingBotShared` exists as a local SwiftPM package, but
/// `PendingBot.xcodeproj` does not currently reference it. Keeping this
/// bridge in the iOS target gives the future shared shell a single swap
/// point without risking a hand-edited package dependency that breaks
/// today's build.
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
        case .crew: CrewTabView()
        case .envelope: EnvelopeTabView()
        case .me: MeTabView()
        }
    }
}
