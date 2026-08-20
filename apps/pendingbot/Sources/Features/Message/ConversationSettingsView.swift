import SwiftUI

// The old per-conversation "会话设置" page is gone — gear icon in the
// chat header now lands directly on the underlying entity's config:
//   • user_bot / self      → BotConfigView           (BotManagement.swift)
//   • user_user (human)    → ContactSettingsView     (this file, below)
//   • group                → GroupSettingsView       (group module)
//
// What this file still holds:
//   • LetterRecipient — recipient identity for the markdown letter sheet.
//     Used by LetterComposeSheet (Envelope module).
//   • LetterSettingsView — knobs for the bot's letter (envelope) loop.
//     Used by BotConfigView.
//   • ContactSettingsView — human 1:1 settings (备注 / 免打扰 / 删除好友).

/// Recipient profile for human-to-human letters. Drives the markdown
/// compose sheet and identifies the receiving side so the worker can
/// route the letter into their 来信 feed.
///
/// `Identifiable` via `userId` so the compose sheet can be driven by
/// `.sheet(item:)` from a stable parent without re-evaluating bool
/// triggers (which used to auto-dismiss the sheet on first open).
struct LetterRecipient: Equatable, Hashable, Identifiable {
    let userId: String
    let displayName: String
    var id: String { userId }
}

// MARK: - Contact (1:1 human) settings

/// 人类私聊的设置页 — 备注 / 免打扰 / 删除好友。所有设置都直接落在「这位
/// 朋友」上,不是会话级别。和 BotConfigView 在概念上对齐:就是「这个
/// 实体的配置」,而不是「这次会话的临时覆盖」。
///
/// 数据通路:
///   • GET    /v1/contacts/:id         — 读初始 alias + muted
///   • PATCH  /v1/contacts/:id         — 改 alias (留空清除)
///   • POST   /v1/contacts/:id/mute    — toggle muted (per-side)
///   • DELETE /v1/contacts/:id         — 删除好友 + 删除共享 user_user 会话
struct ContactSettingsView: View {
    let contactUserId: String
    /// 1:1 conversation id — used as the source for the 写信 entry.
    let conversationId: String
    /// Peer's own profile name — used as the placeholder in the 备注
    /// field and as the recipient label on the 写信 sheet.
    let initialDisplayName: String
    let initialAvatarPath: String?
    let initialAvatarSeed: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.api) private var api

    @State private var alias: String = ""
    @State private var letterRecipient: LetterRecipient?
    @State private var sendingLetter: Bool = false
    /// `alias` server-side as last seen. Used to gate the save button so
    /// pure-edits without changes don't fire a PATCH.
    @State private var loadedAlias: String? = nil
    @State private var muted: Bool = false
    @State private var loaded: Bool = false
    @State private var saving: Bool = false
    @State private var savingMute: Bool = false
    @State private var deleting: Bool = false
    @State private var confirmingDelete: Bool = false
    @State private var error: String?

    private var trimmedAlias: String {
        alias.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var aliasDirty: Bool {
        let normalized = trimmedAlias.isEmpty ? nil : trimmedAlias
        return normalized != loadedAlias
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    UserAvatar(seed: initialAvatarSeed, attachmentId: initialAvatarPath, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(initialDisplayName.isEmpty
                             ? String(contactUserId.prefix(8)) : initialDisplayName)
                            .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.Palette.ink)
                        Text("人类好友")
                            .font(Theme.Fonts.footnote)
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }

            Section {
                TextField(initialDisplayName.isEmpty ? "起个备注" : initialDisplayName,
                          text: $alias)
                    .platformAutocapitalization(false)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await saveAlias() } }
                if aliasDirty {
                    Button {
                        Task { await saveAlias() }
                    } label: {
                        HStack {
                            if saving { ProgressView() }
                            Text(saving ? "保存中…" : "保存备注")
                        }
                    }
                    .disabled(saving)
                }
            } header: {
                Text("备注")
            } footer: {
                Text("只有你看得到。")
            }

            Section {
                Button {
                    letterRecipient = LetterRecipient(
                        userId: contactUserId,
                        displayName: initialDisplayName.isEmpty
                            ? String(contactUserId.prefix(8)) : initialDisplayName
                    )
                } label: {
                    HStack {
                        Image(systemName: "envelope")
                        Text("给 TA 写信")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(Theme.Palette.ink)
                .disabled(sendingLetter)
            }

            Section {
                Toggle("免打扰", isOn: Binding(
                    get: { muted },
                    set: { newValue in
                        muted = newValue
                        Task { await applyMute(newValue) }
                    }
                ))
                .disabled(savingMute || !loaded)
            }

            Section {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    HStack {
                        if deleting { ProgressView() }
                        Text(deleting ? "删除中…" : "删除好友")
                    }
                }
                .disabled(deleting)
            } footer: {
                Text("会话历史会同步删除。")
            }

            if let error {
                Section {
                    Text(error).foregroundStyle(.red).font(Theme.Fonts.footnote)
                }
            }
        }
        .navigationTitle("好友设置")
        .inlineNavTitle()
        .task { await load() }
        .confirmationDialog(
            "确定要删除「\(initialDisplayName.isEmpty ? "这位好友" : initialDisplayName)」吗?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("删除好友", role: .destructive) {
                Task { await deleteContact() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会一并删除你们的聊天记录。")
        }
        .sheet(item: $letterRecipient) { recipient in
            LetterComposeSheet(recipient: recipient) { title, bodyMd in
                await sendLetter(title: title, bodyMd: bodyMd)
            }
            .tint(Theme.Palette.accent)
        }
    }

    // MARK: - Network

    private func load() async {
        loaded = false
        do {
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/contacts/")
                .appendingPathComponent(contactUserId)
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            struct Payload: Decodable {
                let alias: String?
                let muted: Bool
            }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            self.loadedAlias = payload.alias
            self.alias = payload.alias ?? ""
            self.muted = payload.muted
        } catch {
            // Silently fall through — the page still works, the user will
            // just be editing from blank defaults. A loud alert here would
            // be intrusive for a settings page.
        }
        loaded = true
    }

    private func saveAlias() async {
        guard aliasDirty, !saving else { return }
        saving = true; defer { saving = false }
        error = nil
        do {
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/contacts/")
                .appendingPathComponent(contactUserId)
            var req = URLRequest(url: url)
            req.httpMethod = "PATCH"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let normalized = trimmedAlias.isEmpty ? NSNull() : (trimmedAlias as Any)
            req.httpBody = try JSONSerialization.data(
                withJSONObject: ["alias": normalized])
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                error = (payload?["error"] as? String) ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"
                return
            }
            Haptics.success()
            loadedAlias = trimmedAlias.isEmpty ? nil : trimmedAlias
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func applyMute(_ newValue: Bool) async {
        savingMute = true; defer { savingMute = false }
        do {
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/contacts/")
                .appendingPathComponent(contactUserId)
                .appendingPathComponent("mute")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["muted": newValue])
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                // Revert the toggle to match server reality on failure.
                muted = !newValue
                throw URLError(.badServerResponse)
            }
            Haptics.tap()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func sendLetter(title: String?, bodyMd: String) async -> Bool {
        guard let api else {
            self.error = "网络未就绪"
            return false
        }
        sendingLetter = true; defer { sendingLetter = false }
        error = nil
        do {
            _ = try await api.envelopeSendLetter(
                conversationId: conversationId,
                recipientUserId: contactUserId,
                title: title,
                bodyMd: bodyMd
            )
            Haptics.success()
            return true
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
            return false
        }
    }

    private func deleteContact() async {
        deleting = true; defer { deleting = false }
        error = nil
        do {
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/contacts/")
                .appendingPathComponent(contactUserId)
            var req = URLRequest(url: url)
            req.httpMethod = "DELETE"
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                error = (payload?["error"] as? String) ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"
                return
            }
            Haptics.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 写信设置 / Letter settings

/// 写信设置 — 来信(Envelopes)的探索/协作模型、检索引擎、轮数与历史
/// 预算。Edited from BotConfigView (机器人级别默认)。
struct LetterSettingsView: View {
    @Binding var envelope: EnvelopeSettings
    /// 只读模式 — 公有 / 非自有机器人。默认 true(自有机器人可改)。
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
                          value: envelope.explorerModel.isEmpty
                              ? "默认(跟随系统)"
                              : shortSlug(envelope.explorerModel)) {
                    pickerTarget = .explorer
                }
                pickerRow(icon: "person.2.crop.square.stack", title: "协作模型",
                          value: envelope.collaboratorModel.map(shortSlug) ?? "默认(跟随系统)") {
                    pickerTarget = .collaborator
                }
            } header: {
                Text("模型")
            } footer: {
                Text("探索模型驱动来信的研究循环;协作模型在每个非研究轮做点评。「默认(跟随系统)」= 用后台配置的系统默认模型。")
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
                Text("「聊天记录占用」限制聊天历史与框架提示词占主模型上下文窗口的比例,余下留给研究轮。")
            }
        }
        .navigationTitle("写信设置")
        .inlineNavTitle()
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
                allowsClear: true,
                clearLabel: "跟随系统默认",
                onPick: { picked in
                    switch target {
                    case .explorer:
                        // Clear ("" ) = follow the server's envelopeExplorer role.
                        envelope.explorerModel = picked?.slug ?? ""
                    case .collaborator:
                        // Clear (nil) = follow the server's envelopeCollaborator role.
                        envelope.collaboratorModel = (picked?.slug).flatMap { $0.isEmpty ? nil : $0 }
                    }
                    pickerTarget = nil
                }
            )
            .platformDragIndicator()
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
                    .font(Theme.Fonts.caption)
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
