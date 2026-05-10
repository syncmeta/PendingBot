import SwiftUI
import Supabase

/// 加我为好友的方式 — 三部分:
///   1. 二维码 (QR-kind handle)
///   2. 我的 ID — 注册时系统预置的不可更改 handle (kind='id')
///   3. 我的隐私号 — 用户自定义的 handle (kind='number'), 最多 3 个
struct AddMeMethodsView: View {
    var body: some View {
        List {
            QRCardSection()
            PresetIdSection()
            HandlesSection()
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle("加我为好友的方式")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - QR card section

/// Embeds the shared `MyQRBusinessCard` so the inline section here
/// matches the Friends-tab QR sheet exactly. No section header /
/// footer — the card is self-explanatory.
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

// MARK: - Preset ID (id-kind) section — read-only

/// 系统注册时预置的 ID handle (kind='id')。每个用户恰好一个,值不可更改、
/// 不可撤销。展示用一行 + 复制按钮,没有「⋯」菜单。
private struct PresetIdSection: View {
    @State private var presetValue: String?
    @State private var loading = false
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        Section {
            if let v = presetValue {
                HStack(spacing: 8) {
                    Text(v)
                        .font(Theme.Fonts.monoSmall)
                        .foregroundStyle(Theme.Palette.ink)
                        .textSelection(.enabled)
                        .lineLimit(1)
                    Button {
                        UIPasteboard.general.string = v
                        Haptics.tap()
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            await MainActor.run { copied = false }
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.footnote)
                            .foregroundStyle(copied ? Theme.Palette.accent : Theme.Palette.inkMuted)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.vertical, 4)
            } else if loading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("加载中…").foregroundStyle(.secondary)
                }
            } else if let error {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
        } header: {
            Text("我的 ID（不可更改）")
        }
        .task { await load() }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            let rows: [HandleRowDecoded] = try await SupabaseStack.shared
                .from("user_handles")
                .select("id, value, label, kind, is_active, created_at")
                .eq("kind", value: "id")
                .limit(1)
                .execute()
                .value
            self.presetValue = rows.first?.value
        } catch {
            self.error = error.localizedDescription
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
                            .font(.footnote)
                    }
                } else {
                    ForEach(handles) { h in
                        HandleCardRow(
                            handle: h,
                            onRevoke: { Task { await revoke(h.id) } }
                        )
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
                            .font(.footnote.weight(.medium))
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
                    Text(error).foregroundStyle(.red).font(.footnote)
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
            try await SupabaseStack.shared
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
    let onRevoke: () -> Void

    @State private var copied = false

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
            HStack(alignment: .firstTextBaseline) {
                Text(titleText)
                    .font(Theme.Fonts.bodyEmphasized)
                    .foregroundStyle(handle.is_active ? Theme.Palette.ink : Theme.Palette.inkMuted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Menu {
                    Button {
                        copy()
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    if handle.is_active {
                        Button(role: .destructive) {
                            onRevoke()
                        } label: {
                            Label("撤销", systemImage: "xmark.circle")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Text(handle.value)
                    .font(Theme.Fonts.monoSmall)
                    .foregroundStyle(handle.is_active ? Theme.Palette.ink : Theme.Palette.inkMuted)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    copy()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.footnote)
                        .foregroundStyle(copied ? Theme.Palette.accent : Theme.Palette.inkMuted)
                }
                .buttonStyle(.plain)
                .disabled(!handle.is_active)
                Spacer()
            }

            HStack(spacing: 6) {
                if let t = relativeCreated {
                    Text("创建于 \(t)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("·").foregroundStyle(.secondary).font(.footnote)
                StatusPill(active: handle.is_active)
            }
        }
        .padding(.vertical, 4)
    }

    private func copy() {
        UIPasteboard.general.string = handle.value
        Haptics.tap()
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { copied = false }
        }
    }
}

private struct StatusPill: View {
    let active: Bool
    var body: some View {
        Text(active ? "启用中" : "已撤销")
            .font(.caption.weight(.medium))
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
                        .textInputAutocapitalization(.never)
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
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle("新建隐私号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        onClose(false)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
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
            try await SupabaseStack.shared
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
