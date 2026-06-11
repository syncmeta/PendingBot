import SwiftUI

// MARK: - Sort

/// How the merged friend list is ordered. The direction (A→Z vs Z→A,
/// 旧→新 vs 新→旧) is a separate `sortAscending` flag so each field can be
/// flipped without multiplying the cases.
enum FriendSortField: String, CaseIterable {
    case name        // 名称 (pinyin-aware)
    case recentChat  // 最近聊天
    case addedTime   // 加好友时间

    var label: String {
        switch self {
        case .name:       return "名称"
        case .recentChat: return "最近聊天"
        case .addedTime:  return "加好友时间"
        }
    }

    var systemImage: String {
        switch self {
        case .name:       return "textformat"
        case .recentChat: return "bubble.left.and.bubble.right"
        case .addedTime:  return "person.badge.clock"
        }
    }

    /// Sensible default direction when the user first switches to this field:
    /// names read A→Z; time fields lead with the most recent.
    var defaultAscending: Bool {
        switch self {
        case .name:                  return true
        case .recentChat, .addedTime: return false
        }
    }

    /// Direction-aware label for the active row in the sort menu, so the user
    /// can see (and toggle) whether tapping again flips the order.
    func directionLabel(ascending: Bool) -> String {
        switch self {
        case .name:       return ascending ? "A→Z" : "Z→A"
        case .recentChat: return ascending ? "最早优先" : "最近优先"
        case .addedTime:  return ascending ? "最早添加" : "最近添加"
        }
    }
}

// MARK: - Filter pills

/// Five-way filter sitting between the self row and the friend list.
/// Each pill carries the colour of the tag it scopes to (人类 → accent
/// green, 私有机器人 → plum, 公有机器人 → amber, 群聊 → tri-tone gradient).
/// 全部 stays neutral white. All pills share the same frosted-glass
/// capsule treatment as the login screen's brand pills.
enum FriendFilter: Hashable, CaseIterable {
    case all, humans, privateBots, publicBots, groups

    var label: String {
        switch self {
        case .all:         return "全部"
        case .humans:      return "人类"
        case .privateBots: return "私有机器人"
        case .publicBots:  return "公有机器人"
        case .groups:      return "群聊"
        }
    }

    /// Foreground colour when the pill is selected (and used for the
    /// selected-state stroke). 全部 stays in plain ink.
    var fg: Color {
        switch self {
        case .all:         return Theme.Palette.ink
        case .humans:      return Theme.Palette.accent
        case .privateBots: return Theme.Palette.plum
        case .publicBots:  return Theme.Palette.amber
        case .groups:      return Theme.Palette.ink
        }
    }
}
