#if os(macOS)
import SwiftUI
import AppKit

/// 新建 session sheet。在选中 crew 的中栏点 "新建 session" 触发。
///
/// Spec v2 §12.2 全字段(T3.3 + T3.5 合流):
/// - runner kind:Claude Code(主) / Codex(次,只要装了 CLI 就能选);UI 标注
///   Codex 还在 beta(spec v2 §8.1 TODO,部分 flag 未接通)
/// - 模型选:登录态 `GET /v1/models` 拉动态目录,native / OpenRouter 两个 section;
///   BYOK 态 fallback 成手动 model id 输入框
/// - 工作目录三层(spec v2 §8.3):
///   - **使用 crew 默认目录** — 默认,取 `crew.workingDirectory`
///   - **选其他目录** — NSOpenPanel 临时挑一个
///   - **新 git worktree** — 在 crew 默认目录的 repo 里 `git worktree add` 一个
///     临时分支目录(可 checkout 已有分支 / 新建分支)。crew 默认必须是 git
///     work tree 且 `git` 可用。
/// - 所在地(runtime location):v1 写死 `local_host`,peer/fly 灰显 v1.1
/// - 任务 brief + 初始 prompt:prompt 走 stdin 不入 argv(spec v2 §8.4)
/// - Permission 模式:inherit / auto / manual,session-level override
///
/// 创建后调 `CrewSessionRunner.start` 起子进程;若上一个 run 还在跑,sheet 给
/// 确认提示。MVP 一窗一 session,多 tab 留 v1.1。
struct CreateSessionSheet: View {
    let detail: CrewDetail

    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var sessionRunner: CrewSessionRunner
    @Environment(\.dismiss) private var dismiss

    // MARK: - state

    @State private var kind: LocalCodingAgentKind = .claudeCode
    @State private var availableKinds: [LocalCodingAgentKind] = []
    @State private var loadingKinds: Bool = true

    @State private var taskBrief: String = ""
    @State private var initialPrompt: String = ""

    // Working directory —— 三层 picker(spec v2 §8.3)
    @State private var workingDirMode: WorkingDirMode = .crewDefault
    @State private var customWorkingDirectory: URL?
    /// crew 默认目录是否是 git repo,决定 worktree 选项是否可用
    @State private var crewDefaultIsGitRepo: Bool = false
    /// crew 默认目录里能 checkout 的本地分支列表
    @State private var availableBranches: [String] = []
    /// crew 默认目录的当前 branch(展示用,不强制)
    @State private var currentBranch: String?
    /// worktree base 分支(从 `availableBranches` 选)
    @State private var worktreeBaseBranch: String = ""
    /// 是否在新分支上建 worktree(true → 输入新分支名;false → checkout 已有分支)
    @State private var createNewBranch: Bool = true
    /// 新分支名(`createNewBranch == true` 时用)
    @State private var newBranchName: String = ""
    @State private var loadingBranches: Bool = false

    // Model picker —— logged 模式拉 /v1/models;BYOK 走手动输入。
    @State private var availableModels: [ModelCatalogEntry] = []
    @State private var loadingModels: Bool = false
    @State private var modelsError: String?
    @State private var selectedModelSlug: String = ""    // "" = 让 CLI 用自带默认
    @State private var manualModelSlug: String = ""       // BYOK fallback

    // Runtime location —— v1 只允许 local_host。
    @State private var runtimeLocation: RuntimeLocation = .localHost

    @State private var permissionMode: PermissionModeSelection = .inherit
    @State private var starting: Bool = false
    @State private var localError: String?

    enum WorkingDirMode: String, CaseIterable, Identifiable {
        case crewDefault
        case custom
        case gitWorktree

        var id: String { rawValue }

        var label: String {
            switch self {
            case .crewDefault: return "使用 crew 默认目录"
            case .custom:      return "选其他目录"
            case .gitWorktree: return "新 git worktree"
            }
        }
    }

    /// Spec v2 §10 — session-level permission mode picker. `inherit`
    /// means "use whatever the crew default is" and maps to a null
    /// `permission_mode_override` on the server; `auto` / `manual`
    /// override the crew default for just this session.
    enum PermissionModeSelection: String, CaseIterable, Identifiable {
        case inherit
        case auto
        case manual

        var id: String { rawValue }

        var label: String {
            switch self {
            case .inherit: return "跟随 crew 默认"
            case .auto:    return "自动（不请示）"
            case .manual:  return "手动（高危请示）"
            }
        }

        /// Wire value for CrewSessionRunner.start. `nil` = inherit
        /// (server-side null clears the override).
        var wireValue: String? {
            switch self {
            case .inherit: return nil
            case .auto:    return "auto"
            case .manual:  return "manual"
            }
        }
    }

    /// Spec v2 §12.2 — 所在地。v1 只放 `localHost`;其余两个 case 在 UI 上灰显
    /// 让用户知道 roadmap 上有,但选不动。
    enum RuntimeLocation: String, CaseIterable, Identifiable {
        case localHost     // 本机(MVP 唯一选项)
        case peerDevice    // 另一台已登录设备(v1.1)
        case flyMachine    // 云端 Fly machine(v1.1)

        var id: String { rawValue }

        var label: String {
            switch self {
            case .localHost:  return "本机"
            case .peerDevice: return "另一台设备"
            case .flyMachine: return "云端 Fly machine"
            }
        }

        var isEnabled: Bool { self == .localHost }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 620)
        .frame(minHeight: 680)
        .task {
            await bootstrap()
        }
    }

    // MARK: - bootstrap

    private func bootstrap() async {
        // 1. discover 装好的 runner kind
        availableKinds = await MacLocalCodingAgentService().discoverAvailable()
        loadingKinds = false
        if !availableKinds.contains(kind), let first = availableKinds.first {
            kind = first
        }
        // 2. 拉模型目录(logged 模式;BYOK 模式 backend 返回空,UI 自动 fallback)
        await refreshModels()
        // 3. 探测 crew 默认目录是不是 git repo + 列 branch
        await refreshGitInfo()
    }

    private func refreshModels() async {
        guard let backend = appModel.backend else { return }
        loadingModels = true
        modelsError = nil
        defer { loadingModels = false }
        do {
            let list = try await backend.listModels()
            availableModels = list
            // 默认选 native section 的第一条(spec:native 永远排最前)
            if selectedModelSlug.isEmpty, let first = list.first {
                selectedModelSlug = first.slug
            }
        } catch {
            modelsError = error.localizedDescription
        }
    }

    /// 起 session 前把 crew 默认目录 probe 一遍:
    /// - 是不是 git repo → 决定 worktree 选项是否可选
    /// - 列出 local 分支 → 给 worktree 选 base
    /// - current branch → 默认选它作 base
    ///
    /// 失败不抛 —— git 没装时 worktree 选项就灰显,不影响 crew 默认 / custom 路径。
    private func refreshGitInfo() async {
        guard let crewDir = crewDefaultURL else {
            crewDefaultIsGitRepo = false
            availableBranches = []
            currentBranch = nil
            return
        }
        loadingBranches = true
        defer { loadingBranches = false }
        let info = await Task.detached(priority: .userInitiated) { () -> (Bool, [String], String?) in
            do {
                let isRepo = try GitWorktreeService.isGitRepository(at: crewDir)
                guard isRepo else { return (false, [], nil) }
                let branches = (try? GitWorktreeService.listLocalBranches(at: crewDir)) ?? []
                let current = try? GitWorktreeService.currentBranch(at: crewDir)
                return (true, branches, current)
            } catch {
                return (false, [], nil)
            }
        }.value
        crewDefaultIsGitRepo = info.0
        availableBranches = info.1
        currentBranch = info.2
        if worktreeBaseBranch.isEmpty {
            if let cur = info.2, info.1.contains(cur) {
                worktreeBaseBranch = cur
            } else {
                worktreeBaseBranch = info.1.first ?? ""
            }
        }
    }

    // MARK: - sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("新建 session")
                .font(.title3.weight(.semibold))
            Text("· \(detail.crew.title)")
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                kindField
                modelField
                workingDirField
                locationField
                permissionModeField
                briefField
                promptField
            }
            .padding(20)
        }
    }

    // MARK: kind

    private var kindField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Runner")
                .font(.callout.weight(.medium))
            if loadingKinds {
                ProgressView().controlSize(.small)
            } else if availableKinds.isEmpty {
                Text("本机未安装 Claude Code 或 Codex CLI。请先安装一个。")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else {
                Picker("", selection: $kind) {
                    ForEach(LocalCodingAgentKind.allCases, id: \.self) { k in
                        Text(label(for: k)).tag(k)
                            .disabled(!availableKinds.contains(k))
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                if kind == .codex {
                    Text("Codex 还在 beta —— 模型选项暂不透传给 CLI(spec v2 §8.1 TODO)。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func label(for kind: LocalCodingAgentKind) -> String {
        let installed = availableKinds.contains(kind)
        return installed ? kind.displayName : "\(kind.displayName)（未安装）"
    }

    // MARK: model

    private var modelField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("模型")
                    .font(.callout.weight(.medium))
                if appModel.mode == .byok {
                    Text("(BYOK)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if loadingModels {
                    ProgressView().controlSize(.small)
                }
            }
            if appModel.mode == .byok {
                // BYOK:edge 不可达,让用户直接填 model id(留空 = 让 CLI 用默认)
                TextField("如 claude-sonnet-4-5(留空 = CLI 默认)", text: $manualModelSlug)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
            } else if let err = modelsError {
                VStack(alignment: .leading, spacing: 4) {
                    Text("加载模型目录失败:\(err)")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("重试") { Task { await refreshModels() } }
                        .controlSize(.small)
                }
            } else if availableModels.isEmpty && !loadingModels {
                Text("模型目录暂时为空 —— 可能 edge 还没拉到 OpenRouter catalog。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: $selectedModelSlug) {
                    Section("Native") {
                        ForEach(nativeModels) { m in
                            Text(m.displayName).tag(m.slug)
                        }
                    }
                    Section("OpenRouter") {
                        ForEach(openrouterModels) { m in
                            Text(m.displayName).tag(m.slug)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                if let row = availableModels.first(where: { $0.slug == selectedModelSlug }) {
                    Text(row.slug)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var nativeModels: [ModelCatalogEntry] {
        availableModels.filter { $0.isNative }
    }

    private var openrouterModels: [ModelCatalogEntry] {
        availableModels.filter { !$0.isNative }
    }

    /// 最终透传给 runner 的 model slug。BYOK 走手动框;logged 走 picker。
    /// 空串 → nil(让 CLI 用默认)。
    private var resolvedModelSlug: String? {
        let raw = appModel.mode == .byok ? manualModelSlug : selectedModelSlug
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - working dir section (3-mode picker)

    private var workingDirField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("工作目录")
                    .font(.callout.weight(.medium))
                if loadingBranches {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            Picker("", selection: $workingDirMode) {
                ForEach(WorkingDirMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                        .disabled(mode == .gitWorktree && !crewDefaultIsGitRepo)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: workingDirMode) { _, newValue in
                if newValue == .gitWorktree {
                    // 默认新分支名 = session-<8字 uuid>;用户可改。
                    if newBranchName.isEmpty {
                        newBranchName = "session-\(UUID().uuidString.lowercased().prefix(8))"
                    }
                }
            }
            workingDirContent
        }
    }

    @ViewBuilder
    private var workingDirContent: some View {
        switch workingDirMode {
        case .crewDefault:
            crewDefaultBox
        case .custom:
            customDirBox
        case .gitWorktree:
            worktreeBox
        }
    }

    private var crewDefaultBox: some View {
        HStack(spacing: 8) {
            if let url = crewDefaultURL {
                Text(url.path)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("crew 没设默认目录 —— 请先编辑 crew 设个工作目录, 或改用其他模式")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private var customDirBox: some View {
        HStack(spacing: 8) {
            if let url = customWorkingDirectory {
                Text(url.path)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("未选择")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("选择…") { pickCustomDirectory() }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private var worktreeBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            // base 分支 picker
            HStack(spacing: 8) {
                Text("base 分支")
                    .font(.caption.weight(.medium))
                    .frame(width: 70, alignment: .leading)
                Picker("", selection: $worktreeBaseBranch) {
                    if availableBranches.isEmpty {
                        Text("(无)").tag("")
                    }
                    ForEach(availableBranches, id: \.self) { b in
                        Text(b).tag(b)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                if let cur = currentBranch {
                    Text("HEAD: \(cur)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            // 新分支 toggle
            Toggle(isOn: $createNewBranch) {
                Text("从 base 起一个新分支")
                    .font(.caption)
            }
            if createNewBranch {
                HStack(spacing: 8) {
                    Text("分支名")
                        .font(.caption.weight(.medium))
                        .frame(width: 70, alignment: .leading)
                    TextField("session-xxxxxxxx", text: $newBranchName)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                Text("会直接在 \(worktreeBaseBranch.isEmpty ? "选定分支" : worktreeBaseBranch) 上 checkout (注意多个 worktree 不能 checkout 同一分支 —— git 会拒绝)。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Text("worktree 会建在 `<repo 根>/.pendingcrew/worktrees/...`(自动加进 .git/info/exclude)。session 退出后不会自动清理,可手动 `git worktree remove`。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: runtime location

    private var locationField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("所在地")
                .font(.callout.weight(.medium))
            Picker("", selection: $runtimeLocation) {
                ForEach(RuntimeLocation.allCases) { loc in
                    Text(loc.label).tag(loc)
                        .disabled(!loc.isEnabled)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Text("peer_device / fly_machine 留到 v1.1(spec v2 §12.2 + §13.2)。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: permission

    private var permissionModeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Permission 模式")
                    .font(.callout.weight(.medium))
                Text("(spec v2 §10)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Picker("", selection: $permissionMode) {
                ForEach(PermissionModeSelection.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Text(permissionModeHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionModeHint: String {
        switch permissionMode {
        case .inherit: return "用 crew 设定的默认模式（如果没设过,默认为自动）。"
        case .auto:    return "agent 自由执行,不弹卡片请权限。"
        case .manual:  return "agent 做高危操作前要在群里弹卡片等批准。v1 还没接通真正暂停 agent —— 闭环留 T4.5。"
        }
    }

    // MARK: brief / prompt

    private var briefField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("任务简介（brief）")
                .font(.callout.weight(.medium))
            TextEditor(text: $taskBrief)
                .font(.callout)
                .frame(minHeight: 50, maxHeight: 70)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
        }
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("初始 prompt")
                .font(.callout.weight(.medium))
            TextEditor(text: $initialPrompt)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 120, maxHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let err = localError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                Task { await submit() }
            } label: {
                if starting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("起 session")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit || starting)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - derived state

    private var crewDefaultURL: URL? {
        guard let wd = detail.crew.workingDirectory, !wd.isEmpty else { return nil }
        return URL(fileURLWithPath: (wd as NSString).expandingTildeInPath)
    }

    // MARK: - actions

    private var canSubmit: Bool {
        guard !loadingKinds else { return false }
        guard availableKinds.contains(kind) else { return false }
        guard !initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard runtimeLocation == .localHost else { return false }
        switch workingDirMode {
        case .crewDefault:
            return crewDefaultURL != nil
        case .custom:
            return customWorkingDirectory != nil
        case .gitWorktree:
            guard crewDefaultIsGitRepo, !worktreeBaseBranch.isEmpty else { return false }
            if createNewBranch {
                return !newBranchName.trimmingCharacters(in: .whitespaces).isEmpty
            }
            return true
        }
    }

    private func pickCustomDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择工作目录"
        if let initial = customWorkingDirectory ?? crewDefaultURL {
            panel.directoryURL = initial
        }
        if panel.runModal() == .OK, let url = panel.url {
            customWorkingDirectory = url
        }
    }

    private func submit() async {
        // 若已经有 active running run,提示用户先停（MVP 简单 guard;
        // 未来支持多 session 时这里改成允许并行）。
        if let cur = sessionRunner.current, cur.status == .running {
            localError = "已有一个 session 正在运行，请先停止。"
            return
        }
        starting = true
        defer { starting = false }
        localError = nil

        // resolve 实际 cwd —— worktree 模式在这里跑 `git worktree add`。
        let resolvedDir: URL
        do {
            resolvedDir = try await resolveWorkingDirectory()
        } catch {
            localError = "解析工作目录失败: \(error)"
            return
        }

        do {
            try await sessionRunner.start(
                crewId: detail.crew.id,
                kind: kind,
                workingDirectory: resolvedDir,
                taskBrief: taskBrief.trimmingCharacters(in: .whitespacesAndNewlines),
                initialPrompt: initialPrompt,
                model: resolvedModelSlug,
                permissionModeOverride: permissionMode.wireValue
            )
            dismiss()
        } catch {
            localError = error.localizedDescription
        }
    }

    /// 把当前选择折成 session 子进程真用的 cwd。`gitWorktree` 模式会跑
    /// `git worktree add` 创建新目录;其他模式直接返回已选 URL。
    private func resolveWorkingDirectory() async throws -> URL {
        switch workingDirMode {
        case .crewDefault:
            guard let url = crewDefaultURL else {
                throw NSError(domain: "PendingCrew", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "crew 默认目录为空",
                ])
            }
            return url
        case .custom:
            guard let url = customWorkingDirectory else {
                throw NSError(domain: "PendingCrew", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "未选择目录",
                ])
            }
            return url
        case .gitWorktree:
            guard let source = crewDefaultURL else {
                throw NSError(domain: "PendingCrew", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "crew 默认目录为空",
                ])
            }
            let baseBranch = worktreeBaseBranch
            let newBranch = createNewBranch
                ? newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            let crewTitle = detail.crew.title
            // off-main 跑 git;worktree add 慢起来要几秒(checkout 文件)。
            return try await Task.detached(priority: .userInitiated) { () -> URL in
                try GitWorktreeService.addWorktree(
                    sourceRepository: source,
                    branchName: baseBranch,
                    newBranchName: newBranch,
                    worktreeNameHint: crewTitle
                )
            }.value
        }
    }
}
#endif
