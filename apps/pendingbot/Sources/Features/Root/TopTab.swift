import SwiftUI

enum AppSymbol: Hashable {
    case system(String)
    case custom(String)

    static let pendingCrew = AppSymbol.custom("PendingCrewSymbol")

    var image: Image {
        switch self {
        case .system(let name):
            Image(systemName: name)
        case .custom(let name):
            Image(name)
        }
    }
}

/// One of the top-level tabs (消息 / 好友 / 来信 / 我).
///
/// 跨平台共享:iOS 的 `SidebarTabBar` / `TabRoot` 用它驱动 regular-size-class
/// 布局,Mac/iPad 的 `WideRootView` 用它驱动三列宽屏壳的侧栏选择。原先这个
/// enum 内联在 `Components/SidebarTabBar.swift`(iOS-locked),A5 把它抽出来
/// 作为壳↔tab 的共享枚举。
enum TopTab: String, Hashable, CaseIterable, Identifiable {
    case message
    case friends
    case crew
    case envelope
    case me

    var id: String { rawValue }

    var label: String {
        switch self {
        case .message:  return "消息"
        case .friends:  return "好友"
        case .crew:     return "机组"
        case .envelope: return "来信"
        case .me:       return "我"
        }
    }

    var symbol: AppSymbol {
        switch self {
        case .message:  return .system("bubble.left")
        case .friends:  return .system("person.2")
        case .crew:     return .pendingCrew
        case .envelope: return .system("envelope.open")
        case .me:       return .system("person.crop.circle")
        }
    }
}
