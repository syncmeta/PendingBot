import SwiftUI
import Supabase

/// "Number" handle management — moved out of the Friends tab into 我.
/// Each handle is a shareable code. Generate multiple, label them, revoke
/// when needed. The QR-kind handle has its own surface (FriendsTabView's
/// QR sheet); this view manages the typed-number kind.
struct MyHandlesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var handles: [HandleRow] = []
    @State private var loading = false
    @State private var newLabel: String = ""
    @State private var newValue: String = ""
    @State private var error: String?

    private let valueFormat = #"^[A-Za-z0-9_-]{4,20}$"#
    private var activeCount: Int { handles.filter(\.is_active).count }
    private var atLimit: Bool { activeCount >= 5 }
    private var trimmedValue: String { newValue.trimmingCharacters(in: .whitespaces) }
    private var valueIsValid: Bool {
        trimmedValue.isEmpty
            || trimmedValue.range(of: valueFormat, options: .regularExpression) != nil
    }

    struct HandleRow: Identifiable, Hashable {
        let id: String
        let value: String
        let label: String?
        let kind: String
        let is_active: Bool
        let created_at: String?
    }
    private struct Decoded: Decodable {
        let id: String
        let value: String
        let label: String?
        let kind: String
        let is_active: Bool
        let created_at: String?
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("自定义号码（留空则随机生成）", text: $newValue)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .font(Theme.Fonts.monoSmall)
                    TextField("备注（如 'blog'）", text: $newLabel)
                    HStack {
                        if !valueIsValid {
                            Text("格式：4-20 位字母 / 数字 / _ / -")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        } else if atLimit {
                            Text("已达到 5 个上限，先撤销一个")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("已用 \(activeCount) / 5")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(trimmedValue.isEmpty ? "随机生成" : "添加") {
                            Task { await mint() }
                        }
                        .disabled(atLimit || !valueIsValid)
                    }
                } header: {
                    Text("新增号码")
                } footer: {
                    Text("号码全局唯一。别人加你时你能看到他用了哪个号码。")
                }
                Section("我的号码") {
                    if handles.isEmpty {
                        Text("还没生成过号码").foregroundStyle(.secondary)
                    }
                    ForEach(handles) { h in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(h.value)
                                    .font(Theme.Fonts.monoSmall)
                                    .textSelection(.enabled)
                                Spacer()
                                if h.is_active {
                                    Button("撤销") { Task { await revoke(h.id) } }
                                        .foregroundStyle(.red)
                                        .font(.footnote)
                                } else {
                                    Text("已撤销")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let label = h.label {
                                Text(label)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("我的号码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            let rows: [Decoded] = try await SupabaseStack.shared
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

    private func mint() async {
        guard let userId = AccountStore.shared.current?.id else { return }
        let trimmedLabel = newLabel.trimmingCharacters(in: .whitespaces)
        // Either the user-chosen value (already format-validated client-side
        // and again by the DB CHECK) or a 10-char crockford-ish token from
        // an unambiguous alphabet (no 0/O/1/L/I).
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
            newLabel = ""
            newValue = ""
            Haptics.success()
            await load()
        } catch {
            // Friendly translation for the two common DB-side rejects:
            // unique-violation (someone else has this number) and the
            // format CHECK constraint.
            let raw = error.localizedDescription
            if raw.contains("duplicate") || raw.contains("unique") {
                self.error = "号码已被占用，换一个"
            } else if raw.contains("handles_value_format") {
                self.error = "号码格式不符（4-20 位字母 / 数字 / _ / -）"
            } else if raw.contains("handle limit") {
                self.error = "最多 5 个号码，先撤销一个再来"
            } else {
                self.error = raw
            }
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
