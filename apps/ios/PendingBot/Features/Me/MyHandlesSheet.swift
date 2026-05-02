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
    @State private var error: String?

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
                Section("生成新号码") {
                    HStack {
                        TextField("备注（如 'blog'）", text: $newLabel)
                        Button("生成") { Task { await mint() } }
                            .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
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
            let rows: [Decoded] = try await SupabaseStack.shared.database
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
        let trimmed = newLabel.trimmingCharacters(in: .whitespaces)
        let alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
        let token = String((0..<10).compactMap { _ in alphabet.randomElement() })
        struct Insert: Encodable {
            let user_id: String
            let value: String
            let label: String?
            let kind: String
        }
        do {
            try await SupabaseStack.shared.database
                .from("user_handles")
                .insert(Insert(user_id: userId, value: token,
                               label: trimmed.isEmpty ? nil : trimmed,
                               kind: "number"))
                .execute()
            newLabel = ""
            Haptics.success()
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func revoke(_ id: String) async {
        do {
            try await SupabaseStack.shared.database
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
