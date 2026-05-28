#if os(macOS)
import SwiftUI
import AppKit

/// 新建 session sheet。在选中 crew 的中栏点 "新建 session" 触发。
///
/// MVP scope:
/// - runner kind: Claude Code / Codex
/// - 任务 brief（一句话） + 初始 prompt（多行）
/// - 工作目录默认沿用 crew.workingDirectory，可改
/// - worktree / branch 选项灰显（下次）
///
/// 创建后调 CrewSessionRunner.start —— 真起子进程；如果有上一个 run
/// 还没结束，sheet 上给个确认提示。
struct CreateSessionSheet: View {
    let detail: CrewDetail

    @EnvironmentObject private var sessionRunner: CrewSessionRunner
    @Environment(\.dismiss) private var dismiss

    @State private var kind: LocalCodingAgentKind = .claudeCode
    @State private var availableKinds: [LocalCodingAgentKind] = []
    @State private var loadingKinds: Bool = true
    @State private var taskBrief: String = ""
    @State private var initialPrompt: String = ""
    @State private var workingDirectory: URL?
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 560)
        .frame(minHeight: 560)
        .task {
            // discover 装好的 runner kind；同时填默认 cwd。
            availableKinds = await MacLocalCodingAgentService().discoverAvailable()
            loadingKinds = false
            if !availableKinds.contains(kind) {
                if let first = availableKinds.first {
                    kind = first
                }
            }
            if workingDirectory == nil, let wd = detail.crew.workingDirectory, !wd.isEmpty {
                workingDirectory = URL(fileURLWithPath: (wd as NSString).expandingTildeInPath)
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
                workingDirField
                worktreePlaceholder
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
        case .inherit: return "用 crew 设定的默认模式（如果没设过,默认为自动）。"
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
        return installed ? kind.displayName : "\(kind.displayName)（未安装）"
    }

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

    private var worktreePlaceholder: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.tertiary)
            Text("worktree / 分支选项 — 下次再做")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

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
                permissionModeOverride: permissionMode.wireValue
            )
            dismiss()
        } catch {
            localError = error.localizedDescription
        }
    }
}
#endif
