#if os(macOS)
import Foundation

/// edge 信箱同步代理（接合 v2 block 3 relay）。
///
/// 对所有 `remoteConversationId != nil` 的本地 crew 跑 5s 轮询双向搬运：
/// - **拉**：`GET /v1/crews/:remoteId/messages?since=<relayCursor>` →
///   过滤掉 Mac 自己推上去的（`relay.origin == mac_relay`）和已同步过的
///   （按 edge message id 幂等）→ 写进本地白板（带 edge 侧发送者名字、
///   `senderSessionId = nil`）→ 游标推进到 `lastCursor`。
/// - **推**：本地白板推送水位之后的、本地产生的（非 relay 写入的）新消息 →
///   `POST messages`（senderLabel = 本地发送者名、localSessionId =
///   senderSessionId；edge 据此打 `origin:mac_relay`，拉取侧不会拉回）→
///   每发成功一条就推进水位（半途失败下个 tick 从断点续推）。
///
/// **绑定基线**：首 tick 发现水位为 nil 且白板非空 → 把水位钉在当前白板末尾、
/// 本 tick 不上行 —— 接入前的本地历史不回灌 edge（spec §3.3：只搬"之后"的）。
///
/// 纯合并/过滤/水位逻辑在 `CrewRelaySyncLogic`（可单测）；本类只做编排 + IO。
/// 网络错误静默吞掉（console log），下一 tick 自然重试 —— relay 本来就是
/// best-effort 搬运，断线靠 cursor/水位补齐。
///
/// captain 感知（M4）：relay 消息落进 LocalWhiteboardStore 后，captain 的
/// 世界观注入 / 唤醒（LocalSessionWorldModel 读同一份白板）自动覆盖，无需新通道。
@MainActor
final class CrewRelayAgent: ObservableObject {
    private weak var appModel: AppModel?
    /// task_request 自动起 session 用（#242）。MacThreePaneView 注入（与右栏
    /// 手动起 session 是同一个 runner —— 自动起的 run 直接出现在切换条上）。
    private weak var sessionRunner: CrewSessionRunner?
    private var timer: Timer?
    /// tick 重入保护 —— 上一轮还在网络 IO 时跳过本轮。
    private var ticking = false

    private let crewStore: LocalCrewStore
    private let whiteboard: LocalWhiteboardStore

    init(crewStore: LocalCrewStore? = nil, whiteboard: LocalWhiteboardStore? = nil) {
        self.crewStore = crewStore ?? .shared
        self.whiteboard = whiteboard ?? .shared
    }

    /// 启动轮询（MacThreePaneView `.task` 调，幂等）。未登录时 tick 是 no-op，
    /// 登录后无需重启 —— 下个 tick 自动开始干活。
    func start(appModel: AppModel, sessionRunner: CrewSessionRunner? = nil) {
        self.appModel = appModel
        self.sessionRunner = sessionRunner
        guard timer == nil else { return }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task { await tick() }   // 启动立即跑一轮，不等首个 5s
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Tick

    private func tick() async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        guard let appModel, appModel.isAuthenticated,
              let api = try? appModel.loggedAPIClient() else { return }
        for binding in crewStore.listRelayBindings() {
            await pull(binding, api: api)
            await push(binding, api: api)
        }
    }

    /// 拉：edge 新条目 → 本地白板。
    private func pull(_ b: LocalCrewRelayBinding, api: PendingCrewAPI) async {
        do {
            let page = try await api.listCrewWhiteboardPage(
                crewId: b.remoteConversationId, since: b.relayCursor)
            let known = whiteboard.relayRemoteIds(crewId: b.crewId)
            let importable = Set(CrewRelaySyncLogic.importableRemoteIds(
                pulled: page.whiteboard.map {
                    .init(remoteId: $0.id, isMacRelayOrigin: $0.relay?.origin == "mac_relay")
                },
                known: known))
            for entry in page.whiteboard where importable.contains(entry.id) {
                let text = entry.displayText
                guard !text.isEmpty else { continue }
                whiteboard.appendRelayMessage(
                    crewId: b.crewId,
                    remoteId: entry.id,
                    senderKind: entry.senderKind,
                    senderDisplayName: Self.remoteSenderName(entry),
                    text: text,
                    createdAt: entry.createdAt)
            }
            if let cursor = page.lastCursor {
                crewStore.setRelayCursor(crewId: b.crewId, cursor: cursor)
            }
            // #242 遥控 v1：本批里的新 task_request 指令 → 本地起 session。
            // 白板写入在上面照常发生（用户能看到这条指令本身）。
            let requests = CrewRelaySyncLogic.newTaskRequests(
                pulled: page.whiteboard.map {
                    .init(remoteId: $0.id,
                          isMacRelayOrigin: $0.relay?.origin == "mac_relay",
                          isTaskRequest: $0.messageKind == "task_request",
                          action: $0.payload?.action,
                          taskBrief: $0.payload?.taskBrief,
                          runnerKind: $0.payload?.runnerKind)
                },
                processed: crewStore.processedTaskRequestIds(crewId: b.crewId))
            for req in requests {
                await handleTaskRequest(req, binding: b, api: api)
            }
        } catch {
            NSLog("[CrewRelayAgent] pull \(b.crewId) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - task_request → 本地起 session（#242 遥控 v1）

    /// 处理一条远程 task_request：成功 / 明确不可行（无 runner / 无工作目录 /
    /// session 满）都标记 processed —— 不可行时上行一条 mac_relay 说明，用户
    /// 看到后可调整再发一条新指令；不做静默重试（避免每 tick 反复尝试 + 刷屏）。
    private func handleTaskRequest(
        _ req: CrewRelaySyncLogic.RelayTaskRequest,
        binding b: LocalCrewRelayBinding,
        api: PendingCrewAPI
    ) async {
        // 先落 processed —— start 是 async，防极端情况下（本 tick 内异常）重复处理。
        crewStore.markTaskRequestProcessed(crewId: b.crewId, remoteId: req.remoteId)

        func reportBack(_ text: String) async {
            do {
                // senderLabel 必带 → edge 打 origin:mac_relay，拉取侧不会拉回。
                _ = try await api.postCrewMessage(
                    crewId: b.remoteConversationId, text: text, senderLabel: "Mac")
            } catch {
                NSLog("[CrewRelayAgent] task_request report-back failed: \(error.localizedDescription)")
            }
        }

        guard let runner = sessionRunner else {
            NSLog("[CrewRelayAgent] task_request \(req.remoteId) skipped: no sessionRunner injected")
            return
        }
        guard runner.runs.filter({ $0.status == .running }).count < CrewSessionRunner.maxConcurrentRuns else {
            await reportBack("📥 任务已收到，但本机同时运行的 session 已满（\(CrewSessionRunner.maxConcurrentRuns)）—— 先停掉一些再重新发一次指令。")
            return
        }
        guard let wd = b.workingDirectory, !wd.isEmpty else {
            await reportBack("📥 任务已收到，但这个 crew 没有工作目录 —— 在 Mac 上设置后重新发一次指令。")
            return
        }
        let dir = URL(fileURLWithPath: (wd as NSString).expandingTildeInPath)

        // 镜像 CrewSessionWindowView 手动起 worker session 的工序：
        // kind → isolation workdir → 世界观 → 本地 comms（MCP + hooks）。
        let kind: LocalCodingAgentKind =
            (req.runnerKind?.contains("codex") == true) ? .codex : .claudeCode
        var cfg = SessionConfig(kind: kind, initialPrompt: req.taskBrief)
        let workdir = SessionWorkspace.resolve(
            crewDirectory: dir, isolation: cfg.isolation, hint: req.taskBrief)
        let localSessionId = UUID().uuidString.lowercased()
        // 世界观 + comms 接线按 kind 分叉：claude 走文件标志（--append-system-prompt-file
        // / --settings / --mcp-config）；codex 没这些通道 —— 世界观经 developerInstructions、
        // MCP 经 mcpServers dict 走协议传入。best-effort：渲染失败 nil 不挡启动。
        var codexDevInstructions: String? = nil
        var codexMcp: [String: Any]? = nil
        let members: [CrewMember]
        if let backend = appModel?.backend {
            members = (try? await backend.listCrewMembers(crewId: b.crewId))?.members ?? []
        } else {
            members = []
        }
        let detail = crewStore.getCrew(b.crewId)
        // relay 自动起的 worker session 的白板发送者名：agent 名 + session id 前缀
        // （与手动起 / CrewSessionRun.displayName 同款），post_to_crew 不再裸 uuid。
        let workerLabel = kind.displayName + " · " + String(localSessionId.prefix(6))
        switch kind {
        case .claudeCode:
            // claude 行为不变：detail+backend 都在才渲染世界观文件；comms 恒接。
            if let detail, appModel?.backend != nil {
                cfg.appendSystemPromptFile = LocalSessionLaunch.renderWorldModelFile(
                    detail: detail, members: members, taskBrief: req.taskBrief,
                    workdir: workdir, sessionId: localSessionId, runnerKind: kind)
            }
            let comms = LocalSessionLaunch.prepareLocalCommsConfig(
                crewId: b.crewId, sessionId: localSessionId, label: workerLabel)
            cfg.settingsFile = comms.settings
            cfg.mcpConfigFile = comms.mcp
        case .codex:
            if let detail {
                codexDevInstructions = LocalSessionLaunch.renderWorldModelString(
                    detail: detail, members: members, taskBrief: req.taskBrief,
                    workdir: workdir, sessionId: localSessionId)
            }
            codexMcp = LocalSessionLaunch.codexMcpServers(
                crewId: b.crewId, sessionId: localSessionId, label: workerLabel)
        }
        do {
            try await runner.start(
                crewId: b.crewId,
                sessionId: localSessionId,
                config: cfg,
                workingDirectory: workdir,
                taskBrief: req.taskBrief,
                developerInstructions: codexDevInstructions,
                codexMcpServers: codexMcp)
            await reportBack("🚀 已在 Mac 上启动 \(kind.displayName) session（\(localSessionId.prefix(8))），任务：\(req.taskBrief)")
        } catch {
            await reportBack("⚠️ 任务已收到，但本机起 session 失败：\(error.localizedDescription)")
        }
    }

    /// 推：本地新消息 → edge。
    private func push(_ b: LocalCrewRelayBinding, api: PendingCrewAPI) async {
        let local = whiteboard.list(crewId: b.crewId)
        // 绑定基线：水位 nil 且白板已有历史 → 钉在末尾，不回灌历史。
        if b.relayPushedThroughId == nil, let last = local.last {
            crewStore.setRelayPushedThrough(crewId: b.crewId, messageId: last.id)
            return
        }
        let pendingIds = Set(CrewRelaySyncLogic.pendingPushIds(
            local: local.map { .init(id: $0.id, isRelayWritten: $0.relayRemoteId != nil) },
            pushedThroughId: b.relayPushedThroughId))
        for m in local where pendingIds.contains(m.id) {
            do {
                // senderLabel 必带 —— edge 靠它打 origin:mac_relay（回环防护）。
                _ = try await api.postCrewMessage(
                    crewId: b.remoteConversationId,
                    text: m.text,
                    senderLabel: Self.localSenderLabel(m, captainName: b.captainName),
                    localSessionId: m.senderSessionId)
                crewStore.setRelayPushedThrough(crewId: b.crewId, messageId: m.id)
            } catch {
                // 半途失败 → 水位停在最后成功那条，下一 tick 续推（顺序保持）。
                NSLog("[CrewRelayAgent] push \(b.crewId) failed: \(error.localizedDescription)")
                return
            }
        }
    }

    // MARK: - 名字映射

    /// edge 条目在本地白板上的显示名（senderDisplayName）。edge 不下发成员名，
    /// 先用 kind + id 缩写兜底；后续可在拉取侧补一次 members 解析。
    static func remoteSenderName(_ entry: CrewWhiteboardEntry) -> String {
        switch entry.senderKind {
        case "user", "human":
            return "PendingBot 用户" + (entry.senderUserId.map { " · \($0.prefix(8))" } ?? "")
        case "bot":
            return "bot" + (entry.senderBotId.map { " · \($0.prefix(8))" } ?? "")
        case "session":
            return CrewSenderNaming.sessionFallback(entry.senderSessionId)
        default:
            return entry.senderKind
        }
    }

    /// 本地消息上行时的 senderLabel（edge 落 attachments.senderLabel，iOS 端
    /// 展示来源）。
    static func localSenderLabel(_ m: LocalWhiteboardMessage, captainName: String?) -> String {
        switch m.senderKind {
        case "user": return "我 (Mac)"
        case "session": return CrewSenderNaming.sessionFallback(m.senderSessionId)
        case "captain": return captainName ?? "Captain"
        default: return m.senderKind
        }
    }
}
#endif
