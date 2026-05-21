import SwiftUI
import Supabase
import CoreImage.CIFilterBuiltins
import UIKit

// User-facing bot CRUD lives behind RLS — INSERT / UPDATE / DELETE all
// gate on creator_id = auth.uid() so the iOS client can talk to PostgREST
// directly. The creator keeps full settings control even after a bot goes
// public; the only one-way rule (private → public, never back) and the
// public-bot delete block are enforced by the bots_guard_public_update
// trigger + the bots_creator_delete RLS policy.

// MARK: - Slug rule

/// Validation for a public bot's user-chosen slug — the stable, public
/// handle others type in 加机器人 and that powers the share link / QR
/// (see BotShareLink). Private bots never use this; they keep the
/// synthetic `u_<random>` slug minted at creation.
///
/// Reserved namespaces are refused so a user can't squat on the
/// machine-minted forms: `u_` (user-created private bots) and `self-`
/// (per-user self-bot, filtered out of the friends list).
enum BotSlugRule {
    static let minLen = 3
    static let maxLen = 20
    private static let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")

    /// Lowercase + drop surrounding whitespace and a leading/trailing @.
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
    }

    static func isValid(_ slug: String) -> Bool {
        guard slug.count >= minLen, slug.count <= maxLen else { return false }
        guard slug.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        if slug.hasPrefix("u_") || slug.hasPrefix("self-") { return false }
        return true
    }

    static let helpText = "3–20 位，小写字母、数字、下划线或连字符"
}

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
    /// User-chosen public handle. Only required (and only sent) when the
    /// bot is public — private bots keep the synthetic `u_<random>` slug.
    @State private var slug: String = ""
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
                return "只有你自己能聊。可以随时改设置、改名、删除。"
            case .publicInvite:
                return "你邀请的人才能聊。建好后你还能改设置和改名,但不能删、不能转回私有。"
            case .publicOpen:
                return "任何人都能加好友聊。建好后你还能改设置和改名,但不能删、不能转回私有。"
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

                // Public bots need a human-chosen slug — it's the handle
                // others type in 加机器人 and the payload of the share
                // link / QR. Private bots don't (can't be added by anyone
                // else), so the field only shows for public visibilities.
                if visibility != .privateBot {
                    Section {
                        HStack(spacing: 4) {
                            Text("@").foregroundStyle(Theme.Palette.inkMuted)
                            TextField("机器人标识(slug)", text: $slug)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .onChange(of: slug) { _, v in
                                    let n = BotSlugRule.normalize(v)
                                    if n != v { slug = n }
                                }
                        }
                    } header: {
                        Text("机器人标识")
                    } footer: {
                        Text("别人按这个标识、链接或二维码加你的机器人。\(BotSlugRule.helpText)。建好后可在管理里修改。")
                    }
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
            .task { await seedDefaultName() }
        }
    }

    /// "Lorem ipsum" tokens used to seed the default display name when
    /// 新建机器人 opens — the user can still edit. We pick the first token
    /// they haven't already used, so spamming + walks down the sequence
    /// Lorem → Ipsum → Dolor → …
    private static let loremTokens: [String] = [
        "Lorem", "Ipsum", "Dolor", "Sit", "Amet",
        "Consectetur", "Adipiscing", "Elit", "Sed", "Do",
        "Eiusmod", "Tempor", "Incididunt", "Ut", "Labore",
        "Et", "Dolore", "Magna", "Aliqua", "Enim",
        "Ad", "Minim", "Veniam", "Quis", "Nostrud",
        "Exercitation", "Ullamco", "Laboris", "Nisi", "Aliquip",
    ]

    private func seedDefaultName() async {
        guard displayName.isEmpty else { return }
        guard let userId = AccountStore.shared.current?.id else { return }
        struct Row: Decodable { let display_name: String }
        let rows: [Row] = (try? await SupabaseStack.shared
            .from("bots")
            .select("display_name")
            .eq("creator_id", value: userId)
            .execute()
            .value) ?? []
        let used = Set(rows.map { $0.display_name.lowercased() })
        let pick = Self.loremTokens.first { !used.contains($0.lowercased()) }
            ?? Self.loremTokens[0]
        guard displayName.isEmpty else { return }
        displayName = pick
    }

    private var canCreate: Bool {
        let nameOK = !displayName.trimmingCharacters(in: .whitespaces).isEmpty
        let modelOK = !modelSlug.isEmpty
        // Public bots additionally require a valid slug.
        if visibility == .privateBot { return nameOK && modelOK }
        return nameOK && modelOK && BotSlugRule.isValid(slug)
    }

    private func create() async {
        guard let userId = AccountStore.shared.current?.id else { return }
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !modelSlug.isEmpty else { return }
        creating = true; defer { creating = false }
        do {
            // bots.slug is NOT NULL UNIQUE. Public bots use the creator's
            // chosen handle (the thing others type / scan to add); private
            // bots mint a synthetic slug from a fresh UUID so the unique
            // constraint stays satisfied without leaking creator info and
            // without burning a nice handle no one can reach anyway.
            struct BotInsert: Encodable {
                let creator_id: String
                let visibility: String
                let display_name: String
                let model_id: String
                let model_provider: String?
                let slug: String
                /// IANA tz on the bot row. Public bots default to the
                /// creator's device tz at creation; private bots stay
                /// null (they always 1:1 with the creator and the
                /// per-turn clientTz already carries the tz).
                let tz: String?
            }
            struct BotOut: Decodable {
                let id: String
                let display_name: String
                let model_id: String?
                let visibility: String?
                let creator_id: String?
            }
            let finalSlug: String = visibility == .privateBot
                ? "u_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).description
                : BotSlugRule.normalize(slug)
            let row: BotOut = try await SupabaseStack.shared
                .from("bots")
                .insert(BotInsert(
                    creator_id: userId,
                    visibility: visibility.rawValue,
                    display_name: trimmedName,
                    model_id: modelSlug,
                    model_provider: modelProvider,
                    slug: finalSlug,
                    tz: visibility == .privateBot ? nil : TimeZone.current.identifier
                ))
                .select("id, display_name, model_id, visibility, creator_id")
                .single()
                .execute()
                .value

            // The friends-tab bot list reads from user_bot_contacts, not the
            // bots table — so without a contact row the freshly-created bot
            // vanishes on the next load(). The conversations→contact trigger
            // only fires once a conversation exists, which doesn't happen at
            // creation time, so register the creator here explicitly. RLS
            // allows it via the creator_id = auth.uid() branch.
            struct ContactInsert: Encodable {
                let user_id: String
                let bot_id: String
                let added_via: String
            }
            try await SupabaseStack.shared
                .from("user_bot_contacts")
                .insert(ContactInsert(user_id: userId, bot_id: row.id, added_via: "manual"))
                .execute()

            let pick = FriendsTabView.BotPick(
                id: row.id,
                display_name: row.display_name,
                model_id: row.model_id,
                visibility: row.visibility,
                creator_id: row.creator_id,
                voice_call_enabled: true
            )
            onCreated(pick)
            Haptics.success()
            dismiss()
        } catch {
            // 23505 == unique_violation on bots.slug — the chosen handle
            // is taken (by another public bot or a preset). Surface a
            // targeted message so the user knows to pick a different slug.
            let msg = error.localizedDescription
            if msg.contains("23505") || msg.lowercased().contains("duplicate") {
                self.error = "「\(BotSlugRule.normalize(slug))」这个标识已被占用，换一个试试。"
            } else {
                self.error = msg
            }
            Haptics.error()
        }
    }
}

// MARK: - Manage

/// Shown by long-pressing a bot row that the current user created.
/// Name, model and voice are editable regardless of visibility. The
/// visibility-specific surface:
///   - private:       can promote to public, and can delete
///   - public_invite: visibility toggle + invite list (no delete)
///   - public_open:   visibility toggle only (no delete)
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
    /// IANA tz the bot considers its own. Only meaningful on public bots
    /// — for private bots the column stays NULL and the bot follows the
    /// listener's clientTz like before. Loaded from the bots row on
    /// appear; default = device tz when the row's tz is null but the
    /// bot is public (which only happens for legacy rows or for a
    /// promotion-in-progress that hasn't yet persisted).
    @State private var tz: String = TimeZone.current.identifier
    @State private var initialTz: String = ""
    /// Public handle. Loaded from the bots row; editable for public bots
    /// (the others-add-me identity), frozen-irrelevant for private ones.
    /// `initialSlug` is the persisted value — also what the share page
    /// uses, so an unsaved edit doesn't hand out a dead link.
    @State private var slug: String = ""
    @State private var initialSlug: String = ""
    @State private var saving = false
    @State private var deleting = false
    @State private var confirmingDelete = false
    @State private var confirmingPromote = false
    @State private var error: String?

    private var isPrivate: Bool { visibility == "private" }

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
                    Toggle("语音通话", isOn: $voiceCallEnabled)
                } footer: {
                    Text("打开后,聊天页顶部会出现电话按钮,可以和这个机器人语音通话。计费走实时音频用量。")
                        .font(Theme.Fonts.caption)
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
                        Text("升级为公有后不能再转回私有,也不能删除,但仍能改设置和改名。请确认。")
                            .font(Theme.Fonts.caption)
                    }
                }

                // Public bots carry a user-facing slug — the handle others
                // type / scan / tap to add. Editable here (rename anytime);
                // old links break on rename, same as changing a username.
                if visibility != "private" {
                    Section {
                        HStack(spacing: 4) {
                            Text("@").foregroundStyle(Theme.Palette.inkMuted)
                            TextField("机器人标识(slug)", text: $slug)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .onChange(of: slug) { _, v in
                                    let n = BotSlugRule.normalize(v)
                                    if n != v { slug = n }
                                }
                        }
                    } header: {
                        Text("机器人标识")
                    } footer: {
                        Text("别人按这个标识、链接或二维码加你的机器人。\(BotSlugRule.helpText)。")
                    }
                }

                // Share affordance — only for already-public bots with a
                // persisted slug. (A promotion-in-progress shows the slug
                // editor above but not this, until the row is saved.)
                if (initial.visibility ?? "private") != "private" && !initialSlug.isEmpty {
                    Section {
                        NavigationLink {
                            BotSharePage(
                                slug: initialSlug,
                                botName: displayName.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? initial.display_name : displayName)
                        } label: {
                            Label("分享机器人", systemImage: "square.and.arrow.up")
                                .foregroundStyle(Theme.Palette.ink)
                        }
                    } footer: {
                        if BotSlugRule.normalize(slug) != initialSlug {
                            Text("标识改了记得先保存,分享的链接 / 二维码才会用新的。")
                                .font(Theme.Fonts.caption)
                        }
                    }
                }

                // Public bots have a self-tz: drives the "你所在的时区是
                // X" line in the bot's system prompt and the group time
                // hint. Private bots don't (follow listener clientTz).
                if visibility != "private" {
                    Section {
                        NavigationLink {
                            TimeZonePickerView(selection: $tz)
                        } label: {
                            HStack {
                                Text("机器人时区").foregroundStyle(Theme.Palette.ink)
                                Spacer()
                                Text(tz.isEmpty ? TimeZone.current.identifier : tz)
                                    .foregroundStyle(Theme.Palette.inkMuted)
                            }
                        }
                    } footer: {
                        Text("机器人会认为自己在这个时区，群聊里的时间提示也按这个时区显示。私聊里，时间提示仍按你的设备时区。")
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
                    // Block save on an invalid public slug — otherwise the
                    // INSERT/UPDATE just bounces off the format/unique guard.
                    .disabled(saving || !dirty
                              || (visibility != "private" && !BotSlugRule.isValid(slug)))
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
                    Text("升级为公有后不能转回私有,也不能删除,但仍能改设置和改名。")
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

    /// model_provider + tz aren't on BotPick — pull them from the bots
    /// row so the pickers pre-select the right values and the dirty
    /// check is accurate.
    private func loadModelProvider() async {
        struct Row: Decodable { let model_provider: String?; let tz: String?; let slug: String? }
        if let row: Row = try? await SupabaseStack.shared
            .from("bots")
            .select("model_provider, tz, slug")
            .eq("id", value: initial.id)
            .single()
            .execute()
            .value {
            modelProvider = row.model_provider
            initialModelProvider = row.model_provider
            slug = row.slug ?? ""
            initialSlug = row.slug ?? ""
            // Public bots have a tz from creation/backfill ('Etc/UTC'
            // for preset, creator-device-tz for user-created). The
            // empty initial state lets the dirty check distinguish
            // "loaded null from a private bot" from "explicitly set
            // an empty tz".
            let loaded = row.tz ?? ""
            tz = loaded.isEmpty ? TimeZone.current.identifier : loaded
            initialTz = loaded
        }
    }

    /// True when there's actually something to save vs the row we loaded.
    private var dirty: Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        if trimmed != initial.display_name { return true }
        if modelSlug != (initial.model_id ?? "") { return true }
        if modelProvider != initialModelProvider { return true }
        if voiceCallEnabled != (initial.voice_call_enabled ?? false) { return true }
        if visibility != (initial.visibility ?? "public_open") { return true }
        // slug renames only matter on public bots (private bots keep their
        // synthetic slug and never send it).
        if visibility != "private" && BotSlugRule.normalize(slug) != initialSlug { return true }
        // tz changes only matter on public bots. Private edits don't
        // touch the column, so don't flag the form dirty just because
        // the placeholder device-tz differs from the row's null.
        if visibility != "private" && tz != initialTz { return true }
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
            // Encodable omits nil optionals, so a custom encode force-emits it.
            struct Update: Encodable {
                let display_name: String
                let model_id: String
                let model_provider: String?
                let visibility: String
                let voice_call_enabled: Bool
                /// nil here means "not promoting / no tz change for a
                /// private bot" — the encode() below force-emits it as
                /// JSON null so a private→public promotion correctly
                /// SET tz = ... too.
                let tz: String?
                /// nil = leave the slug untouched (private bots keep their
                /// synthetic slug). Unlike tz, slug is NOT NULL, so the
                /// encode() OMITS the key when nil rather than sending null.
                let slug: String?
                enum CodingKeys: String, CodingKey {
                    case display_name, model_id, model_provider
                    case visibility, voice_call_enabled, tz, slug
                }
                func encode(to encoder: Encoder) throws {
                    var c = encoder.container(keyedBy: CodingKeys.self)
                    try c.encode(display_name, forKey: .display_name)
                    try c.encode(model_id, forKey: .model_id)
                    try c.encode(model_provider, forKey: .model_provider)
                    try c.encode(visibility, forKey: .visibility)
                    try c.encode(voice_call_enabled, forKey: .voice_call_enabled)
                    try c.encode(tz, forKey: .tz)
                    if let slug { try c.encode(slug, forKey: .slug) }
                }
            }
            // The creator may edit every column regardless of visibility, so
            // one payload covers private edits, public edits, and the
            // private→public promotion alike. tz round-trips as null for
            // a row that should clear the column (private bot, or a
            // promotion we forgot to default — unlikely with the UI gate
            // but the schema tolerates it).
            let payload = Update(
                display_name: displayName.trimmingCharacters(in: .whitespaces),
                model_id: modelSlug,
                model_provider: modelProvider,
                visibility: visibility,
                voice_call_enabled: voiceCallEnabled,
                tz: visibility == "private" ? nil : tz,
                slug: visibility == "private" ? nil : BotSlugRule.normalize(slug)
            )
            try await SupabaseStack.shared
                .from("bots")
                .update(payload)
                .eq("id", value: initial.id)
                .execute()
            onChanged()
            Haptics.success()
            dismiss()
        } catch {
            // 23505 == unique_violation on bots.slug — the renamed handle
            // is taken. Surface a targeted message so the user retries.
            let msg = error.localizedDescription
            if msg.contains("23505") || msg.lowercased().contains("duplicate") {
                self.error = "「\(BotSlugRule.normalize(slug))」这个标识已被占用,换一个。"
            } else {
                self.error = msg
            }
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

// MARK: - Time zone picker

/// Searchable list of IANA time zones (TimeZone.knownTimeZoneIdentifiers).
/// Pushed from ManageBotSheet when the creator wants to pin a public bot
/// to a specific zone. The current device tz is offered as a one-tap
/// reset row at the top.
struct TimeZonePickerView: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var search: String = ""

    private var identifiers: [String] {
        // Sort alphabetically — IANA names group naturally by continent
        // when sorted, and search makes scrolling unnecessary anyway.
        TimeZone.knownTimeZoneIdentifiers.sorted()
    }

    private var filtered: [String] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return identifiers }
        return identifiers.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        List {
            // Quick reset to whatever the device thinks "here" is.
            // Common case: creator's tz moved (travel, relocation) and
            // they want the bot to follow.
            Section {
                Button {
                    selection = TimeZone.current.identifier
                    dismiss()
                } label: {
                    HStack {
                        Text("当前设备时区")
                        Spacer()
                        Text(TimeZone.current.identifier)
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                }
                .foregroundStyle(Theme.Palette.ink)
            }
            Section {
                ForEach(filtered, id: \.self) { id in
                    Button {
                        selection = id
                        dismiss()
                    } label: {
                        HStack {
                            Text(id)
                            Spacer()
                            if id == selection {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.Palette.accent)
                            }
                        }
                    }
                    .foregroundStyle(Theme.Palette.ink)
                }
            }
        }
        .searchable(text: $search, prompt: "搜索时区")
        .navigationTitle("机器人时区")
        .navigationBarTitleDisplayMode(.inline)
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
/// Read-only for bots the caller didn't create (the worker enforces the
/// same gate). The settings still render so the user can *see* how the
/// bot is set up.
struct BotConfigView: View {
    let bot: Bot
    let currentUserId: String?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var catalog: ModelCatalog

    @State private var model: String = ""
    /// API route pin for the main model — nil = default routing,
    /// 'openai' = the native Responses route. Set by the model picker.
    @State private var modelProvider: String?
    @State private var voiceEnabled: Bool = false
    /// Realtime voice model slug. Always concrete — a bot with voice on
    /// has a model; the default is gpt-realtime-2. Never empty.
    @State private var voiceModel: String = "gpt-realtime-2"
    /// Per-bot realtime call knobs (voice id, VAD mode + thresholds,
    /// auto-respond / interrupt flags). Lives under `bots.config.voice`.
    @State private var voiceSettings: BotVoiceSettings = .defaults
    @State private var visionModel: String = ""   // "" = auto
    @State private var envelope: EnvelopeSettings = .defaults
    /// Per-bot OpenRouter web-search knobs. Lives under
    /// `bots.config.webSearch`; only takes effect on the default
    /// (OpenRouter) routing path — native-provider bots reach search
    /// through their own provider tools, so the section is hidden for them.
    @State private var webSearch: BotWebSearchSettings = .defaults
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
        let voiceSettings: BotVoiceSettings
        let visionModel: String
        let envelope: EnvelopeSettings
        let webSearch: BotWebSearchSettings
        let lookbackEnabled: Bool
        let lookbackInterval: Int
    }

    private enum PickerTarget: Identifiable {
        case main, vision
        var id: Int {
            switch self {
            case .main: return 0
            case .vision: return 1
            }
        }
    }

    /// Only the creator may edit — including after the bot goes public.
    /// Preset bots have a NULL creator and stay read-only here.
    private var canEdit: Bool {
        guard let me = currentUserId, let owner = bot.creator_id else { return false }
        return owner == me
    }

    private var snapshot: Snapshot {
        Snapshot(
            model: model, modelProvider: modelProvider,
            voiceEnabled: voiceEnabled, voiceModel: voiceModel,
            voiceSettings: voiceSettings,
            visionModel: visionModel, envelope: envelope,
            webSearch: webSearch,
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
                    Text("这是「\(bot.display_name)」的配置。只有创建者本人能修改。")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            }

            modelSection
            // Web search only applies on the default (OpenRouter) routing
            // path; native-provider bots ignore it, so hide the knob then.
            if modelProvider == nil {
                webSearchSection
            }
            voiceSection
            envelopeSection
            lookbackSection

            Section("技能") {
                NavigationLink {
                    // Match the user's skills view to whichever provider
                    // this bot routes through — OpenAI native goes one
                    // way, everything else (OpenRouter default) the other.
                    SkillsView(provider: modelProvider == "openai" ? .openaiNative : .openrouter)
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
            pickerRow(icon: "cube.transparent", title: "主模型",
                      value: model.isEmpty ? "—" : catalog.displayName(for: model),
                      enabled: canEdit) {
                pickerTarget = .main
            }
            pickerRow(icon: "eye", title: "识图模型",
                      value: visionModel.isEmpty ? "自动" : catalog.displayName(for: visionModel),
                      enabled: canEdit) {
                pickerTarget = .vision
            }
        } header: {
            Text("模型")
        }
    }

    @ViewBuilder
    private var webSearchSection: some View {
        Section {
            Toggle("联网搜索", isOn: $webSearch.enabled)
                .disabled(!canEdit)
            if webSearch.enabled {
                NavigationLink {
                    BotWebSearchSettingsView(settings: $webSearch, canEdit: canEdit)
                } label: {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text("搜索设置")
                        Spacer()
                        Text(webSearch.engine.label)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(Theme.Palette.ink)
            }
        } header: {
            Text("联网搜索")
        } footer: {
            Text("打开后，机器人可以在需要时自己联网搜索并引用结果（由模型决定何时搜）。「搜索设置」里可以选搜索引擎、结果数量、上下文大小，以及限定/排除域名。仅对默认（OpenRouter）模型生效。")
        }
    }

    @ViewBuilder
    private var voiceSection: some View {
        Section {
            Toggle("通话能力", isOn: $voiceEnabled)
                .disabled(!canEdit)
            if voiceEnabled {
                // Friendly labels for the two realtime models — we don't
                // route these through ModelCatalog because the catalog
                // exists for the chat-side LLM picker, and the realtime
                // names ("GPT Realtime 2" / "GPT Realtime Mini") are
                // stable, short, and worth showing as-is.
                Picker(selection: $voiceModel) {
                    Text("GPT Realtime 2").tag("gpt-realtime-2")
                    Text("GPT Realtime Mini").tag("gpt-realtime-mini-2025-12-15")
                } label: {
                    HStack {
                        Image(systemName: "waveform")
                        Text("语音模型")
                    }
                }
                .disabled(!canEdit)
                .foregroundStyle(Theme.Palette.ink)

                NavigationLink {
                    BotVoiceSettingsView(settings: $voiceSettings, canEdit: canEdit)
                } label: {
                    HStack {
                        Image(systemName: "slider.horizontal.3")
                        Text("通话设置")
                    }
                }
                .foregroundStyle(Theme.Palette.ink)
            }
        } header: {
            Text("通话")
        } footer: {
            Text("Realtime 2 比较贵，Mini 比较笨。「通话设置」里可以调音色、回合检测模式与阈值、是否自动回复、是否被打断。")
        }
    }

    @ViewBuilder
    private var envelopeSection: some View {
        Section {
            NavigationLink {
                LetterSettingsView(envelope: $envelope, canEdit: canEdit)
            } label: {
                HStack {
                    Image(systemName: "envelope.open")
                    Text("写信设置")
                }
            }
            .foregroundStyle(Theme.Palette.ink)
        } header: {
            Text("写信 / Envelopes")
        } footer: {
            Text("这个机器人写信（来信）时的默认设置：探索/协作模型、检索引擎、轮数与历史预算。在具体对话里可以临时覆盖。")
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
            Text("检查")
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
        }
    }

    // ── Load / save ─────────────────────────────────────────────────────────

    private func load() async {
        guard !loaded else { return }
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
        voiceSettings = BotVoiceSettings.from(dict["voice"])
        envelope = EnvelopeSettings.from(dict["envelope"])
        webSearch = BotWebSearchSettings.from(dict["webSearch"])
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
            let envelopeCfg: [String: Any] = [
                "explorerModel": envelope.explorerModel,
                "collaboratorModel": collabVal,
                "searchProvider": envelope.searchProvider.rawValue,
                "scrapeProvider": envelope.scrapeProvider.rawValue,
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
                "voiceModel": voiceModel,
                "voice": voiceSettings.toConfigDict(),
                "webSearch": webSearch.toConfigDict(),
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

// MARK: - 通话设置 / Realtime voice + turn-detection knobs

/// Per-bot realtime call knobs persisted under `bots.config.voice`. The
/// edge resolver (lib/voice-config) maps this to OpenAI's
/// `audio.output.voice` + `audio.input.turn_detection` on session create.
///
/// `turnType` is a four-way switch:
///   • .auto         → omit turn_detection (OpenAI default = semantic_vad)
///   • .server_vad   → energy-based VAD with threshold + paddings
///   • .semantic_vad → model-decided end-of-turn with eagerness
///   • .none         → no VAD; user controls every response (push-to-talk)
///
/// `createResponse` / `interruptResponse` only apply to server_vad +
/// semantic_vad; the UI hides them when turnType is .auto or .none.
struct BotVoiceSettings: Codable, Hashable {
    enum VoiceId: String, Codable, CaseIterable, Hashable {
        case marin, cedar, alloy, ash, ballad, coral, echo, sage, shimmer, verse
        var label: String { rawValue.capitalized }
    }

    enum TurnDetectionType: String, Codable, CaseIterable, Hashable {
        case auto, server_vad, semantic_vad, none
        var label: String {
            switch self {
            case .auto:         return "自动"
            case .server_vad:   return "服务端 VAD"
            case .semantic_vad: return "语义 VAD"
            case .none:         return "关闭（按住说话）"
            }
        }
    }

    enum Eagerness: String, Codable, CaseIterable, Hashable {
        case low, medium, high, auto
        var label: String {
            switch self {
            case .low:    return "低"
            case .medium: return "中"
            case .high:   return "高"
            case .auto:   return "自动"
            }
        }
    }

    var voiceId: VoiceId = .marin
    var turnType: TurnDetectionType = .auto
    /// server_vad activity threshold — 0.0 (mic always on) … 1.0 (only
    /// shouting trips). OpenAI's own default is 0.5; ours matches.
    var threshold: Double = 0.5
    /// server_vad — how much audio before VAD-trip to keep as the user's
    /// utterance (default 300 ms).
    var prefixPaddingMs: Int = 300
    /// server_vad — how long silence must hold before VAD declares
    /// end-of-turn (default 200 ms).
    var silenceDurationMs: Int = 200
    /// semantic_vad — how eager the model is to assume the user is done.
    var eagerness: Eagerness = .auto
    /// After VAD declares end-of-turn, immediately ask the model for a
    /// response. Off = user (or a tool call) must trigger one manually.
    var createResponse: Bool = true
    /// When the user starts speaking mid-response, truncate the current
    /// model audio so the bot stops talking over them.
    var interruptResponse: Bool = true

    static let defaults = BotVoiceSettings()

    /// Decode from a Supabase JSONB blob (`AnyJSON`). Every field is
    /// optional — missing keys fall back to defaults so older bot rows
    /// still render.
    static func from(_ json: AnyJSON?) -> BotVoiceSettings {
        var s = BotVoiceSettings.defaults
        guard let json, case let .object(dict) = json else { return s }
        if case let .string(v)? = dict["voiceId"], let id = VoiceId(rawValue: v) {
            s.voiceId = id
        }
        guard case let .object(td)? = dict["turnDetection"] else { return s }
        if case let .string(v)? = td["type"], let t = TurnDetectionType(rawValue: v) {
            s.turnType = t
        }
        if case let .double(v)? = td["threshold"] {
            s.threshold = max(0, min(1, v))
        } else if case let .integer(v)? = td["threshold"] {
            s.threshold = max(0, min(1, Double(v)))
        }
        if case let .integer(v)? = td["prefixPaddingMs"], v >= 0 {
            s.prefixPaddingMs = v
        } else if case let .double(v)? = td["prefixPaddingMs"], v >= 0 {
            s.prefixPaddingMs = Int(v)
        }
        if case let .integer(v)? = td["silenceDurationMs"], v >= 0 {
            s.silenceDurationMs = v
        } else if case let .double(v)? = td["silenceDurationMs"], v >= 0 {
            s.silenceDurationMs = Int(v)
        }
        if case let .string(v)? = td["eagerness"], let e = Eagerness(rawValue: v) {
            s.eagerness = e
        }
        if case let .bool(v)? = td["createResponse"] { s.createResponse = v }
        if case let .bool(v)? = td["interruptResponse"] { s.interruptResponse = v }
        return s
    }

    /// Serialize for the PATCH body. The whole sub-object is sent every
    /// save — the edge resolver only consumes fields relevant to the
    /// chosen `type`, so extras are harmless.
    func toConfigDict() -> [String: Any] {
        [
            "voiceId": voiceId.rawValue,
            "turnDetection": [
                "type": turnType.rawValue,
                "threshold": threshold,
                "prefixPaddingMs": prefixPaddingMs,
                "silenceDurationMs": silenceDurationMs,
                "eagerness": eagerness.rawValue,
                "createResponse": createResponse,
                "interruptResponse": interruptResponse,
            ] as [String: Any],
        ]
    }
}

struct BotVoiceSettingsView: View {
    @Binding var settings: BotVoiceSettings
    var canEdit: Bool = true

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.voiceId) {
                    ForEach(BotVoiceSettings.VoiceId.allCases, id: \.self) { v in
                        Text(v.label).tag(v)
                    }
                } label: {
                    HStack {
                        Image(systemName: "person.wave.2")
                        Text("音色")
                    }
                }
                .foregroundStyle(Theme.Palette.ink)
            } header: {
                Text("声音")
            } footer: {
                Text("OpenAI Realtime 提供的音色。Marin 是默认。")
            }

            Section {
                Picker(selection: $settings.turnType) {
                    ForEach(BotVoiceSettings.TurnDetectionType.allCases, id: \.self) { t in
                        Text(t.label).tag(t)
                    }
                } label: {
                    HStack {
                        Image(systemName: "ear")
                        Text("检测模式")
                    }
                }
                .foregroundStyle(Theme.Palette.ink)

                switch settings.turnType {
                case .server_vad:
                    serverVadRows
                case .semantic_vad:
                    semanticVadRows
                case .auto, .none:
                    EmptyView()
                }
            } header: {
                Text("回合检测（VAD）")
            } footer: {
                Text(turnDetectionFooter)
            }

            if settings.turnType == .server_vad || settings.turnType == .semantic_vad {
                Section {
                    Toggle("说完自动回复", isOn: $settings.createResponse)
                        .foregroundStyle(Theme.Palette.ink)
                    Toggle("被打断时停止当前回答", isOn: $settings.interruptResponse)
                        .foregroundStyle(Theme.Palette.ink)
                } header: {
                    Text("回复行为")
                } footer: {
                    Text("「说完自动回复」关掉后，机器人不会主动接话；「被打断时停止」关掉后，你说话时它会继续讲完当前那句。")
                }
            }
        }
        .navigationTitle("通话设置")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(!canEdit)
        .tint(Theme.Palette.accent)
    }

    @ViewBuilder
    private var serverVadRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "speaker.wave.2")
                Text("音量阈值")
                Spacer()
                Text(String(format: "%.2f", settings.threshold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $settings.threshold, in: 0...1, step: 0.05)
                .tint(Theme.Palette.accent)
        }
        .foregroundStyle(Theme.Palette.ink)

        Stepper(value: $settings.prefixPaddingMs, in: 0...1000, step: 50) {
            HStack {
                Image(systemName: "arrow.backward.to.line")
                Text("前导补足")
                Spacer()
                Text("\(settings.prefixPaddingMs) ms")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .foregroundStyle(Theme.Palette.ink)

        Stepper(value: $settings.silenceDurationMs, in: 0...2000, step: 50) {
            HStack {
                Image(systemName: "pause.circle")
                Text("静音判定")
                Spacer()
                Text("\(settings.silenceDurationMs) ms")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .foregroundStyle(Theme.Palette.ink)
    }

    @ViewBuilder
    private var semanticVadRows: some View {
        Picker(selection: $settings.eagerness) {
            ForEach(BotVoiceSettings.Eagerness.allCases, id: \.self) { e in
                Text(e.label).tag(e)
            }
        } label: {
            HStack {
                Image(systemName: "brain")
                Text("灵敏度")
            }
        }
        .foregroundStyle(Theme.Palette.ink)
    }

    private var turnDetectionFooter: String {
        switch settings.turnType {
        case .auto:
            return "由模型决定何时认为你说完。最稳。"
        case .server_vad:
            return "按音量切换回合。阈值越低越敏感；前导补足是触发时往前保留的音频；静音判定是认为说完所需的静音长度。"
        case .semantic_vad:
            return "由模型判断语义是否完整。灵敏度越高越早抢答。"
        case .none:
            return "关闭检测，需要手动控制（暂未支持完全的按住说话 UI，建议选「自动」）。"
        }
    }
}

// MARK: - 联网搜索设置 / OpenRouter web_search knobs

/// Per-bot OpenRouter `openrouter:web_search` server-tool config, persisted
/// under `bots.config.webSearch`. The edge maps these camelCase fields to
/// OpenRouter's snake_case `parameters` at request build. Only applies on
/// the default (OpenRouter) routing path.
///
/// Two fields are "omittable" so the server keeps OpenRouter's adaptive
/// defaults instead of a forced value:
///   • `maxTotalResults == 0` → no total-results cap (key omitted)
///   • `contextSize == .auto` → let Exa size highlights adaptively (omitted)
struct BotWebSearchSettings: Codable, Hashable {
    enum Engine: String, Codable, CaseIterable, Hashable {
        case auto, native, exa, firecrawl, parallel
        var label: String {
            switch self {
            case .auto:      return "自动"
            case .native:    return "模型原生"
            case .exa:       return "Exa"
            case .firecrawl: return "Firecrawl"
            case .parallel:  return "Parallel"
            }
        }
    }

    enum ContextSize: String, Codable, CaseIterable, Hashable {
        case auto, low, medium, high
        var label: String {
            switch self {
            case .auto:   return "自动"
            case .low:    return "少"
            case .medium: return "中"
            case .high:   return "多"
            }
        }
    }

    var enabled: Bool = true
    var engine: Engine = .auto
    /// Results per search call (1–25). OpenRouter's own default is 5.
    var maxResults: Int = 5
    /// Cap on total results across all search calls in one request.
    /// 0 = no cap (key omitted on save).
    var maxTotalResults: Int = 0
    /// Highlight size per result. `.auto` = let the engine pick (omitted).
    var contextSize: ContextSize = .auto
    var allowedDomains: [String] = []
    var excludedDomains: [String] = []

    static let defaults = BotWebSearchSettings()

    static func from(_ json: AnyJSON?) -> BotWebSearchSettings {
        var s = BotWebSearchSettings.defaults
        guard let json, case let .object(d) = json else { return s }
        if case let .bool(b)? = d["enabled"] { s.enabled = b }
        if case let .string(v)? = d["engine"], let e = Engine(rawValue: v) { s.engine = e }
        if case let .integer(v)? = d["maxResults"], v > 0 {
            s.maxResults = min(25, max(1, v))
        } else if case let .double(v)? = d["maxResults"], v > 0 {
            s.maxResults = min(25, max(1, Int(v)))
        }
        if case let .integer(v)? = d["maxTotalResults"], v > 0 {
            s.maxTotalResults = min(100, v)
        } else if case let .double(v)? = d["maxTotalResults"], v > 0 {
            s.maxTotalResults = min(100, Int(v))
        }
        if case let .string(v)? = d["searchContextSize"], let c = ContextSize(rawValue: v) {
            s.contextSize = c
        }
        if case let .array(arr)? = d["allowedDomains"] {
            s.allowedDomains = arr.compactMap { if case let .string(x) = $0 { return x } else { return nil } }
        }
        if case let .array(arr)? = d["excludedDomains"] {
            s.excludedDomains = arr.compactMap { if case let .string(x) = $0 { return x } else { return nil } }
        }
        return s
    }

    /// Serialize for the PATCH body. Omittable fields are left out so the
    /// server falls back to OpenRouter's adaptive defaults.
    func toConfigDict() -> [String: Any] {
        var d: [String: Any] = [
            "enabled": enabled,
            "engine": engine.rawValue,
            "maxResults": maxResults,
        ]
        if maxTotalResults > 0 { d["maxTotalResults"] = maxTotalResults }
        if contextSize != .auto { d["searchContextSize"] = contextSize.rawValue }
        if !allowedDomains.isEmpty { d["allowedDomains"] = allowedDomains }
        if !excludedDomains.isEmpty { d["excludedDomains"] = excludedDomains }
        return d
    }
}

struct BotWebSearchSettingsView: View {
    @Binding var settings: BotWebSearchSettings
    var canEdit: Bool = true

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.engine) {
                    ForEach(BotWebSearchSettings.Engine.allCases, id: \.self) { e in
                        Text(e.label).tag(e)
                    }
                } label: {
                    HStack {
                        Image(systemName: "server.rack")
                        Text("搜索引擎")
                    }
                }
                .foregroundStyle(Theme.Palette.ink)
            } header: {
                Text("引擎")
            } footer: {
                Text("「自动」会优先用模型自带的联网搜索，没有就退回 Exa。Firecrawl 需要在 OpenRouter 后台填自己的 key。")
            }

            Section {
                Stepper(value: $settings.maxResults, in: 1...25) {
                    HStack {
                        Image(systemName: "list.number")
                        Text("单次结果数")
                        Spacer()
                        Text("\(settings.maxResults)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(Theme.Palette.ink)

                Stepper(value: $settings.maxTotalResults, in: 0...100, step: 5) {
                    HStack {
                        Image(systemName: "sum")
                        Text("总结果上限")
                        Spacer()
                        Text(settings.maxTotalResults == 0 ? "不限" : "\(settings.maxTotalResults)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(Theme.Palette.ink)
            } header: {
                Text("结果数量")
            } footer: {
                Text("「单次结果数」是每次搜索返回多少条；「总结果上限」是一轮里多次搜索加起来最多多少条，0 表示不限。条数越多越贵、占用上下文越多。")
            }

            Section {
                Picker(selection: $settings.contextSize) {
                    ForEach(BotWebSearchSettings.ContextSize.allCases, id: \.self) { c in
                        Text(c.label).tag(c)
                    }
                } label: {
                    HStack {
                        Image(systemName: "text.alignleft")
                        Text("上下文大小")
                    }
                }
                .foregroundStyle(Theme.Palette.ink)
            } header: {
                Text("每条摘要长度")
            } footer: {
                Text("每条结果保留多少正文喂给模型。「自动」让引擎自己定（Exa 约 2–4K 字符）；多 = 更全但更贵。原生搜索与 Firecrawl 不支持此项。")
            }

            DomainListEditor(
                title: "只搜这些域名",
                icon: "checkmark.shield",
                placeholder: "如 arxiv.org",
                footer: "留空表示不限。Exa 可同时配置黑白名单；其它引擎两者互斥，建议只填一边。",
                domains: $settings.allowedDomains,
                canEdit: canEdit
            )

            DomainListEditor(
                title: "排除这些域名",
                icon: "xmark.shield",
                placeholder: "如 reddit.com",
                footer: nil,
                domains: $settings.excludedDomains,
                canEdit: canEdit
            )
        }
        .navigationTitle("搜索设置")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(!canEdit)
        .tint(Theme.Palette.accent)
    }
}

/// Add/remove editor for a domain allow/deny list. Domains are lowercased
/// and de-duplicated on add; rows swipe to delete.
private struct DomainListEditor: View {
    let title: String
    let icon: String
    let placeholder: String
    let footer: String?
    @Binding var domains: [String]
    var canEdit: Bool
    @State private var draft: String = ""

    var body: some View {
        Section {
            ForEach(domains, id: \.self) { d in
                HStack {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                    Text(d)
                }
            }
            .onDelete { domains.remove(atOffsets: $0) }

            if canEdit {
                HStack {
                    TextField(placeholder, text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit(add)
                    Button(action: add) {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(cleaned(draft) == nil)
                    .buttonStyle(.borderless)
                }
                .foregroundStyle(Theme.Palette.ink)
            }
        } header: {
            HStack { Image(systemName: icon); Text(title) }
        } footer: {
            if let footer { Text(footer) }
        }
    }

    private func add() {
        guard let d = cleaned(draft) else { return }
        if !domains.contains(d) { domains.append(d) }
        draft = ""
    }

    private func cleaned(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.isEmpty ? nil : t
    }
}

// MARK: - 分享机器人 / share page (link + QR)

/// Pushed from ManageBotSheet for a public bot. Surfaces the three ways
/// to add it — the typed slug (@handle), the universal link, and a QR —
/// all keyed on the same `bots.slug`. Presentational only: the slug is
/// the persisted one, so edits in ManageBotSheet must be saved first
/// before they show up here (the caller passes the saved value).
struct BotSharePage: View {
    let slug: String
    let botName: String

    @State private var copied = false

    private var shareURLString: String { BotShareLink.url(forSlug: slug) }
    private var shareURL: URL? { URL(string: shareURLString) }
    /// Display form drops the scheme — `bot.pendingname.com/b/<slug>`.
    private var displayURL: String {
        shareURLString.replacingOccurrences(of: "https://", with: "")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                BotQRCard(slug: slug, botName: botName)

                VStack(spacing: 12) {
                    Text(displayURL)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal)

                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = shareURLString
                            copied = true
                            Haptics.tap()
                        } label: {
                            Label(copied ? "已复制" : "复制链接",
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(Theme.Palette.accentBg))
                                .foregroundStyle(Theme.Palette.accent)
                        }
                        .buttonStyle(.plain)

                        if let shareURL {
                            ShareLink(item: shareURL) {
                                Label("分享", systemImage: "square.and.arrow.up")
                                    .font(.system(size: 14, weight: .semibold))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(Capsule().fill(Theme.Palette.accentBg))
                                    .foregroundStyle(Theme.Palette.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Text("把这个链接、二维码,或者标识 @\(slug) 发给别人。对方点开链接、扫码,或在「加机器人」里输入这个标识,就能加这个机器人。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.vertical, 8)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle("分享机器人")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Bot QR card

/// Bot-side counterpart to GroupQRCard. Renders a deep-green QR of the
/// bot-share link (`BotShareLink.url(forSlug:)`) with the brand mark in
/// the centre, plus the bot name + handle below. No rotation/minting —
/// the slug is the bot's stable public identity, so the QR is a pure
/// function of the slug.
struct BotQRCard: View {
    let slug: String
    let botName: String

    private let context = CIContext()

    var body: some View {
        VStack(spacing: 18) {
            qrPanel
            VStack(spacing: 6) {
                Text(botName.isEmpty ? "@\(slug)" : botName)
                    .font(Theme.Fonts.serif(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("@\(slug) · 扫码加我")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var qrPanel: some View {
        let size: CGFloat = 240
        ZStack {
            background(size: size)
            if let qr = qrImage(for: BotShareLink.url(forSlug: slug)) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size - 32, height: size - 32)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white)
                    )
                Image("BrandMark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.Palette.canvas)
                    )
            } else {
                Text("生成二维码失败")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func background(size: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        if #available(iOS 26.0, *) {
            Color.clear
                .frame(width: size, height: size)
                .glassEffect(.regular, in: shape)
        } else {
            shape
                .fill(Theme.Palette.surface)
                .frame(width: size, height: size)
                .overlay(
                    shape.strokeBorder(Theme.Palette.accent.opacity(0.08),
                                       lineWidth: 0.5)
                )
                .shadow(color: Theme.Palette.accent.opacity(0.12),
                        radius: 18, y: 8)
        }
    }

    // Mirrors MyQRBusinessCard.qrImage / GroupQRCard.qrImage — kept in
    // sync intentionally (CIQRCodeGenerator + recolour + manual
    // quiet-zone padding). Extracting a shared helper would need pbxproj
    // juggling for a new file; this copy is cheaper.
    private func qrImage(for payload: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "H"
        guard let raw = filter.outputImage else { return nil }
        let recolour = CIFilter.falseColor()
        recolour.inputImage = raw
        recolour.color0 = CIColor(red: 4 / 255.0, green: 71 / 255.0, blue: 53 / 255.0)
        recolour.color1 = CIColor(red: 253 / 255.0, green: 252 / 255.0, blue: 250 / 255.0)
        guard let coloured = recolour.outputImage else { return nil }
        let scale: CGFloat = 10
        let scaled = coloured.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let inner = CGFloat(cg.width)
        let quiet = scale * 4
        let total = inner + quiet * 2
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: total, height: total),
            format: {
                let f = UIGraphicsImageRendererFormat.default()
                f.scale = 1
                f.opaque = true
                return f
            }(),
        )
        return renderer.image { ctx in
            UIColor(red: 253 / 255.0, green: 252 / 255.0, blue: 250 / 255.0, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: total, height: total))
            ctx.cgContext.translateBy(x: 0, y: total)
            ctx.cgContext.scaleBy(x: 1, y: -1)
            ctx.cgContext.draw(cg, in: CGRect(x: quiet, y: quiet, width: inner, height: inner))
        }
    }
}
