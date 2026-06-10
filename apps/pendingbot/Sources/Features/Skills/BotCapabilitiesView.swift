import SwiftUI

/// 「我 → 机器人能力扩展」entry. Splits by upstream provider because
/// each one has its own native equivalents we don't override:
///
/// - OpenAI 原生 — uses OpenAI's built-in code interpreter + web search.
///   User-added Skills / MCP here layer on top of those natives.
/// - 其它（OpenRouter） — no native code/search; the Board ships the
///   anthropic preset triad (code-runner / mcp-builder / skill-creator)
///   default-on so OpenRouter bots have parity. Those presets are
///   admin-managed and don't show in this UI.
///
/// User-defined entries default to empty and are scoped per provider
/// (skills.provider column, MCP equivalent coming later).
enum BotProvider: String, Hashable {
    case openaiNative = "openai"
    case openrouter   = "openrouter"

    var displayName: String {
        switch self {
        case .openaiNative: return "OpenAI 原生"
        case .openrouter:   return "其它（OpenRouter）"
        }
    }

    var subtitle: String {
        switch self {
        case .openaiNative:
            return "原生 code interpreter + 搜索；可叠加自定义 Skills / MCP"
        case .openrouter:
            return "预设三件套由 Board 管理；这里只放你自己的 Skills / MCP"
        }
    }
}

struct BotCapabilitiesView: View {
    var body: some View {
        Form {
            Section {
                providerRow(.openaiNative)
                providerRow(.openrouter)
            } footer: {
                Text("按机器人使用的模型供应商分别配置。自建条目默认按所选供应商生效，不跨用。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle("机器人能力扩展")
        .inlineNavTitle()
        .tint(Theme.Palette.accent)
    }

    @ViewBuilder
    private func providerRow(_ p: BotProvider) -> some View {
        NavigationLink {
            ProviderCapabilitiesView(provider: p)
                .platformTabBarVisibility(false)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.displayName)
                Text(p.subtitle)
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.vertical, 2)
        }
    }
}

/// One provider's Skills + MCP root. Both children are user-scoped;
/// any system presets live on the Board side and stay hidden here.
struct ProviderCapabilitiesView: View {
    let provider: BotProvider

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    SkillsView(provider: provider)
                        .platformTabBarVisibility(false)
                } label: {
                    Text("Skills")
                }
                NavigationLink {
                    MCPServersStubView(provider: provider)
                        .platformTabBarVisibility(false)
                } label: {
                    Text("MCP Server")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle(provider.displayName)
        .inlineNavTitle()
        .tint(Theme.Palette.accent)
    }
}

/// Placeholder. User-scoped MCP server registry isn't wired yet —
/// today MCP rows live in the Board-managed `mcp_servers` table and
/// apply globally. Per-user, per-provider entries need their own
/// schema + edge-side merge, deferred to a follow-up.
struct MCPServersStubView: View {
    let provider: BotProvider

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(Theme.Fonts.glyph(size: 32, weight: .light))
                    .foregroundStyle(Theme.Palette.inkMuted.opacity(0.7))
                Text("暂未实现")
                    .font(Theme.Fonts.rounded(size: 16, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink)
                Text("MCP Server 用户侧自定义入口即将开放。")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
        }
        .inlineNavTitle()
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("MCP Server")
                    .font(Theme.Fonts.serif(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
            }
        }
    }
}
