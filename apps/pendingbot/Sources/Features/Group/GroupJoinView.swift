import SwiftUI

/// Scan-to-join flow (decisions.md D2 — per-inviter invite tokens). The user
/// scans a group invite QR or opens a `/g/<token>` link; the app resolves the
/// token to a group preview, then joins (redeem):
///   - 'scan_open' policy → instantly joined → onJoined(convId)
///   - 'approval' policy → request filed → "等待审批"
/// Groups are no longer joined by typing a short shared code — each invite is
/// an inviter-scoped token (recorded as invited_by on join).
struct GroupJoinView: View {
    /// Called when the user is now a participant of `conversationId`.
    let onJoined: (String) -> Void
    /// When non-empty, resolves straight away (scan / universal-link flow).
    var prefilledToken: String = ""

    @Environment(\.dismiss) private var dismiss

    @State private var token: String = ""
    @State private var preview: Preview = .idle
    @State private var message: String = ""
    @State private var pendingState: PendingState? = nil
    @State private var submitting = false
    @State private var showScanner = false
    @State private var error: String?

    enum Preview {
        case idle
        case loading
        case loaded(GroupInvitePreview)
        case notFound(String)
    }

    private let api = APIClient()

    private var canJoin: Bool {
        if submitting { return false }
        if case .loaded = preview { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                switch preview {
                case .idle:
                    Section(footer: Text("扫描群邀请二维码,或打开别人发你的群邀请链接 —— 群聊改为邀请制,每个人的邀请码都不一样。")) {
                        Button {
                            showScanner = true
                        } label: {
                            Label("扫码加群", systemImage: "qrcode.viewfinder")
                        }
                    }
                case .loading:
                    Section { HStack(spacing: 12) { ProgressView(); Text("正在打开邀请…").foregroundStyle(.secondary) } }
                case .loaded(let g):
                    Section("群聊") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(g.title?.isEmpty == false ? g.title! : "未命名群聊")
                                .font(Theme.Fonts.body)
                            Text("\(g.memberCount) 名成员")
                                .font(Theme.Fonts.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    if let inviter = g.inviterName, !inviter.isEmpty {
                        Section { Text("由 \(inviter) 邀请你加入").font(Theme.Fonts.footnote).foregroundStyle(.secondary) }
                    }
                    if g.joinPolicy == "approval" {
                        Section("给群主的留言(可选)") {
                            TextField("例如:做产品的,想加入讨论", text: $message, axis: .vertical)
                                .lineLimit(2...5)
                        }
                    }
                case .notFound(let msg):
                    Section { Text(msg).foregroundStyle(.red) }
                }

                if let pendingState {
                    Section {
                        switch pendingState {
                        case .joined:
                            Label("已加入,正在打开…", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .pending:
                            Label("已发出请求,等群主或管理员审批。", systemImage: "clock.fill").foregroundStyle(.orange)
                        }
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }

                if canJoin {
                    Section {
                        Button {
                            Task { await join() }
                        } label: {
                            if submitting {
                                HStack { ProgressView(); Text("提交中…") }
                            } else {
                                Text("加入群聊").frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(!canJoin)
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("加群")
            .inlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .sheet(isPresented: $showScanner) {
                #if os(iOS)
                QRScannerView { scanned in
                    showScanner = false
                    Task { await resolve(GroupShareLink.token(fromScanned: scanned)) }
                }
                #else
                // No camera on macOS — group invites arrive via the universal
                // link (`/g/<token>`) handled by `prefilledToken` below.
                VStack(spacing: 12) {
                    Text("Mac 暂不支持扫码")
                        .font(Theme.Fonts.body)
                    Text("打开别人发你的群邀请链接即可加群。")
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(.secondary)
                    Button("关闭") { showScanner = false }
                        .buttonStyle(.borderedProminent)
                }
                .padding(40)
                #endif
            }
            .onAppear {
                if !prefilledToken.isEmpty, case .idle = preview {
                    Task { await resolve(GroupShareLink.token(fromScanned: prefilledToken)) }
                }
            }
        }
    }

    // MARK: - Resolve + redeem

    private func resolve(_ t: String) async {
        token = t
        preview = .loading
        error = nil
        do {
            let g = try await api.resolveGroupInvite(token: t)
            preview = .loaded(g)
        } catch {
            preview = .notFound(inviteErrorText(error))
        }
    }

    private func join() async {
        guard case .loaded = preview else { return }
        submitting = true; error = nil; pendingState = nil
        defer { submitting = false }
        do {
            let trimmed = message.trimmingCharacters(in: .whitespaces)
            let r = try await api.redeemGroupInvite(token: token, message: trimmed.isEmpty ? nil : trimmed)
            if r.joined {
                pendingState = .joined
                try? await Task.sleep(nanoseconds: 600_000_000)
                onJoined(r.conversationId)
                dismiss()
            } else if r.requestId != nil {
                pendingState = .pending
            } else {
                error = "服务器返回意外的结果"
            }
        } catch {
            self.error = inviteErrorText(error)
        }
    }

    private func inviteErrorText(_ error: Error) -> String {
        if let apiErr = error as? APIError, let msg = apiErr.errorDescription, !msg.isEmpty {
            return msg
        }
        return error.localizedDescription
    }

    private enum PendingState { case joined, pending }
}
