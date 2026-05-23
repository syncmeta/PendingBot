import SwiftUI

/// Group billing sheet — owner/admin sets the cost-split mode + window;
/// every member sets their own per-group PND cap. Wired to the
/// /v1/groups/:id/billing and /v1/groups/:id/cap endpoints.
///
/// "custom" mode UI (per-user weight entry) is a future polish; this
/// shell ships the four canonical modes and the personal cap.
struct GroupBillingSheet: View {
    let conversationId: String
    let isAdmin: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var mode: SplitMode = .hybrid
    @State private var loadedMode: SplitMode = .hybrid
    @State private var windowSeconds: Int = 86_400
    @State private var capCredits: String = ""
    @State private var capEnabled: Bool = false

    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    private static let modeLabel: [SplitMode: String] = [
        .hybrid: "条数 50% + token 50%(默认)",
        .perHead: "按人头平分",
        .perMessage: "按发言条数",
        .perToken: "按发言 token",
        .custom: "自定义比例(暂不支持编辑)",
    ]

    private static let windowOptions: [(Int, String)] = [
        (3_600, "最近 1 小时"),
        (86_400, "最近 1 天"),
        (7 * 86_400, "最近 7 天"),
    ]

    private var modeOptions: [SplitMode] {
        var modes: [SplitMode] = [.hybrid, .perHead, .perMessage, .perToken]
        if mode == .custom {
            modes.insert(.custom, at: 0)
        }
        return modes
    }

    var body: some View {
        NavigationStack {
            Form {
                if isAdmin {
                    Section("分摊方式") {
                        Picker("模式", selection: $mode) {
                            ForEach(modeOptions, id: \.self) { m in
                                Text(Self.modeLabel[m] ?? m.rawValue).tag(m)
                                    .disabled(m == .custom)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }

                    if mode == .perMessage || mode == .perToken || mode == .hybrid {
                        Section("统计窗口") {
                            Picker("窗口", selection: $windowSeconds) {
                                ForEach(Self.windowOptions, id: \.0) { (sec, label) in
                                    Text(label).tag(sec)
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                    }

                    if mode == .custom {
                        Section {
                            Text("当前为自定义比例。要修改分摊方式,请选择上面的其他模式。")
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section(header: Text("我在本群消耗 PND 的上限"),
                        footer: Text("超过上限后,本群产生的费用不会再从你账户扣,不影响你继续聊天。")) {
                    Toggle("启用上限", isOn: $capEnabled)
                    if capEnabled {
                        TextField("PND", text: $capCredits)
                            .keyboardType(.numberPad)
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving {
                            HStack { ProgressView(); Text("保存中…") }
                        } else {
                            Text("保存").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(saving)
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("谁为机器人的 Token 买单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await load() }
            .disabled(loading && error == nil)
        }
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let meId = (try? await SupabaseStack.shared.auth.session.user.id.uuidString.lowercased()) ?? ""
            async let cfgResp: [BillingConfigDecodable] = SupabaseStack.shared
                .from("group_billing_config")
                .select("mode, window_seconds")
                .eq("conversation_id", value: conversationId)
                .execute()
                .value
            async let mineResp: [MineDecodable] = SupabaseStack.shared
                .from("group_member_billing")
                .select("user_id, cap_credits")
                .eq("conversation_id", value: conversationId)
                .eq("user_id", value: meId)
                .execute()
                .value
            if let cfg = (try await cfgResp).first {
                let loaded = SplitMode(rawValue: cfg.mode) ?? .hybrid
                mode = loaded
                loadedMode = loaded
                windowSeconds = cfg.window_seconds
            }
            if let mine = (try await mineResp).first {
                if let cap = mine.cap_credits {
                    capEnabled = true
                    capCredits = String(cap)
                }
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Save

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }

        if isAdmin {
            struct BillingBody: Encodable {
                let mode: String
                let windowSeconds: Int
                let customShares: [String]?
            }
            if mode != .custom {
                await postVoid(
                    path: "v1/groups/\(conversationId)/billing",
                    body: BillingBody(
                        mode: mode.rawValue,
                        windowSeconds: windowSeconds,
                        customShares: nil,
                    ),
                )
                if error != nil { return }
            } else if loadedMode != .custom {
                error = "自定义比例编辑还没开放。请选择其他分摊方式。"
                return
            }
        }

        struct CapBody: Encodable { let capCredits: Int? }
        let capValue: Int? = capEnabled
            ? Int(capCredits.trimmingCharacters(in: .whitespaces))
            : nil
        await postVoid(
            path: "v1/groups/\(conversationId)/cap",
            body: CapBody(capCredits: capValue),
        )
        if error == nil { dismiss() }
    }

    private func postVoid<B: Encodable>(path: String, body: B) async {
        do {
            let url = HostedConfig.environment.workerURL.appendingPathComponent(path)
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONEncoder().encode(body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
                throw NSError(
                    domain: "GroupBilling",
                    code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                    userInfo: [NSLocalizedDescriptionKey: msg],
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Models

    enum SplitMode: String, CaseIterable, Hashable {
        case custom, perHead = "per_head", perMessage = "per_message", perToken = "per_token", hybrid
    }

    private struct BillingConfigDecodable: Decodable {
        let mode: String
        let window_seconds: Int
    }

    private struct MineDecodable: Decodable {
        let user_id: String
        let cap_credits: Int?
    }
}
