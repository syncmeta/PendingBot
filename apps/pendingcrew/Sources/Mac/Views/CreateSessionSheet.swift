#if os(macOS)
import SwiftUI
import AppKit

/// 新建 session sheet。在选中 crew 的中栏点 "新建 session" 触发。
///
/// 工作目录三层(spec v2 §8.3):
/// - **使用 crew 默认目录** — 默认选项,直接取 `crew.workingDirectory`
/// - **选其他目录** — NSOpenPanel 临时挑一个
/// - **新 git worktree** — 在 crew 默认目录的 repo 里 `git worktree add` 一个临时
///   分支目录(可选: checkout 已有分支 / 新建分支)。仅当 crew 默认目录是 git
///   work tree 且 `git` 可执行时可选。
///
/// MVP scope:
/// - runner kind: Claude Code / Codex
/// - 任务 brief(一句话) + 初始 prompt(多行)
///
/// 创建后调 CrewSessionRunner.start —— 真起子进程;如果有上一个 run
/// 还没结束,sheet 上给个确认提示。
struct CreateSessionSheet: View {
    let detail: CrewDetail

    @EnvironmentObject private var sessionRunner: CrewSessionRunner
    @Environment(\.dismiss) private var dismiss

    @State private var kind: LocalCodingAgentKind = .claudeCode
    @State private var availableKinds: [LocalCodingAgentKind] = []
    @State private var loadingKinds: Bool = true
    @State private var taskBrief: String = ""
    @State private var initialPrompt: String = ""
    @State private var permissionMode: PermissionModeSelection = .inherit

    // working dir state
    @State private var workingDirMode: WorkingDirMode = .crewDefault
    /// 用户在 `.custom` 模式下挑的目录。
    @State private var customWorkingDirectory: URL?
    /// crew 默认目录是否是 git repo,决定 worktree 选项是否可用。
    @State private var crewDefaultIsGitRepo: Bool = false
    /// crew 默认目录里能 checkout 的本地分支列表(从 `git for-each-ref` 拉)。
    @State private var availableBranches: [String] = []
    /// worktree 起 base 分支(从 `availableBranches` 选)。
    @State private var worktreeBaseBranch: String = ""
    /// 是否在新分支上建 worktree(true → 输入新分支名;false → checkout 已有分支)。
    @State private var createNewBranch: Bool = true
    /// 新分支名(`createNewBranch == true` 时用)。
    @State private var newBranchName: String = ""

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
            case .custom: return "选其他目录"
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
            case .auto:    return "自动(不请示)"
            case .manual:  return "手动(高危请示)"
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 580)
        .frame(minHeight: 620)
        .task {
            // discover 装好的 runner kind。
            availableKinds = await MacLocalCodingAgentService().discoverAvailable()
            loadingKinds = false
            if !availableKinds.contains(kind) {
                if let first = availableKinds.first {
                    kind = first
                }
            }
            await refreshGitInfo()
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
                workingDirField
                permissionModeField
                briefField
                promptField
            }
            .padding(20)
        }
    }

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
        case .inherit: return "用 crew 设定的默认模式(如果没设过,默认为自动)。"
        case .auto:    return "agent 自由执行,不弹卡片请权限。"
        case .manual:  return "agent 做高危操作前要在群里弹卡片等批准。v1 还没接通真正暂停 agent —— 闭环留 T4.5。"
        }
    }

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
            }
        }
    }

    private func label(for kind: LocalCodingAgentKind) -> String {
        let installed = availableKinds.contains(kind)
        return installed ? kind.displayName : "\(kind.displayName)(未安装)"
    }

    // MARK: - working dir section

    private var workingDirField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("工作目录")
                .font(.callout.weight(.medium))
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

    private var briefField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("任务简介(brief)")
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

    /// 用户当前实际会用的 cwd —— 提交时再 resolve(worktree 模式下要先跑 git add)。
    /// 这里只校验 *选择* 是否合法(`canSubmit`),不真 mkdir。
    private var pendingWorkingDirectory: URL? {
        switch workingDirMode {
        case .crewDefault: return crewDefaultURL
        case .custom: return customWorkingDirectory
        case .gitWorktree:
            // git worktree 实际路径在提交时算;这里只要 base 信息齐就够
            return crewDefaultURL
        }
    }

    // MARK: - actions

    private var canSubmit: Bool {
        guard !loadingKinds else { return false }
        guard availableKinds.contains(kind) else { return false }
        guard !initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
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
            return
        }
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
        if worktreeBaseBranch.isEmpty {
            if let cur = info.2, info.1.contains(cur) {
                worktreeBaseBranch = cur
            } else {
                worktreeBaseBranch = info.1.first ?? ""
            }
        }
    }

    private func submit() async {
        // 若已经有 active running run,提示用户先停。
        if let cur = sessionRunner.current, cur.status == .running {
            localError = "已有一个 session 正在运行,请先停止。"
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
