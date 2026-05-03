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
                        ModelPickerButton(slug: $modelSlug, placeholder: "选择模型")
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
                creator_id: row.creator_id
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
    @State private var visibility: String = "private"
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
                            ModelPickerButton(slug: $modelSlug, placeholder: "选择模型")
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
        }
    }

    /// True when there's actually something to save vs the row we loaded.
    private var dirty: Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        if isPrivate {
            if trimmed != initial.display_name { return true }
            if modelSlug != (initial.model_id ?? "") { return true }
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
            struct Update: Encodable {
                let display_name: String?
                let model_id: String?
                let visibility: String?
            }
            // For public bots the trigger blocks anything except visibility,
            // so we only send the changed columns.
            let payload: Update
            if visibility == "private" {
                // Private edit (no promotion) → keep updating identity columns.
                payload = Update(
                    display_name: displayName.trimmingCharacters(in: .whitespaces),
                    model_id: modelSlug,
                    visibility: visibility
                )
            } else if isPrivate {
                // Promotion: snapshot identity + flip visibility in one UPDATE.
                payload = Update(
                    display_name: displayName.trimmingCharacters(in: .whitespaces),
                    model_id: modelSlug,
                    visibility: visibility
                )
            } else {
                // Public → public visibility flip; identity is frozen.
                payload = Update(display_name: nil, model_id: nil, visibility: visibility)
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
    @State private var error: String?

    struct InviteRow: Identifiable, Hashable {
        let user_id: String
        let invited_at: String?
        var id: String { user_id }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("被邀请人的号码 (handle)", text: $addingHandle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Button(adding ? "加…" : "邀请") {
                        Task { await addInvite() }
                    }
                    .disabled(adding || addingHandle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("把对方个人页里的号码贴进来。号码可以撤销。")
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
                            Text(String(row.user_id.prefix(8)))
                                .font(Theme.Fonts.monoSmall)
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
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            struct Decoded: Decodable {
                let user_id: String
                let invited_at: String?
            }
            let rows: [Decoded] = try await SupabaseStack.shared
                .from("bot_invites")
                .select("user_id, invited_at")
                .eq("bot_id", value: botId)
                .order("invited_at", ascending: false)
                .execute()
                .value
            invites = rows.map { InviteRow(user_id: $0.user_id, invited_at: $0.invited_at) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func addInvite() async {
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
