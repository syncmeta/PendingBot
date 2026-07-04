import SwiftUI
import Supabase

/// User-customized skills list, scoped to one provider (OpenAI native
/// or OpenRouter). Opens from 「我 → 机器人能力扩展 → <provider> →
/// Skills」. System presets (owner_id IS NULL) are admin-managed in
/// the Board and stay hidden here.
struct SkillsView: View {
    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss

    let provider: BotProvider

    @State private var skills: [SkillSummary] = []
    @State private var loading = true
    @State private var error: String?
    @State private var editingSkill: SkillDetail?
    @State private var forkingFrom: SkillDetail?
    @State private var creatingNew = false
    @State private var pendingToggle: Set<String> = []

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    headerCard
                    if loading {
                        ProgressView().tint(Theme.Palette.accent)
                            .padding(.top, 20)
                    } else if skills.isEmpty {
                        Text("还没有自定义 Skill — 点右上 + 新建")
                            .font(Theme.Fonts.footnote)
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .padding(.top, 20)
                    } else {
                        ForEach(skills) { skill in
                            skillCard(skill)
                        }
                    }
                }
                .padding(.horizontal, Theme.Metrics.gutter)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .refreshable { await load() }
        }
        .inlineNavTitle()
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Skills · \(provider.displayName)")
                    .font(Theme.Fonts.serif(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
            }
            ToolbarItem(placement: .platformTrailing) {
                Button {
                    creatingNew = true
                    Haptics.tap()
                } label: { Image(systemName: "plus") }
                .foregroundStyle(Theme.Palette.accent)
            }
        }
        .task { await load() }
        .sheet(item: $editingSkill) { detail in
            SkillEditorSheet(mode: .edit(detail), provider: provider) { Task { await load() } }
                .tint(Theme.Palette.accent)
                .platformDragIndicator()
        }
        .sheet(item: $forkingFrom) { source in
            SkillEditorSheet(mode: .fork(source), provider: provider) { Task { await load() } }
                .tint(Theme.Palette.accent)
                .platformDragIndicator()
        }
        .sheet(isPresented: $creatingNew) {
            SkillEditorSheet(mode: .create, provider: provider) { Task { await load() } }
                .tint(Theme.Palette.accent)
                .platformDragIndicator()
        }
        .alert("出错", isPresented: .constant(error != nil)) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    // ── Cards ──────────────────────────────────────────────────────────────

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("启用后会拼进系统提示词，使用 \(provider.displayName) 的机器人按需调用。")
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.Palette.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func skillCard(_ skill: SkillSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(Theme.Fonts.rounded(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(1)
                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(Theme.Fonts.footnote)
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(
                    get: { skill.enabled },
                    set: { newVal in Task { await toggle(skill, enabled: newVal) } }
                ))
                .labelsHidden()
                .tint(Theme.Palette.accent)
                .disabled(pendingToggle.contains(skill.id))
            }

            HStack(spacing: 10) {
                Text("\(skill.body_length) 字符")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                Spacer(minLength: 0)
                Button("编辑") {
                    Task { await openEditor(skill) }
                }
                .font(Theme.Fonts.rounded(size: 12, weight: .medium))
                .foregroundStyle(Theme.Palette.accent)
                .buttonStyle(.plain)
                Button("删除") {
                    Task { await delete(skill) }
                }
                .font(Theme.Fonts.rounded(size: 12, weight: .medium))
                .foregroundStyle(Theme.Palette.danger)
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .strokeBorder(skill.enabled ? Theme.Palette.accent.opacity(0.5)
                                            : Theme.Palette.hairline,
                              lineWidth: skill.enabled ? 1.0 : 0.5)
        )
    }

    // ── Data ────────────────────────────────────────────────────────────────

    private func load() async {
        loading = true; defer { loading = false }
        guard let userId = AccountStore.shared.current?.id else {
            self.skills = []
            return
        }
        do {
            // Only user-owned skills in this provider scope — presets
            // (owner_id IS NULL) are admin-managed in the Board.
            struct SkillRow: Decodable {
                let id: String
                let frontmatter: SkillFrontmatter
                let body_md: String
                let updated_at: String?
            }
            struct SkillFrontmatter: Decodable {
                let name: String?
                let description: String?
            }
            struct SubRow: Decodable { let skill_id: String }

            async let skillRows: [SkillRow] = SupabaseStack.shared
                .from("skills")
                .select("id, frontmatter, body_md, updated_at")
                .eq("owner_id", value: userId)
                .eq("provider", value: provider.rawValue)
                .order("updated_at", ascending: false)
                .execute()
                .value
            async let subRows: [SubRow] = SupabaseStack.shared
                .from("skill_subscriptions")
                .select("skill_id")
                .is("conversation_id", value: nil)
                .execute()
                .value

            let subscribed = Set(try await subRows.map(\.skill_id))
            self.skills = try await skillRows.map { row in
                SkillSummary(
                    id: row.id,
                    name: row.frontmatter.name ?? "未命名",
                    description: row.frontmatter.description ?? "",
                    enabled: subscribed.contains(row.id),
                    source: nil,
                    source_url: nil,
                    license: nil,
                    is_preset: false,
                    body_length: row.body_md.count,
                    updated_at: row.updated_at.map { ServerTimestamp.epochSeconds($0, default: 0) } ?? 0
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Toggle global subscription (`skill_subscriptions` row with
    /// conversation_id IS NULL). Per-conv subscriptions surface in the
    /// in-chat skills chip — not this screen.
    private func toggle(_ skill: SkillSummary, enabled: Bool) async {
        guard let userId = AccountStore.shared.current?.id else { return }
        pendingToggle.insert(skill.id)
        defer { pendingToggle.remove(skill.id) }
        do {
            if enabled {
                struct SubInsert: Encodable {
                    let user_id: String
                    let skill_id: String
                    let conversation_id: String? = nil
                }
                try await SupabaseStack.authedClient()
                    .from("skill_subscriptions")
                    .insert(SubInsert(user_id: userId, skill_id: skill.id))
                    .execute()
            } else {
                try await SupabaseStack.authedClient()
                    .from("skill_subscriptions")
                    .delete()
                    .eq("user_id", value: userId)
                    .eq("skill_id", value: skill.id)
                    .is("conversation_id", value: nil)
                    .execute()
            }
            // Optimistically update local row.
            if let idx = skills.firstIndex(where: { $0.id == skill.id }) {
                skills[idx] = SkillSummary(
                    id: skill.id, name: skill.name, description: skill.description,
                    enabled: enabled, source: skill.source, source_url: skill.source_url,
                    license: skill.license, is_preset: skill.is_preset,
                    body_length: skill.body_length, updated_at: skill.updated_at
                )
            }
            Haptics.tap()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func openEditor(_ skill: SkillSummary) async {
        if let detail = await fetchDetail(skill) {
            self.editingSkill = detail
        }
    }

    /// Fetch the source preset's body, then drop the user into the editor in
    /// fork mode. The save path INSERTs a fresh row with `forked_from`
    /// pointing at the original — preserving the lineage trail.
    private func openFork(_ skill: SkillSummary) async {
        if let detail = await fetchDetail(skill) {
            self.forkingFrom = detail
        }
    }

    private func fetchDetail(_ skill: SkillSummary) async -> SkillDetail? {
        do {
            struct Row: Decodable {
                let id: String
                let frontmatter: FM
                let body_md: String
                let owner_id: String?
                let updated_at: String?
                struct FM: Decodable { let name: String?; let description: String? }
            }
            let row: Row = try await SupabaseStack.shared
                .from("skills")
                .select("id, frontmatter, body_md, owner_id, updated_at")
                .eq("id", value: skill.id)
                .single()
                .execute()
                .value
            let updatedSecs = row.updated_at.map { ServerTimestamp.epochSeconds($0, default: 0) } ?? 0
            return SkillDetail(
                id: row.id,
                name: row.frontmatter.name ?? "未命名",
                description: row.frontmatter.description ?? "",
                enabled: skill.enabled,
                source: nil, source_url: nil, license: nil,
                is_preset: row.owner_id == nil,
                body_length: row.body_md.count,
                updated_at: updatedSecs,
                body: row.body_md
            )
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func delete(_ skill: SkillSummary) async {
        do {
            try await SupabaseStack.authedClient()
                .from("skills")
                .delete()
                .eq("id", value: skill.id)
                .execute()
            skills.removeAll { $0.id == skill.id }
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// ── Editor sheet ────────────────────────────────────────────────────────────

/// Used both for editing an existing skill (mode: .edit) and creating a new
/// one (mode: .create or .createPrefilled with a body draft from a chat
/// bubble's "保存为技能" action).
struct SkillEditorSheet: View {
    enum Mode {
        case create
        case createPrefilled(body: String)
        case edit(SkillDetail)
        /// Fork a preset: pre-fills name/description/body from the source and
        /// stamps `forked_from = source.id` on the inserted row.
        case fork(SkillDetail)
    }

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    /// Provider scope to stamp on the row on create/fork. Defaults to
    /// `.openrouter` so the in-chat "保存为技能" path (which doesn't
    /// know the bot's provider) stays consistent with the legacy
    /// route. For .edit the value is ignored — provider is fixed.
    var provider: BotProvider = .openrouter
    var onSaved: () -> Void = {}

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var skillBody: String = ""
    @State private var enabled: Bool = true
    @State private var saving = false
    @State private var error: String?

    private var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var titleText: String {
        switch mode {
        case .edit: return "编辑技能"
        case .fork: return "Fork 技能"
        case .create, .createPrefilled: return "新建技能"
        }
    }

    private var saveActionLabel: String {
        switch mode {
        case .edit: return "保存"
        case .fork: return "Fork"
        case .create, .createPrefilled: return "创建"
        }
    }

    private var forkSourceId: String? {
        if case .fork(let s) = mode { return s.id }
        return nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 22) {
                        nameCard
                        descriptionCard
                        bodyCard
                        enabledCard
                    }
                    .padding(.horizontal, Theme.Metrics.gutter)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
            }
            .inlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(titleText)
                        .font(Theme.Fonts.serif(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView().tint(Theme.Palette.accent)
                    } else {
                        Button(saveActionLabel) {
                            Task { await save() }
                        }
                        .foregroundStyle(canSave ? Theme.Palette.accent
                                                 : Theme.Palette.inkMuted.opacity(0.5))
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                    }
                }
            }
            .alert("出错", isPresented: .constant(error != nil)) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
            .onAppear { hydrate() }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var nameCard: some View {
        labeledCard(title: "名称", footer: "小写 + 连字符，例如 my-skill") {
            TextField("my-skill", text: $name)
                .platformAutocapitalization()
                .autocorrectionDisabled(true)
                .font(Theme.Fonts.rounded(size: 15, weight: .regular))
                .foregroundStyle(Theme.Palette.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(roundedFieldBackground)
        }
    }

    private var descriptionCard: some View {
        labeledCard(title: "描述", footer: "一句话告诉机器人什么时候用这个技能") {
            TextField("什么时候用这个技能", text: $description)
                .font(Theme.Fonts.rounded(size: 15, weight: .regular))
                .foregroundStyle(Theme.Palette.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(roundedFieldBackground)
        }
    }

    private var bodyCard: some View {
        labeledCard(title: "正文（Markdown）", footer: "启用后，正文会作为技能指令拼进系统提示词。") {
            TextEditor(text: $skillBody)
                .font(Theme.Fonts.monospaced(size: 14))
                .foregroundStyle(Theme.Palette.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 220)
                .padding(10)
                .background(roundedFieldBackground)
        }
    }

    private var enabledCard: some View {
        labeledCard(title: nil, footer: nil) {
            Toggle(isOn: $enabled) {
                Text("立即启用")
                    .font(Theme.Fonts.rounded(size: 15, weight: .medium))
                    .foregroundStyle(Theme.Palette.ink)
            }
            .tint(Theme.Palette.accent)
        }
    }

    private var roundedFieldBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.Palette.canvas)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func labeledCard<Content: View>(title: String?, footer: String?,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(Theme.Fonts.serif(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .padding(.leading, 4)
            }
            content()
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                        .fill(Theme.Palette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                        .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                )
            if let footer {
                Text(footer)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .padding(.horizontal, 4)
            }
        }
    }

    // ── Lifecycle ──────────────────────────────────────────────────────────

    private func hydrate() {
        switch mode {
        case .create:
            // Empty form, enabled by default.
            break
        case .createPrefilled(let draft):
            skillBody = draft
        case .edit(let detail):
            name = detail.name
            description = detail.description
            skillBody = detail.body
            enabled = detail.enabled
        case .fork(let source):
            // Suffix the source's name so the fork doesn't collide visually
            // with the preset in the list. User is free to rename before save.
            name = "\(source.name)-fork"
            description = source.description
            skillBody = source.body
            enabled = true
        }
    }

    private func save() async {
        guard canSave, let userId = AccountStore.shared.current?.id else { return }
        saving = true; defer { saving = false }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        struct Frontmatter: Codable {
            let name: String
            let description: String
        }
        let fm = Frontmatter(name: trimmedName, description: description)

        do {
            switch mode {
            case .create, .createPrefilled, .fork:
                struct Insert: Encodable {
                    let owner_id: String
                    let frontmatter: Frontmatter
                    let body_md: String
                    let visibility = "private"
                    let provider: String
                    let forked_from: String?
                }
                struct InsertedId: Decodable { let id: String }
                let inserted: InsertedId = try await SupabaseStack.authedClient()
                    .from("skills")
                    .insert(Insert(
                        owner_id: userId,
                        frontmatter: fm,
                        body_md: skillBody,
                        provider: provider.rawValue,
                        forked_from: forkSourceId
                    ))
                    .select("id")
                    .single()
                    .execute()
                    .value
                if enabled {
                    struct SubInsert: Encodable {
                        let user_id: String
                        let skill_id: String
                        let conversation_id: String? = nil
                    }
                    try await SupabaseStack.authedClient()
                        .from("skill_subscriptions")
                        .insert(SubInsert(user_id: userId, skill_id: inserted.id))
                        .execute()
                }
            case .edit(let detail):
                struct Patch: Encodable {
                    let frontmatter: Frontmatter
                    let body_md: String
                }
                try await SupabaseStack.authedClient()
                    .from("skills")
                    .update(Patch(frontmatter: fm, body_md: skillBody))
                    .eq("id", value: detail.id)
                    .execute()
                // Sync the global subscription state with the editor toggle.
                if enabled && !detail.enabled {
                    struct SubInsert: Encodable {
                        let user_id: String
                        let skill_id: String
                        let conversation_id: String? = nil
                    }
                    _ = try? await SupabaseStack.authedClient()
                        .from("skill_subscriptions")
                        .insert(SubInsert(user_id: userId, skill_id: detail.id))
                        .execute()
                } else if !enabled && detail.enabled {
                    _ = try? await SupabaseStack.authedClient()
                        .from("skill_subscriptions")
                        .delete()
                        .eq("user_id", value: userId)
                        .eq("skill_id", value: detail.id)
                        .is("conversation_id", value: nil)
                        .execute()
                }
            }
            Haptics.success()
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
