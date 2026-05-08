import SwiftUI

/// Per-conversation settings sheet — opened from the gear icon in the chat
/// header. Houses skills and model controls.
struct ConversationSettingsView: View {
    @Binding var modelOverride: String
    /// Per-conversation provider pin. nil = "自动" (follow bot/model
    /// alias routing). Otherwise an llm_providers.slug — the chat POST
    /// passes it as `providerOverride` and the worker writes it back to
    /// conversations.provider_override.
    @Binding var providerOverride: String?

    let enabledSkillCount: Int
    let totalSkillCount: Int
    var onOpenSkills: () -> Void
    var onApplyModel: (String?, ModelPickScope) -> Void
    var onApplyProvider: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showModelPicker = false
    @State private var pendingPick: PickPayload?

    private struct PickPayload: Identifiable {
        let id = UUID()
        let slug: String?
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("技能") {
                    Button {
                        dismiss()
                        onOpenSkills()
                    } label: {
                        HStack {
                            Image(systemName: "puzzlepiece.extension")
                            Text("管理技能")
                            Spacer()
                            if totalSkillCount > 0 {
                                Text("\(enabledSkillCount)/\(totalSkillCount)")
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(Theme.Palette.ink)
                }

                Section("模型") {
                    Button {
                        showModelPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "cube.transparent")
                            Text("选择模型")
                            Spacer()
                            Text(modelOverride.isEmpty ? "跟随默认" : shortSlug(modelOverride))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(Theme.Palette.ink)
                }

                // 提供商：本地选择走 LLMRouter 的 preferProvider，挂了
                // 仍会走 fallback 到其它家。"自动" = 不传 preferProvider，
                // 由 alias 权重决定。WorldRouter 一般比 OpenRouter 便宜
                // ~30%（它声明转发 Anthropic native usage），可对账验证。
                Section {
                    Picker(selection: Binding(
                        get: { providerOverride ?? "" },
                        set: { newValue in
                            let normalized = newValue.isEmpty ? nil : newValue
                            providerOverride = normalized
                            onApplyProvider(normalized)
                        }
                    )) {
                        Text("自动").tag("")
                        Text("WorldRouter").tag("worldrouter")
                        Text("OpenRouter").tag("openrouter")
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.branch")
                            Text("提供商")
                        }
                    }
                    .foregroundStyle(Theme.Palette.ink)
                } footer: {
                    Text("选「自动」按系统默认路由。指定一家时仍保留 fallback：那家 5xx 时会自动落到另一家。")
                }
            }
            .navigationTitle("会话设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showModelPicker) {
                ModelPickerSheet(
                    initial: modelOverride,
                    allowsClear: true,
                    onPick: { picked in
                        showModelPicker = false
                        pendingPick = PickPayload(slug: picked)
                    }
                )
                .presentationDragIndicator(.visible)
                .tint(Theme.Palette.accent)
            }
            .confirmationDialog(
                pendingPick?.slug.map { "应用「\(shortSlug($0))」到…" } ?? "清除模型选择…",
                isPresented: Binding(
                    get: { pendingPick != nil },
                    set: { if !$0 { pendingPick = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("仅本次会话") {
                    if let p = pendingPick { onApplyModel(p.slug, .conversation) }
                    pendingPick = nil
                }
                Button("这个机器人（仅自己）") {
                    if let p = pendingPick { onApplyModel(p.slug, .bot) }
                    pendingPick = nil
                }
                Button("取消", role: .cancel) { pendingPick = nil }
            } message: {
                Text(pendingPick?.slug == nil
                     ? "选择「仅本次会话」会清掉本会话的临时指定；选择「这个机器人」会把你为这个机器人指定的模型也一并清掉，回到机器人默认。"
                     : "选择「仅本次会话」只影响当前对话；选择「这个机器人」会改你这台号上这个机器人的默认模型，对所有未单独指定的会话生效。")
            }
        }
        .tint(Theme.Palette.accent)
    }

    private func shortSlug(_ slug: String) -> String {
        slug.split(separator: "/").last.map(String.init) ?? slug
    }
}
