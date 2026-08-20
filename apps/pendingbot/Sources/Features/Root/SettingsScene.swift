#if os(macOS)
import SwiftUI

/// macOS `Settings` 场景(⌘,)的根内容。现在托管的是**跨平台共享**的
/// `SettingsView`(就是 iOS「我 → 设置」push 进去的那一份),Mac 端 Me tab
/// 的「设置」入口用 `SettingsLink` 指到这个独立窗口(D4:两端同一份设置)。
///
/// `Settings { SettingsRootView() }` 场景本身挂在 App 的 `body: some Scene`
/// 里(见 PendingBotApp 的 macOS 段),⌘, 的绑定来自 SwiftUI 的 `Settings`
/// 场景,所以场景 wrapper 必须住在 App body,而这里只提供其内容视图。
///
/// `SettingsView` 自带 `Form` + `.navigationTitle("设置")`;`Settings` 场景
/// 不提供导航容器,所以给一个固定窗口尺寸 + 画布底色,让它在设置窗口里
/// 排版稳妥(标题由系统设置窗口的 chrome 承载,`.navigationTitle` 在无栈
/// 时是 no-op,无害)。
struct SettingsRootView: View {
    var body: some View {
        SettingsView()
            .frame(minWidth: 520, minHeight: 460)
            .background(Theme.Palette.canvas)
    }
}
#endif
