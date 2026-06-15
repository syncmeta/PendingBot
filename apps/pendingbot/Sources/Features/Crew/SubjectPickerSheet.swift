import SwiftUI

/// Modal shown after scanning a PendingCrew/PendingBot device-login QR.
///
/// Lets the user pick which subject the new device will act as
/// (spec v2 §4.4):
/// - 本人 user_account (默认)
/// - 自己 owner/admin 的群账号
///
/// Member-only group memberships are filtered out server-side by
/// `GET /v1/me/subjects`. The flow:
///
/// 1. Sheet loads `api.meSubjects()` on appear.
/// 2. User picks one (defaults to personal subject).
/// 3. Tapping "授权" calls back `onApprove(SubjectSelection)`. The
///    parent (CrewTabView) hits the approve endpoint.
struct SubjectPickerSheet: View {
    @Environment(\.api) private var api

    let payload: DeviceLoginLink.Payload
    /// The CrewTabView already loaded the caller's personal subject; we
    /// pass it in as a fallback so this sheet can render immediately
    /// without a network round-trip (and as the default selection).
    let defaultSubject: CrewSubject?
    let onApprove: (SubjectSelection) -> Void
    let onCancel: () -> Void

    @State private var subjects: [SubjectListItem] = []
    @State private var selectedSubjectId: String?
    @State private var loading = false
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("选择身份")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { onCancel() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("授权") {
                            guard let id = selectedSubjectId,
                                  let item = subjects.first(where: { $0.id == id })
                                    ?? defaultSubjectAsListItem()
                            else { return }
                            onApprove(SubjectSelection(id: id, label: item.displayName))
                        }
                        .disabled(selectedSubjectId == nil)
                    }
                }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if loading && subjects.isEmpty {
            ProgressView("加载身份列表…")
                .padding()
        } else if let loadError, subjects.isEmpty {
            VStack(spacing: 12) {
                Text("无法加载身份列表")
                    .font(.headline)
                Text(loadError)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("重试") { Task { await load() } }
            }
            .padding()
        } else {
            List(selection: $selectedSubjectId) {
                Section {
                    Text(payloadSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("设备")
                }
                Section {
                    ForEach(subjects) { item in
                        SubjectRow(item: item, selected: item.id == selectedSubjectId)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedSubjectId = item.id }
                    }
                } header: {
                    Text("以哪个身份授权")
                } footer: {
                    Text(footerText)
                }
            }
        }
    }

    private var payloadSummary: String {
        let target = payload.appKind?.displayName ?? "未知客户端"
        return "正在授权：\(target)\n会话编号：\(payload.challengeId.prefix(8))…"
    }

    private var footerText: String {
        if payload.appKind == .pendingBotMacOS {
            return "PendingBot Mac 登录会建立本人账号的正式会话，不能选择群账号。"
        }
        return "只有自己是 owner / admin 的群账号才能用于 PendingCrew 桌面端登录；其他身份留给 Crew 的费用分摊。"
    }

    // MARK: - Loading

    private func load() async {
        guard let api else {
            loadError = "未连接到 API"
            return
        }
        loading = true
        defer { loading = false }
        do {
            let items = try await api.meSubjects()
            let selectableItems = payload.appKind == .pendingBotMacOS
                ? items.filter { $0.kind == "user_account" }
                : items
            // Surface user_account first, then group accounts; the API
            // already does this but be defensive against future changes.
            subjects = selectableItems.sorted { lhs, rhs in
                if lhs.kind == rhs.kind { return lhs.displayName < rhs.displayName }
                return lhs.kind == "user_account"
            }
            // Default selection: caller's personal subject if it's in the
            // list, otherwise the first row.
            if let fallback = defaultSubject, subjects.contains(where: { $0.id == fallback.id }) {
                selectedSubjectId = fallback.id
            } else {
                selectedSubjectId = subjects.first?.id
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func defaultSubjectAsListItem() -> SubjectListItem? {
        guard let s = defaultSubject else { return nil }
        return SubjectListItem(
            id: s.id,
            kind: s.subject_type,
            displayName: s.display_name,
            role: nil
        )
    }
}

/// Lightweight payload the parent uses to call approve.
struct SubjectSelection {
    let id: String
    let label: String
}

private struct SubjectRow: View {
    let item: SubjectListItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isGroupAccount ? "person.3.fill" : "person.crop.circle.fill")
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(item.isGroupAccount ? "群账号" : "本人账号")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let role = item.role {
                        Text(role)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                }
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 4)
    }
}
