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
    func start(appModel: AppModel) {
        self.appModel = appModel
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
        } catch {
            NSLog("[CrewRelayAgent] pull \(b.crewId) failed: \(error.localizedDescription)")
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
            return "session" + (entry.senderSessionId.map { " · \($0.prefix(8))" } ?? "")
        default:
            return entry.senderKind
        }
    }

    /// 本地消息上行时的 senderLabel（edge 落 attachments.senderLabel，iOS 端
    /// 展示来源）。
    static func localSenderLabel(_ m: LocalWhiteboardMessage, captainName: String?) -> String {
        switch m.senderKind {
        case "user": return "我 (Mac)"
        case "session": return "session" + (m.senderSessionId.map { " · \($0.prefix(8))" } ?? "")
        case "captain": return captainName ?? "机长"
        default: return m.senderKind
        }
    }
}
#endif
