#if os(macOS)
import SwiftUI

/// 右栏：当前 session 的 stdout/stderr 实时视图。
///
/// 这一层只观察 `CrewSessionRunner.current`（哪个 run 在前台）。具体
/// run 的 stdout/stderr/status 变化由内层 `SessionRunContentView` 通过
/// `@ObservedObject` 观察 —— **必须分两层**：`CrewSessionRun` 是嵌套的
/// ObservableObject，父 view 只 `@EnvironmentObject` 持有 runner 时不会
/// 订阅到 run 自己的 `@Published`，否则 stdout/status 更新了 UI 不刷新
/// （会卡在 "running" / "(空)"）。
struct CrewSessionWindowView: View {
    @EnvironmentObject private var sessionRunner: CrewSessionRunner
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var crewStore: CrewStore

    @State private var draft = ""
    @State private var starting = false
    @State private var localError: String?
    @State private var selectedKind: LocalCodingAgentKind = .claudeCode

    /// spec §9.3 + 用户心智：右栏是**常驻**和 claude/codex 交互的面（像 Codex
    /// Desktop）。没有 session 时就地给一个 composer —— **第一条消息即开始
    /// session**（零配置，用 crew 默认目录/runner/权限模式；无标题、无单独的
    /// 「新建」表单）。运行中再发 = `send_prompt` 续跑回合。
    var body: some View {
        VStack(spacing: 0) {
            if let run = sessionRunner.current {
                SessionRunContentView(run: run)
            } else {
                idleState
            }
            Divider()
            composer
        }
        .navigationTitle("Session")
    }

    private var isRunning: Bool { sessionRunner.current?.status == .running }

    private var idleState: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            if crewStore.selectedDetail == nil {
                Text("先在左侧选一个 crew").foregroundStyle(.secondary)
            } else {
                Text("给 agent 下第一条指令，开始一个 session")
                    .foregroundStyle(.secondary)
                Text("用 crew 的默认工作目录与权限模式，无需任何配置")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        VStack(spacing: 4) {
            if let localError {
                Text(localError).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                if !isRunning {
                    Picker("", selection: $selectedKind) {
                        Text("Claude Code").tag(LocalCodingAgentKind.claudeCode)
                        Text("Codex").tag(LocalCodingAgentKind.codex)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .disabled(starting)
                }
                TextField(isRunning ? "继续对 agent 说…（⌘↩ 发送）" : "下第一条指令开始…",
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .disabled(starting || crewStore.selectedDetail == nil)
                    .onSubmit { Task { await send() } }
                Button {
                    Task { await send() }
                } label: {
                    if starting { ProgressView().controlSize(.small) }
                    else { Image(systemName: "paperplane.fill") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(starting || crewStore.selectedDetail == nil
                          || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    // MARK: - actions

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let run = sessionRunner.current, run.status == .running {
            // Running session → queue as a send_prompt resume turn (T4.5).
            run.enqueueFollowUp(text)
            draft = ""
        } else {
            await startSession(firstPrompt: text)
        }
    }

    /// Zero-config start: crew default dir + runner kind + permission mode, with
    /// `firstPrompt` as the initial turn. No title, no task brief. Replicates the
    /// logged server-link prep (register host → create → claim) so cross-device
    /// viewers can follow it; BYOK stays local.
    private func startSession(firstPrompt: String) async {
        guard let detail = crewStore.selectedDetail else { return }
        guard let wd = detail.crew.workingDirectory, !wd.isEmpty else {
            localError = "这个 crew 没有工作目录 —— 在建 crew 时设置后再开 session。"
            return
        }
        let dir = URL(fileURLWithPath: (wd as NSString).expandingTildeInPath)
        starting = true
        defer { starting = false }
        localError = nil

        var serverLink: CrewSessionServerLink? = nil
        if appModel.mode == .logged {
            do { serverLink = try await prepareServerSession(detail: detail) }
            catch {
                localError = "服务端 session 准备失败: \(error.localizedDescription)"
                return
            }
        }
        do {
            try await sessionRunner.start(
                crewId: detail.crew.id,
                kind: selectedKind,
                workingDirectory: dir,
                taskBrief: "",
                initialPrompt: firstPrompt,
                serverLink: serverLink
            )
            draft = ""
        } catch {
            localError = error.localizedDescription
        }
    }

    private func prepareServerSession(detail: CrewDetail) async throws -> CrewSessionServerLink {
        let api = try appModel.loggedAPIClient()
        let subjects = try await api.listMySubjects()
        guard let subjectId = subjects.first?.id else {
            throw PendingCrewBackendError.invalidConfig("没有可用的 subject（device grant 未解析出主体）")
        }
        let hostId = try await appModel.ensureRunnerHost(
            api: api,
            subjectId: subjectId,
            allowedRunnerKinds: [
                LocalCodingAgentKind.claudeCode.serverRunnerKind,
                LocalCodingAgentKind.codex.serverRunnerKind,
            ]
        )
        let sessionId = try await api.createSession(
            crewId: detail.crew.id,
            runnerKind: selectedKind.serverRunnerKind,
            taskBrief: ""
        )
        _ = try await api.claimSession(runnerHostId: hostId, sessionId: sessionId)
        return CrewSessionServerLink(api: api, runnerHostId: hostId, sessionId: sessionId)
    }
}

/// 单个 run 的内容视图。`@ObservedObject` 订阅 run 的 `@Published`
/// （stdoutText / stderrText / status / exitCode），保证流式输出和状态
/// 变化能驱动 UI 刷新。
private struct SessionRunContentView: View {
    @ObservedObject var run: CrewSessionRun

    enum OutputTab: String, CaseIterable, Identifiable {
        case transcript, stdout, stderr
        var id: String { rawValue }
        var label: String {
            switch self {
            case .transcript: return "转写"
            case .stdout: return "stdout"
            case .stderr: return "stderr"
            }
        }
    }

    @State private var selectedTab: OutputTab = .transcript

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $selectedTab) {
                ForEach(OutputTab.allCases) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            outputView
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: run.kind == .claudeCode ? "sparkles" : "wand.and.stars")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.kind.displayName)
                    .font(.callout.weight(.semibold))
                if !run.taskBrief.isEmpty {
                    Text(run.taskBrief)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            statusBadge(run.status, exitCode: run.exitCode)
            if run.status == .running {
                Button(role: .destructive) {
                    Task { await run.cancel() }
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func statusBadge(_ status: CrewSessionRun.Status, exitCode: Int32?) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case .running: return ("running", .blue)
            case .completed:
                if let code = exitCode {
                    return code == 0 ? ("退出 0", .green) : ("退出 \(code)", .orange)
                }
                return ("已完成", .green)
            case .cancelled: return ("已取消", .secondary)
            case .failed:
                if let code = exitCode {
                    return ("失败 \(code)", .red)
                }
                return ("失败", .red)
            }
        }()
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var outputView: some View {
        if selectedTab == .transcript {
            transcriptView
        } else {
            rawTextView(selectedTab == .stdout ? run.stdoutText : run.stderrText)
        }
    }

    // Parsed, runner-agnostic transcript (the default tab). Falls back to the
    // raw stdout tab when nothing has been parsed yet (e.g. a CLI that printed
    // only non-JSONL warnings, or output not yet arrived).
    @ViewBuilder
    private var transcriptView: some View {
        if run.events.isEmpty {
            VStack(spacing: 8) {
                if run.status == .running {
                    ProgressView().controlSize(.small)
                    Text("等待 agent 输出…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("没有可转写的事件").font(.caption).foregroundStyle(.secondary)
                    Text("查看 stdout 标签页看原始输出").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(run.events.enumerated()), id: \.offset) { idx, event in
                            RunnerEventRow(event: event)
                                .id(idx)
                        }
                        Color.clear.frame(height: 1).id(tailID)
                    }
                    .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: run.events.count) { _, _ in
                    withAnimation(.linear(duration: 0.05)) {
                        proxy.scrollTo(tailID, anchor: .bottom)
                    }
                }
                .onAppear { proxy.scrollTo(tailID, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func rawTextView(_ text: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text.isEmpty ? "(空)" : text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    // sentinel —— scrollTo 用
                    Color.clear.frame(height: 1).id(tailID)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: text) { _, _ in
                // 自动滚到末尾。若用户向上滚了我们也强行回底 —— MVP
                // 阶段简单粗暴；后续可按 scroll position 判定是否粘底。
                withAnimation(.linear(duration: 0.05)) {
                    proxy.scrollTo(tailID, anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo(tailID, anchor: .bottom)
            }
        }
    }

    private var tailID: String { "session-tail" }
}

/// One transcript line. Each `RunnerEvent` case gets a distinct visual
/// grammar (icon + tint + body) so a glance separates assistant prose from
/// tool calls / reasoning / errors — independent of which CLI produced it.
private struct RunnerEventRow: View {
    let event: RunnerEvent

    var body: some View {
        switch event {
        case let .started(model, _):
            label("bolt.horizontal.circle", .secondary,
                  model.map { "会话开始 · \($0)" } ?? "会话开始", mono: false)
        case let .reasoning(text):
            label("brain", .purple, text, mono: false, secondary: true)
        case let .assistant(text):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .toolCall(title, detail):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wrench.and.screwdriver").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold))
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .toolResult(text, isError):
            label("arrow.turn.down.right", isError ? .red : .secondary,
                  text, mono: true, secondary: !isError)
        case let .finished(summary, isError, costUSD):
            let parts = [summary, costUSD.map { String(format: "$%.4f", $0) }]
                .compactMap { $0 }.filter { !$0.isEmpty }
            label(isError ? "xmark.seal" : "checkmark.seal",
                  isError ? .red : .green,
                  parts.isEmpty ? (isError ? "失败" : "完成")
                                : ((isError ? "失败 · " : "完成 · ") + parts.joined(separator: " · ")),
                  mono: false)
        case let .failed(text):
            label("exclamationmark.triangle.fill", .red, text, mono: false)
        case let .unknown(raw):
            label("questionmark.circle", .secondary, raw, mono: true, secondary: true)
        }
    }

    @ViewBuilder
    private func label(_ icon: String, _ tint: Color, _ text: String,
                       mono: Bool, secondary: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
                .font(mono ? .system(.caption, design: .monospaced) : .callout)
                .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
