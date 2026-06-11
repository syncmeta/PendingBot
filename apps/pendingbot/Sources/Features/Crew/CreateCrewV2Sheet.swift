import SwiftUI

/// T4.6 — iOS 简化版的 "新建 crew" sheet。
///
/// 跟 PendingCrew Mac 端的 `CreateCrewSheet` 同一份 wire schema
/// (`CreateCrewRequestV2` ↔ edge `CreateCrewBody`), 但 iOS 这版更精简:
///   - title (必填)
///   - tag (可选)
///   - runtime location Picker — 只允许 `local_host`; peer/fly 灰显 +
///     说明文字 ("Phase 4 接通跨端遥控后开放")
///   - 工作目录 (可选; iOS 没有 NSOpenPanel, P0 这版让用户手填字符串
///     兜底——大多数 v1 用户会从 PendingCrew Mac 创建带工作目录的
///     crew, iOS 这边主要是看 + 简单建)
///   - Captain 部分: 只支持 `system_generated`, 模板 name TextField,
///     默认 "<crew title> 机长"
///
/// 提交→`POST /v1/crews`→关 sheet。父 view（CrewTabV2View）通过
/// onDismiss 重拉列表。
struct CreateCrewV2Sheet: View {
    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss

    /// 父 view 已经拉到的 caller 个人 subject，作为默认 responsibleSubjectId。
    let defaultSubject: CrewSubject?

    /// 创建成功后回调（带新 crewId），父 view 用来 dismiss + refresh。
    let onCreated: (String) -> Void

    @State private var title: String = ""
    @State private var tag: String = ""
    @State private var workingDirectory: String = ""
    @State private var captainTemplateName: String = ""
    @State private var runtimeLocation: RuntimeOption = .localHost
    @State private var creating = false
    @State private var error: String?

    /// 群账号 / 自己账号 picker 留 P1 — P0 默认就用 caller 的 user_account
    /// (defaultSubject)。多 subject 选择 (e.g. 给某个群账号建 crew) 是更
    /// 显眼的 UX，应当在 CrewTabV2View 的 "+" 上方先选 subject 再开 sheet，
    /// 或在 sheet 顶部加 subject picker。本次 sheet 先把简单路径打通。

    enum RuntimeOption: String, CaseIterable, Identifiable {
        case localHost = "local_host"
        case peerDevice = "peer_device"
        case flyMachine = "fly_machine"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .localHost: return "本机（local_host）"
            case .peerDevice: return "peer 设备（待 Phase 4）"
            case .flyMachine: return "Fly machine（待 Phase 4）"
            }
        }

        var isEnabled: Bool { self == .localHost }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：重构鉴权模块", text: $title)
                        .platformAutocapitalization()
                        .autocorrectionDisabled()
                } header: {
                    Text("标题")
                } footer: {
                    Text("会显示在机组列表里。")
                }

                Section {
                    if let subject = defaultSubject {
                        HStack {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(subject.display_name)
                                    .font(.body.weight(.medium))
                                Text(subject.subject_type == "group_account" ? "群账号" : "本人账号")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("未加载身份，请稍后再试").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("责任主体")
                } footer: {
                    Text("crew 所有花费走这个 subject 的钱包结算。代表群账号创建留下次（需要先在顶部菜单切身份）。")
                }

                Section {
                    Picker("位置", selection: $runtimeLocation) {
                        ForEach(RuntimeOption.allCases) { opt in
                            Text(opt.label).tag(opt)
                        }
                    }
                    if !runtimeLocation.isEnabled {
                        Text("MVP 仅支持 local_host；peer / Fly machine 等 Phase 4 跨端遥控接通后开放。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("运行位置")
                }

                Section {
                    TextField("/Users/me/repo (可选)", text: $workingDirectory)
                        .platformAutocapitalization()
                        .autocorrectionDisabled()
                } header: {
                    Text("工作目录")
                } footer: {
                    Text("session 起来时子进程的 cwd。iOS 不能直接选目录；建议留空并在 PendingCrew Mac 上配。")
                }

                Section {
                    TextField("例如：重构、调研", text: $tag)
                        .platformAutocapitalization()
                        .autocorrectionDisabled()
                } header: {
                    Text("标签 (可选)")
                }

                Section {
                    TextField("Captain 名称 (留空用默认)", text: $captainTemplateName)
                        .platformAutocapitalization()
                        .autocorrectionDisabled()
                } header: {
                    Text("机长")
                } footer: {
                    Text("将自动创建一个新的 captain bot 代表本机组。复用已有 bot 作 captain 留下次（需要 GET /v1/me/bots 接通）。")
                }
            }
            .navigationTitle("新建机组")
            .inlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .platformLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .platformTrailing) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if creating {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("创建")
                        }
                    }
                    .disabled(!canSubmit || creating)
                }
            }
            .alert("创建失败", isPresented: .constant(error != nil)) {
                Button("好") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    // MARK: - Submission

    private var canSubmit: Bool {
        guard defaultSubject != nil else { return false }
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard runtimeLocation.isEnabled else { return false }
        return true
    }

    private func submit() async {
        guard let api, let subject = defaultSubject else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }
        creating = true
        defer { creating = false }

        let trimmedTag = tag.trimmingCharacters(in: .whitespaces)
        let trimmedCwd = workingDirectory.trimmingCharacters(in: .whitespaces)
        let trimmedTemplate = captainTemplateName.trimmingCharacters(in: .whitespaces)

        let request = CreateCrewRequestV2.localHost(
            responsibleSubjectId: subject.id,
            title: trimmedTitle,
            workingDirectory: trimmedCwd.isEmpty ? nil : trimmedCwd,
            tag: trimmedTag.isEmpty ? nil : trimmedTag,
            captain: .systemGenerated(templateName: trimmedTemplate.isEmpty ? nil : trimmedTemplate)
        )

        do {
            let response = try await api.createCrewV2(request)
            onCreated(response.crewId)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
