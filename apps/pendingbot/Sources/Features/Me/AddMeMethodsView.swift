import SwiftUI
import Supabase

/// 加我为好友的方式 — 两部分:
///   1. 二维码名片 — QR-kind handle,卡片内同时显示预置 ID (kind='id')
///      (跨平台 — 生成侧走 CoreImage `QRCode` shim;扫码侧仍 iOS 限定)
///   2. 我的隐私号 — 用户自定义的 handle (kind='number'), 最多 3 个
struct AddMeMethodsView: View {
    var body: some View {
        List {
            QRCardSection()
            HandlesSection()
        }
        .platformListStyle()
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle("加我为好友的方式")
        .inlineNavTitle()
    }
}

// MARK: - QR card section

/// Embeds the shared `MyQRBusinessCard` so the inline section here
/// matches the Friends-tab QR sheet exactly. No section header /
/// footer — the card is self-explanatory. Cross-platform: the card
/// generates via the CoreImage `QRCode` shim on both iOS and macOS.
private struct QRCardSection: View {
    var body: some View {
        Section {
            MyQRBusinessCard()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
        }
    }
}

// MARK: - Handles (number-kind) section — API-key-management style

private struct HandleRow: Identifiable, Hashable {
    let id: String
    let value: String
    let label: String?
    let kind: String
    let is_active: Bool
    let created_at: String?
}

private struct HandleRowDecoded: Decodable {
    let id: String
    let value: String
    let label: String?
    let kind: String
    let is_active: Bool
    let created_at: String?
}

private struct HandlesSection: View {
    @State private var handles: [HandleRow] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showCreate = false

    private var activeCount: Int { handles.filter(\.is_active).count }
    private var atLimit: Bool { activeCount >= 3 }

    var body: some View {
        Group {
            Section {
                if handles.isEmpty {
                    if loading {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("加载中…").foregroundStyle(.secondary)
                        }
                    } else {
                        Text("还没创建过隐私号，点右上角「新建」")
                            .foregroundStyle(.secondary)
                            .font(Theme.Fonts.footnote)
                    }
                } else {
                    ForEach(handles) { h in
                        NavigationLink {
                            HandleContactsView(
                                handle: h,
                                onRevoke: { Task { await revoke(h.id); await load() } }
                            )
                        } label: {
                            HandleCardRow(handle: h)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("我的隐私号")
                    Spacer()
                    Button {
                        showCreate = true
                    } label: {
                        Label("新建", systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                            .font(Theme.Fonts.footnote.weight(.medium))
                    }
                    .disabled(atLimit)
                    .textCase(nil)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. 别人可以通过 ID 或者隐私号添加你为好友")
                    Text("2. 你在这里最多可以同时有三个隐私号")
                    Text("3. 你可以看别人通过哪个号加的你")
                    Text("4. 你可以随时创建隐私号，随时更改、撤销你自己创建的隐私号")
                    Text("5. 你同意好友申请后别人可看到你的真实 ID")
                }
            }

            if let error {
                Section {
                    Text(error).foregroundStyle(.red).font(Theme.Fonts.footnote)
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showCreate) {
            MintHandleSheet(activeCount: activeCount) { reload in
                if reload { Task { await load() } }
            }
        }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            let rows: [HandleRowDecoded] = try await SupabaseStack.shared
                .from("user_handles")
                .select("id, value, label, kind, is_active, created_at")
                .eq("kind", value: "number")
                .order("created_at", ascending: false)
                .execute()
                .value
            self.handles = rows.map {
                HandleRow(id: $0.id, value: $0.value, label: $0.label,
                          kind: $0.kind, is_active: $0.is_active,
                          created_at: $0.created_at)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func revoke(_ id: String) async {
        do {
            try await SupabaseStack.authedClient()
                .from("user_handles")
                .update(["is_active": false])
                .eq("id", value: id)
                .execute()
            Haptics.tap()
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Handle row (card)

private struct HandleCardRow: View {
    let handle: HandleRow

    private var titleText: String {
        if let l = handle.label, !l.isEmpty { return l }
        return "未命名"
    }

    private var relativeCreated: String? {
        guard let raw = handle.created_at,
              let date = ServerTimestamp.parse(raw) else { return nil }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titleText)
                .font(Theme.Fonts.bodyEmphasized)
                .foregroundStyle(handle.is_active ? Theme.Palette.ink : Theme.Palette.inkMuted)
                .lineLimit(1)

            Text(handle.value)
                .font(Theme.Fonts.monoSmall)
                .foregroundStyle(handle.is_active ? Theme.Palette.ink : Theme.Palette.inkMuted)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 6) {
                if let t = relativeCreated {
                    Text("创建于 \(t)")
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("·").foregroundStyle(.secondary).font(Theme.Fonts.footnote)
                StatusPill(active: handle.is_active)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct StatusPill: View {
    let active: Bool
    var body: some View {
        Text(active ? "启用中" : "已撤销")
            .font(Theme.Fonts.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(active ? Theme.Palette.accentBg : Theme.Palette.surfaceMuted)
            )
            .foregroundStyle(active ? Theme.Palette.accent : Theme.Palette.inkMuted)
    }
}

// MARK: - Mint sheet

private struct MintHandleSheet: View {
    let activeCount: Int
    /// Called on dismiss; `reload == true` if a row was successfully minted.
    let onClose: (_ reload: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newLabel: String = ""
    @State private var newValue: String = ""
    @State private var error: String?
    @State private var minting = false

    private let valueFormat = #"^[A-Za-z0-9_-]{4,20}$"#
    private var trimmedValue: String { newValue.trimmingCharacters(in: .whitespaces) }
    private var trimmedLabel: String { newLabel.trimmingCharacters(in: .whitespaces) }
    private var valueIsValid: Bool {
        trimmedValue.isEmpty
            || trimmedValue.range(of: valueFormat, options: .regularExpression) != nil
    }
    private var atLimit: Bool { activeCount >= 3 }
    private var submitTitle: String { trimmedValue.isEmpty ? "随机生成" : "添加" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("自定义隐私号（留空则随机生成）", text: $newValue)
                        .platformAutocapitalization()
                        .autocorrectionDisabled(true)
                        .font(Theme.Fonts.monoSmall)
                    TextField("备注（如 'blog'）", text: $newLabel)
                } footer: {
                    if !valueIsValid {
                        Text("格式：4-20 位字母 / 数字 / _ / -").foregroundStyle(.red)
                    } else if atLimit {
                        Text("已达到 3 个上限，先撤销一个再来")
                    } else {
                        Text("隐私号全局唯一。备注只你自己能看到。")
                    }
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).font(Theme.Fonts.footnote)
                    }
                }
            }
            .navigationTitle("新建隐私号")
            .inlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .platformLeading) {
                    Button("取消") {
                        onClose(false)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .platformTrailing) {
                    Button(submitTitle) {
                        Task { await mint() }
                    }
                    .disabled(atLimit || !valueIsValid || minting)
                }
            }
        }
    }

    private func mint() async {
        guard let userId = AccountStore.shared.current?.id else { return }
        minting = true; defer { minting = false }
        let custom = trimmedValue
        let value: String
        if custom.isEmpty {
            let alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
            value = String((0..<10).compactMap { _ in alphabet.randomElement() })
        } else {
            value = custom
        }
        struct Insert: Encodable {
            let user_id: String
            let value: String
            let label: String?
            let kind: String
        }
        do {
            try await SupabaseStack.authedClient()
                .from("user_handles")
                .insert(Insert(user_id: userId, value: value,
                               label: trimmedLabel.isEmpty ? nil : trimmedLabel,
                               kind: "number"))
                .execute()
            Haptics.success()
            onClose(true)
            dismiss()
        } catch {
            let raw = error.localizedDescription
            if raw.contains("duplicate") || raw.contains("unique") {
                self.error = "隐私号已被占用，换一个"
            } else if raw.contains("handles_value_format") {
                self.error = "格式不符（4-20 位字母 / 数字 / _ / -）"
            } else if raw.contains("handle limit") {
                self.error = "最多 3 个隐私号，先撤销一个再来"
            } else {
                self.error = raw
            }
        }
    }
}

// MARK: - Per-handle detail (friend list filtered by added_via_handle_id)

/// 点击某个隐私号进入的详情页 —— 上面是号码本身 + 复制 / 撤销;下面是
/// 通过此号加你为好友的人的列表(GET /v1/contacts?via_handle_id=…)。
private struct HandleContactsView: View {
    let handle: HandleRow
    let onRevoke: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var contacts: [FriendsTabView.HumanPick] = []
    @State private var loading = false
    @State private var error: String?
    @State private var copied = false
    @State private var confirmRevoke = false

    private var titleText: String {
        if let l = handle.label, !l.isEmpty { return l }
        return "未命名"
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Text(handle.value)
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(handle.is_active ? Theme.Palette.ink : Theme.Palette.inkMuted)
                        .textSelection(.enabled)
                        .lineLimit(1)
                    Button {
                        Clipboard.copy(handle.value)
                        Haptics.tap()
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            await MainActor.run { copied = false }
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(Theme.Fonts.footnote)
                            .foregroundStyle(copied ? Theme.Palette.accent : Theme.Palette.inkMuted)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    StatusPill(active: handle.is_active)
                }
                .padding(.vertical, 2)
                if handle.is_active {
                    Button(role: .destructive) {
                        confirmRevoke = true
                    } label: {
                        Label("撤销此隐私号", systemImage: "xmark.circle")
                    }
                }
            } header: {
                Text(titleText)
            } footer: {
                if !handle.is_active {
                    Text("此号已撤销,新的好友申请会被拒。已通过它加上的好友不受影响。")
                }
            }

            Section {
                if loading && contacts.isEmpty {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("加载中…").foregroundStyle(.secondary)
                    }
                } else if let error {
                    Text(error).foregroundStyle(.red).font(Theme.Fonts.footnote)
                } else if contacts.isEmpty {
                    Text("还没有人通过这个号加过你")
                        .foregroundStyle(.secondary)
                        .font(Theme.Fonts.footnote)
                } else {
                    ForEach(contacts) { c in
                        HStack(spacing: 10) {
                            UserAvatar(seed: c.avatarSeed, attachmentId: c.avatarPath, size: 32)
                            Text(c.rowName)
                                .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.Palette.ink)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("通过此号加你的好友")
            }
        }
        .platformListStyle()
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle(titleText)
        .inlineNavTitle()
        .task { await load() }
        .confirmationDialog(
            "撤销「\(titleText)」?",
            isPresented: $confirmRevoke,
            titleVisibility: .visible
        ) {
            Button("撤销", role: .destructive) {
                onRevoke()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("撤销后别人无法用这个号给你发好友申请。已是好友的人不受影响。")
        }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            contacts = try await ContactsAPI.fetchContacts(viaHandleId: handle.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
