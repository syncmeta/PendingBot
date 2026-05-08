import SwiftUI
import Supabase

/// Per-conversation settings sheet — opened from the gear icon in the chat
/// header. Houses skills, model, provider, and the 来信 (Envelopes) trigger
/// + per-conversation envelope config.
struct ConversationSettingsView: View {
    @Binding var modelOverride: String
    /// Per-conversation provider pin. nil = "自动" (follow bot/model
    /// alias routing). Otherwise an llm_providers.slug — the chat POST
    /// passes it as `providerOverride` and the worker writes it back to
    /// conversations.provider_override.
    @Binding var providerOverride: String?

    let conversationId: String
    let enabledSkillCount: Int
    let totalSkillCount: Int
    var onOpenSkills: () -> Void
    var onApplyModel: (String?, ModelPickScope) -> Void
    var onApplyProvider: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.api) private var api
    @State private var showModelPicker = false
    @State private var pendingPick: PickPayload?

    // ── 来信 / Envelopes ─────────────────────────────────────────────────
    @State private var envelope: EnvelopeSettings = .defaults
    @State private var envelopeLoaded: Bool = false
    @State private var pickerTarget: EnvelopeModelPickerTarget?
    @State private var triggering: Bool = false
    @State private var triggerError: String?

    private enum EnvelopeModelPickerTarget: Identifiable {
        case explorer, collaborator
        var id: Int { self == .explorer ? 0 : 1 }
    }

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

                envelopeSection
            }
            .navigationTitle("会话设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await loadEnvelopeSettings() }
            .alert("出错", isPresented: .constant(triggerError != nil)) {
                Button("好") { triggerError = nil }
            } message: { Text(triggerError ?? "") }
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
            .sheet(item: $pickerTarget) { target in
                let initialSlug: String = {
                    switch target {
                    case .explorer:     return envelope.explorerModel
                    case .collaborator: return envelope.collaboratorModel ?? ""
                    }
                }()
                ModelPickerSheet(
                    initial: initialSlug,
                    allowsClear: target == .collaborator,
                    onPick: { picked in
                        switch target {
                        case .explorer:
                            // No clear for explorer — fall back to default if
                            // somehow the picker hands us nil.
                            envelope.explorerModel = picked ?? EnvelopeSettings.defaults.explorerModel
                        case .collaborator:
                            envelope.collaboratorModel = picked
                        }
                        pickerTarget = nil
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

    // MARK: - Envelope (来信) section

    @ViewBuilder
    private var envelopeSection: some View {
        Section {
            Button {
                Task { await triggerEnvelope() }
            } label: {
                HStack {
                    Image(systemName: "envelope.open")
                    Text(triggering ? "正在派出来信…" : "请这位写一封来信")
                    Spacer()
                    if triggering { ProgressView() }
                }
            }
            .foregroundStyle(Theme.Palette.ink)
            .disabled(triggering || conversationId.isEmpty || !envelopeLoaded)

            // Two explorers — main agent that drives the loop, plus an
            // optional collaborator that critiques each non-research turn.
            // Both default to ~google/gemini-flash-latest (cheap, fast).
            Button {
                pickerTarget = .explorer
            } label: {
                HStack {
                    Image(systemName: "person.crop.square")
                    Text("主探索者模型")
                    Spacer()
                    Text(shortSlug(envelope.explorerModel))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(Theme.Palette.ink)

            Button {
                pickerTarget = .collaborator
            } label: {
                HStack {
                    Image(systemName: "person.2.crop.square.stack")
                    Text("协作者模型")
                    Spacer()
                    Text(envelope.collaboratorModel.map(shortSlug) ?? "无")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(Theme.Palette.ink)

            Picker(selection: $envelope.searchProvider) {
                ForEach(EnvelopeSearchProvider.allCases, id: \.self) { p in
                    Text(p.label).tag(p)
                }
            } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("搜索")
                }
            }
            .foregroundStyle(Theme.Palette.ink)

            Picker(selection: $envelope.scrapeProvider) {
                ForEach(EnvelopeScrapeProvider.allCases, id: \.self) { p in
                    Text(p.label).tag(p)
                }
            } label: {
                HStack {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text("抓取")
                }
            }
            .foregroundStyle(Theme.Palette.ink)

            Stepper(value: $envelope.turnCap, in: 1...30) {
                HStack {
                    Image(systemName: "repeat")
                    Text("轮数上限")
                    Spacer()
                    Text("\(envelope.turnCap)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(Theme.Palette.ink)
        } header: {
            Text("来信 / Envelopes")
        } footer: {
            Text("机器人会读你和它的聊天记录，自己决定要不要上网查资料、记笔记，最后写一封来信发回来。在「来信」标签里能读到。轮数上限到了还没收笔就直接结束。")
        }
    }

    /// Pull the conversation row's saved envelope_settings, if any. We
    /// read straight through Supabase RLS — same pattern the Scroll feed
    /// uses — instead of adding a dedicated GET endpoint.
    private func loadEnvelopeSettings() async {
        guard !conversationId.isEmpty else {
            envelopeLoaded = true
            return
        }
        struct Row: Decodable { let envelope_settings: AnyJSON? }
        do {
            let row: Row = try await SupabaseStack.shared
                .from("conversations")
                .select("envelope_settings")
                .eq("id", value: conversationId)
                .single()
                .execute()
                .value
            envelope = EnvelopeSettings.from(row.envelope_settings)
        } catch {
            // No row yet, or no access — fall through to defaults.
        }
        envelopeLoaded = true
    }

    /// Fire the trigger with the current local settings. The worker
    /// persists them back onto the conversation as the new defaults,
    /// so the next manual trigger inherits without re-sending.
    private func triggerEnvelope() async {
        guard let api, !conversationId.isEmpty else { return }
        triggering = true
        defer { triggering = false }
        do {
            _ = try await api.scrollTrigger(
                conversationId: conversationId,
                settings: envelope
            )
            Haptics.success()
            dismiss()
        } catch is CancellationError {
        } catch let error as NSError where error.domain == NSURLErrorDomain
            && error.code == NSURLErrorCancelled {
        } catch {
            triggerError = error.localizedDescription
        }
    }
}
