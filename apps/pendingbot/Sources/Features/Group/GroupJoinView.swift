#if os(iOS)
import SwiftUI

/// Scan-to-join / paste-to-join flow. The user types a group number
/// or scans a group QR (which encodes a handle string), POSTs to
/// /v1/groups/join, and either:
///   - 'scan_open' policy → instantly joined → onJoined(convId)
///   - 'approval' policy → request filed → show "等待审批" message
///   - 'closed' or full → server-side error surfaces
///
/// Reuses Components/QRScannerView.swift for the scanning UI; this
/// view just wires its callback to the join handler.
struct GroupJoinView: View {
    /// Called when the user is now a participant of `conversationId`.
    /// Caller dismisses + navigates to the chat.
    let onJoined: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var handleValue: String = ""
    @State private var message: String = ""
    @State private var pendingState: PendingState? = nil
    @State private var submitting = false
    @State private var showScanner = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("群号 / 群二维码"),
                        footer: Text("扫描群二维码或输入群号(4-20 位字母数字)。如果群里设置了需要审批,会先发起一个加群请求。")) {
                    TextField("例如:dev-room", text: $handleValue)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .submitLabel(.done)
                    Button {
                        showScanner = true
                    } label: {
                        Label("扫码", systemImage: "qrcode.viewfinder")
                    }
                }

                Section("给群主的留言(可选)") {
                    TextField("例如:做产品的,想加入讨论", text: $message, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let pendingState {
                    Section {
                        switch pendingState {
                        case .joined:
                            Label("已加入,正在打开…", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .pending:
                            Label("已发出请求,等群主或管理员审批。", systemImage: "clock.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }

                Section {
                    Button {
                        Task { await join() }
                    } label: {
                        if submitting {
                            HStack { ProgressView(); Text("提交中…") }
                        } else {
                            Text(handleValue.isEmpty ? "先输入群号" : "加入群聊")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(submitting || handleValue.trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("加群")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView { scanned in
                    showScanner = false
                    // Extract a handle from the scanned payload. Group
                    // QRs encode the bare handle string; some scanners
                    // hand back URL forms — strip a known prefix if so.
                    handleValue = sanitizeScan(scanned)
                }
            }
        }
    }

    // MARK: - Submit

    private func join() async {
        submitting = true
        error = nil
        pendingState = nil
        defer { submitting = false }

        do {
            struct Body: Encodable {
                let handleValue: String
                let message: String?
            }
            struct Response: Decodable {
                let conversationId: String?
                let requestId: String?
                let joined: Bool
            }
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/groups/join")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let trimmedMessage = message.trimmingCharacters(in: .whitespaces)
            req.httpBody = try JSONEncoder().encode(Body(
                handleValue: handleValue.trimmingCharacters(in: .whitespaces),
                message: trimmedMessage.isEmpty ? nil : trimmedMessage,
            ))

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
                throw NSError(
                    domain: "GroupJoin",
                    code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                    userInfo: [NSLocalizedDescriptionKey: msg],
                )
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)

            if decoded.joined, let cid = decoded.conversationId {
                pendingState = .joined
                // Brief delay so user sees the green check, then dismiss.
                try? await Task.sleep(nanoseconds: 600_000_000)
                onJoined(cid)
                dismiss()
            } else if decoded.requestId != nil {
                pendingState = .pending
            } else {
                error = "服务器返回意外的结果"
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func sanitizeScan(_ raw: String) -> String {
        // Group QR payload conventions: bare handle, OR a future
        // pendingname.com/g/<handle> universal-link URL. Handle the
        // URL form defensively.
        let prefix = "pendingname.com/g/"
        if let range = raw.range(of: prefix) {
            return String(raw[range.upperBound...])
                .components(separatedBy: CharacterSet(charactersIn: "/?#")).first ?? raw
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum PendingState { case joined, pending }
}
#endif
