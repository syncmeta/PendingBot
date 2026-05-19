import SwiftUI
import Supabase

// User-facing bot CRUD lives behind RLS — INSERT / UPDATE / DELETE all
// gate on creator_id = auth.uid() so the iOS client can talk to PostgREST
// directly. The visibility lifecycle (private → public is one-way; public
// columns immutable except visibility) is enforced by the bots_guard_public_update
// trigger, so the client just shows / hides the right buttons.

// MARK: - Create

struct CreateBotSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Called with the freshly-inserted bot so the parent can prepend it
    /// to its own list without a re-fetch.
    var onCreated: (FriendsTabView.BotPick) -> Void

    @State private var displayName: String = ""
    @State private var modelSlug: String = ""
    /// API route pin for the picked model — nil = default routing,
    /// 'openai' = native Responses route.
    @State private var modelProvider: String?
    @State private var visibility: Visibility = .privateBot
    @State private var creating = false
    @State private var error: String?

    enum Visibility: String, CaseIterable, Identifiable {
        case privateBot     = "private"
        case publicInvite   = "public_invite"
        case publicOpen     = "public_open"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .privateBot:   return "私有"
            case .publicInvite: return "公有 · 邀请制"
            case .publicOpen:   return "公有 · 公开可加"
            }
        }
        var subtitle: String {
            switch self {
            case .privateBot:
                return "只有你自己能聊。可以随时改名/改型号/删。"
            case .publicInvite:
                return "你邀请的人才能聊。建好之后只能切换公开程度,不能改名/改型号/删。"
            case .publicOpen:
                return "任何人都能加好友聊。建好之后只能切换公开程度,不能改名/改型号/删。"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("机器人名字", text: $displayName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    HStack {
                        Text("模型").foregroundStyle(Theme.Palette.inkMuted)
                        Spacer()
                        ModelPickerButton(slug: $modelSlug,
                                          modelProvider: $modelProvider,
                                          placeholder: "选择模型")
                    }
                }

                Section {
                    ForEach(Visibility.allCases) { v in
                        Button { visibility = v; Haptics.tap() } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: visibility == v
                                      ? "largecircle.fill.circle"
                                      : "circle")
                                    .foregroundStyle(visibility == v
                                                     ? Theme.Palette.accent
                                                     : Theme.Palette.inkMuted)
                                    .font(.system(size: 18, weight: .medium))
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(v.label)
                                        .font(Theme.Fonts.rounded(size: 14, weight: .semibold))
                                        .foregroundStyle(Theme.Palette.ink)
                                    Text(v.subtitle)
                                        .font(Theme.Fonts.caption)
                                        .foregroundStyle(Theme.Palette.inkMuted)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("公开程度")
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("新建机器人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(creating ? "创建中…" : "创建") {
                        Task { await create() }
                    }
                    .disabled(creating || !canCreate)
                }
            }
        }
    }

    private var canCreate: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty
        && !modelSlug.isEmpty
    }

    private func create() async {
        guard let userId = AccountStore.shared.current?.id else { return }
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !modelSlug.isEmpty else { return }
        creating = true; defer { creating = false }
        do {
            // bots.slug is NOT NULL UNIQUE, but it's only meaningful for the
            // 8 system presets ("lorem"/"ipsum"/...). For user-created bots
            // we mint a synthetic slug from a fresh UUID so the unique
            // constraint stays satisfied without leaking creator info.
            struct BotInsert: Encodable {
                let creator_id: String
                let visibility: String
                let display_name: String
                let model_id: String
                let model_provider: String?
                let slug: String
            }
            struct BotOut: Decodable {
                let id: String
                let display_name: String
                let model_id: String?
                let visibility: String?
                let creator_id: String?
            }
            let slug = "u_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
            let row: BotOut = try await SupabaseStack.shared
                .from("bots")
                .insert(BotInsert(
                    creator_id: userId,
                    visibility: visibility.rawValue,
                    display_name: trimmedName,
                    model_id: modelSlug,
                    model_provider: modelProvider,
                    slug: String(slug)
                ))
                .select("id, display_name, model_id, visibility, creator_id")
                .single()
                .execute()
                .value

            let pick = FriendsTabView.BotPick(
                id: row.id,
                display_name: row.display_name,
                model_id: row.model_id,
                visibility: row.visibility,
                creator_id: row.creator_id,
                voice_call_enabled: false
            )
            onCreated(pick)
            Haptics.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }
}

// MARK: - Manage

/// Shown by long-pressing a bot row that the current user created.
/// Surface depends on visibility:
///   - private:       rename + change model + delete + promote-to-public
///   - public_invite: visibility toggle + invite list
///   - public_open:   visibility toggle only
struct ManageBotSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Called after a mutation so the parent can refresh its list.
    var onChanged: () -> Void
    var onDeleted: (String) -> Void

    let initial: FriendsTabView.BotPick

    @State private var displayName: String = ""
    @State private var modelSlug: String = ""
    /// API route pin — nil = default, 'openai' = native Responses route.
    /// Loaded from the bots row on appear (BotPick doesn't carry it).
    @State private var modelProvider: String?
    @State private var initialModelProvider: String?
    @State private var visibility: String = "private"
    @State private var voiceCallEnabled: Bool = false
    @State private var saving = false
    @State private var deleting = false
    @State private var confirmingDelete = false
    @State private var confirmingPromote = false
    @State private var error: String?

    private var isPrivate: Bool { visibility == "private" }
    private var isPublic: Bool  { visibility == "public_invite" || visibility == "public_open" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isPrivate {
                        TextField("机器人名字", text: $displayName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                        HStack {
                            Text("模型").foregroundStyle(Theme.Palette.inkMuted)
                            Spacer()
                            ModelPickerButton(slug: $modelSlug,
                                              modelProvider: $modelProvider,
                                              placeholder: "选择模型")
                        }
                    } else {
                        // Public: identity is frozen. Show, don't edit.
                        LabeledContent("机器人名字", value: displayName)
                        LabeledContent("模型", value: modelSlug.isEmpty ? "—" : modelSlug)
                    }
                } header: {
                    Text(isPrivate ? "可编辑" : "已锁定")
                } footer: {
                    if !isPrivate {
                        Text("公有机器人创建后,改名/改型号都被锁定。只能切换下面的公开程度。")
                            .font(Theme.Fonts.caption)
                    }
                }

                if isPrivate {
                    Section {
                        Toggle("语音通话", isOn: $voiceCallEnabled)
                    } footer: {
                        Text("打开后,聊天页顶部会出现电话按钮,可以和这个机器人语音通话。计费走实时音频用量。")
                            .font(Theme.Fonts.caption)
                    }
                }

                Section {
                    Picker("公开程度", selection: $visibility) {
                        if isPrivate {
                            Text("私有").tag("private")
                        }
                        Text("公有 · 邀请制").tag("public_invite")
                        Text("公有 · 公开可加").tag("public_open")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("公开程度")
                } footer: {
                    if isPrivate {
                        Text("升级为公有后不能再改回私有,也无法再改名/改型号/删除。请确认。")
                            .font(Theme.Fonts.caption)
                    }
                }

                if visibility == "public_invite" {
                    Section {
                        NavigationLink("管理被邀请人") {
                            InviteListEditor(botId: initial.id)
                        }
                    }
                }

                if isPrivate {
                    Section {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            HStack {
                                Spacer()
                                Text(deleting ? "删除中…" : "删除机器人")
                                Spacer()
                            }
                        }
                        .disabled(deleting)
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(initial.display_name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") {
                        Task { await save() }
                    }
                    .disabled(saving || !dirty)
                }
            }
            .confirmationDialog(
                "确定要删除这个机器人吗?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible,
                actions: {
                    Button("删除", role: .destructive) {
                        Task { await delete() }
                    }
                    Button("取消", role: .cancel) {}
                },
                message: {
                    Text("聊天记录会保留,但不能再继续聊。")
                }
            )
            .confirmationDialog(
                "升级为公有机器人?",
                isPresented: $confirmingPromote,
                titleVisibility: .visible,
                actions: {
                    Button("升级", role: .destructive) {
                        Task { await persistUpdate() }
                    }
                    Button("取消", role: .cancel) {}
                },
                message: {
                    Text("升级后只能切换公开程度,不能再改名/改型号/删除,也不能转回私有。")
                }
            )
        }
        .onAppear {
            displayName = initial.display_name
            modelSlug = initial.model_id ?? ""
            visibility = initial.visibility ?? "public_open"
            voiceCallEnabled = initial.voice_call_enabled ?? false
        }
        .task { await loadModelProvider() }
    }

    /// model_provider isn't on BotPick — pull it from the bots row so the
    /// picker pre-selects the right route and the dirty check is accurate.
    private func loadModelProvider() async {
        struct Row: Decodable { let model_provider: String? }
        if let row: Row = try? await SupabaseStack.shared
            .from("bots")
            .select("model_provider")
            .eq("id", value: initial.id)
            .single()
            .execute()
            .value {
            modelProvider = row.model_provider
            initialModelProvider = row.model_provider
        }
    }

    /// True when there's actually something to save vs the row we loaded.
    private var dirty: Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        if isPrivate {
            if trimmed != initial.display_name { return true }
            if modelSlug != (initial.model_id ?? "") { return true }
            if modelProvider != initialModelProvider { return true }
            if voiceCallEnabled != (initial.voice_call_enabled ?? false) { return true }
        }
        if visibility != (initial.visibility ?? "public_open") { return true }
        return false
    }

    private func save() async {
        let prevVisibility = initial.visibility ?? "public_open"
        let promoting = prevVisibility == "private" && visibility != "private"
        if promoting {
            // Promotion is one-way; gate on a confirmation dialog. The
            // dialog's primary button calls persistUpdate() directly.
            confirmingPromote = true
            return
        }
        await persistUpdate()
    }

    private func persistUpdate() async {
        saving = true; defer { saving = false }
        do {
            // model_provider must round-trip an explicit JSON null when a
            // bot is switched off the native route — Swift's synthesized
            // Encodable omits nil optionals, so a custom encode force-emits
            // it (gated by writeModelProvider so the public-flip branch can
            // still leave it out).
            struct Update: Encodable {
                let display_name: String?
                let model_id: String?
                let model_provider: String?
                let visibility: String?
                let voice_call_enabled: Bool?
                let writeModelProvider: Bool
                enum CodingKeys: String, CodingKey {
                    case display_name, model_id, model_provider
                    case visibility, voice_call_enabled
                }
                func encode(to encoder: Encoder) throws {
                    var c = encoder.container(keyedBy: CodingKeys.self)
                    try c.encodeIfPresent(display_name, forKey: .display_name)
                    try c.encodeIfPresent(model_id, forKey: .model_id)
                    if writeModelProvider {
                        try c.encode(model_provider, forKey: .model_provider)
                    }
                    try c.encodeIfPresent(visibility, forKey: .visibility)
                    try c.encodeIfPresent(voice_call_enabled, forKey: .voice_call_enabled)
                }
            }
            // For public bots the trigger blocks anything except visibility,
            // so we only send the changed columns.
            let payload: Update
            if visibility == "private" {
                // Private edit (no promotion) → keep updating identity columns.
                payload = Update(
                    display_name: displayName.trimmingCharacters(in: .whitespaces),
                    model_id: modelSlug,
                    model_provider: modelProvider,
                    visibility: visibility,
                    voice_call_enabled: voiceCallEnabled,
                    writeModelProvider: true
                )
            } else if isPrivate {
                // Promotion: snapshot identity + flip visibility in one UPDATE.
                // voice_call_enabled is private-only (edge route gates on it),
                // so freeze it to its pre-promotion value here.
                payload = Update(
                    display_name: displayName.trimmingCharacters(in: .whitespaces),
                    model_id: modelSlug,
                    model_provider: modelProvider,
                    visibility: visibility,
                    voice_call_enabled: voiceCallEnabled,
                    writeModelProvider: true
                )
            } else {
                // Public → public visibility flip; identity is frozen.
                payload = Update(
                    display_name: nil,
                    model_id: nil,
                    model_provider: nil,
                    visibility: visibility,
                    voice_call_enabled: nil,
                    writeModelProvider: false
                )
            }
            try await SupabaseStack.shared
                .from("bots")
                .update(payload)
                .eq("id", value: initial.id)
                .execute()
            onChanged()
            Haptics.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }

    private func delete() async {
        deleting = true; defer { deleting = false }
        do {
            try await SupabaseStack.shared
                .from("bots")
                .delete()
                .eq("id", value: initial.id)
                .execute()
            onDeleted(initial.id)
            Haptics.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }
}

// MARK: - Invitee editor

struct InviteListEditor: View {
    let botId: String

    @State private var invites: [InviteRow] = []
    @State private var loading = false
    @State private var addingHandle: String = ""
    @State private var adding = false
    @State private var pickingContact = false
    @State private var error: String?

    struct InviteRow: Identifiable, Hashable {
        let user_id: String
        let display_name: String
        let invited_at: String?
        var id: String { user_id }
        var label: String {
            display_name.isEmpty ? String(user_id.prefix(8)) : display_name
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("对方的号码", text: $addingHandle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Button(adding ? "加…" : "邀请") {
                        Task { await addInviteByHandle() }
                    }
                    .disabled(adding || addingHandle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button {
                    pickingContact = true
                    Haptics.tap()
                } label: {
                    Label("从联系人选", systemImage: "person.crop.circle.badge.plus")
                }
            } footer: {
                Text("可以贴对方个人页里的号码,或者直接从你的联系人里选。")
                    .font(Theme.Fonts.caption)
            }

            Section {
                if loading && invites.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if invites.isEmpty {
                    Text("还没邀请任何人").foregroundStyle(Theme.Palette.inkMuted)
                } else {
                    ForEach(invites) { row in
                        HStack {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(Theme.Palette.accent.opacity(0.7))
                            Text(row.label)
                                .font(Theme.Fonts.rounded(size: 14, weight: .medium))
                                .foregroundStyle(Theme.Palette.ink)
                            Spacer()
                            Button(role: .destructive) {
                                Task { await remove(row) }
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(Theme.Palette.inkMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } header: {
                Text("已邀请")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("被邀请人")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $pickingContact) {
            InviteContactPickerSheet(
                botId: botId,
                alreadyInvited: Set(invites.map(\.user_id)),
                onPicked: { Task { await load() } }
            )
            .presentationDragIndicator(.visible)
        }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            struct Args: Encodable { let p_bot_id: String }
            struct Decoded: Decodable {
                let user_id: String
                let display_name: String
                let invited_at: String?
            }
            // Goes through list_bot_invitees RPC (SECURITY DEFINER) so the
            // caller, as the bot's creator, can see invitees' display_name
            // without us widening users RLS.
            let rows: [Decoded] = try await SupabaseStack.shared
                .rpc("list_bot_invitees", params: Args(p_bot_id: botId))
                .execute()
                .value
            invites = rows.map {
                InviteRow(user_id: $0.user_id, display_name: $0.display_name, invited_at: $0.invited_at)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func addInviteByHandle() async {
        let handle = addingHandle.trimmingCharacters(in: .whitespaces)
        guard !handle.isEmpty else { return }
        adding = true; defer { adding = false }
        do {
            struct Args: Encodable {
                let p_bot_id: String
                let p_handle: String
            }
            let _: UUID = try await SupabaseStack.shared
                .rpc("bot_invites_add", params: Args(p_bot_id: botId, p_handle: handle))
                .execute()
                .value
            addingHandle = ""
            error = nil
            Haptics.success()
            await load()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }

    private func remove(_ row: InviteRow) async {
        do {
            try await SupabaseStack.shared
                .from("bot_invites")
                .delete()
                .eq("bot_id", value: botId)
                .eq("user_id", value: row.user_id)
                .execute()
            invites.removeAll { $0.user_id == row.user_id }
            Haptics.tap()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }
}

// MARK: - Contact picker (forward existing contacts to a public_invite bot)

/// Sheet listing the user's existing contacts. Tapping one inserts a
/// bot_invites row for that contact (no handle resolution needed — we
/// already have their user_id). Already-invited contacts render disabled.
struct InviteContactPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let botId: String
    let alreadyInvited: Set<String>
    var onPicked: () -> Void

    @State private var contacts: [Row] = []
    @State private var loading = false
    @State private var inviting = false
    @State private var error: String?
    @State private var query: String = ""

    struct Row: Identifiable, Hashable {
        let user_id: String
        let alias: String?
        var id: String { user_id }
        var displayLabel: String {
            (alias?.isEmpty == false ? alias! : String(user_id.prefix(8)))
        }
    }

    private var filtered: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return contacts }
        return contacts.filter {
            $0.displayLabel.lowercased().contains(q)
            || $0.user_id.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading && contacts.isEmpty {
                    ProgressView()
                } else if contacts.isEmpty {
                    Text("还没有联系人")
                        .foregroundStyle(Theme.Palette.inkMuted)
                } else {
                    List {
                        Section {
                            ForEach(filtered) { row in
                                Button {
                                    Task { await invite(row) }
                                } label: {
                                    HStack {
                                        Image(systemName: "person.crop.circle.fill")
                                            .foregroundStyle(Theme.Palette.accent.opacity(0.85))
                                        Text(row.displayLabel)
                                            .foregroundStyle(Theme.Palette.ink)
                                        Spacer()
                                        if alreadyInvited.contains(row.user_id) {
                                            Text("已邀请")
                                                .font(Theme.Fonts.caption)
                                                .foregroundStyle(Theme.Palette.inkMuted)
                                        } else {
                                            Image(systemName: "plus.circle")
                                                .foregroundStyle(Theme.Palette.accent)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(alreadyInvited.contains(row.user_id) || inviting)
                            }
                        } header: {
                            if !contacts.isEmpty {
                                Text("联系人")
                            }
                        }
                        if let error {
                            Section { Text(error).foregroundStyle(.red) }
                        }
                    }
                    .searchable(text: $query, prompt: "搜索联系人")
                }
            }
            .navigationTitle("从联系人选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            struct Decoded: Decodable {
                let contact_user_id: String
                let alias: String?
            }
            let rows: [Decoded] = try await SupabaseStack.shared
                .from("user_contacts")
                .select("contact_user_id, alias")
                .order("created_at", ascending: true)
                .execute()
                .value
            contacts = rows.map { Row(user_id: $0.contact_user_id, alias: $0.alias) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func invite(_ row: Row) async {
        guard !alreadyInvited.contains(row.user_id) else { return }
        inviting = true; defer { inviting = false }
        do {
            struct InviteInsert: Encodable {
                let bot_id: String
                let user_id: String
            }
            // Direct INSERT — RLS allows the bot's creator to write
            // bot_invites rows. ON CONFLICT DO NOTHING is implicit
            // because the PK is (bot_id, user_id) and we filter
            // already-invited above; if it raced, postgres just errors.
            try await SupabaseStack.shared
                .from("bot_invites")
                .insert(InviteInsert(bot_id: botId, user_id: row.user_id))
                .execute()
            Haptics.success()
            onPicked()
            dismiss()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }
}

// MARK: - Bot config

/// Bot-level configuration page — pushed from the pre-chat 设置 button.
/// Houses everything that belongs to *the bot* rather than a single
/// conversation: default model, voice-call gate + voice model, vision
/// model, the 来信 (envelope) defaults, the lookback cadence, and a link
/// into 技能. Persisted into `bots.config` jsonb (+ the `model_id` /
/// `voice_call_enabled` columns) via PATCH /v1/bots/:id so the worker
/// merges and drops the bot KV cache in one trip.
///
/// Read-only for bots the caller didn't create, or any public bot
/// (the worker enforces the same gate). The settings still render so the
/// user can *see* how the bot is set up.
struct BotConfigView: View {
    let bot: Bot
    let currentUserId: String?

    @Environment(\.dismiss) private var dismiss

    @State private var model: String = ""
    /// API route pin for the main model — nil = default routing,
    /// 'openai' = the native Responses route. Set by the model picker.
    @State private var modelProvider: String?
    @State private var voiceEnabled: Bool = false
    @State private var voiceModel: String = ""    // "" = auto
    @State private var visionModel: String = ""   // "" = auto
    @State private var envelope: EnvelopeSettings = .defaults
    @State private var lookbackEnabled: Bool = true
    @State private var lookbackInterval: Int = 10

    @State private var initial: Snapshot?
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?
    @State private var pickerTarget: PickerTarget?

    /// Editable knobs snapshot — drives the dirty check so 保存 only
    /// lights up once the form actually diverges from what we loaded.
    private struct Snapshot: Equatable {
        let model: String
        let modelProvider: String?
        let voiceEnabled: Bool
        let voiceModel: String
        let visionModel: String
        let envelope: EnvelopeSettings
        let lookbackEnabled: Bool
        let lookbackInterval: Int
    }

    private enum PickerTarget: Identifiable {
        case main, vision, voice, explorer, collaborator
        var id: Int {
            switch self {
            case .main: return 0
            case .vision: return 1
            case .voice: return 2
            case .explorer: return 3
            case .collaborator: return 4
            }
        }
    }

    /// Only the creator of a *private* bot may edit. Public bots are
    /// frozen — the worker rejects the PATCH anyway. Preset private bots
    /// are per-user clones, so their creator is the user — editable.
    private var canEdit: Bool {
        guard let me = currentUserId, let owner = bot.creator_id else { return false }
        return bot.visibility == "private" && owner == me
    }

    private var snapshot: Snapshot {
        Snapshot(
            model: model, modelProvider: modelProvider,
            voiceEnabled: voiceEnabled, voiceModel: voiceModel,
            visionModel: visionModel, envelope: envelope,
            lookbackEnabled: lookbackEnabled, lookbackInterval: lookbackInterval
        )
    }

    private var dirty: Bool {
        guard let initial else { return false }
        return snapshot != initial
    }

    var body: some View {
        Form {
            if !canEdit {
                Section {
                    Text("这是「\(bot.display_name)」的配置。只有创建者能修改自己的私有机器人；公有机器人不可改。")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            }

            modelSection
            voiceSection
            visionSection
            envelopeSection
            lookbackSection

            Section("技能") {
                NavigationLink {
                    SkillsView()
                } label: {
                    HStack {
                        Image(systemName: "puzzlepiece.extension")
                        Text("管理技能")
                    }
                }
                .foregroundStyle(Theme.Palette.ink)
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .disabled(!loaded)
        .navigationTitle("机器人设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") {
                        Task { await save() }
                    }
                    .disabled(saving || !dirty || !loaded)
                }
            }
        }
        .sheet(item: $pickerTarget) { target in
            modelPicker(for: target)
                .presentationDragIndicator(.visible)
                .tint(Theme.Palette.accent)
        }
        .tint(Theme.Palette.accent)
    }

    // ── Sections ────────────────────────────────────────────────────────────

    @ViewBuilder
    private var modelSection: some View {
        Section {
            pickerRow(icon: "cube.transparent", title: "默认模型",
                      value: shortSlug(model), enabled: canEdit) {
                pickerTarget = .main
            }
        } header: {
            Text("模型")
        } footer: {
            Text("这个机器人聊天时用的主模型。每个对话可以再单独覆盖。")
        }
    }

    @ViewBuilder
    private var voiceSection: some View {
        Section {
            Toggle("语音通话", isOn: $voiceEnabled)
                .disabled(!canEdit)
            if voiceEnabled {
                pickerRow(icon: "waveform", title: "语音模型",
                          value: voiceModel.isEmpty ? "自动" : shortSlug(voiceModel),
                          enabled: canEdit) {
                    pickerTarget = .voice
                }
            }
        } header: {
            Text("语音")
        } footer: {
            Text("打开后，聊天页顶部会出现电话按钮。「语音模型」留空时用系统默认的实时语音模型。")
        }
    }

    @ViewBuilder
    private var visionSection: some View {
        Section {
            pickerRow(icon: "eye", title: "识图模型",
                      value: visionModel.isEmpty ? "自动" : shortSlug(visionModel),
                      enabled: canEdit) {
                pickerTarget = .vision
            }
        } header: {
            Text("视觉")
        } footer: {
            Text("看图、给图片写摘要、回答关于图片的问题时用这个模型。「自动」时：主模型若支持识图就直接用，否则回落到服务端默认。")
        }
    }

    @ViewBuilder
    private var envelopeSection: some View {
        Section {
            pickerRow(icon: "person.crop.square", title: "探索模型",
                      value: shortSlug(envelope.explorerModel), enabled: canEdit) {
                pickerTarget = .explorer
            }
            pickerRow(icon: "person.2.crop.square.stack", title: "协作模型",
                      value: envelope.collaboratorModel.map(shortSlug) ?? "无",
                      enabled: canEdit) {
                pickerTarget = .collaborator
            }
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
            .disabled(!canEdit)
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
                .disabled(!canEdit)
            }
            .foregroundStyle(Theme.Palette.ink)
        } header: {
            Text("写信 / Envelopes")
        } footer: {
            Text("这个机器人写信（来信）时的默认设置。在具体对话里可以临时覆盖。")
        }
    }

    @ViewBuilder
    private var lookbackSection: some View {
        Section {
            Toggle("自动回看", isOn: $lookbackEnabled)
                .disabled(!canEdit)
            if lookbackEnabled {
                Stepper(value: $lookbackInterval, in: 1...100) {
                    HStack {
                        Image(systemName: "arrow.uturn.backward")
                        Text("回看间隔")
                        Spacer()
                        Text("每 \(lookbackInterval) 轮")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .disabled(!canEdit)
            }
        } header: {
            Text("回看 / Lookback")
        } footer: {
            Text("打开后，机器人每隔若干轮会自我复盘一次，检查你或它说过的内容是否需要更正、补充。")
        }
    }

    // ── Reusable picker row ─────────────────────────────────────────────────

    @ViewBuilder
    private func pickerRow(icon: String, title: String, value: String,
                           enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                Text(title)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if enabled {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .foregroundStyle(Theme.Palette.ink)
        .disabled(!enabled)
    }

    @ViewBuilder
    private func modelPicker(for target: PickerTarget) -> some View {
        switch target {
        case .main:
            ModelPickerSheet(initial: model, allowsClear: false) { picked in
                if let picked, !picked.slug.isEmpty {
                    model = picked.slug
                    modelProvider = picked.model_provider
                }
                pickerTarget = nil
            }
        case .vision:
            ModelPickerSheet(initial: visionModel, allowsClear: true,
                             clearLabel: "自动（跟随主模型 / 服务端默认）",
                             visionOnly: true) { picked in
                visionModel = (picked?.slug).flatMap { $0.isEmpty ? nil : $0 } ?? ""
                pickerTarget = nil
            }
        case .voice:
            ModelPickerSheet(initial: voiceModel, allowsClear: true,
                             clearLabel: "自动（系统默认语音模型）") { picked in
                voiceModel = (picked?.slug).flatMap { $0.isEmpty ? nil : $0 } ?? ""
                pickerTarget = nil
            }
        case .explorer:
            ModelPickerSheet(initial: envelope.explorerModel, allowsClear: false) { picked in
                if let picked, !picked.slug.isEmpty { envelope.explorerModel = picked.slug }
                pickerTarget = nil
            }
        case .collaborator:
            ModelPickerSheet(initial: envelope.collaboratorModel ?? "",
                             allowsClear: true, clearLabel: "无协作者") { picked in
                envelope.collaboratorModel = (picked?.slug).flatMap { $0.isEmpty ? nil : $0 }
                pickerTarget = nil
            }
        }
    }

    private func shortSlug(_ slug: String) -> String {
        guard !slug.isEmpty else { return "—" }
        return slug.split(separator: "/").last.map(String.init) ?? slug
    }

    // ── Load / save ─────────────────────────────────────────────────────────

    private func load() async {
        struct Row: Decodable {
            let model_id: String?
            let model_provider: String?
            let voice_call_enabled: Bool?
            let config: AnyJSON?
        }
        do {
            let row: Row = try await SupabaseStack.shared
                .from("bots")
                .select("model_id, model_provider, voice_call_enabled, config")
                .eq("id", value: bot.id)
                .single()
                .execute()
                .value
            model = row.model_id ?? bot.model ?? ""
            modelProvider = row.model_provider
            voiceEnabled = row.voice_call_enabled ?? bot.voice_call_enabled ?? false
            applyConfig(row.config)
        } catch {
            // Fall back to whatever the Bot row already carried so the
            // page still renders something usable.
            model = bot.model ?? ""
            voiceEnabled = bot.voice_call_enabled ?? false
        }
        initial = snapshot
        loaded = true
    }

    /// Parse the `bots.config` jsonb blob into the editable fields. Every
    /// key is optional — a bot that's never been configured decodes to
    /// the same defaults the worker resolvers use.
    private func applyConfig(_ json: AnyJSON?) {
        guard let json, case let .object(dict) = json else { return }
        if case let .string(s)? = dict["voiceModel"], !s.isEmpty { voiceModel = s }
        if case let .string(s)? = dict["visionModel"], !s.isEmpty { visionModel = s }
        envelope = EnvelopeSettings.from(dict["envelope"])
        if case let .object(lb)? = dict["lookback"] {
            if case let .bool(b)? = lb["enabled"] { lookbackEnabled = b }
            if case let .integer(i)? = lb["roundInterval"], i > 0 {
                lookbackInterval = i
            } else if case let .double(d)? = lb["roundInterval"], d > 0 {
                lookbackInterval = Int(d)
            }
        }
    }

    private func save() async {
        guard canEdit, dirty else { return }
        saving = true; defer { saving = false }
        error = nil
        do {
            // Raw PATCH so cleared model picks can send an explicit JSON
            // `null` (NSNull) — the worker schema treats null as "clear",
            // an absent key as "leave untouched".
            let collabVal: Any = envelope.collaboratorModel ?? NSNull()
            let visionVal: Any = visionModel.isEmpty ? NSNull() : visionModel
            let voiceVal: Any = voiceModel.isEmpty ? NSNull() : voiceModel
            let envelopeCfg: [String: Any] = [
                "explorerModel": envelope.explorerModel,
                "collaboratorModel": collabVal,
                "turnCap": envelope.turnCap,
                "historyTokenBudgetPct": envelope.historyTokenBudgetPct,
            ]
            let lookbackCfg: [String: Any] = [
                "enabled": lookbackEnabled,
                "roundInterval": lookbackInterval,
            ]
            let cfg: [String: Any] = [
                "lookback": lookbackCfg,
                "envelope": envelopeCfg,
                "visionModel": visionVal,
                "voiceModel": voiceVal,
            ]
            let body: [String: Any] = [
                "model_id": model,
                "model_provider": modelProvider ?? NSNull(),
                "voice_call_enabled": voiceEnabled,
                "config": cfg,
            ]
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/bots/")
                .appendingPathComponent(bot.id)
            var req = URLRequest(url: url)
            req.httpMethod = "PATCH"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if !(200..<300).contains(http.statusCode) {
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let errObj = payload?["error"] as? [String: Any]
                let msg = (errObj?["message"] as? String)
                    ?? (errObj?["code"] as? String)
                    ?? "HTTP \(http.statusCode)"
                self.error = msg
                Haptics.error()
                return
            }
            initial = snapshot
            Haptics.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }
}
