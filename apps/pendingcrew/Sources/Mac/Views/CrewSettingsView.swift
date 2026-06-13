#if os(macOS)
import SwiftUI

/// PendingCrew macOS 设置窗口（⌘,）。
///
/// 外观 Picker 对齐 PendingBot SettingsView —— 三态(跟随系统/浅色/深色)，
/// `@AppStorage(AppearanceMode.storageKey)` 写盘，`PendingCrewApp.body` 的
/// `.preferredColorScheme` 实时响应。
///
/// iPad shell 暂为占位页(task B2)，外观 Picker 届时在 iPad 设置入口再暴露。
struct CrewSettingsView: View {
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.default.rawValue

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .default
    }

    var body: some View {
        Form {
            Section {
                Picker("外观", selection: Binding(
                    get: { appearance },
                    set: { appearanceRaw = $0.rawValue }
                )) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("外观")
            } footer: {
                Text("「跟随系统」随设备的浅色/深色自动切换；也可固定为浅色或深色。")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
#endif
