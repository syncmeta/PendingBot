#if os(macOS)
import SwiftUI
import AppKit

/// 新建 session sheet。在选中 crew 的中栏点 "新建 session" 触发。
///
/// Spec v2 §12.2 全字段：
/// - runner kind:Claude Code(主) / Codex(次,只要装了 CLI 就能选);UI 标注
///   Codex 还在 beta(spec v2 §8.1 TODO,部分 flag 未接通)
/// - 模型选:登录态 `GET /v1/models` 拉动态目录,native / OpenRouter 两个 section;
///   BYOK 态 fallback 成手动 model id 输入框
/// - 工作目录:默认沿用 `crew.workingDirectory`,可改;并据此推导 git repo / branch
/// - 所在地(runtime location):v1 写死 `local_host`,`peer_device` / `fly_machine`
///   灰显标注 "v1.1"
/// - 是否从新 worktree 起 + 选分支:勾上时 picker 从 `git for-each-ref` 列已有分支
///   (后续 T3.6 时真起 `git worktree add`;现在只把意图记下来)
/// - 任务 brief + 初始 prompt:文本框,prompt 走 stdin 不入 argv(spec v2 §8.4)
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

    @State private var workingDirectory: URL?

    // Model picker —— logged 模式拉 /v1/models;BYOK 走手动输入。
    @State private var availableModels: [ModelCatalogEntry] = []
    @State private var loadingModels: Bool = false
    @State private var modelsError: String?
    @State private var selectedModelSlug: String = ""    // "" = 让 CLI 用自带默认
    @State private var manualModelSlug: String = ""       // BYOK fallback

    // Runtime location —— v1 只允许 local_host。
    @State private var runtimeLocation: RuntimeLocation = .localHost

    // Worktree —— 勾上则起新分支(picker 列已有 branch);意图记下,实际
    // `git worktree add` 留 T3.6。
    @State private var useNewWorktree: Bool = false
    @State private var availableBranches: [String] = []
    @State private var loadingBranches: Bool = false
    @State private var selectedBranch: String = ""
    @State private var currentBranch: String?
    @State private var isGitRepo: Bool = false

    @State private var permissionMode: PermissionModeSelection = .inherit
    @State private var starting: Bool = false
    @State private var localError: String?

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
        // 2. 默认 cwd = crew 自带工作目录
        if workingDirectory == nil, let wd = detail.crew.workingDirectory, !wd.isEmpty {
            workingDirectory = URL(fileURLWithPath: (wd as NSString).expandingTildeInPath)
        }
        // 3. 拉模型目录(logged 模式;BYOK 模式 backend 返回空,UI 自动 fallback)
        await refreshModels()
        // 4. 探测 cwd 是不是 git repo + 列 branch
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

    private func refreshGitInfo() async {
        guard let wd = workingDirectory else {
            isGitRepo = false
            availableBranches = []
            currentBranch = nil
            return
        }
        loadingBranches = true
        defer { loadingBranches = false }
        let root = await GitInspector.repoRoot(at: wd)
        isGitRepo = (root != nil)
        if isGitRepo {
            currentBranch = await GitInspector.currentBranch(at: wd)
            availableBranches = await GitInspector.listBranches(at: wd)
            if selectedBranch.isEmpty, let cur = currentBranch {
                selectedBranch = cur
            }
        } else {
            availableBranches = []
            currentBranch = nil
            // 非 repo 时不允许勾 "新 worktree"
            useNewWorktree = false
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
                worktreeField
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

    // MARK: working directory

    private var workingDirField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("工作目录")
                .font(.callout.weight(.medium))
            HStack(spacing: 8) {
                if let url = workingDirectory {
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
                Button("选择…") { pickWorkingDirectory() }
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
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

    // MARK: worktree

    private var worktreeField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Toggle(isOn: $useNewWorktree) {
                    Text("从新 git worktree 起")
                        .font(.callout.weight(.medium))
                }
                .toggleStyle(.checkbox)
                .disabled(!isGitRepo)
                if loadingBranches {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            if !isGitRepo {
                Text(workingDirectory == nil
                    ? "选定工作目录后再决定。"
                    : "当前工作目录不是 git 仓库 —— 不能起 worktree。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(useNewWorktree ? "从分支:" : "在分支:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if availableBranches.isEmpty {
                            Text(currentBranch ?? "(detached HEAD)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("", selection: $selectedBranch) {
                                ForEach(availableBranches, id: \.self) { b in
                                    Text(b).tag(b)
                                        .font(.system(.callout, design: .monospaced))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 320, alignment: .leading)
                        }
                    }
                    if useNewWorktree {
                        Text("v1 还没真起 `git worktree add` —— 选中的分支会作为意图记下,T3.6 LocalRunner 闭环时接通。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else if let cur = currentBranch, cur != selectedBranch {
                        Text("提醒:选了 \(selectedBranch) 但 HEAD 在 \(cur);v1 不会替你切换,session 实际跑的是 HEAD 上的代码。")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
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

    // MARK: - actions

    private var canSubmit: Bool {
        guard !loadingKinds else { return false }
        guard availableKinds.contains(kind) else { return false }
        guard workingDirectory != nil else { return false }
        guard !initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard runtimeLocation == .localHost else { return false }
        return true
    }

    private func pickWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择工作目录"
        if let initial = workingDirectory {
            panel.directoryURL = initial
        }
        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url
            // 切了 cwd 就重新探 git
            Task { await refreshGitInfo() }
        }
    }

    private func submit() async {
        guard let wd = workingDirectory else { return }
        // 若已经有 active running run，提示用户先停（MVP 简单 guard；
        // 未来支持多 session 时这里改成允许并行）。
        if let cur = sessionRunner.current, cur.status == .running {
            localError = "已有一个 session 正在运行，请先停止。"
            return
        }
        starting = true
        defer { starting = false }
        localError = nil
        do {
            try await sessionRunner.start(
                crewId: detail.crew.id,
                kind: kind,
                workingDirectory: wd,
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
}
#endif
