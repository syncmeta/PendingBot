#if os(macOS)
import SwiftUI

/// 右栏：当前 session 的 stdout/stderr 实时视图。
struct CrewSessionWindowView: View {
    @EnvironmentObject private var sessionRunner: CrewSessionRunner

    enum OutputTab: String, CaseIterable, Identifiable {
        case stdout, stderr
        var id: String { rawValue }
        var label: String {
            switch self {
            case .stdout: return "stdout"
            case .stderr: return "stderr"
            }
        }
    }

    @State private var selectedTab: OutputTab = .stdout

    var body: some View {
        Group {
            if let run = sessionRunner.current {
                content(run: run)
            } else {
                empty
            }
        }
        .navigationTitle("Session")
    }

    @ViewBuilder
    private func content(run: CrewSessionRun) -> some View {
        VStack(spacing: 0) {
            header(run: run)
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
            outputView(run: run)
        }
    }

    @ViewBuilder
    private func header(run: CrewSessionRun) -> some View {
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
    private func outputView(run: CrewSessionRun) -> some View {
        let text = selectedTab == .stdout ? run.stdoutText : run.stderrText
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

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("没有正在运行的 session")
                .foregroundStyle(.secondary)
            Text("在中栏点 \"新建 session\" 开始")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
