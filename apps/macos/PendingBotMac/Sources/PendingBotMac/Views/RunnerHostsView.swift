import SwiftUI

struct RunnerHostsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var displayName = Host.current().localizedName ?? "Mac Runner"
    @State private var selectedKinds: Set<RunnerKind> = [.localCodex]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                registerBox
                hostsBox
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
                        }
                        Divider()
                    }
                }
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

