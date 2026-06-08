#if os(macOS)
import SwiftUI

/// Mac 端原生菜单栏意图。命令按钮**只广播意图**,不直接改状态 —— 真正
/// 的响应由 shell / feature 在后续 slice 里订阅 `.appCommand` 通知后接线
/// (例如朋友面 surface 监听 `.newBot`)。现在还没有 observer 是正常的:
/// 广播本身已满足"菜单项可用 + 快捷键注册"这一层。
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
    var body: some Commands {
        // 文件菜单 —— 紧跟系统 "New" 项之后插入新建动作。
        CommandGroup(after: .newItem) {
            Button("新建机器人") { post(.newBot) }
                .keyboardShortcut("n", modifiers: .command)

            Button("新建会话") { post(.newConversation) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        // 搜索 —— 单列一个顶层菜单,⌘F 触发。
        CommandMenu("搜索") {
            Button("搜索") { post(.search) }
                .keyboardShortcut("f", modifiers: .command)
        }
    }
}
#endif
