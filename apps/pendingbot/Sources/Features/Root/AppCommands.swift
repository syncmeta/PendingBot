#if os(macOS)
import SwiftUI

/// 旧菜单广播意图；新建会话使用 focused scene action，避免多窗口同时响应。
enum AppCommand {
    case newBot
    case newConversation
    case search
}

extension Notification.Name {
    /// 由 `AppCommands` 发出、携带一个 `AppCommand` 作为 object 的通知。
    static let appCommand = Notification.Name("PendingBotAppCommand")
}

private func post(_ command: AppCommand) {
    NotificationCenter.default.post(name: .appCommand, object: command)
}

/// 把"新建机器人 / 新建会话 / 搜索"挂到 macOS 系统菜单栏,并带上原生快捷键。
/// 通过 `.commands { AppCommands() }` 挂在 App 的 `WindowGroup` 上。
struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.newConversationAction) private var newConversationAction
    var body: some Commands {
        // 替换系统 New，避免默认新窗口与新建会话抢占 ⌘N。
        CommandGroup(replacing: .newItem) {
            Button("新建机器人") { post(.newBot) }

            Button("新建会话") { newConversationAction?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(newConversationAction == nil)

            Button("新建窗口") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        // 搜索 —— 单列一个顶层菜单,⌘F 触发。
        CommandMenu("搜索") {
            Button("搜索") { post(.search) }
                .keyboardShortcut("f", modifiers: .command)
        }
    }
}

private struct NewConversationActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var newConversationAction: (() -> Void)? {
        get { self[NewConversationActionKey.self] }
        set { self[NewConversationActionKey.self] = newValue }
    }
}
#endif
