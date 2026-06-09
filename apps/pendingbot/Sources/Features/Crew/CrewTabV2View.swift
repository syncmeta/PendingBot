import SwiftUI

/// T4.6 — PendingBot iOS Crew Tab v2.
///
/// spec v2 §11.2 — Crew Tab is a普通群聊 UI grammar, not a dashboard:
///   crew 列表（按 updatedAt 倒序，扁平）→ tap 进 crew → 群聊页面.
///
/// **P0 MVP scope** (this commit):
///   - List of crews via `GET /v1/crews` (F agent's Phase 2 endpoint)
///   - Tap-through to `CrewDetailV2View` showing metadata + relationships
///   - "+" creates a crew via `POST /v1/crews` (local_host + system_generated
///     captain only for v1.0 launch; peer/fly + reuse_bot wait for T4.5
///     and a `GET /v1/me/bots` endpoint respectively)
///   - SubjectPickerSheet 入口保留（顶部菜单触发扫码 → 选身份 → 授权
///     PendingCrew/PendingBot Mac device-login）
///
/// **Out of scope for P0** (留 T4.1 / T4.3 / T4.5):
///   - 真消息流 / composer / @session / @captain mention
///   - session 状态卡 / 子 crew 摘要卡
///   - 跨端遥控状态指示
///   - Permission Request 卡片
///
/// 当 T4.1 通信规则 ship 后，CrewDetailV2View 会接上消息流 + composer，
/// 把 §11.2 完整图景填满。
struct CrewTabV2View: View {
    @Environment(\.api) private var api

    @State private var crews: [CrewSummaryV2] = []
    @State private var subject: CrewSubject?
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    @State private var showingCreateSheet = false

    // SubjectPickerSheet 触发链路（沿用 CrewTabView 的扫码 → 选身份 →
    // approve 老套路；这里搬一份到新 view 以保 T1.3 入口仍能用）。
    @State private var scanningDeviceLogin = false
    @State private var pendingDeviceLogin: DeviceLoginLink.Payload?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("机组")
                .toolbar {
                    ToolbarItem(placement: .platformTrailing) {
                        Menu {
                            Button {
                                showingCreateSheet = true
                            } label: {
                                Label("新建机组", systemImage: "plus.square")
                            }
                            .disabled(subject == nil)

                            #if os(iOS)
                            // 扫码授权桌面端 needs the camera (QRScannerView /
                            // AVFoundation) — iOS-only. Mac has no camera, so
                            // the scan entry is hidden there (a Mac user
                            // approves device-login from a different surface).
                            Divider()

                            Button {
                                scanningDeviceLogin = true
                            } label: {
                                Label("扫码授权桌面端", systemImage: "qrcode.viewfinder")
                            }
                            #endif

                            Button {
                                Task { await loadAll() }
                            } label: {
                                Label("刷新", systemImage: "arrow.clockwise")
                            }
                            .disabled(loading)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .refreshable { await loadAll() }
        }
        .task { await loadAll() }
        .sheet(isPresented: $showingCreateSheet, onDismiss: {
            // Sheet dismiss path also covers "created" — refresh either way
            // so a successful create immediately surfaces in the list.
            Task { await loadAll() }
        }) {
            CreateCrewV2Sheet(
                defaultSubject: subject,
                onCreated: { _ in showingCreateSheet = false }
            )
        }
        #if os(iOS)
        .sheet(isPresented: $scanningDeviceLogin) {
            QRScannerView { value in
                scanningDeviceLogin = false
                if let payload = DeviceLoginLink.parse(value) {
                    pendingDeviceLogin = payload
                } else {
                    error = "这不是 PendingCrew 登录二维码"
                }
            } onError: { err in
                error = err.localizedDescription
            }
            .ignoresSafeArea()
        }
        #endif
        .sheet(item: $pendingDeviceLogin) { payload in
            SubjectPickerSheet(
                payload: payload,
                defaultSubject: subject,
                onApprove: { selected in
                    pendingDeviceLogin = nil
                    Task {
                        await approveDeviceLogin(
                            payload: payload,
                            subjectId: selected.id,
                            label: selected.label
                        )
                    }
                },
                onCancel: { pendingDeviceLogin = nil }
            )
        }
        .alert("出错", isPresented: .constant(error != nil)) {
            Button("好") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .alert("完成", isPresented: .constant(notice != nil)) {
            Button("好") { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if loading && crews.isEmpty {
            ProgressView("加载中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if crews.isEmpty {
            ContentUnavailableView {
                Label("还没有机组", systemImage: "command")
            } description: {
                Text("机组 = 一组群聊 + coding agent 的权限边界。\n点右上角 + 新建一个，或者在 PendingCrew 桌面端创建。")
                    .multilineTextAlignment(.center)
            } actions: {
                Button {
                    showingCreateSheet = true
                } label: {
                    Label("新建机组", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(subject == nil)
            }
        } else {
            List(sortedCrews) { crew in
                NavigationLink(value: crew) {
                    CrewRowV2(crew: crew)
                }
            }
            .platformListStyle()
            .navigationDestination(for: CrewSummaryV2.self) { crew in
                CrewDetailV2View(crewId: crew.id, fallbackTitle: crew.title)
            }
        }
    }

    /// 按 updatedAt 倒序。ISO-8601 字符串可直接字典序比较（同时区）。
    /// 数据量小（list cap 200 in edge）一次性排即可。
    private var sortedCrews: [CrewSummaryV2] {
        crews.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Loading

    private func loadAll() async {
        guard let api, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            async let crewsTask = api.listCrewsV2()
            // crewCurrentSubject() 在 CrewAPI.swift 老 extension 里；只
            // 用来给 SubjectPickerSheet 拿 default subject + CreateCrewV2Sheet
            // 默认 responsibleSubjectId。
            async let subjectTask = api.crewCurrentSubject()
            self.crews = try await crewsTask
            // subject 单独 try?，挂了不阻塞 crew 列表。
            self.subject = try? await subjectTask
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func approveDeviceLogin(
        payload: DeviceLoginLink.Payload,
        subjectId: String,
        label: String
    ) async {
        guard let api else { return }
        let initialApproval: DeviceLoginGrantApproval = payload.appKind == .pendingBotMacOS
            ? .pendingBotClient
            : .pendingCrewControl
        do {
            let response: DeviceLoginApprovalResponse
            do {
                response = try await api.approvePendingCrewDeviceLogin(
                    challengeId: payload.challengeId,
                    secret: payload.secret,
                    subjectId: subjectId,
                    approval: initialApproval
                )
            } catch {
                guard let retry = DeviceLoginGrantApproval.retryPlan(after: error) else { throw error }
                guard retry != initialApproval else { throw error }
                response = try await api.approvePendingCrewDeviceLogin(
                    challengeId: payload.challengeId,
                    secret: payload.secret,
                    subjectId: subjectId,
                    approval: retry
                )
            }
            notice = response.ok
                ? "已以 \(label) 身份授权桌面端登录"
                : "扫码登录状态：\(response.status)"
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Row

private struct CrewRowV2: View {
    let crew: CrewSummaryV2

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "command")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(crew.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    runtimeBadge
                    if let tag = crew.tag, !tag.isEmpty {
                        Text("#\(tag)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let status = crew.status, !status.isEmpty {
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var runtimeBadge: some View {
        if let kind = crew.runtimeLocationKind {
            HStack(spacing: 3) {
                Image(systemName: kind.sfSymbol)
                    .font(.caption2)
                Text(kind.shortLabel)
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        } else {
            // 未知 runtime location：原样兜底显示字符串。
            Text(crew.runtimeLocation)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
