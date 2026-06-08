#if os(macOS)
import SwiftUI

/// 左栏：crew 列表 + toolbar（新建 / 刷新）。
///
/// MVP 阶段是平铺 list —— DAG 树形 sidebar 留下次（spec v2 §12.1 说明）。
/// `runtimeLocation` 用一个 systemImage + 缩写标签提示用户这是 local /
/// peer / fly。
struct CrewSidebarView: View {
    @EnvironmentObject private var crewStore: CrewStore
    @EnvironmentObject private var model: AppModel
    @State private var showingCreateSheet = false
    @State private var confirmingSignOut = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selectionBinding) {
                Section {
                    if crewStore.crews.isEmpty {
                        emptyRow
                    } else {
                        ForEach(crewStore.crews) { crew in
                            CrewRow(crew: crew).tag(crew.id)
                        }
                    }
                } header: {
                    Text("Crew")
                }
                // Machines section — 占位提示(v1.1 才接真 Fly machine 列表)。
                // BYOK 模式显示 "登录解锁" prompt;登录模式显示 v1.1 placeholder。
                // 这条目前不可选(没 tag),只展示状态。
                Section {
                    machinesRow
                } header: {
                    Text("Machines")
                }
            }
            .listStyle(.sidebar)
            // 当前身份 + 切换/登出。device grant 是 subject-scoped(spec v2 §4.4),
            // 想换 subject 必须撤掉这台机器的 grant 重新扫码 —— 所以"切换身份"
            // 路径就是签出后再去 LoginView 扫一遍。这里集中放在 sidebar 底部,
            // 让 user 始终能看见"我现在以谁的身份在花钱"。
            identityFooter
        }
        .navigationTitle("PendingCrew")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showingCreateSheet = true
                } label: {
                    Label("新建 crew", systemImage: "plus")
                }
                .help("新建 crew")
                Button {
                    Task { await crewStore.refreshList() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("刷新 crew 列表")
                .disabled(crewStore.loadingList)
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateCrewSheet()
        }
        .confirmationDialog(
            currentMode == .logged
                ? "签出当前身份"
                : "退出本机模式",
            isPresented: $confirmingSignOut,
            titleVisibility: .visible
        ) {
            Button(currentMode == .logged ? "签出" : "退出本机模式", role: .destructive) {
                signOut()
            }
            Button("取消", role: .cancel) {}
        } message: {
            if currentMode == .logged {
                Text("签出后本机 device grant 立即失效;若需切换到别的身份(本人 / 群账号),签出后回到登录页重新扫码即可。")
            } else {
                Text("退出后本机 BYOK 配置会清空,需要重新填 API key 才能继续本地 crew。")
            }
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { crewStore.selectedCrewId },
            set: { crewStore.selectCrew($0) }
        )
    }

    /// 根据 backend.mode 切两种 placeholder。
    /// - logged → "Fly machine — v1.1 上线"(灰显)
    /// - byok → "登录 PendingBot 解锁云端 Fly machine"(灰显 + 锁图标)
    @ViewBuilder
    private var machinesRow: some View {
        if crewStore.supportsCloudRuntime {
            HStack(spacing: 8) {
                Image(systemName: "cloud")
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fly machine")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("v1.1 上线")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("云端 Fly machine")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("登录 PendingBot 解锁")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Sidebar 底部固定条:显示当前 backend mode + (登录态)代表的 subject,
    /// 右侧 menu 触发签出。device grant 是 subject-scoped(spec v2 §4.4),
    /// 切换身份 = 签出 + 重扫,所以同一条 UI 同时覆盖两种语义。
    private var identityFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: identityIcon)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(identityTitle)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(identitySubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Menu {
                if currentMode == .logged {
                    Button {
                        confirmingSignOut = true
                    } label: {
                        Label("签出 / 切换身份", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } else if currentMode == .local {
                    Button {
                        confirmingSignOut = true
                    } label: {
                        Label("退出 BYOK 模式", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.medium)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(currentMode == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var currentMode: BackendMode? { crewStore.mode }

    private var identityIcon: String {
        guard let mode = currentMode else { return "questionmark.circle" }
        switch mode {
        case .logged:
            if crewStore.subjects.first?.kindEnum == .groupAccount {
                return "person.3.fill"
            }
            return "person.crop.circle.fill"
        case .local:
            return "laptopcomputer"
        }
    }

    private var identityTitle: String {
        guard let mode = currentMode else { return "未配置" }
        switch mode {
        case .logged:
            return crewStore.subjects.first?.displayName ?? "已登录"
        case .local:
            return "本机 claude / codex"
        }
    }

    private var identitySubtitle: String {
        guard let mode = currentMode else { return "—" }
        switch mode {
        case .logged:
            if let kind = crewStore.subjects.first?.kindEnum {
                return kind == .groupAccount ? "群账号 · unified billing" : "本人账号 · unified billing"
            }
            return "已登录 · unified billing"
        case .local:
            return "本地 crew · 本机已登录的 claude / codex"
        }
    }

    private func signOut() {
        switch currentMode {
        case .logged:
            model.clearAuth()
        case .local:
            model.clearByokConfig()
        case .none:
            break
        }
        // crewStore.reset() 由 RootView 监听 model.isConfigured 自动调,
        // 不在这里重复 wire 以避免双触发顺序歧义。
    }

    private var emptyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if crewStore.loadingList {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("加载中…").foregroundStyle(.secondary)
                }
            } else {
                Text("还没有 crew")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("点上面 + 创建第一个")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct CrewRow: View {
    let crew: CrewSummary

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: crew.runtimeLocationKind?.displayIcon ?? "questionmark.circle")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(crew.title)
                    .font(.callout)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(crew.runtimeLocationKind?.shortLabel ?? crew.runtimeLocation)
                    if let tag = crew.tag, !tag.isEmpty {
                        Text("·")
                        Text(tag).lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
#endif
