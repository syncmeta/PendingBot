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
///
/// 跨平台:iOS 渲染既有的 `NavigationStack` 列表 → push 详情(iPhone/iPad
/// 一致,无 sidebarLayout 分叉)。macOS 走 `FeatureSurface`,壳把 crew 列表
/// 放中列、`CrewDetailV2View` 放右栏(详情按 crewId 自取,与中列是不同实例
/// 也无妨)。`externalSelection` 默认 nil → iOS `body` 与改前逐字一致。
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

    /// External selection sink, only set when the Mac three-column shell
    /// reuses our crew list via `FeatureSurface.listColumn(selection:)`. When
    /// non-nil, row taps + highlight read/write THIS binding (a crew id) instead
    /// of pushing onto the internal `NavigationStack`, so the shell's own detail
    /// column (a separate `NavigationSplitView` column) updates. nil for every
    /// iOS code path — the normal `body` never sets it, so iOS behavior is
    /// byte-identical to before.
    var externalSelection: Binding<String?>? = nil

    var body: some View {
        chrome(
            NavigationStack {
                content
                    .navigationTitle("机组")
                    .toolbar {
                        ToolbarItem(placement: .platformTrailing) {
                            crewMenu
                        }
                    }
                    .refreshable { await loadAll() }
                    .navigationDestination(for: CrewSummaryV2.self) { crew in
                        CrewDetailV2View(crewId: crew.id, fallbackTitle: crew.title)
                    }
            }
        )
    }

    /// Wraps a root view with the tab's shared chrome — the `.task { loadAll() }`,
    /// the create / device-login sheet stack, and the error / notice alerts.
    /// Pulled out of `body` so the Mac three-column shell's `listColumn` and the
    /// `compactRoot` can each be self-contained: every entry point that hosts the
    /// crew list carries the same actions + loading, regardless of which SwiftUI
    /// container it's planted in. The iOS `body` calls this with the exact same
    /// content it used to inline, so its behavior is unchanged.
    @ViewBuilder
    private func chrome(_ content: some View) -> some View {
        content
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

    /// Top-right "…" menu — shared by the iOS toolbar and the Mac list column.
    private var crewMenu: some View {
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
                // iOS (externalSelection == nil): push onto the NavigationStack
                // via NavigationLink — the iPhone/iPad path, unchanged.
                // Mac (externalSelection != nil): write the shell's binding so
                // its separate detail column swaps in place; the row also tints
                // when it's the current selection.
                if externalSelection != nil {
                    CrewRowV2(crew: crew)
                        .contentShape(Rectangle())
                        .listRowBackground(
                            externalSelection?.wrappedValue == crew.id
                                ? Color.accentColor.opacity(0.12) : nil
                        )
                        .onTapGesture { open(crew) }
                } else {
                    NavigationLink(value: crew) {
                        CrewRowV2(crew: crew)
                    }
                }
            }
            .platformListStyle()
        }
    }

    /// 按 updatedAt 倒序。ISO-8601 字符串可直接字典序比较（同时区）。
    /// 数据量小（list cap 200 in edge）一次性排即可。
    private var sortedCrews: [CrewSummaryV2] {
        crews.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Route a tapped crew to the right surface: the Mac shell's detail column
    /// via the external binding (when hosted there). Only reachable from the
    /// Mac `listColumn` — the iOS `body` uses `NavigationLink` directly and
    /// leaves `externalSelection` nil, so iPhone / iPad keep their push path.
    private func open(_ crew: CrewSummaryV2) {
        externalSelection?.wrappedValue = crew.id
        Haptics.tap()
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

// MARK: - FeatureSurface (Mac three-column shell)

/// Exposes the crew LIST and the crew DETAIL as separate columns so the macOS
/// `WideRootView` can drop them into one shared `NavigationSplitView` (list =
/// middle column, detail = right column) — no nested split views. The iOS
/// `body` above is untouched; these methods are additive and only the Mac
/// shell calls them.
///
/// Selection plumbing: the shell owns the `Binding<String?>` (a crew id) and
/// passes it into `listColumn`. We build a `CrewTabV2View` instance with its
/// `externalSelection` set to that binding, so the (otherwise unchanged)
/// `content` routes row taps + highlight through the shell's selection instead
/// of pushing onto the internal `NavigationStack`. `detailColumn` renders the
/// same `CrewDetailV2View` the iOS push shows, which self-fetches the crew by
/// id (`getCrewV2`) — so the shell only needs to carry the id, not the full
/// summary row. `fallbackTitle` is "" because the detail overwrites the nav
/// title with `detail.crew.title` once the fetch lands.
extension CrewTabV2View: FeatureSurface {
    typealias Selection = String

    func listColumn(selection: Binding<String?>) -> some View {
        // A fresh instance bound to the shell's selection. Its body is the crew
        // list alone (no NavigationStack — on Mac the shell owns navigation),
        // carrying the shared chrome so the create / device-login actions and
        // `loadAll()` all work from this column.
        var view = self
        view.externalSelection = selection
        return view.macListColumn
    }

    func detailColumn(selection: String?) -> some View {
        Group {
            if let crewId = selection {
                CrewDetailV2View(crewId: crewId, fallbackTitle: "")
                    // .id forces a fresh detail view (and a fresh crew socket)
                    // when the user picks a different crew — without it the
                    // existing view would just rebind, leaking the prior crew's
                    // chat store / realtime subscription state.
                    .id(crewId)
            } else {
                EmptyDetailHint(text: "选择一个机组查看", systemImage: "command")
            }
        }
    }

    func compactRoot() -> some View {
        // The iOS NavigationStack list → push, made self-contained by wrapping
        // the same content the iOS `body` uses in the shared chrome.
        body
    }
}

private extension CrewTabV2View {
    /// The crew list as a standalone column for the Mac shell: the shared
    /// `content` (no NavigationStack) on canvas, carrying the full chrome so
    /// create / device-login / `loadAll()` work from this column. A "+/…" menu
    /// rides the toolbar since there's no NavigationStack to host one.
    var macListColumn: some View {
        chrome(
            content
                .navigationTitle("机组")
                .toolbar {
                    ToolbarItem(placement: .platformTrailing) {
                        crewMenu
                    }
                }
        )
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
