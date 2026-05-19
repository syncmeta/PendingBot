import SwiftUI
import Supabase

/// Recipient profile for human-to-human letters. Non-nil only on
/// user_user conversations — when set, the 来信 section flips from
/// "请这位机器人写信给你" (kick off bot envelope) to "给对方写信"
/// (open the markdown editor sheet). Mirrors what `peerProfileForBubble`
/// produces in ConversationView.
///
/// `Identifiable` via `userId` so the compose sheet can be driven by
/// `.sheet(item:)` from a stable parent — the prior `.sheet(isPresented:)`
/// attached inside a conditional sub-view would auto-dismiss on first
/// open because the conditional re-evaluated when the bool flipped.
struct LetterRecipient: Equatable, Hashable, Identifiable {
    let userId: String
    let displayName: String
    var id: String { userId }
}

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
    /// Set on user_user conversations to switch the 来信 section into
    /// "compose a letter to this person" mode. nil on bot/self/group.
    let recipient: LetterRecipient?
    let enabledSkillCount: Int
    let totalSkillCount: Int
    var onOpenSkills: () -> Void
    var onApplyModel: (String?, ModelPickScope) -> Void
    var onApplyProvider: (String?) -> Void
    /// Per-conv vision-model pin. nil means "auto" (use the main model
    /// when it has vision, else server's default — currently kimi-latest).
    /// Saved via PATCH /v1/conversations/:id { vision_model_slug }.
    var onApplyVisionModel: (String?) -> Void
    /// Per-conv realtime voice-model pin. nil = "跟随机器人设置" (follow the
    /// bot's default voice model). Saved via PATCH /v1/conversations/:id
    /// { voice_model_slug }.
    var onApplyVoiceModel: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.api) private var api
    @State private var showModelPicker = false
    @State private var showVisionPicker = false
    @State private var pendingPick: PickPayload?
    @State private var visionModelOverride: String? = nil
    @State private var visionLoaded: Bool = false
    @State private var voiceModelOverride: String? = nil

    // ── 来信 / Envelopes ─────────────────────────────────────────────────
    @State private var envelope: EnvelopeSettings = .defaults
    @State private var envelopeLoaded: Bool = false
    @State private var triggering: Bool = false
    @State private var triggerError: String?

    // ── 给对方写信 / human letter compose ────────────────────────────────
    // Driven via `.sheet(item:)` from the outer body so that flipping the
    // entry-point button doesn't fight the conditional `if let recipient`
    // inside `envelopeSection` (which used to dismiss the sheet on its
    // first open).
    @State private var letterTarget: LetterRecipient? = nil
    @State private var sendingLetter: Bool = false

    // ── Lookback 笔记 ─────────────────────────────────────────────────────
    @State private var lookbacks: [LookbackRow] = []
    @State private var lookbacksLoaded: Bool = false

    private struct LookbackRow: Identifiable, Decodable {
        let id: String
        let body_md: String
        let active: Bool
        let created_at: String
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

                    // 识图模型 — only used when the bot needs to describe
                    // an image. nil = auto: main model if it has vision,
                    // else server falls back to kimi-latest.
                    Section {
                        Button {
                            showVisionPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "eye")
                                Text("识图模型")
                                Spacer()
                                Text(currentVisionLabel)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .foregroundStyle(Theme.Palette.ink)
                    } footer: {
                        Text("看图、给图片写摘要、回答关于图片的问题时用这个模型。「自动」时：主模型若支持识图就直接用主模型，否则回落到默认（kimi-latest）。")
                    }

                    // 语音模型 — only when this bot has voice calls on.
                    // nil = 跟随机器人设置 (bots.config.voiceModel).
                    if bot?.voice_call_enabled == true {
                        Section {
                            Picker(selection: Binding(
                                get: { voiceModelOverride },
                                set: { newValue in
                                    voiceModelOverride = newValue
                                    onApplyVoiceModel(newValue)
                                    Haptics.tap()
                                }
                            )) {
                                Text("跟随机器人设置").tag(String?.none)
                                Text("gpt-realtime-2")
                                    .tag(String?("gpt-realtime-2"))
                                Text("gpt-realtime-mini")
                                    .tag(String?("gpt-realtime-mini-2025-12-15"))
                            } label: {
                                HStack {
                                    Image(systemName: "waveform")
                                    Text("语音模型")
                                }
                            }
                            .foregroundStyle(Theme.Palette.ink)
                        } footer: {
                            Text("这次对话语音通话用的实时模型。「跟随机器人设置」时用机器人设置里的语音模型。")
                        }
                    }
                }

                // 提供商：本地选择走 LLMRouter 的 preferProvider，挂了
                // 仍会走 fallback 到其它家。"自动" = 不传 preferProvider，
                // 由路由默认决定。
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

            botSettingsSection
            envelopeSection
            lookbackSection
        }
        .navigationTitle("会话设置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadEnvelopeSettings()
            await loadLookbacks()
            await loadVisionSettings()
            await loadVoiceSettings()
        }
        .alert("出错", isPresented: .constant(triggerError != nil)) {
            Button("好") { triggerError = nil }
        } message: { Text(triggerError ?? "") }
        .sheet(item: $letterTarget) { recipient in
            LetterComposeSheet(recipient: recipient) { title, bodyMd in
                await sendHumanLetter(title: title, bodyMd: bodyMd)
            }
            .presentationDragIndicator(.visible)
            .tint(Theme.Palette.accent)
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(
                initial: modelOverride,
                allowsClear: false,
                onPick: { picked in
                    showModelPicker = false
                    // allowsClear=false → picker only emits non-nil rows.
                    if let picked { pendingPick = PickPayload(slug: picked.slug) }
                }
            )
            .presentationDragIndicator(.visible)
            .tint(Theme.Palette.accent)
        }
        .sheet(isPresented: $showVisionPicker) {
            ModelPickerSheet(
                initial: visionModelOverride ?? "",
                allowsClear: true,
                clearLabel: "自动（跟随主模型 / 默认 kimi-latest）",
                visionOnly: true,
                onPick: { picked in
                    showVisionPicker = false
                    let normalized = (picked?.slug).flatMap { $0.isEmpty ? nil : $0 }
                    visionModelOverride = normalized
                    onApplyVisionModel(normalized)
                    Haptics.success()
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

    /// Label for the vision-model picker. nil = "自动" (server resolves
    /// at call time). Don't surface "kimi-latest" as the visible default
    /// here — that's a server-side detail and could change.
    private var currentVisionLabel: String {
        guard let slug = visionModelOverride, !slug.isEmpty else { return "自动" }
        return shortSlug(slug)
    }

    // MARK: - Bot settings link

    /// Entry into the bot-level config (default model / voice / vision /
    /// 写信 defaults / lookback / skills). Only shown on user_bot convs —
    /// group / self / user_user convs have no bot to configure.
    @ViewBuilder
    private var botSettingsSection: some View {
        if let bot {
            Section {
                NavigationLink {
                    BotConfigView(bot: bot, currentUserId: currentUserId)
                } label: {
                    HStack {
                        Image(systemName: "gearshape")
                        Text("机器人设置")
                    }
                }
                .foregroundStyle(Theme.Palette.ink)
            } footer: {
                Text("机器人本身的默认配置。这里的「会话设置」只覆盖当前这一个对话。")
            }
        }
    }

    // MARK: - Envelope (来信) section

    @ViewBuilder
    private var envelopeSection: some View {
        if let recipient {
            humanLetterSection(recipient: recipient)
        } else if bot != nil {
            botLetterSection
        }
        // self / group / no-bot conv with no peer → hide section.
    }

    /// User-to-user conversation: a single entry that opens the markdown
    /// compose sheet. The recipient sees the resulting letter on their
    /// own 来信 tab. Server enforces mutual-friend gating; the entry is
    /// always visible inside the conversation settings — friendship is
    /// already implied by being able to message each other.
    @ViewBuilder
    private func humanLetterSection(recipient: LetterRecipient) -> some View {
        Section {
            Button {
                letterTarget = recipient
            } label: {
                HStack {
                    Image(systemName: "square.and.pencil")
                    Text("给对方写信")
                    Spacer()
                    if sendingLetter { ProgressView() }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(Theme.Palette.ink)
            .disabled(sendingLetter || conversationId.isEmpty)
        } header: {
            Text("来信 / Envelopes")
        } footer: {
            Text("写一封 markdown 信给「\(recipient.displayName)」，发出后对方会在自己的「来信」选项卡里看到。")
        }
    }

    /// User-to-bot conversation: kick off the bot's envelope (research
    /// loop + writer phase). The trigger uses the current `envelope`
    /// settings; the detailed knobs live behind the 写信设置 sub-page.
    @ViewBuilder
    private var botLetterSection: some View {
        Section {
            Button {
                Task { await triggerEnvelope() }
            } label: {
                HStack {
                    Image(systemName: "envelope.open")
                    Text(triggering ? "正在派出来信…" : "请这位机器人写信给你")
                    Spacer()
                    if triggering { ProgressView() }
                }
            }
            .foregroundStyle(Theme.Palette.ink)
            .disabled(triggering || conversationId.isEmpty || !envelopeLoaded)

            // Detailed envelope knobs (explorer / collaborator model,
            // search + scrape engine, turn cap, history budget). Editing
            // these only overrides the current conversation — the trigger
            // handler persists them as this conv's new defaults.
            NavigationLink {
                LetterSettingsView(envelope: $envelope)
            } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                    Text("写信设置")
                }
            }
            .foregroundStyle(Theme.Palette.ink)
        } header: {
            Text("来信 / Envelopes")
        } footer: {
            Text("你可以在「来信」选项卡看到它写的信。")
        }
    }

    /// Shared helper for the user_user compose sheet — calls the edge
    /// endpoint, surfaces errors via the existing alert binding, and
    /// dismisses the conversation settings on success so the user lands
    /// back on the chat (the recipient's 来信 tab is where the letter
    /// will appear, not this user's).
    private func sendHumanLetter(title: String?, bodyMd: String) async -> Bool {
        guard let api, let recipient, !conversationId.isEmpty else { return false }
        sendingLetter = true
        defer { sendingLetter = false }
        do {
            _ = try await api.scrollSendLetter(
                conversationId: conversationId,
                recipientUserId: recipient.userId,
                title: title,
                bodyMd: bodyMd
            )
            Haptics.success()
            return true
        } catch is CancellationError {
            return false
        } catch let error as NSError where error.domain == NSURLErrorDomain
            && error.code == NSURLErrorCancelled {
            return false
        } catch {
            triggerError = error.localizedDescription
            return false
        }
    }

    /// Pull the conversation row's saved vision_model_override (0064)
    /// straight through Supabase RLS. nil = auto. Read-only here; saves
    /// flow through the API patch in onApplyVisionModel.
    private func loadVisionSettings() async {
        guard !conversationId.isEmpty else {
            visionLoaded = true
            return
        }
        struct Row: Decodable { let vision_model_override: String? }
        do {
            let row: Row = try await SupabaseStack.shared
                .from("conversations")
                .select("vision_model_override")
                .eq("id", value: conversationId)
                .single()
                .execute()
                .value
            visionModelOverride = row.vision_model_override
        } catch {
            // No row yet, no access, or column missing on an unmigrated
            // server — fall through to "auto" so the UI still works.
        }
        visionLoaded = true
    }

    /// Pull the conversation row's saved voice_model_override. nil =
    /// follow the bot's default voice model. Read-only here; saves flow
    /// through onApplyVoiceModel → PATCH.
    private func loadVoiceSettings() async {
        guard !conversationId.isEmpty else { return }
        struct Row: Decodable { let voice_model_override: String? }
        do {
            let row: Row = try await SupabaseStack.shared
                .from("conversations")
                .select("voice_model_override")
                .eq("id", value: conversationId)
                .single()
                .execute()
                .value
            voiceModelOverride = row.voice_model_override
        } catch {
            // No row, no access, or unmigrated server — fall through to
            // "跟随机器人设置".
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

// MARK: - 写信设置 / Letter settings

/// 写信设置 — 来信（Envelopes）的探索/协作模型、检索引擎、轮数与历史预算。
/// 由「会话设置」（会话级覆盖）与「机器人设置」（机器人默认）两处推入,
/// 编辑同一个 `EnvelopeSettings` binding;持久化由各自的父视图负责
/// （会话级随 trigger 上送,机器人级随 BotConfigView 的保存写入 config）。
struct LetterSettingsView: View {
    @Binding var envelope: EnvelopeSettings
    /// 只读模式 — 公有 / 非自有机器人。会话级覆盖永远可改,默认 true。
    var canEdit: Bool = true

    private enum PickerTarget: Identifiable {
        case explorer, collaborator
        var id: Int { self == .explorer ? 0 : 1 }
    }
    @State private var pickerTarget: PickerTarget?

    var body: some View {
        Form {
            Section {
                pickerRow(icon: "person.crop.square", title: "探索模型",
                          value: shortSlug(envelope.explorerModel)) {
                    pickerTarget = .explorer
                }
                pickerRow(icon: "person.2.crop.square.stack", title: "协作模型",
                          value: envelope.collaboratorModel.map(shortSlug) ?? "无") {
                    pickerTarget = .collaborator
                }
            } header: {
                Text("模型")
            } footer: {
                Text("探索模型驱动来信的研究循环；协作模型在每个非研究轮做点评，可留空。")
            }

            Section {
                Picker(selection: $envelope.searchProvider) {
                    ForEach(EnvelopeSearchProvider.allCases, id: \.self) { p in
                        Text(p.label).tag(p)
                    }
                } label: {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text("搜索引擎")
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
                        Text("用什么读网页")
                    }
                }
                .foregroundStyle(Theme.Palette.ink)
            } header: {
                Text("检索")
            }

            Section {
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

                // History budget — caps (history + framing prompts) at this
                // fraction of the bot's main-model context window, leaving
                // the rest for the loop's research turns.
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "tray.full")
                        Text("聊天记录占用")
                        Spacer()
                        Text("\(envelope.historyTokenBudgetPct)%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { Double(envelope.historyTokenBudgetPct) },
                            set: { envelope.historyTokenBudgetPct = Int($0.rounded()) }
                        ),
                        in: 5...90, step: 5
                    )
                    .tint(Theme.Palette.accent)
                }
                .foregroundStyle(Theme.Palette.ink)
            } header: {
                Text("预算")
            } footer: {
                Text("「聊天记录占用」限制聊天历史与框架提示词占主模型上下文窗口的比例，余下留给研究轮。")
            }
        }
        .navigationTitle("写信设置")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(!canEdit)
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
                        // the picker somehow hands us nil.
                        envelope.explorerModel = picked?.slug ?? EnvelopeSettings.defaults.explorerModel
                    case .collaborator:
                        envelope.collaboratorModel = (picked?.slug).flatMap { $0.isEmpty ? nil : $0 }
                    }
                    pickerTarget = nil
                }
            )
            .presentationDragIndicator(.visible)
            .tint(Theme.Palette.accent)
        }
        .tint(Theme.Palette.accent)
    }

    @ViewBuilder
    private func pickerRow(icon: String, title: String, value: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                Text(title)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(Theme.Palette.ink)
    }

    private func shortSlug(_ slug: String) -> String {
        guard !slug.isEmpty else { return "—" }
        return slug.split(separator: "/").last.map(String.init) ?? slug
    }
}
