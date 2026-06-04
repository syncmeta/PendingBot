#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// T0.1 — macOS 消息 tab（完整原生 Mac 版 #212 的主体第一块）。
///
/// 三列里:中列 `MacConversationListColumn`(会话列表)+ detail 列 `MacChatView`
/// (气泡 + 输入框 + 流式发送)。逻辑全复用跨平台 `ChatDataSource`(查询)+
/// `ChatStream`(SSE 发送)+ `RealtimeManager`(RealtimeHub WS),UI 纯 SwiftUI 原生。
///
/// Realtime 走的就是 iOS 那套自建 RealtimeHubDO(`RealtimeManager` / `RealtimeSocket`),
/// **不是 Supabase Realtime、也不是轮询**:会话列表订阅 user channel(unread 变更即
/// 刷新),聊天订阅 conv channel(对端 / bot 新消息即刷新)。和
/// `MessageTabView`/`ConversationView` 是同一条实时通道,逻辑一致。
///
/// 范围(见 docs/tech-debt.md #212):1:1(user_bot/self/user_user)+ 群(group)
/// 文字读写;未读红点;**图片/文件附件**(NSOpenPanel → 复用跨平台 `ChatDataSource.upload`
/// 同 iOS /v1/upload 通道);**群发送者抬头**(每条非自己气泡顶部画发送者头像+名字,
/// 数据来自 `ChatDataSource.loadGroupSenders`)。未做:语音入口(iOS-only)、@提及
/// (iOS 这块也未定型)、附件全屏查看器、上传图片客户端压缩(Mac 直传原图)。

// MARK: - 中列:会话列表

struct MacConversationListColumn: View {
    @Binding var selectedConversationId: String?

    @State private var conversations: [ChatConversationSummary] = []
    @State private var loadError: String?
    @State private var didLoad = false

    var body: some View {
        List(selection: $selectedConversationId) {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            if conversations.isEmpty && didLoad && loadError == nil {
                Text("还没有会话").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(conversations) { c in
                HStack(spacing: 12) {
                    BrandAvatar(seed: c.id, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(c.title).font(.body).lineLimit(1)
                            Spacer(minLength: 4)
                            if c.unreadCount > 0 {
                                Text("\(c.unreadCount)")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(.red))
                                    .foregroundStyle(.white)
                            }
                        }
                        if !c.preview.isEmpty {
                            Text(c.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .padding(.vertical, 6)
                .tag(c.id)
            }
        }
        .navigationTitle("消息")
        // 和 iOS MessageTabView 同款:先拉一次,再订阅 user-level RealtimeHub。
        // 每条 user_unread_counts 变更(任何会话来新消息)即刷新列表 —— 顺序 /
        // 预览 / 未读数实时更新,无轮询。user channel 是常驻的,startUserChannel
        // 幂等(已开则 no-op),所以这里不在 disappear 关它。
        .task {
            await refresh()
            didLoad = true
            if let userId = AccountStore.shared.current?.id {
                await RealtimeManager.shared.startUserChannel(userId: userId) { _ in
                    Task { @MainActor in await refresh() }
                }
            }
        }
    }

    private func refresh() async {
        do {
            let fresh = try await ChatDataSource.listConversations()
            if fresh != conversations { conversations = fresh }
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - detail 列:聊天

struct MacChatView: View {
    let conversationId: String

    @State private var messages: [ChatMessageRow] = []
    @State private var input = ""
    @State private var streamingBotText: String?
    @State private var sending = false
    @State private var loadError: String?
    @State private var didLoad = false
    /// conv-level RealtimeHub 订阅 token —— 每个会话一个(MacRootView 用 `.id(convId)`
    /// 给每个会话独立的 MacChatView 实例,各自持有 / 释放自己的 token)。
    @State private var convToken: ConvSubscriptionToken?
    /// `user_bot` / `self` / `user_user` / `group` — 决定发送路径(bot/self/group
    /// 走 SSE `/v1/messages`,user_user 直插 Supabase)与是否画群发送者抬头。
    @State private var conversationType: String?
    /// 群成员 name/avatar 查找表(key = `"\(kind):\(id)"`),仅 group 会话填充。
    @State private var groupSenders: [String: ChatGroupSender] = [:]
    /// 已上传、等待随下一条消息发出的附件(对齐 iOS 的 pendingAttachments)。
    @State private var pendingAttachments: [Attachment] = []
    /// 正在上传中的附件数(>0 时禁发送,UI 显示进度,对齐 iOS 上传占位)。
    @State private var uploadingCount = 0

    private var isGroup: Bool { conversationType == "group" }
    private var isPeerUser: Bool { conversationType == "user_user" }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .background(Color(hex: 0xFDFCFA)) // 对齐 iOS canvas 米白,白 bot 气泡浮其上
        .navigationTitle("对话")
        // 和 iOS ConversationView 同款:拉历史 + 订阅 conv-level RealtimeHub。
        // 对端 / bot 写入 messages 即刷新(自己正在发的那条由 SSE 流接管,
        // 发完会 reload 拿 server 真值,所以 sending 期间忽略实时事件防抖动)。
        .task(id: conversationId) {
            // 先认会话类型(决定发送路径 + 是否画群抬头),再拉历史 + 群成员。
            conversationType = (try? await ChatDataSource.conversationType(conversationId: conversationId)) ?? conversationType
            await reload()
            if conversationType == "group" {
                groupSenders = await ChatDataSource.loadGroupSenders(conversationId: conversationId)
            }
            let token = await RealtimeManager.shared.startConvChannel(
                conversationId: conversationId,
                onMessage: { _ in
                    Task { @MainActor in
                        guard !sending else { return }
                        await reload()
                    }
                }
            )
            convToken = token
        }
        .onDisappear {
            if let convToken {
                Task { await RealtimeManager.shared.stopConvChannel(convToken) }
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let loadError {
                        Text(loadError).font(.caption).foregroundStyle(.red)
                    }
                    ForEach(visibleMessages) { m in
                        bubble(row: m).id(m.id)
                    }
                    if let streamingBotText, !streamingBotText.isEmpty {
                        bubble(row: ChatMessageRow(id: "streaming", role: "assistant",
                                                   content: streamingBotText, seq: nil)).id("streaming")
                    }
                    Color.clear.frame(height: 1).id("tail")
                }
                .padding(.horizontal, 22).padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: messages.count) { _, _ in scrollToTail(proxy) }
            .onChange(of: streamingBotText) { _, _ in scrollToTail(proxy) }
        }
    }

    private var visibleMessages: [ChatMessageRow] {
        messages.filter { !$0.isHidden }
    }

    /// 群会话里非自己的气泡解析发送者(name + avatar);1:1 或自己的消息返回 nil
    /// (对齐 iOS `groupSenderFor`:自己的消息保持右侧布局,不画抬头)。
    private func groupSender(for row: ChatMessageRow) -> ChatGroupSender? {
        guard isGroup, !row.isMine, !row.senderId.isEmpty else { return nil }
        return groupSenders["\(row.senderType):\(row.senderId)"]
    }

    @ViewBuilder
    private func bubble(row: ChatMessageRow) -> some View {
        let isMine = row.isMine
        let content = row.content
        let imagePaths = row.imagePaths
        let files = row.fileAttachments
        let sender = groupSender(for: row)
        HStack(alignment: .top, spacing: 10) {
            if isMine {
                Spacer(minLength: 56)
            } else if let sender {
                // 群:对方头像用其本人 avatar(有上传图走 ServerImage,否则 seed emoji)。
                senderAvatar(sender, size: 30)
            } else {
                BrandAvatar(seed: conversationId, size: 30)
            }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 6) {
                // 群:非自己气泡顶部显示发送者名字(对齐 iOS 群气泡抬头)。
                if let sender, !isMine {
                    Text(sender.displayName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color(hex: 0x6E6B5E))
                        .padding(.leading, 4)
                }
                // 图片附件:复用 iOS 同一个 auth-gated ServerImage 加载器。
                ForEach(imagePaths, id: \.self) { path in
                    ServerImage(path: path,
                                serverURL: HostedConfig.environment.workerURL,
                                contentMode: .fill)
                        .frame(maxWidth: 240, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                // 非图片附件:图标 + 文件名 chip(对齐 iOS 的 file chip)。
                ForEach(files) { att in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color(hex: 0x6E6B5E))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(att.filename ?? "文件").font(.callout).lineLimit(1)
                                .foregroundStyle(Color(hex: 0x1B1A14))
                            if let size = att.size {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0xFFFFFF)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(hex: 0xE2E0D7), lineWidth: 0.5))
                }
                if !content.isEmpty {
                    Text(content)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(
                            // 对齐 iOS:用户气泡淡绿(accentBg 0xE3EEEA)、bot 气泡白(surface)+ hairline 描边,圆角 18。
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(isMine ? Color(hex: 0xE3EEEA) : Color(hex: 0xFFFFFF))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(isMine ? Color.clear : Color(hex: 0xE2E0D7), lineWidth: 0.5)
                        )
                        .foregroundStyle(Color(hex: 0x1B1A14)) // ink 深字,两种气泡都用
                }
            }
            if !isMine { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }

    /// 群发送者头像:有上传 avatar 走 auth-gated ServerImage,否则按 seed 画
    /// 确定性 emoji 头像(对齐 iOS UserAvatar 的 fallback,Mac 无 UIKit 用 ServerImage)。
    @ViewBuilder
    private func senderAvatar(_ sender: ChatGroupSender, size: CGFloat) -> some View {
        if let path = sender.avatarPath, !path.isEmpty {
            ServerImage(path: path,
                        serverURL: HostedConfig.environment.workerURL,
                        contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color(hex: 0xE2E0D7), lineWidth: 0.5))
        } else {
            BrandAvatar(seed: sender.avatarSeed, size: size)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 待发附件预览条(对齐 iOS composer 的附件 strip):图片缩略 + 文件 chip,
            // 各带删除按钮;上传中显示进度。空则整条隐藏。
            if !pendingAttachments.isEmpty || uploadingCount > 0 {
                pendingAttachmentStrip
            }
            HStack(spacing: 8) {
                // 附件按钮 → NSOpenPanel(图片/文件)。iOS 用 PhotosPicker +
                // UIDocumentPicker;Mac 等价物是 NSOpenPanel,复用同一上传通道。
                Button {
                    pickAttachments()
                } label: {
                    Image(systemName: "paperclip").font(.title3)
                        .foregroundStyle(Color(hex: 0x6E6B5E))
                }
                .buttonStyle(.plain)
                .disabled(sending)
                .help("添加图片或文件")

                TextField("发消息…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                    .onSubmit { send() }
                Button {
                    send()
                } label: {
                    if sending { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(12)
    }

    /// 可发送 = 有正文或已上传附件,且没在发送 / 没有上传中的附件。
    private var canSend: Bool {
        let hasText = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !pendingAttachments.isEmpty) && !sending && uploadingCount == 0
    }

    private var pendingAttachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { att in
                    ZStack(alignment: .topTrailing) {
                        if att.isImage {
                            ServerImage(path: att.url,
                                        serverURL: HostedConfig.environment.workerURL,
                                        contentMode: .fill)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.fill").foregroundStyle(Color(hex: 0x6E6B5E))
                                Text(att.filename ?? "文件").font(.caption).lineLimit(1)
                                    .foregroundStyle(Color(hex: 0x1B1A14))
                            }
                            .padding(.horizontal, 10).frame(height: 56)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: 0xFFFFFF)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color(hex: 0xE2E0D7), lineWidth: 0.5))
                        }
                        Button {
                            pendingAttachments.removeAll { $0.id == att.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white, .black.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .padding(2)
                    }
                }
                if uploadingCount > 0 {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.1))
                            .frame(width: 56, height: 56)
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .frame(maxHeight: 60)
    }

    private func scrollToTail(_ proxy: ScrollViewProxy) {
        withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("tail", anchor: .bottom) }
    }

    // MARK: data

    private func reload() async {
        do {
            messages = try await ChatDataSource.loadMessages(conversationId: conversationId)
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        didLoad = true
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachIds = pendingAttachments.map(\.id)
        guard (!text.isEmpty || !attachIds.isEmpty), !sending, uploadingCount == 0 else { return }
        input = ""
        sending = true
        // optimistic user 气泡(发送后 reload 会用 server canonical 行替换);带上
        // 已上传附件的本地预览,发送瞬间就能看到自己发的图/文件。
        let optimisticImages = pendingAttachments.filter(\.isImage).map(\.url)
        let optimisticFiles = pendingAttachments.filter { !$0.isImage }
        messages.append(ChatMessageRow(
            id: "local-\(UUID().uuidString)", role: "user", content: text, seq: nil,
            imagePaths: optimisticImages, fileAttachments: optimisticFiles))
        let toSend = pendingAttachments
        pendingAttachments = []

        Task {
            if isPeerUser {
                // user_user:直插 Supabase,无 SSE,无 bot 回复;canonical 行靠 reload/realtime。
                do {
                    try await ChatDataSource.sendPeerMessage(
                        conversationId: conversationId, text: text, attachmentIds: attachIds)
                } catch {
                    loadError = error.localizedDescription
                    // 发送失败:把附件放回待发条,避免静默丢失。
                    pendingAttachments = toSend
                }
            } else {
                // user_bot / self / group:走 SSE /v1/messages(group 的 bot 回复
                // 也由 RealtimeHub 推,reload 拿 server 真值)。
                streamingBotText = ""
                do {
                    for try await ev in ChatDataSource.sendMessage(
                        conversationId: conversationId, text: text, attachmentIds: attachIds) {
                        switch ev {
                        case .token(let delta):
                            streamingBotText = (streamingBotText ?? "") + delta
                        case .bubble(_, _, _, let content, _):
                            streamingBotText = content
                        case .done(_, let total):
                            if !total.isEmpty { streamingBotText = total }
                        case .error(let message):
                            loadError = message
                        default:
                            break
                        }
                    }
                } catch {
                    loadError = error.localizedDescription
                }
                streamingBotText = nil
            }
            sending = false
            await reload() // server truth(替换 optimistic + 流式临时气泡)
        }
    }

    // MARK: attachments

    /// 打开 NSOpenPanel 选图片/文件(可多选)→ 逐个上传 → 进待发条。
    /// 复用跨平台 `ChatDataSource.upload`(同 iOS 的 /v1/upload 通道)。
    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "选择要发送的图片或文件"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await ingest(urls) }
    }

    private func ingest(_ urls: [URL]) async {
        for url in urls {
            guard let data = try? Data(contentsOf: url) else {
                loadError = "无法读取文件: \(url.lastPathComponent)"
                continue
            }
            if data.count > ChatDataSource.maxUploadBytes {
                loadError = "文件过大（上限 25 MB）: \(url.lastPathComponent)"
                continue
            }
            let filename = url.lastPathComponent
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            uploadingCount += 1
            do {
                let att = try await ChatDataSource.upload(
                    conversationId: conversationId, data: data, filename: filename, mime: mime)
                pendingAttachments.append(att)
            } catch {
                loadError = "上传失败: \(error.localizedDescription)"
            }
            uploadingCount -= 1
        }
    }
}
#endif
