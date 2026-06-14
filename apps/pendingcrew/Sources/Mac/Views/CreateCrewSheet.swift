#if os(macOS)
import SwiftUI
import AppKit

/// 新建 crew 的 sheet（精简版）。
///
/// 表单只剩三件事：
/// - **标题**：自动（留给 captain 之后总结命名）vs 手动填。
/// - **machine**：仅当本账号有 >1 台机器时显示（默认本机）；单机不显示。
/// - **工作目录**：手动选择 / 用上次 / CrewGround（默认 CrewGround，会在
///   `~/CrewGround/<随机地名>` 新建一个目录）。
///
/// 删掉了旧版的：代表 subject picker（默认本人 subject）、runtime picker、
/// 标签、captain 配置（captain 恒 `.systemGenerated(templateName: nil)`，
/// 配置由父 crew / 本机模板池在别处承载）。
///
/// `parentCrewId` 非 nil 时（从某个 crew 里点「新建子 crew」进来），建完
/// 自动 `attachParent` 把新 crew 挂到该父 crew 之下。
struct CreateCrewSheet: View {
    @EnvironmentObject private var crewStore: CrewStore
    @Environment(\.dismiss) private var dismiss

    /// 非 nil = 这是某个 crew 的「新建子 crew」，建完自动挂到它之下。
    let parentCrewId: String?

    init(parentCrewId: String? = nil) {
        self.parentCrewId = parentCrewId
    }

    enum TitleMode: Hashable { case auto, manual }
    enum WorkingDirMode: Hashable { case manual, lastUsed, crewGround }

    @State private var titleMode: TitleMode = .auto
    @State private var title: String = ""
    /// nil = 本机。
    @State private var selectedMachineId: String?
    @State private var workingDirMode: WorkingDirMode = .crewGround
    @State private var manualWorkingDir: URL?
    @State private var creating = false
    @State private var localError: String?

    private static let lastDirKey = "pendingcrew.lastWorkingDirectory"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 520)
        .frame(minHeight: 460)
        .task {
            // sheet 打开时确保 subjects / machines 已拉过（父 view 多半已 prefetch，
            // 这里再保险一次）。
            if crewStore.subjects.isEmpty {
                await crewStore.refreshSubjects()
            }
            if crewStore.machines.isEmpty {
                await crewStore.refreshMachines()
            }
        }
    }

    // MARK: - sections

    private var header: some View {
        HStack {
            Text(parentCrewId == nil ? "新建 crew" : "新建子 crew")
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
                if crewStore.machines.count > 1 {
                    machineField
                }
                workingDirField
            }
            .padding(20)
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("标题")
                .font(.callout.weight(.medium))
            Picker("", selection: $titleMode) {
                Text("自动（让机长之后命名）").tag(TitleMode.auto)
                Text("手动填写").tag(TitleMode.manual)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            if titleMode == .manual {
                TextField("例如：重构鉴权模块", text: $title)
                    .textFieldStyle(.roundedBorder)
            } else {
                Text("留空交给机长 —— 它会在干起来之后总结一个标题。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var machineField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("运行机器")
                .font(.callout.weight(.medium))
            Picker("", selection: Binding(
                get: { selectedMachineId ?? "" },
                set: { selectedMachineId = $0.isEmpty ? nil : $0 }
            )) {
                Text("本机").tag("")
                ForEach(crewStore.machines) { machine in
                    if machine.deviceId != DeviceIdentity.current {
                        Text(machineLabel(machine)).tag(machine.id)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Text("crew 的 session 在这台机器上跑。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func machineLabel(_ m: Machine) -> String {
        let online = (m.status == "online") ? " ·在线" : ""
        return "\(m.displayName)\(online)"
    }

    private var workingDirField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("工作目录")
                .font(.callout.weight(.medium))
            Picker("", selection: $workingDirMode) {
                Text("CrewGround（自动新建）").tag(WorkingDirMode.crewGround)
                Text("手动选择").tag(WorkingDirMode.manual)
                if hasLastDir {
                    Text("用上次").tag(WorkingDirMode.lastUsed)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            switch workingDirMode {
            case .crewGround:
                Text("将在 ~/CrewGround/<随机地名> 新建一个目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .manual:
                HStack(spacing: 8) {
                    if let url = manualWorkingDir {
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
            case .lastUsed:
                if let last = lastDir {
                    Text(last)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Text("没有上次使用的目录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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

    // MARK: - working-dir helpers

    private var lastDir: String? {
        UserDefaults.standard.string(forKey: Self.lastDirKey)
    }

    private var hasLastDir: Bool {
        !(lastDir?.isEmpty ?? true)
    }

    // MARK: - actions

    /// CrewGround / 用上次 恒可提交；手动模式须已选目录。标题自动允许空。
    private var canSubmit: Bool {
        switch workingDirMode {
        case .manual: return manualWorkingDir != nil
        case .lastUsed: return hasLastDir
        case .crewGround: return true
        }
    }

    private func pickWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择工作目录"
        if panel.runModal() == .OK, let url = panel.url {
            manualWorkingDir = url
        }
    }

    /// 代表 subject —— 默认 caller 本人。登录态 = 本人 user_account subject
    /// （`crewStore.subjects.first`，`/v1/me/subject` 返回的就是 grant 代表的
    /// 那个）；本地态 = LocalBackend 的假本机 subject（`local-byok`）。两条路
    /// 都走 `crewStore.subjects.first?.id`，跟各自 backend 的 listMySubjects 一致。
    private func resolveResponsibleSubjectId() async throws -> String {
        if crewStore.subjects.isEmpty {
            await crewStore.refreshSubjects()
        }
        guard let id = crewStore.subjects.first?.id else {
            throw CreateCrewError.noSubject
        }
        return id
    }

    private func resolveWorkingDirectory() throws -> URL {
        switch workingDirMode {
        case .manual:
            guard let d = manualWorkingDir else { throw CreateCrewError.noDirectory }
            return d
        case .lastUsed:
            guard let p = lastDir, !p.isEmpty else { throw CreateCrewError.noLastDirectory }
            return URL(fileURLWithPath: p)
        case .crewGround:
            return try makeCrewGroundDirectory()
        }
    }

    /// 在 `~/CrewGround/` 下挑一个还没被占用的地名建子目录。全占满了就退化到
    /// `Crew-<uuid8>`，保证总能建出来。
    private func makeCrewGroundDirectory() throws -> URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent("CrewGround", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let existing = Set((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
        let names = PlaceNames.all.shuffled()
        let pick = names.first { !existing.contains($0) } ?? "Crew-\(UUID().uuidString.prefix(8))"
        let dir = root.appendingPathComponent(pick, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func submit() async {
        creating = true
        defer { creating = false }
        localError = nil
        do {
            let subjectId = try await resolveResponsibleSubjectId()
            let resolvedDir = try resolveWorkingDirectory()
            let titleValue: String? = (titleMode == .manual)
                ? {
                    let t = title.trimmingCharacters(in: .whitespaces)
                    return t.isEmpty ? nil : t
                }()
                : nil
            let request = CreateCrewRequest.make(
                responsibleSubjectId: subjectId,
                title: titleValue,
                machineId: selectedMachineId,
                workingDirectory: resolvedDir.path,
                captain: .systemGenerated(templateName: nil)
            )
            let resp = try await crewStore.createCrew(request)
            // 从某个 crew 里建的子 crew → 自动挂到父 crew 之下。
            if let parentCrewId {
                try await crewStore.attachParent(crewId: resp.crewId, parentCrewId: parentCrewId)
            }
            UserDefaults.standard.set(resolvedDir.path, forKey: Self.lastDirKey)
            dismiss()
        } catch {
            localError = error.localizedDescription
        }
    }
}

/// CreateCrewSheet 本地解析错误。
enum CreateCrewError: LocalizedError {
    case noSubject
    case noDirectory
    case noLastDirectory

    var errorDescription: String? {
        switch self {
        case .noSubject: return "没有可代表的 subject"
        case .noDirectory: return "请先选择工作目录"
        case .noLastDirectory: return "没有上次使用的目录"
        }
    }
}
#endif
