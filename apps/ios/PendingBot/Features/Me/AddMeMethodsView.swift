import SwiftUI
import CoreImage.CIFilterBuiltins
import Supabase

/// 加我为好友的方式 — 合并了二维码（QR-kind handle）与号码（number-kind
/// handle）两套入口。NavigationLink 推入此页面，原生 List 分组样式。
struct AddMeMethodsView: View {
    var body: some View {
        List {
            QRCardSection()
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

private struct QRCardSection: View {
    @State private var currentValue: String?
    @State private var loading = false
    @State private var error: String?

    private let context = CIContext()

    var body: some View {
        Section {
            VStack(spacing: 16) {
                let store = AccountStore.shared
                let avatarSeed = store.avatarSeed ?? store.current?.id ?? "?"
                let displayName = store.profileDisplayName
                    ?? store.current?.displayName ?? "你"
                HStack(spacing: 14) {
                    UserAvatar(
                        seed: avatarSeed,
                        attachmentId: store.avatarAttachmentId,
                        size: 56
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName)
                            .font(Theme.Fonts.serif(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.Palette.ink)
                            .lineLimit(1)
                        Text("PendingBot 名片")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                    Spacer(minLength: 0)
                }

                Divider().background(Theme.Palette.hairline)

                if loading {
                    ProgressView()
                        .controlSize(.large)
                        .frame(width: 220, height: 220)
                } else if let value = currentValue, let img = qrImage(for: value) {
                    VStack(spacing: 12) {
                        Image(uiImage: img)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 220, height: 220)
                        Text(value)
                            .font(Theme.Fonts.monoSmall)
                            .textSelection(.enabled)
                            .foregroundStyle(Theme.Palette.inkMuted)
                    }
                } else {
                    Text("生成二维码失败")
                        .foregroundStyle(.secondary)
                        .frame(width: 220, height: 220)
                }

                Button {
                    Task { await refresh() }
                } label: {
                    Label("刷新（旧码作废）", systemImage: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Theme.Palette.accent))
                }
                .buttonStyle(.plain)

                if let error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.hidden)
        } header: {
            Text("二维码")
        } footer: {
            Text("扫一扫，把我加为好友。")
        }
        .task { await ensureActive() }
    }

    private func ensureActive() async {
        loading = true; defer { loading = false }
        struct Row: Decodable { let id: String; let value: String }
        do {
            let rows: [Row] = try await SupabaseStack.shared
                .from("user_handles")
                .select("id, value")
                .eq("kind", value: "qr")
                .eq("is_active", value: true)
                .order("created_at", ascending: false)
                .limit(1)
                .execute()
                .value
            if let row = rows.first {
                self.currentValue = row.value
            } else {
                try await mintNew()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refresh() async {
        loading = true; defer { loading = false }
        do {
            try await SupabaseStack.shared
                .from("user_handles")
                .update(["is_active": false])
                .eq("kind", value: "qr")
                .eq("is_active", value: true)
                .execute()
            try await mintNew()
            Haptics.tap()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func mintNew() async throws {
        guard let userId = AccountStore.shared.current?.id else { return }
        let alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
        let token = String((0..<10).compactMap { _ in alphabet.randomElement() })
        struct Insert: Encodable {
            let user_id: String
            let value: String
            let kind: String
            let label: String?
        }
        try await SupabaseStack.shared
            .from("user_handles")
            .insert(Insert(user_id: userId, value: token, kind: "qr", label: "QR"))
            .execute()
        self.currentValue = token
    }

    private func qrImage(for s: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(s.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Handles (number-kind) section

private struct HandlesSection: View {
    @State private var handles: [HandleRow] = []
    @State private var loading = false
    @State private var newLabel: String = ""
    @State private var newValue: String = ""
    @State private var error: String?

    private let valueFormat = #"^[A-Za-z0-9_-]{4,20}$"#
    private var activeCount: Int { handles.filter(\.is_active).count }
    private var atLimit: Bool { activeCount >= 5 }
    private var trimmedValue: String {
        newValue.trimmingCharacters(in: .whitespaces)
    }
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
        Group {
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
