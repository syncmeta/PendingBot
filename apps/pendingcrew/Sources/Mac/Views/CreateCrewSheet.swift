#if os(macOS)
import SwiftUI
import AppKit

/// 新建 crew 的 sheet。MVP 阶段:
/// - title 必填
/// - 代表 subject Picker，从 crewStore.subjects（GET /v1/me/subjects）
/// - runtimeLocation 强制 local_host（peer/fly 灰显，下次接通后开放）
/// - 工作目录通过 NSOpenPanel 选
/// - 可选 tag
/// - Captain section: MVP 只支持 system_generated（自动建新 captain bot）
///
/// reuse_bot 路径需要先 ship `GET /v1/me/bots`；留下次。
struct CreateCrewSheet: View {
    @EnvironmentObject private var crewStore: CrewStore
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var tag: String = ""
    @State private var selectedSubjectId: String?
    @State private var runtimeLocation: String = "local_host"
    @State private var workingDirectory: URL?
    @State private var captainTemplateName: String = ""
    @State private var creating: Bool = false
    @State private var localError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 520)
        .frame(minHeight: 540)
        .task {
            // sheet 打开时确保 subjects 已经拉过 —— 父 view 也 prefetch
            // 过一次，但 sheet 单独 mount 时再保险一次。
            if crewStore.subjects.isEmpty {
                await crewStore.refreshSubjects()
            }
            // 默认选 user_account（caller 本人）
            if selectedSubjectId == nil {
                selectedSubjectId = crewStore.subjects.first(where: { $0.kindEnum == .userAccount })?.id
                    ?? crewStore.subjects.first?.id
            }
        }
    }

    // MARK: - sections

    private var header: some View {
        HStack {
            Text("新建 crew")
                .font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                titleField
                subjectField
                runtimeField
                workingDirField
                tagField
                Divider()
                captainSection
            }
            .padding(20)
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("标题")
                .font(.callout.weight(.medium))
            TextField("例如：重构鉴权模块", text: $title)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var subjectField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("代表 subject")
                .font(.callout.weight(.medium))
            if crewStore.loadingSubjects && crewStore.subjects.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("加载中…").foregroundStyle(.secondary)
                }
            } else if crewStore.subjects.isEmpty {
                Text("没有可代表的 subject")
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: Binding(
                    get: { selectedSubjectId ?? "" },
                    set: { selectedSubjectId = $0.isEmpty ? nil : $0 }
                )) {
                    ForEach(crewStore.subjects) { subj in
                        Text(subjectLabel(subj)).tag(subj.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            Text("crew 的所有花费走这个 subject 的钱包结算。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func subjectLabel(_ s: UserSubject) -> String {
        switch s.kindEnum {
        case .userAccount: return "\(s.displayName)（本人）"
        case .groupAccount: return "\(s.displayName)（群账号·\(s.role ?? "?")）"
        case .none: return s.displayName
        }
    }

    private var runtimeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Runtime location")
                .font(.callout.weight(.medium))
            Picker("", selection: $runtimeLocation) {
                Text("本机（local_host）").tag("local_host")
                Text("peer 设备（待 Phase 4）").tag("peer_device")
                // Fly machine 在 BYOK 模式禁用 —— 加 "(需登录)" 后缀让用户
                // 一眼看出原因。Picker.disabled 的 case 在 macOS 上跟正常
                // case 视觉差异不明显,通过文字补强。
                Text(crewStore.supportsCloudRuntime
                     ? "Fly machine（待 Phase 4）"
                     : "Fly machine（需登录 PendingBot 解锁）")
                    .tag("fly_machine")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            if runtimeLocation == "fly_machine", !crewStore.supportsCloudRuntime {
                Label(
                    "BYOK 模式不支持云端 runtime。登录 PendingBot 账号后可用 Fly machine。",
                    systemImage: "lock.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else if runtimeLocation != "local_host" {
                Text("MVP 仅支持 local_host；peer/Fly 等 Phase 4 完成后开放。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
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
                        .foregroundStyle(.primary)
                } else {
                    Text("未选择")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("选择…") { pickWorkingDirectory() }
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            Text("session 起来时子进程的 cwd。可在新建 session 时按需覆盖。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tagField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("标签（可选）")
                .font(.callout.weight(.medium))
            TextField("例如：重构、调研", text: $tag)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var captainSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("机长（captain bot）")
                .font(.callout.weight(.medium))
            Text("将自动创建一个新的 captain bot 代表本 crew。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Captain 名称（留空则用默认）", text: $captainTemplateName)
                .textFieldStyle(.roundedBorder)
            Text("注：复用已有 bot 作 captain 留下次（需要 GET /v1/me/bots 接通）。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let err = localError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                Task { await submit() }
            } label: {
                if creating {
                    ProgressView().controlSize(.small)
                } else {
                    Text("创建")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit || creating)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - actions

    private var canSubmit: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard selectedSubjectId != nil else { return false }
        guard runtimeLocation == "local_host" else { return false }
        // 工作目录对 local_host 是强烈推荐而非硬性必填（edge 允许 null），
        // 但 MVP 阶段 session 起来需要它，所以强制要求。
        guard workingDirectory != nil else { return false }
        // BYOK 模式不接受 fly_machine —— 上面 picker 已禁用,这里防御一下
        // 万一 picker 状态绕过。
        if !crewStore.supportsCloudRuntime, runtimeLocation == "fly_machine" {
            return false
        }
        return true
    }

    private func pickWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择工作目录"
        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url
        }
    }

    private func submit() async {
        guard let subjectId = selectedSubjectId,
              let wd = workingDirectory else { return }
        creating = true
        defer { creating = false }
        localError = nil

        let templateName = captainTemplateName.trimmingCharacters(in: .whitespaces)
        let captain: CreateCrewRequest.Captain = .systemGenerated(
            templateName: templateName.isEmpty ? nil : templateName
        )

        let tagValue = tag.trimmingCharacters(in: .whitespaces)
        let request = CreateCrewRequest.localHost(
            responsibleSubjectId: subjectId,
            title: title.trimmingCharacters(in: .whitespaces),
            workingDirectory: wd.path,
            tag: tagValue.isEmpty ? nil : tagValue,
            captain: captain
        )

        do {
            _ = try await crewStore.createCrew(request)
            dismiss()
        } catch {
            localError = error.localizedDescription
        }
    }
}
#endif
