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
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    headerCard
                    VStack(spacing: 0) {
                        providerRow(.openaiNative)
                        optionDivider
                        providerRow(.openrouter)
                    }
                    .meGlassGroup()
                }
                .padding(.horizontal, Theme.Metrics.gutter)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("机器人能力扩展")
                    .font(Theme.Fonts.serif(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("按机器人使用的模型供应商分别配置。自建条目默认按所选供应商生效，不跨用。")
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.Palette.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func providerRow(_ p: BotProvider) -> some View {
        NavigationLink {
            ProviderCapabilitiesView(provider: p)
                .toolbar(.hidden, for: .tabBar)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.displayName)
                        .font(Theme.Fonts.rounded(size: 15, weight: .medium))
                        .foregroundStyle(Theme.Palette.ink)
                    Text(p.subtitle)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.inkMuted.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var optionDivider: some View {
        Rectangle()
            .fill(Theme.Palette.hairline)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}

/// One provider's Skills + MCP root. Both children are user-scoped;
/// any system presets live on the Board side and stay hidden here.
struct ProviderCapabilitiesView: View {
    let provider: BotProvider

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 0) {
                        NavigationLink {
                            SkillsView(provider: provider)
                                .toolbar(.hidden, for: .tabBar)
                        } label: {
                            OptionRow(title: "Skills")
                        }
                        .buttonStyle(.plain)

                        Rectangle()
                            .fill(Theme.Palette.hairline)
                            .frame(height: 0.5)
                            .padding(.leading, 16)

                        NavigationLink {
                            MCPServersStubView(provider: provider)
                                .toolbar(.hidden, for: .tabBar)
                        } label: {
                            OptionRow(title: "MCP Server")
                        }
                        .buttonStyle(.plain)
                    }
                    .meGlassGroup()
                }
                .padding(.horizontal, Theme.Metrics.gutter)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(provider.displayName)
                    .font(Theme.Fonts.serif(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
            }
        }
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
                    .font(.system(size: 32, weight: .light))
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("MCP Server")
                    .font(Theme.Fonts.serif(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
            }
        }
    }
}
