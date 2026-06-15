import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// 中栏 = crew 群聊会话页（spec v2 §9：群聊 = 沟通渠道 + 白板）。
///
/// - 时间线渲染 crew 白板（`crew_announcements`，经 `listCrewWhiteboard`）。
/// - 底部 composer 发消息（`postCrewMessage`，默认 broadcast = 全 session）。
/// - ask_human 交互卡（`payload.kind == "interaction"`，spec §10.6）就地渲染
///   问题 + 回答框，操作者直接在群聊里答（`answerInteraction`），不必跳别处。
///
/// 详细 IO（stdout/stderr/工具日志）不在这——那在右栏 session 窗口（§9.3）。
struct CrewChatView: View {
    let crewId: String
    let crewTitle: String
    /// macOS:点 session(右侧成员行 / session 气泡)时打开 inspector 并选中。
    /// 由 CrewCenterView 注入(用它持有的 inspectorPresented + sessionRunner)。iOS 传 nil。
    var onOpenSession: ((UUID) -> Void)? = nil
    /// macOS:成员区「+」起新 session(进新建态 + 弹 inspector)。iOS 传 nil。
    var onNewSession: (() -> Void)? = nil

    @EnvironmentObject private var appModel: AppModel
    #if os(macOS)
    /// MacThreePaneView 注入（经 CrewCenterView）—— session 发的消息点击可
    /// 跳到右栏对应 session（chunk2 T6 中栏跳转）。
    @EnvironmentObject private var sessionRunner: CrewSessionRunner
    #endif

    @State private var entries: [CrewWhiteboardEntry] = []
    @State private var draft = ""
    /// Source-of-truth attachment list (file importer writes here on both platforms).
    @State private var pendingAttachments: [PendingComposerAttachment] = []
    @State private var loadError: String?
    @State private var sending = false
    /// Per-interaction reply drafts, keyed by permission_request_id.
    @State private var replyDrafts: [String: String] = [:]
    /// Crew roster (spec §9 — everyone is a member): rendered as a participant strip.
    @State private var members: [CrewMember] = []
    @State private var captainBotId: String?

    // MARK: - ComposerView bindings
    /// Forwarded to ComposerView; ChatActionSheet flips this to open
    /// the system document picker (.fileImporter works on iOS 14+ too).
    @State private var showFileImporter = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var cameraImage: PlatformImage? = nil
    @State private var showPhotoPicker = false
    @State private var showCamera = false

    private let pollInterval: UInt64 = 3_000_000_000 // 3s

    /// Bridge: convert PendingComposerAttachment → PendingAttachment for ComposerView's
    /// pending tray display. Data already in memory (eagerly read at pick time), so
    /// uploadState = .uploaded (no async pipeline in the tray; upload happens on send).
    private var pendingForDisplay: Binding<[PendingAttachment]> {
        Binding(
            get: {
                pendingAttachments.map { a in
                    PendingAttachment(
                        id: a.id.uuidString,
                        mime: a.mime,
                        size: a.byteSize,
                        filename: a.isImage ? nil : a.filename,
                        uploadState: .uploaded,
                        localPreviewData: a.isImage ? a.data : nil
                    )
                }
            },
            set: { newValue in
                // Removals: ComposerView's tray "x" button removes by id.
                let keptIds = Set(newValue.map { $0.id })
                pendingAttachments.removeAll { !keptIds.contains($0.id.uuidString) }
            }
        )
    }

    private var canSend: Bool {
        guard !sending else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
               || !pendingAttachments.isEmpty
    }

    var body: some View {
        content
        .background(Theme.Palette.canvas)
        .task(id: crewId) { await pollLoop() }
        // File importer — .fileImporter is available on iOS 14+ and macOS 11+.
        // On iOS the system presents a document picker; on macOS a Finder sheet.
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image, .pdf, .plainText, .data],
            allowsMultipleSelection: true,
            onCompletion: handleImport
        )
        // Photo picker — iOS only; wires the showPhotoPicker binding from ComposerView.
        #if os(iOS)
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoItems,
            matching: .images
        )
        .onChange(of: photoItems) { _, items in
            Task { await handlePhotoItems(items) }
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        // 成员列表 + 待审批已搬进 inspector(CrewSessionWindowView 的成员列表模式)。
        // 中栏只留群聊本体。composer 悬浮在消息流底部，背景走「渐进模糊」——对齐 PendingBot：
        // ultraThinMaterial 用上→下(透明→不透明)的渐变遮罩，顶部淡出所以**没有硬边线**，
        // 消息滚到底会从 composer 背后透出渐进模糊。不再用硬 Divider 分隔。
        timeline
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    errorBar
                    composer
                }
                .background {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black, location: 0.45),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            }
        #else
        VStack(spacing: 0) {
            if !members.isEmpty {
                CrewRosterBar(members: members, captainBotId: captainBotId)
                Divider()
            }
            timeline
            errorBar
            Divider()
            composer
        }
        #endif
    }

    @ViewBuilder
    private var errorBar: some View {
        if let errorText = loadError {
            Text(errorText)
                .font(Theme.Fonts.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 4)
        }
    }

    private var composer: some View {
        ComposerView(
            input: $draft,
            pending: pendingForDisplay,
            photoItems: $photoItems,
            cameraImage: $cameraImage,
            showFileImporter: $showFileImporter,
            showPhotoPicker: $showPhotoPicker,
            showCamera: $showCamera,
            canSend: canSend,
            onSend: { Task { await send() } },
            isStreaming: false,
            showsAttachments: true,
            placeholder: "发消息"
        )
    }

    // 本机用户哨兵 id —— 接合 v2 后 macOS 白板恒为本地，本机人类消息都标
    // `LocalWhiteboardStore.localUserId`，CrewSenderResolver 据此把自己的
    // 消息识别成"自己"(右对齐、无头像)。
    // iOS: 暂无本地后端 — 使用 AppModel.currentUserId。
    private var localUserId: String? {
        #if os(macOS)
        return LocalWhiteboardStore.localUserId
        #else
        return appModel.currentUserId
        #endif
    }

    /// 时间线渲染的消息。macOS 把交互卡滤掉(挪去右上待审批区);iOS 保留 inline。
    private var timelineEntries: [CrewWhiteboardEntry] {
        #if os(macOS)
        return entries.filter { !$0.isInteraction }
        #else
        return entries
        #endif
    }

    @ViewBuilder
    private var timeline: some View {
        if timelineEntries.isEmpty {
            // 空白态：只居中放一个聊天图标，别的什么都不要。
            emptyState
        } else {
            messageScroll
        }
    }

    private var messageScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(timelineEntries.enumerated()), id: \.element.id) { idx, entry in
                        let prevDate = idx > 0 ? CrewTimeSeparator.parse(timelineEntries[idx - 1].createdAt) : nil
                        if let cur = CrewTimeSeparator.parse(entry.createdAt),
                           CrewTimeSeparator.needsSeparator(prev: prevDate, cur: cur) {
                            CrewTimeSeparator(date: cur)
                        }
                        rowView(entry).id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("tail")
                }
                .padding(.vertical, 10)
            }
            .onChange(of: timelineEntries.count) { _, _ in
                withAnimation(.linear(duration: 0.05)) { proxy.scrollTo("tail", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowView(_ entry: CrewWhiteboardEntry) -> some View {
        if entry.isInteraction {
            let reqId = entry.payload?.permissionRequestId ?? entry.id
            CrewInteractionCard(
                entry: entry,
                reply: Binding(get: { replyDrafts[reqId] ?? "" }, set: { replyDrafts[reqId] = $0 })
            ) { Task { await answer(reqId) } }
        } else {
            let (msg, sender) = CrewChatAdapter.adapt(
                entry,
                members: members,
                captainBotId: captainBotId,
                localUserId: localUserId
            )
            let bubble = BubbleView(
                message: msg,
                botName: sender?.displayName ?? "机组",
                conversationID: crewId,
                currentUserId: localUserId,
                groupSender: sender,
                serverURL: appModel.imageAuth?.baseURL,
                onRetry: nil,
                menu: { EmptyView() }
            )
            #if os(macOS)
            // session 发的消息可点 → 右栏切到对应 session（chunk2 T6 中栏跳转）。
            // 找不到对应 run（已移除/别的 crew）则点击无事发生。
            if let senderSessionId = entry.senderSessionId {
                bubble
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let run = sessionRunner.runs.first(where: { $0.sessionId == senderSessionId }) {
                            onOpenSession?(run.runID)
                        }
                    }
            } else {
                bubble
            }
            #else
            bubble
            #endif
        }
    }

    private var emptyState: some View {
        Image(systemName: "bubble.left.and.bubble.right")
            .font(.system(size: 40))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - data

    private func pollLoop() async {
        entries = []
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    private func refresh() async {
        // 走 backend(双轨):登录态 → edge;BYOK → 本地白板 store。
        guard let backend = appModel.backend else {
            loadError = "未配置 backend"
            return
        }
        do {
            entries = try await backend.listCrewWhiteboard(crewId: crewId)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        // Roster is best-effort decoration — a failure leaves the prior strip.
        if let roster = try? await backend.listCrewMembers(crewId: crewId) {
            members = roster.members
            captainBotId = roster.captainBotId
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let toUpload = pendingAttachments
        // Allow attachment-only sends (no text) as long as something is present.
        guard !text.isEmpty || !toUpload.isEmpty,
              let backend = appModel.backend else { return }
        sending = true
        defer { sending = false }
        do {
            // 附件上传是登录后的能力叠加(走 edge 上传)：未登录 → 软报错、不发。
            // 上传走 loggedAPIClient(edge 专属),拿到 ids 再交给 backend 发文。
            var attachmentIds: [String] = []
            if !toUpload.isEmpty {
                guard appModel.isAuthenticated, let api = try? appModel.loggedAPIClient() else {
                    loadError = "群聊附件需登录 PendingBot"
                    return
                }
                for att in toUpload {
                    let id = try await api.uploadAttachment(
                        data: att.data, filename: att.filename, mime: att.mime)
                    attachmentIds.append(id)
                }
            }
            try await backend.postCrewMessage(
                crewId: crewId, text: text, mentions: [], attachmentIds: attachmentIds)
            draft = ""
            pendingAttachments = []
            await refresh()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func answer(_ reqId: String) async {
        let reply = (replyDrafts[reqId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty, let api = try? appModel.loggedAPIClient() else { return }
        do {
            try await api.answerInteraction(reqId: reqId, reply: reply)
            replyDrafts[reqId] = nil
            await refresh()
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - File import (cross-platform via .fileImporter)

    /// Called by the `.fileImporter` modifier bound to `showFileImporter`.
    /// Works on both macOS (Finder sheet) and iOS (document picker). Reads bytes
    /// eagerly inside the security-scoped access window.
    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType)
                ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            pendingAttachments.append(PendingComposerAttachment(
                filename: url.lastPathComponent,
                mime: mime,
                data: data
            ))
        }
    }

    // MARK: - Photo picker (iOS)

    #if os(iOS)
    /// Decode PhotosPickerItems into PendingComposerAttachments and append.
    @MainActor
    private func handlePhotoItems(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            // Best-effort MIME detection from the supported content types.
            let mime: String
            if let types = item.supportedContentTypes.first,
               let mimeType = types.preferredMIMEType {
                mime = mimeType
            } else {
                mime = "image/jpeg"
            }
            // Generate a filename from a timestamp so the tray shows something readable.
            let ext = mime.components(separatedBy: "/").last ?? "jpg"
            let filename = "photo_\(Int(Date().timeIntervalSince1970)).\(ext)"
            pendingAttachments.append(PendingComposerAttachment(
                filename: filename,
                mime: mime,
                data: data
            ))
        }
        // Clear selection so the same photo can be re-picked if needed.
        photoItems = []
    }
    #endif
}
