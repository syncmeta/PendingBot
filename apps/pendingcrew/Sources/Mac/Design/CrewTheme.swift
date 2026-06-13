#if os(macOS)
import SwiftUI

/// PendingCrew 本地设计 token —— 数值对齐 PendingBot iOS Theme，但独立成 macOS
/// 原生实现，不依赖 PendingBot 私有代码（保住 PendingCrew 可独立开源定位）。
enum CrewTheme {
    enum Palette {
        static let accent           = Color(hex: 0x044735)
        static let accentBg         = Color(hex: 0xE3EEEA)   // 我的气泡底
        static let userBubble       = accentBg
        static let canvas           = Color(hex: 0xFDFCFA)
        static let surface          = Color(hex: 0xFFFFFF)   // 别人气泡 / 卡片底
        static let surfaceMuted     = Color(hex: 0xEFEEE9)   // chip / roster 底
        static let ink              = Color(hex: 0x1B1A14)
        static let inkMuted         = Color(hex: 0x6E6A5C)   // 名字抬头 / 时间戳
        static let hairline         = Color(hex: 0xE2E0D7)
        static let amber            = Color(hex: 0x6F5A0B)   // 交互卡强调
        static let amberBg          = Color(hex: 0xFAEDC2)
    }

    enum Metrics {
        static let gutter: CGFloat       = 16
        static let bubbleRadius: CGFloat = 18
        static let cardRadius: CGFloat   = 14
        static let avatar: CGFloat       = 30
    }

    enum Fonts {
        static func rounded(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .rounded)
        }
        static func system(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight)
        }
        static let body     = system(16)
        static let callout  = system(15)
        static let caption  = system(12)
        static let caption2 = system(11)
    }
}

// Color(hex:) is provided by the vendored Chat/Vendored/ColorHex.swift
// (cross-platform, superset of the old local definition). Local copy removed
// to avoid duplicate-overload ambiguity after vendoring.
#endif
