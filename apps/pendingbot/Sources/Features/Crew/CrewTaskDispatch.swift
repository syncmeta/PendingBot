import SwiftUI

// #242 遥控 v1 — the「派任务」surface for crew chat.
//
// `CrewTaskDispatchSheet` collects a task brief + runner choice and posts a
// `message_kind='task_request'` crew message via CrewChatStore (the Mac
// relay picks it up and runs the session — out of scope here).
// `CrewTaskRequestCardView` is the timeline rendering of such a row: a small
// card (icon + 任务派发 + brief + runner tag) instead of a bubble.

// MARK: - Dispatch sheet

struct CrewTaskDispatchSheet: View {
    let store: CrewChatStore
    let detail: CrewDetailV2?

    @Environment(\.dismiss) private var dismiss
    @State private var brief = ""
    /// Wire vocab: 'claude_code' | 'codex'.
    @State private var runnerKind = "claude_code"
    @State private var sending = false

    private var canSubmit: Bool {
        !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("任务描述") {
                    TextField("要让 Mac 做什么…", text: $brief, axis: .vertical)
                        .lineLimit(4...10)
                }
                Section("Runner") {
                    Picker("Runner", selection: $runnerKind) {
                        Text("Claude Code").tag("claude_code")
                        Text("Codex").tag("codex")
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Button {
                        submit()
                    } label: {
                        if sending {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("派发中…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Text("派给 Mac")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle("派任务")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(sending)
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }

    private func submit() {
        guard canSubmit else { return }
        sending = true
        Task {
            // Failure surfaces via store.error (the crew view's existing
            // error alert); the sheet stays up so the brief isn't lost.
            let ok = await store.sendTaskRequest(
                brief: brief, runnerKind: runnerKind, detail: detail
            )
            sending = false
            if ok { dismiss() }
        }
    }
}

// MARK: - Timeline card

/// Inline rendering of a `message_kind=='task_request'` row.
struct CrewTaskRequestCardView: View {
    let payload: CrewTaskRequestPayload
    /// Fallback text when the payload carries no task_brief.
    let summary: String

    private var brief: String {
        payload.task_brief?.isEmpty == false ? payload.task_brief! : summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.footnote.weight(.semibold))
                Text("任务派发")
                    .font(.footnote.weight(.semibold))
                Spacer()
                Text(payload.runnerLabel)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.Palette.surfaceMuted))
            }
            .foregroundStyle(.secondary)

            Text(brief)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.Palette.surfaceMuted.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.Palette.surfaceMuted)
        )
        .padding(.horizontal, Theme.Metrics.gutter)
    }
}
