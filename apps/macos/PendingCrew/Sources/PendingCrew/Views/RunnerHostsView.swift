import SwiftUI

struct RunnerHostsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var displayName = Host.current().localizedName ?? "Mac Runner"
    @State private var selectedKinds: Set<RunnerKind> = [.localCodex]
    @State private var progressSummary = "正在处理"
    @State private var finalSummary = "已完成"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                registerBox
                hostsBox
                activeSessionBox
            }
            .padding()
        }
        .navigationTitle("Runner")
    }

    private var registerBox: some View {
        GroupBox("注册本机 Runner") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("显示名称", text: $displayName)
                    .textFieldStyle(.roundedBorder)

                TextField("工作目录", text: $model.localWorkspacePath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        model.saveSettings()
                    }

                RunnerKindPicker(selectedKinds: $selectedKinds)

                Button {
                    Task {
                        await model.registerRunnerHost(displayName: displayName, kinds: selectedKinds)
                    }
                } label: {
                    Label("注册", systemImage: "desktopcomputer.and.arrow.down")
                }
                .disabled(model.personalSubjectId == nil || selectedKinds.isEmpty)
            }
        }
    }

    private var hostsBox: some View {
        GroupBox("已注册 Runner") {
            if model.runnerHosts.isEmpty {
                ContentUnavailableView("还没有 runner", systemImage: "desktopcomputer")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.runnerHosts) { host in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(host.displayName)
                                    .font(.headline)
                                Text("\(host.platform) · \(host.status)")
                                    .foregroundStyle(.secondary)
                                if let lastSeen = host.lastSeenAt {
                                    Text(lastSeen)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button {
                                Task { await model.heartbeat(hostId: host.id, kinds: selectedKinds) }
                            } label: {
                                Label("心跳", systemImage: "waveform.path.ecg")
                            }
                            .disabled(selectedKinds.isEmpty)

                            Button {
                                Task { await model.claimNextSession(hostId: host.id, kinds: selectedKinds) }
                            } label: {
                                Label("认领", systemImage: "tray.and.arrow.down")
                            }
                            .disabled(selectedKinds.isEmpty)
                        }
                        Divider()
                    }
                }
            }
        }
    }

    private var activeSessionBox: some View {
        GroupBox("当前认领") {
            if let session = model.activeRunnerSession {
                VStack(alignment: .leading, spacing: 12) {
                    Text(session.taskBrief)
                        .font(.headline)
                    Text("\(session.runnerKind) · \(session.status)")
                        .foregroundStyle(.secondary)
                    if let leaseId = model.activeRunnerLeaseId {
                        Text("lease: \(leaseId)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        model.saveSettings()
                        Task { await model.runActiveSessionLocally() }
                    } label: {
                        Label("本机执行", systemImage: "terminal")
                    }
                    .disabled(model.localWorkspacePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    TextField("进度摘要", text: $progressSummary)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button {
                            Task { await model.appendRunnerStatus(summary: progressSummary) }
                        } label: {
                            Label("上报进度", systemImage: "dot.radiowaves.left.and.right")
                        }

                        TextField("结束摘要", text: $finalSummary)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            Task { await model.finishActiveRunnerSession(status: "completed", summary: finalSummary) }
                        } label: {
                            Label("完成", systemImage: "checkmark.circle")
                        }
                        Button(role: .destructive) {
                            Task { await model.finishActiveRunnerSession(status: "failed", summary: finalSummary) }
                        } label: {
                            Label("失败", systemImage: "xmark.circle")
                        }
                    }
                }
            } else {
                ContentUnavailableView("还没有认领 session", systemImage: "tray")
            }
        }
    }
}

private struct RunnerKindPicker: View {
    @Binding var selectedKinds: Set<RunnerKind>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("能力")
                .foregroundStyle(.secondary)
            FlowLayout {
                ForEach(RunnerKind.allCases) { kind in
                    Toggle(kind.label, isOn: Binding(
                        get: { selectedKinds.contains(kind) },
                        set: { isSelected in
                            if isSelected {
                                selectedKinds.insert(kind)
                            } else {
                                selectedKinds.remove(kind)
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
        }
    }
}

private struct FlowLayout<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 14) {
            content
        }
    }
}
