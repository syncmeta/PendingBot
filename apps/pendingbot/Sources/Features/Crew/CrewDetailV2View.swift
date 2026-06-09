import SwiftUI

/// T4.6 — crew 详情页。**P1：群聊 UI 为主体**。
///
/// spec v2 §11.2 的完整形态：消息流 + composer + @人/@session/@captain
/// mention + session 状态卡 + 子 crew 摘要卡 + "在 PendingCrew 中打开"。
/// 这版把聊天做成主体，元数据（基本信息 / 机长 / 父子机组 / 责任比例）
/// 挪进右上角 "…"→机组详情 sheet。
///
/// P1 取舍（详见 docs/tech-debt.md）：消息流轮询刷新（下拉 + 发送后
/// reload），无实时推送（T4.5）；inline 权限卡片暂缺数据源，先不渲染；
/// composer 无附件。
struct CrewDetailV2View: View {
    @Environment(\.api) private var api
    @Environment(\.account) private var account

    let crewId: String
    /// list row 已经知道 title，先用它做 placeholder，等 detail 拉回来再
    /// 用 detail.crew.title 覆盖，避免 nav title 一闪空白。
    let fallbackTitle: String

    @State private var store: CrewChatStore?
    @State private var detail: CrewDetailV2?
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    @State private var showingDetailSheet = false
    @State private var showingSessionsSheet = false

    var body: some View {
        Group {
            if let store {
                chatBody(store: store)
            } else if loading {
                ProgressView("加载中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("无法加载机组", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle(detail?.crew.title ?? fallbackTitle)
        .inlineNavTitle()
        .toolbar {
            ToolbarItem(placement: .platformTrailing) {
                Button {
                    showingSessionsSheet = true
                } label: {
                    Image(systemName: "terminal")
                }
                .accessibilityLabel("查看服务端 session")
            }
            ToolbarItem(placement: .platformTrailing) {
                Button {
                    showingDetailSheet = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(detail == nil)
            }
        }
        .task { await bootstrap() }
        .onDisappear {
            // Drop the crew's realtime socket when leaving. Re-entering
            // re-runs `.task` → bootstrap → store.start(), and start() is
            // idempotent so a warm re-subscribe is a no-op if it somehow
            // races the teardown.
            if let store { Task { await store.stop() } }
        }
        .sheet(isPresented: $showingDetailSheet) {
            if let detail {
                CrewDetailSheet(
                    detail: detail,
                    crewId: crewId,
                    onCopyDeepLink: {
                        Clipboard.copy(pendingCrewDeepLink.absoluteString)
                        showingDetailSheet = false
                        notice = "深链已复制到剪贴板"
                    }
                )
            }
        }
        .alert("出错", isPresented: .constant(error != nil)) {
            Button("好") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .alert("已复制", isPresented: .constant(notice != nil)) {
            Button("好") { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: - Chat body

    @ViewBuilder
    private func chatBody(store: CrewChatStore) -> some View {
        @Bindable var bindableStore = store
        VStack(spacing: 0) {
            CrewSessionStrip(sessions: store.sessions, crewId: crewId)
            CrewChildSummaryStrip(children: store.children)
            CrewMessageListView(
                store: store,
                serverURL: account?.workerURL,
                currentUserId: AccountStore.shared.current?.id,
                retryMentions: [],
                detail: detail
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CrewComposerBar(store: store, detail: detail)
        }
    }

    // MARK: - Load

    private func bootstrap() async {
        guard let api, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let detail = try await api.getCrewV2(crewId)
            self.detail = detail
            let store = CrewChatStore(crewId: crewId, api: api)
            self.store = store
            await store.load(detail: detail)
            // Go live: open the crew's conv-channel so crew_announcements /
            // crew_sessions changes push in without a poll. start() is
            // idempotent and must follow the first load (it needs the
            // adapter the load built). The socket is dropped in .onDisappear.
            await store.start(detail: detail)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private var pendingCrewDeepLink: URL {
        // spec v2 §11.3 — `pendingcrew://crew/<crew-id>`
        URL(string: "pendingcrew://crew/\(crewId)")!
    }
}

// MARK: - 机组详情 sheet（原 P0 的 metadata List 整体搬进来）

/// 把 crew 元数据从主体抽进 "…" sheet：基本信息 / 机长 / 父子机组 /
/// 责任比例 / 在 PendingCrew 中打开。
private struct CrewDetailSheet: View {
    let detail: CrewDetailV2
    let crewId: String
    let onCopyDeepLink: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// spec v2 §11.3 — `pendingcrew://crew/<crew-id>`. ShareLink hands this
    /// to the system share sheet (cross-platform; replaces the iOS-only
    /// UIActivityViewController bridge).
    private var deepLink: URL { URL(string: "pendingcrew://crew/\(crewId)")! }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledRow(label: "标题", value: detail.crew.title)
                    LabeledRow(label: "状态", value: detail.crew.status ?? "—")
                    LabeledRow(label: "运行位置", value: runtimeLabel(for: detail.crew))
                    if let tag = detail.crew.tag, !tag.isEmpty {
                        LabeledRow(label: "标签", value: "#\(tag)")
                    }
                    if let cwd = detail.crew.workingDirectory, !cwd.isEmpty {
                        LabeledRow(label: "工作目录", value: cwd, monospaced: true)
                    }
                    LabeledRow(label: "责任主体 ID", value: detail.crew.responsibleSubjectId.prefix(8) + "…", monospaced: true)
                } header: {
                    Text("基本信息")
                }

                #if os(iOS)
                // 群钱包入口依赖 Group slice 的 `GroupWalletView`,后者还在
                // `#if os(iOS)` 围栏里(Group slice 跨平台化是单独一档活)。
                // Mac 先不显示这一行,等 Group slice 解锁后去掉这个 gate。
                Section {
                    NavigationLink {
                        GroupWalletView(subjectId: detail.crew.responsibleSubjectId)
                    } label: {
                        Label("群钱包", systemImage: "wallet.pass")
                    }
                } header: {
                    Text("账户")
                }
                #endif

                Section {
                    if let captain = detail.captain {
                        HStack {
                            ZStack {
                                Circle().fill(Color.accentColor.opacity(0.15))
                                Image(systemName: "person.crop.circle.badge.checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                            .frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(captain.displayName)
                                    .font(.body.weight(.medium))
                                Text("机长（captain）")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("还没有指定机长").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("机长")
                } footer: {
                    Text("机长是 crew 的「代理人格」和「对父 crew 的代表」。spec v2 §6.3。")
                }

                Section {
                    if detail.parents.isEmpty {
                        Text("没有父机组").foregroundStyle(.secondary)
                    } else {
                        ForEach(detail.parents) { link in
                            crewLinkRow(link)
                        }
                    }
                } header: {
                    Text("父机组")
                }

                Section {
                    if detail.children.isEmpty {
                        Text("没有子机组").foregroundStyle(.secondary)
                    } else {
                        ForEach(detail.children) { link in
                            crewLinkRow(link)
                        }
                    }
                } header: {
                    Text("子机组")
                }

                Section {
                    if detail.shares.isEmpty {
                        Text("没有责任分配").foregroundStyle(.secondary)
                    } else {
                        ForEach(detail.shares) { share in
                            shareRow(share)
                        }
                    }
                } header: {
                    Text("责任比例")
                } footer: {
                    Text("总和恒为 10000 bps（100%）。带星号 ★ 的是拍板方。spec v2 §7.3。")
                }

                Section {
                    ShareLink(item: deepLink) {
                        Label("在 PendingCrew 中打开", systemImage: "square.and.arrow.up")
                    }
                    Button(action: onCopyDeepLink) {
                        Label("复制深链", systemImage: "doc.on.doc")
                    }
                } header: {
                    Text("操作")
                } footer: {
                    Text("PendingCrew Mac / iPad 打开深链后会自动跳到这个机组。")
                }
            }
            .platformListStyle()
            .navigationTitle("机组详情")
            .inlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .platformTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func crewLinkRow(_ link: CrewLinkV2) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(link.title)
                    .font(.body)
                    .lineLimit(1)
                Text("子方保留 \(bpsAsPercent(link.childShareBps))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(link.crewId.prefix(8) + "…")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
    }

    private func shareRow(_ share: CrewShareV2) -> some View {
        HStack(spacing: 10) {
            Image(systemName: share.kind == "group_account" ? "person.3.fill" : "person.crop.circle.fill")
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(share.displayName.isEmpty ? share.subjectId.prefix(8) + "…" : share.displayName)
                        .font(.body)
                        .lineLimit(1)
                    if share.isTiebreaker {
                        Text("★")
                            .foregroundStyle(.orange)
                            .font(.body.weight(.bold))
                    }
                }
                Text(share.kind == "group_account" ? "群账号" : "本人账号")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(bpsAsPercent(share.shareBps))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)
        }
    }

    private func bpsAsPercent(_ bps: Int) -> String {
        let percent = Double(bps) / 100.0
        return String(format: "%.1f%%", percent)
    }

    private func runtimeLabel(for crew: CrewBodyV2) -> String {
        if let kind = crew.runtimeLocationKind {
            return kind.shortLabel
        }
        return crew.runtimeLocation
    }
}

// MARK: - Small reusable rows

private struct LabeledRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false

    init(label: String, value: any StringProtocol, monospaced: Bool = false) {
        self.label = label
        self.value = String(value)
        self.monospaced = monospaced
    }

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
