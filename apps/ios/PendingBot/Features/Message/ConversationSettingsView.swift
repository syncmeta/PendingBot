import SwiftUI
import Supabase

/// Per-conversation settings page — pushed from the gear icon in the chat
/// header. Houses skills, model, provider, the 来信 (Envelopes) trigger
/// + per-conversation envelope config, and the lookback notes log.
struct ConversationSettingsView: View {
    @Binding var modelOverride: String
    /// Per-conversation provider pin. nil = "自动" (follow bot/model
    /// alias routing). Otherwise an llm_providers.slug — the chat POST
    /// passes it as `providerOverride` and the worker writes it back to
    /// conversations.provider_override.
    @Binding var providerOverride: String?

    let conversationId: String
    /// Bot powering this conv. Drives the "model picker visible?" gate:
    /// only the creator of a *private* bot can change the model. nil for
    /// non-bot convs (group/user_user); section hides outright there too.
    let bot: Bot?
    /// Currently signed-in user — needed to compare against bot.creator_id.
    let currentUserId: String?
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

    // ── Lookback 笔记 ─────────────────────────────────────────────────────
    @State private var lookbacks: [LookbackRow] = []
    @State private var lookbacksLoaded: Bool = false

    private struct LookbackRow: Identifiable, Decodable {
        let id: String
        let body_md: String
        let active: Bool
        let created_at: String
    }

    private enum EnvelopeModelPickerTarget: Identifiable {
        case explorer, collaborator
        var id: Int { self == .explorer ? 0 : 1 }
    }

    private struct PickPayload: Identifiable {
        let id = UUID()
        let slug: String?
    }

    var body: some View {
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

                if canEditModel {
                    Section("模型") {
                        Button {
                            showModelPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "cube.transparent")
                                Text("选择模型")
                                Spacer()
                                Text(currentModelLabel)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .foregroundStyle(Theme.Palette.ink)
                    }
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
            lookbackSection
        }
        .navigationTitle("会话设置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadEnvelopeSettings()
            await loadLookbacks()
        }
        .alert("出错", isPresented: .constant(triggerError != nil)) {
            Button("好") { triggerError = nil }
        } message: { Text(triggerError ?? "") }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(
                initial: modelOverride,
                allowsClear: false,
                onPick: { picked in
                    showModelPicker = false
                    // allowsClear=false → picker only emits non-nil slugs.
                    if let picked { pendingPick = PickPayload(slug: picked) }
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
                clearLabel: "无协作者",
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
            pendingPick.map { "应用「\(shortSlug($0.slug ?? ""))」到…" } ?? "",
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
            Button("改机器人默认模型") {
                if let p = pendingPick { onApplyModel(p.slug, .bot) }
                pendingPick = nil
            }
            Button("取消", role: .cancel) { pendingPick = nil }
        } message: {
            Text("「仅本次会话」只影响当前对话；「改机器人默认模型」会替换这个机器人的默认模型，并清掉本会话的会话级指定，让这里也跟上新默认。")
        }
        .tint(Theme.Palette.accent)
    }

    private func shortSlug(_ slug: String) -> String {
        slug.split(separator: "/").last.map(String.init) ?? slug
    }

    /// Only the creator of a *private* bot may pin a model — for this conv
    /// (per-conv override) or for the bot itself (default model). Public
    /// and preset bots are read-only on the client; the worker enforces
    /// the same gate server-side.
    private var canEditModel: Bool {
        guard let bot, let me = currentUserId else { return false }
        return bot.visibility == "private" && bot.creator_id == me
    }

    /// Label for the picker row: per-conv pin first, then the bot's
    /// default. Both are slugs — show the short tail to match the rest of
    /// the UI.
    private var currentModelLabel: String {
        if !modelOverride.isEmpty { return shortSlug(modelOverride) }
        if let m = bot?.model, !m.isEmpty { return shortSlug(m) }
        return "—"
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

    // MARK: - Lookback section

    @ViewBuilder
    private var lookbackSection: some View {
        Section {
            if !lookbacksLoaded {
                HStack { ProgressView(); Text("加载中…").foregroundStyle(.secondary) }
            } else if lookbacks.isEmpty {
                Text("暂无回看笔记。每隔 10 轮，机器人会自动回看一次最近的对话，发现需要更正/补充的地方就在这里记一笔。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(lookbacks) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(row.active ? "活跃" : "已撤")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    (row.active ? Theme.Palette.accent : Color.secondary)
                                        .opacity(0.15),
                                    in: Capsule()
                                )
                                .foregroundStyle(row.active ? Theme.Palette.accent : .secondary)
                            Text(formattedTime(row.created_at))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(row.body_md)
                            .font(.callout)
                            .foregroundStyle(row.active ? Theme.Palette.ink : .secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("回看笔记 / Lookback")
        } footer: {
            Text("机器人每隔 10 轮自我复盘一次：检查你或它说过的内容是否需要更正、补充。活跃笔记会注入到下一次回复的上下文里；机器人觉得没问题就会撤掉。")
        }
    }

    private func loadLookbacks() async {
        guard !conversationId.isEmpty else {
            lookbacksLoaded = true
            return
        }
        do {
            let rows: [LookbackRow] = try await SupabaseStack.shared
                .from("bot_lookbacks")
                .select("id, body_md, active, created_at")
                .eq("conversation_id", value: conversationId)
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value
            lookbacks = rows
        } catch {
            // Silent — section just shows the empty hint.
        }
        lookbacksLoaded = true
    }

    private func formattedTime(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return iso }
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        return df.string(from: date)
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
