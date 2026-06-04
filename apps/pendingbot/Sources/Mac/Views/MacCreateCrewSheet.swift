#if os(macOS)
import SwiftUI
import AppKit

/// 完整原生 Mac 版 #212 — 新建 crew sheet(对齐 iOS `CreateCrewV2Sheet`)。
///
/// 同一份 wire schema(`CreateCrewRequestV2` ↔ edge `CreateCrewBody`,刚从
/// `CrewAPI.swift` 去 iOS 门禁变跨平台)。Mac 版相比 iOS:
///   - 责任主体默认 caller 个人 subject(`crewCurrentSubject()`);多 subject 选择
///     留下次(同 iOS 取舍)。
///   - 运行位置 Picker 只允许 `local_host`;peer/fly 灰显 + 说明(待 Phase 4)。
///   - 工作目录:iOS 让用户手填,Mac 有 NSOpenPanel,这里给「选择目录…」按钮
///     直接选真实目录(AppKit 等价物,对齐铁律)。
///   - Captain:只支持 `system_generated`,模板 name 可填,默认走 edge 默认。
///
/// 提交→`POST /v1/crews`→`onCreated(crewId)` 关 sheet + 让父列重拉。
struct MacCreateCrewSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// 创建成功回调(带新 crewId),父 view 用来 refresh + 选中。
    let onCreated: (String) -> Void

    @State private var subject: CrewSubject?
    @State private var subjectLoadError: String?
    @State private var title = ""
    @State private var tag = ""
    @State private var workingDirectory = ""
    @State private var captainTemplateName = ""
    @State private var runtimeLocation: RuntimeOption = .localHost
    @State private var creating = false
    @State private var error: String?

    private let api = APIClient()

    enum RuntimeOption: String, CaseIterable, Identifiable {
        case localHost = "local_host"
        case peerDevice = "peer_device"
        case flyMachine = "fly_machine"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .localHost: return "本机(local_host)"
            case .peerDevice: return "peer 设备(待 Phase 4)"
            case .flyMachine: return "Fly machine(待 Phase 4)"
            }
        }
        var isEnabled: Bool { self == .localHost }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section("标题") {
                    TextField("例如:重构鉴权模块", text: $title)
                }

                Section("责任主体") {
                    if let subject {
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(subject.display_name).font(.body.weight(.medium))
                                Text(subject.subject_type == "group_account" ? "群账号" : "本人账号")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else if let subjectLoadError {
                        Text(subjectLoadError).font(.caption).foregroundStyle(.red)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("加载身份…").foregroundStyle(.secondary)
                        }
                    }
                    Text("crew 所有花费走这个 subject 的钱包结算。代表群账号创建留下次。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("运行位置") {
                    Picker("位置", selection: $runtimeLocation) {
                        ForEach(RuntimeOption.allCases) { opt in
                            Text(opt.label).tag(opt)
                        }
                    }
                    if !runtimeLocation.isEnabled {
                        Text("MVP 仅支持 local_host;peer / Fly machine 等 Phase 4 跨端遥控接通后开放。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                Section("工作目录") {
                    HStack(spacing: 8) {
                        TextField("/Users/me/repo(可选)", text: $workingDirectory)
                        Button("选择目录…") { pickWorkingDirectory() }
                    }
                    Text("session 起来时子进程的 cwd。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("标签(可选)") {
                    TextField("例如:重构、调研", text: $tag)
                }

                Section("机长") {
                    TextField("Captain 名称(留空用默认)", text: $captainTemplateName)
                    Text("将自动创建一个新的 captain bot 代表本机组。复用已有 bot 作 captain 留下次。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .frame(width: 460, height: 560)
        .task { await loadSubject() }
    }

    private var header: some View {
        HStack {
            Button("取消") { dismiss() }
            Spacer()
            Text("新建机组").font(.headline)
            Spacer()
            Button {
                Task { await submit() }
            } label: {
                if creating { ProgressView().controlSize(.small) }
                else { Text("创建") }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit || creating)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: 工作目录选择(AppKit NSOpenPanel — iOS 无此能力)

    private func pickWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 crew session 的工作目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workingDirectory = url.path
    }

    // MARK: 提交

    private var canSubmit: Bool {
        guard subject != nil else { return false }
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard runtimeLocation.isEnabled else { return false }
        return true
    }

    private func loadSubject() async {
        do {
            subject = try await api.crewCurrentSubject()
            subjectLoadError = nil
        } catch {
            subjectLoadError = "未加载身份:\(error.localizedDescription)"
        }
    }

    private func submit() async {
        guard let subject else { return }
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
#endif
