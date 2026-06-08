#if os(macOS)
import SwiftUI

/// macOS `Settings` 场景(⌘,)的根内容。现在只是把既有的 `MacSettingsView`
/// 嵌进来 —— 真正跨平台共享的设置内容在后续 slice 才到位,这里先保持薄。
///
/// `Settings { SettingsRootView() }` 场景本身挂在 App 的 `body: some Scene`
/// 里(见 PendingBotApp 的 macOS 段),⌘, 的绑定来自 SwiftUI 的 `Settings`
/// 场景,所以场景 wrapper 必须住在 App body,而这里只提供其内容视图。
struct SettingsRootView: View {
    var body: some View {
        MacSettingsView()
    }
}
#endif
