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
    /// 机长跑哪个本机 coding agent。**默认 Codex**（spec A）。
    @State private var selectedCaptainKind: LocalCodingAgentKind = .codex
    /// CrewGround 模式下提前挑好的目录名（如 "Lisbon"）—— 提交前就显示在框里
    /// （`~/CrewGround/Lisbon`），稳定不抖；真正建目录推迟到 submit。空 = 尚未算出。
    @State private var crewGroundName: String = ""
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
        // CrewGround 目录名提前挑好（稳定显示在框里），只挑一次。
        .onAppear { ensureCrewGroundName() }
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
                captainField
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    /// 通用「药丸式」可点选项按钮 —— 选中态高亮，未选灰底。替代下拉/菜单 Picker，
    /// 所有选项一眼平铺可点（spec B.1）。
    @ViewBuilder
    private func optionButton(_ label: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Color.accentColor : Color.gray.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("标题")
                .font(.callout.weight(.medium))
            HStack(spacing: 8) {
                optionButton("自动", selected: titleMode == .auto) { titleMode = .auto }
                optionButton("手动", selected: titleMode == .manual) { titleMode = .manual }
            }
            // 框始终在：自动模式下禁用 + 占位「Captain 来取名」、内容空；
            // 手动模式启用，可填。
            TextField(titleMode == .auto ? "Captain 来取名" : "例如：重构鉴权模块",
                      text: titleMode == .auto ? .constant("") : $title)
                .textFieldStyle(.roundedBorder)
                .disabled(titleMode == .auto)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var machineField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("运行机器")
                .font(.callout.weight(.medium))
            HStack(spacing: 8) {
                optionButton("本机", selected: selectedMachineId == nil) {
                    selectedMachineId = nil
                }
                ForEach(crewStore.machines) { machine in
                    if machine.deviceId != DeviceIdentity.current {
                        optionButton(machineLabel(machine),
                                     selected: selectedMachineId == machine.id) {
                            selectedMachineId = machine.id
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("crew 的 session 在这台机器上跑。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func machineLabel(_ m: Machine) -> String {
        let online = (m.status == "online") ? " ·在线" : ""
        return "\(m.displayName)\(online)"
    }

    private var workingDirField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("工作目录")
                .font(.callout.weight(.medium))
            HStack(spacing: 8) {
                optionButton("CrewGround", selected: workingDirMode == .crewGround) {
                    workingDirMode = .crewGround
                }
                optionButton("手动选择", selected: workingDirMode == .manual) {
                    workingDirMode = .manual
                }
                if hasLastDir {
                    optionButton("用上次", selected: workingDirMode == .lastUsed) {
                        workingDirMode = .lastUsed
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 目录框始终在下面，左对齐。
            workingDirBox
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var workingDirBox: some View {
        switch workingDirMode {
        case .crewGround:
            // 提前算好的目标路径（如 ~/CrewGround/Lisbon），稳定显示；submit 时才建。
            dirPathBox(crewGroundDisplayPath)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        case .lastUsed:
            if let last = lastDir {
                dirPathBox(last)
            } else {
                Text("没有上次使用的目录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 只读路径框 —— 等宽字体、左对齐、可选中。
    private func dirPathBox(_ path: String) -> some View {
        Text(path)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    /// CrewGround 模式要显示的完整目标路径 `~/CrewGround/<name>`（提交前预览）。
    private var crewGroundDisplayPath: String {
        let name = crewGroundName.isEmpty ? "…" : crewGroundName
        return "~/CrewGround/\(name)"
    }

    private var captainField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("机长（captain）")
                .font(.callout.weight(.medium))
            HStack(spacing: 8) {
                optionButton(LocalCodingAgentKind.claudeCode.displayName,
                             selected: selectedCaptainKind == .claudeCode) {
                    selectedCaptainKind = .claudeCode
                }
                optionButton(LocalCodingAgentKind.codex.displayName,
                             selected: selectedCaptainKind == .codex) {
                    selectedCaptainKind = .codex
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("机长以这个本机 coding agent 运行。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// 提前为 CrewGround 模式挑一个还没被占用的地名（只挑一次，存进
    /// `crewGroundName` 让框里显示稳定）。全占满了退化到 `Crew-<uuid8>`。
    /// 真正建目录推迟到 submit（`makeCrewGroundDirectory`）。
    private func ensureCrewGroundName() {
        guard crewGroundName.isEmpty else { return }
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("CrewGround", isDirectory: true)
        let existing = Set((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
        let names = PlaceNames.all.shuffled()
        crewGroundName = names.first { !existing.contains($0) }
            ?? "Crew-\(UUID().uuidString.prefix(8))"
    }

    /// 在 `~/CrewGround/` 下建出框里显示的那个目录（`crewGroundName`）。submit 时调。
    /// 名字为空（理论上不会，onAppear 已挑）兜底现挑一个；目标已存在则现退避换名。
    private func makeCrewGroundDirectory() throws -> URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent("CrewGround", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if crewGroundName.isEmpty { ensureCrewGroundName() }
        var pick = crewGroundName.isEmpty
            ? "Crew-\(UUID().uuidString.prefix(8))"
            : crewGroundName
        var dir = root.appendingPathComponent(pick, isDirectory: true)
        // 极小概率：onAppear 挑名后到提交前该名被占用 —— 退避换一个，别覆盖既有目录。
        if fm.fileExists(atPath: dir.path) {
            let existing = Set((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            pick = PlaceNames.all.shuffled().first { !existing.contains($0) }
                ?? "Crew-\(UUID().uuidString.prefix(8))"
            dir = root.appendingPathComponent(pick, isDirectory: true)
        }
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
                captainAgentKind: selectedCaptainKind.rawValue,
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
