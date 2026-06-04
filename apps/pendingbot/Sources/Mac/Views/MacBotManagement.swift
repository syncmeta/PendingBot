#if os(macOS)
import SwiftUI
import Supabase

// macOS-native bot CRUD + 加好友, mirroring the iOS surfaces in
// Sources/Features/Friends/{BotManagement,FriendsTabView}.swift (#212).
//
// Logic is fully reused: all reads/writes go through the SAME cross-platform
// SupabaseStack / APIClient / AccountStore / ModelCatalog the iOS sheets use,
// gated by the SAME RLS (creator_id = auth.uid() for bot INSERT/UPDATE/DELETE;
// the bots_guard_public_update trigger enforces the one-way private→public
// rule and the public-bot delete block server-side). Only the rendering is
// re-done natively because the iOS sheets lean on UIKit-coupled types
// (FriendsTabView.BotPick, ArenaModelPoolEditor, ModelPickerSheet,
// navigationBarTitleDisplayMode, …) that don't exist on macOS.
//
// Differences from iOS, by design:
//   • Model selection is single-model only (a native List picker off
//     ModelCatalog). iOS's arena (multi-model) pool editor is not ported —
//     Mac bots are created single-model; gap logged in the task return.
//   • No avatar picker (iOS-only image picker) — emoji placeholder only.
//   • 加好友 / 加机器人 only support the type-a-handle / type-a-token paths;
//     there is no camera on Mac so QR scan entry is skipped (gap logged).

// MARK: - Thin bot value model

/// macOS counterpart to iOS `FriendsTabView.BotPick`. Carries exactly the
/// fields the Mac create/manage sheets read back so the parent list can
/// refresh without depending on the iOS view type.
struct MacBotPick: Identifiable, Hashable {
    let id: String
    let displayName: String
    let modelId: String?
    let visibility: String?
    let creatorId: String?
}

// MARK: - Slug rule (Mac copy)

/// Mirror of iOS `BotSlugRule` (which lives behind `#if os(iOS)` in
/// BotManagement.swift, so it isn't visible here). Same rules, same reserved
/// namespaces — kept in sync by hand. The server's slug constraint is the
/// real source of truth; this is only client-side pre-validation.
enum MacBotSlugRule {
    static let minLen = 3
    static let maxLen = 20
    private static let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")

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

// MARK: - Native model picker

/// Single-model picker backed by the cross-platform `ModelCatalog`. Lists the
/// catalog (sorted by display name) with a search box; tapping a row selects
/// it and stores both the slug and its `model_provider` (so native-route bots
/// pin correctly). Mac doesn't port iOS's arena multi-model pool editor.
struct MacModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var catalog: ModelCatalog
    /// Current selection (empty = none).
    let initialSlug: String
    /// (slug, model_provider) on pick.
    var onPicked: (String, String?) -> Void

    @State private var query: String = ""

    private var rows: [OpenRouterModel] {
        // De-dupe by slug (the catalog map can key one model under several
        // slugs), then sort by display name.
        var seen = Set<String>()
        let unique = catalog.bySlug.values.filter { seen.insert($0.slug).inserted }
        let sorted = unique.sorted { $0.display_name.localizedCaseInsensitiveCompare($1.display_name) == .orderedAscending }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sorted }
        return sorted.filter {
            $0.display_name.lowercased().contains(q) || $0.slug.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选择模型").font(Theme.Fonts.headline)
                Spacer()
                Button("关闭") { dismiss() }
            }
            .padding()

            TextField("搜索模型", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 8)

            List {
                ForEach(rows) { model in
                    Button {
                        onPicked(model.slug, model.model_provider)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.display_name)
                                    .foregroundStyle(Theme.Palette.ink)
                                Text(model.slug)
                                    .font(Theme.Fonts.caption2)
                                    .foregroundStyle(Theme.Palette.inkMuted)
                            }
                            Spacer()
                            if model.slug == initialSlug {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.Palette.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 380, minHeight: 460)
        .task { catalog.loadIfNeeded() }
    }
}

// MARK: - Create bot

/// macOS 新建机器人 — mirrors iOS `CreateBotSheet` (name + model + visibility
/// + public slug), minus the arena pool editor (single model only). Writes the
/// `bots` row + the creator's `user_bot_contacts` row exactly like iOS, behind
/// the same RLS.
struct MacCreateBotSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var catalog: ModelCatalog
    /// Called with the freshly-inserted bot so the parent can prepend it.
    var onCreated: (MacBotPick) -> Void

    @State private var displayName: String = ""
    @State private var modelSlug: String = ""
    @State private var modelProvider: String?
    @State private var visibility: Visibility = .privateBot
    @State private var slug: String = ""
    @State private var creating = false
    @State private var error: String?
    @State private var showingModelPicker = false

    enum Visibility: String, CaseIterable, Identifiable {
        case privateBot   = "private"
        case publicInvite = "public_invite"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .privateBot:   return "私有"
            case .publicInvite: return "公有 · 邀请制"
            }
        }
        var subtitle: String {
            switch self {
            case .privateBot:
                return "只有你自己能聊。可以随时改设置、改名、删除。"
            case .publicInvite:
                return "你邀请的人才能聊。建好后你还能改设置和改名,但不能删、不能转回私有。"
            }
        }
    }

    private var canCreate: Bool {
        let nameOK = !displayName.trimmingCharacters(in: .whitespaces).isEmpty
        let modelOK = !modelSlug.isEmpty
        if visibility == .privateBot { return nameOK && modelOK }
        return nameOK && modelOK && MacBotSlugRule.isValid(slug)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Text("新建机器人").font(Theme.Fonts.headline)
                Spacer()
                Button(creating ? "创建中…" : "创建") { Task { await create() } }
                    .disabled(creating || !canCreate)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Form {
                Section {
                    TextField("机器人名字", text: $displayName)
                    HStack {
                        Text("模型").foregroundStyle(Theme.Palette.inkMuted)
                        Spacer()
                        Button(modelSlug.isEmpty ? "选择模型" : catalog.displayName(for: modelSlug)) {
                            showingModelPicker = true
                        }
                        .buttonStyle(.link)
                    }
                }

                Section("公开程度") {
                    ForEach(Visibility.allCases) { v in
                        Button { visibility = v } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: visibility == v
                                      ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(visibility == v
                                                     ? Theme.Palette.accent : Theme.Palette.inkMuted)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(v.label)
                                        .font(Theme.Fonts.rounded(size: 14, weight: .semibold))
                                        .foregroundStyle(Theme.Palette.ink)
                                    Text(v.subtitle)
                                        .font(Theme.Fonts.caption)
                                        .foregroundStyle(Theme.Palette.inkMuted)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if visibility != .privateBot {
                    Section {
                        HStack(spacing: 4) {
                            Text("@").foregroundStyle(Theme.Palette.inkMuted)
                            TextField("机器人标识(slug)", text: $slug)
                                .onChange(of: slug) { _, v in
                                    let n = MacBotSlugRule.normalize(v)
                                    if n != v { slug = n }
                                }
                        }
                    } header: {
                        Text("机器人标识")
                    } footer: {
                        Text("机器人的公开展示标识(@名)。\(MacBotSlugRule.helpText)。别人加这个机器人走邀请链接或二维码,不是靠输入标识。建好后可在管理里修改。")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 420, minHeight: 440)
        .sheet(isPresented: $showingModelPicker) {
            MacModelPickerSheet(initialSlug: modelSlug) { picked, provider in
                modelSlug = picked
                modelProvider = provider
            }
            .environmentObject(catalog)
        }
        .task {
            catalog.loadIfNeeded()
            await seedDefaultName()
        }
    }

    /// Same lorem-token seeding as iOS so a fresh sheet pre-fills a name the
    /// creator can edit.
    private static let loremTokens: [String] = [
        "Lorem", "Ipsum", "Dolor", "Sit", "Amet",
        "Consectetur", "Adipiscing", "Elit", "Sed", "Do",
        "Eiusmod", "Tempor", "Incididunt", "Ut", "Labore",
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
        let pick = Self.loremTokens.first { !used.contains($0.lowercased()) } ?? Self.loremTokens[0]
        guard displayName.isEmpty else { return }
        displayName = pick
    }

    private func create() async {
        guard let userId = AccountStore.shared.current?.id else { return }
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !modelSlug.isEmpty else { return }
        creating = true; defer { creating = false }
        do {
            struct BotInsert: Encodable {
                let creator_id: String
                let visibility: String
                let display_name: String
                let model_id: String
                let model_provider: String?
                let slug: String
                let tz: String?
            }
            struct BotOut: Decodable {
                let id: String
                let display_name: String
                let model_id: String?
                let visibility: String?
                let creator_id: String?
            }
            // Private bots mint a synthetic slug so the NOT NULL UNIQUE
            // constraint is satisfied without burning a real handle.
            let finalSlug: String = visibility == .privateBot
                ? "u_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).description
                : MacBotSlugRule.normalize(slug)
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

            // Friends-tab bot list reads user_bot_contacts, not bots — register
            // the creator's contact row explicitly (same as iOS).
            struct ContactInsert: Encodable {
                let user_id: String
                let bot_id: String
                let added_via: String
            }
            try await SupabaseStack.shared
                .from("user_bot_contacts")
                .insert(ContactInsert(user_id: userId, bot_id: row.id, added_via: "manual"))
                .execute()

            onCreated(MacBotPick(
                id: row.id,
                displayName: row.display_name,
                modelId: row.model_id,
                visibility: row.visibility,
                creatorId: row.creator_id
            ))
            Haptics.success()
            dismiss()
        } catch {
            let msg = error.localizedDescription
            if msg.contains("23505") || msg.lowercased().contains("duplicate") {
                self.error = "「\(MacBotSlugRule.normalize(slug))」这个标识已被占用,换一个试试。"
            } else {
                self.error = msg
            }
            Haptics.error()
        }
    }
}

// MARK: - Manage bot

/// macOS 管理机器人 — mirrors iOS `ManageBotSheet` (rename / model / visibility
/// promote / public slug / delete). Same direct-supabase UPDATE/DELETE behind
/// the same RLS + bots_guard_public_update trigger. Invite-list management,
/// share page, tz picker, voice/output toggles, and bot-config are NOT ported
/// to this first Mac pass (gap logged).
struct MacManageBotSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var catalog: ModelCatalog
    var onChanged: () -> Void
    var onDeleted: (String) -> Void

    let initial: MacBotPick

    @State private var displayName: String = ""
    @State private var modelSlug: String = ""
    @State private var modelProvider: String?
    @State private var initialModelProvider: String?
    @State private var visibility: String = "private"
    @State private var slug: String = ""
    @State private var initialSlug: String = ""
    @State private var saving = false
    @State private var deleting = false
    @State private var confirmingDelete = false
    @State private var confirmingPromote = false
    @State private var error: String?
    @State private var showingModelPicker = false

    private var isPrivate: Bool { visibility == "private" }

    private var dirty: Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        if trimmed != initial.displayName { return true }
        if modelSlug != (initial.modelId ?? "") { return true }
        if modelProvider != initialModelProvider { return true }
        if visibility != (initial.visibility ?? "public_invite") { return true }
        if visibility != "private" && MacBotSlugRule.normalize(slug) != initialSlug { return true }
        return false
    }

    private var saveDisabled: Bool {
        saving || !dirty || (visibility != "private" && !MacBotSlugRule.isValid(slug))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Text(initial.displayName).font(Theme.Fonts.headline).lineLimit(1)
                Spacer()
                Button(saving ? "保存中…" : "保存") { Task { await save() } }
                    .disabled(saveDisabled)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Form {
                Section {
                    TextField("机器人名字", text: $displayName)
                    HStack {
                        Text("模型").foregroundStyle(Theme.Palette.inkMuted)
                        Spacer()
                        Button(modelSlug.isEmpty ? "选择模型" : catalog.displayName(for: modelSlug)) {
                            showingModelPicker = true
                        }
                        .buttonStyle(.link)
                    }
                }

                Section {
                    Picker("公开程度", selection: $visibility) {
                        if isPrivate { Text("私有").tag("private") }
                        Text("公有 · 邀请制").tag("public_invite")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("公开程度")
                } footer: {
                    if isPrivate {
                        Text("升级为公有后不能再转回私有,也不能删除,但仍能改设置和改名。请确认。")
                            .font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.inkMuted)
                    }
                }

                if visibility != "private" {
                    Section {
                        HStack(spacing: 4) {
                            Text("@").foregroundStyle(Theme.Palette.inkMuted)
                            TextField("机器人标识(slug)", text: $slug)
                                .onChange(of: slug) { _, v in
                                    let n = MacBotSlugRule.normalize(v)
                                    if n != v { slug = n }
                                }
                        }
                    } header: {
                        Text("机器人标识")
                    } footer: {
                        Text("别人按这个标识、链接或二维码加你的机器人。\(MacBotSlugRule.helpText)。")
                            .font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.inkMuted)
                    }
                }

                if isPrivate {
                    Section {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Text(deleting ? "删除中…" : "删除机器人")
                        }
                        .disabled(deleting)
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 420, minHeight: 420)
        .sheet(isPresented: $showingModelPicker) {
            MacModelPickerSheet(initialSlug: modelSlug) { picked, provider in
                modelSlug = picked
                modelProvider = provider
            }
            .environmentObject(catalog)
        }
        .confirmationDialog(
            "确定要删除这个机器人吗?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { Task { await delete() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("聊天记录会保留,但不能再继续聊。")
        }
        .confirmationDialog(
            "升级为公有机器人?",
            isPresented: $confirmingPromote,
            titleVisibility: .visible
        ) {
            Button("升级", role: .destructive) { Task { await persistUpdate() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("升级为公有后不能转回私有,也不能删除,但仍能改设置和改名。")
        }
        .onAppear {
            displayName = initial.displayName
            modelSlug = initial.modelId ?? ""
            visibility = initial.visibility ?? "public_invite"
        }
        .task {
            catalog.loadIfNeeded()
            await loadRow()
        }
    }

    /// model_provider + slug aren't on MacBotPick — pull from the bots row so
    /// the picker pre-selects and the dirty check is accurate.
    private func loadRow() async {
        struct Row: Decodable {
            let model_provider: String?
            let slug: String?
        }
        if let row: Row = try? await SupabaseStack.shared
            .from("bots")
            .select("model_provider, slug")
            .eq("id", value: initial.id)
            .single()
            .execute()
            .value {
            modelProvider = row.model_provider
            initialModelProvider = row.model_provider
            slug = row.slug ?? ""
            initialSlug = row.slug ?? ""
        }
    }

    private func save() async {
        let prevVisibility = initial.visibility ?? "public_invite"
        let promoting = prevVisibility == "private" && visibility != "private"
        if promoting {
            confirmingPromote = true
            return
        }
        await persistUpdate()
    }

    private func persistUpdate() async {
        saving = true; defer { saving = false }
        do {
            // model_provider round-trips an explicit JSON null when cleared;
            // slug key is OMITTED when nil (private bots keep their synthetic
            // slug). Same encode contract as iOS.
            struct Update: Encodable {
                let display_name: String
                let model_id: String
                let model_provider: String?
                let visibility: String
                let tz: String?
                let slug: String?
                enum CodingKeys: String, CodingKey {
                    case display_name, model_id, model_provider, visibility, tz, slug
                }
                func encode(to encoder: Encoder) throws {
                    var c = encoder.container(keyedBy: CodingKeys.self)
                    try c.encode(display_name, forKey: .display_name)
                    try c.encode(model_id, forKey: .model_id)
                    try c.encode(model_provider, forKey: .model_provider)
                    try c.encode(visibility, forKey: .visibility)
                    try c.encode(tz, forKey: .tz)
                    if let slug { try c.encode(slug, forKey: .slug) }
                }
            }
            let payload = Update(
                display_name: displayName.trimmingCharacters(in: .whitespaces),
                model_id: modelSlug,
                model_provider: modelProvider,
                visibility: visibility,
                tz: visibility == "private" ? nil : TimeZone.current.identifier,
                slug: visibility == "private" ? nil : MacBotSlugRule.normalize(slug)
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
            let msg = error.localizedDescription
            if msg.contains("23505") || msg.lowercased().contains("duplicate") {
                self.error = "「\(MacBotSlugRule.normalize(slug))」这个标识已被占用,换一个。"
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

// MARK: - Add friend (handle path only)

/// macOS 加好友 — mirrors iOS `AddFriendSheet` + `AddFriendPreviewPage`, but
/// folded into a single page (no nav push): type a handle, 查找 resolves the
/// profile via GET /v1/friend-requests/lookup, then 发送申请 posts to
/// POST /v1/friend-requests. Same worker endpoints iOS uses; no scan entry
/// (no camera on Mac — gap logged).
struct MacAddFriendSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onAdded: () -> Void = {}

    enum Preview: Equatable {
        case idle
        case loading
        case loaded(userId: String, displayName: String, avatarPath: String?, avatarSeed: String)
        case notFound(message: String)
    }

    @State private var handleValue: String = ""
    @State private var preview: Preview = .idle
    @State private var verifyMessage: String = ""
    @State private var submitting = false
    @State private var error: String?
    @State private var successHint: String?

    private var trimmedHandle: String {
        handleValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canLookup: Bool { trimmedHandle.count >= 4 && !isLoading }
    private var isLoading: Bool { if case .loading = preview { return true }; return false }
    private var canSubmit: Bool {
        if submitting { return false }
        if case .loaded = preview { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Text("加好友").font(Theme.Fonts.headline)
                Spacer()
                Button("发送申请") { Task { await submit() } }
                    .disabled(!canSubmit)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Form {
                Section {
                    HStack(spacing: 8) {
                        TextField("号码 / 隐私号", text: $handleValue)
                            .onSubmit { Task { await lookup() } }
                        Button("查找") { Task { await lookup() } }
                            .disabled(!canLookup)
                    }
                }

                Section("对方") {
                    previewRow
                }

                if case .loaded = preview {
                    Section("验证信息（可选）") {
                        TextField("给对方留个话,会和申请一起送达", text: $verifyMessage, axis: .vertical)
                            .lineLimit(1...3)
                    }
                }

                if let successHint {
                    Section { Text(successHint).foregroundStyle(Theme.Palette.accent) }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    @ViewBuilder
    private var previewRow: some View {
        switch preview {
        case .idle:
            Text("输入对方的号码或隐私号,点「查找」。")
                .font(Theme.Fonts.footnote).foregroundStyle(Theme.Palette.inkMuted)
        case .loading:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("正在查找…").foregroundStyle(.secondary).font(Theme.Fonts.footnote)
            }
        case .loaded(let userId, let displayName, let avatarPath, let avatarSeed):
            HStack(spacing: 12) {
                MacContactAvatar(avatarPath: avatarPath, seed: avatarSeed, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName.isEmpty ? String(userId.prefix(8)) : displayName)
                        .font(Theme.Fonts.body)
                    Text("可以添加为好友").foregroundStyle(.secondary).font(Theme.Fonts.footnote)
                }
            }
        case .notFound(let message):
            Text(message).foregroundStyle(.red).font(Theme.Fonts.footnote)
        }
    }

    private func lookup() async {
        let value = trimmedHandle
        guard value.count >= 4 else { return }
        preview = .loading
        error = nil
        successHint = nil
        do {
            var comps = URLComponents(
                url: HostedConfig.environment.workerURL
                    .appendingPathComponent("v1/friend-requests/lookup"),
                resolvingAgainstBaseURL: false
            )!
            comps.queryItems = [URLQueryItem(name: "handleValue", value: value)]
            var req = URLRequest(url: comps.url!)
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 404 {
                preview = .notFound(message: "号码无效或已撤销")
                return
            }
            if !(200..<300).contains(http.statusCode) {
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let msg = (payload?["error"] as? String) ?? "HTTP \(http.statusCode)"
                preview = .notFound(message: msg)
                return
            }
            struct LookupResp: Decodable {
                let userId: String
                let displayName: String
                let avatarPath: String?
                let avatarSeed: String?
            }
            let r = try JSONDecoder().decode(LookupResp.self, from: data)
            preview = .loaded(
                userId: r.userId,
                displayName: r.displayName,
                avatarPath: r.avatarPath,
                avatarSeed: r.avatarSeed ?? r.userId
            )
        } catch {
            preview = .notFound(message: error.localizedDescription)
        }
    }

    private func submit() async {
        submitting = true; defer { submitting = false }
        error = nil
        successHint = nil
        do {
            var body: [String: Any] = ["handleValue": trimmedHandle]
            let trimmedMessage = verifyMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedMessage.isEmpty { body["message"] = trimmedMessage }

            let url = HostedConfig.environment.workerURL.appendingPathComponent("v1/friend-requests")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if !(200..<300).contains(http.statusCode) {
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                error = (payload?["error"] as? String) ?? "HTTP \(http.statusCode)"
                return
            }
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if (payload?["alreadyContacts"] as? Bool) == true {
                successHint = "你们已经是好友了"
            } else if (payload?["autoAccepted"] as? Bool) == true {
                successHint = "对方此前也加过你 — 已直接成为好友"
            } else {
                successHint = "发过去了 等对方同意"
            }
            Haptics.success()
            onAdded()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Add bot (invite-only info)

/// macOS 加机器人 — mirrors iOS `AddBotSheet`'s info page. Bots are invite-only
/// (decisions.md D1): you can't add one by typing a slug. On iOS the QR-scan /
/// universal-link flow resolves+redeems an invite token; Mac has no camera, so
/// this first pass shows the same explanation and skips the token path. Pasting
/// an invite link / deep-link handoff is a follow-up (gap logged).
struct MacAddBotSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Text("加机器人").font(Theme.Fonts.headline)
                Spacer()
                Color.clear.frame(width: 44)
            }
            .padding()

            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("机器人是邀请制的", systemImage: "person.badge.shield.checkmark")
                            .font(Theme.Fonts.headline)
                        Text("没法靠输入标识直接加机器人。让认识它的人把邀请链接或二维码发给你 —— 在手机上打开链接或扫码就能加入。")
                            .font(Theme.Fonts.footnote)
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                    .padding(.vertical, 4)
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 420, minHeight: 240)
    }
}
#endif
