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
                    .font(Theme.Fonts.footnote).foregroundStyle(.red)
            }
            // 对齐 iOS MessageTabView 空态:EmptyHint 文案 "和 AI 聊天",footnote + inkMuted。
            if conversations.isEmpty && didLoad && loadError == nil {
                Text("和 AI 聊天")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
            ForEach(conversations) { c in
                HStack(alignment: .top, spacing: 10) {
                    // 对齐 iOS ConversationListRow:头像 36。
                    BrandAvatar(seed: c.id, size: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            // 标题:iOS 用 serif 16 semibold + ink。
                            Text(c.title)
                                .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.Palette.ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            // 未读徽标:iOS 是绿色(accent)胶囊 + 白字 bold 11,>99 显示 99+。
                            if c.unreadCount > 0 {
                                Text(c.unreadCount > 99 ? "99+" : "\(c.unreadCount)")
                                    .font(Theme.Fonts.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .frame(minWidth: 18)
                                    .frame(height: 18)
                                    .background(Capsule().fill(Theme.Palette.accent))
                            }
                        }
                        // 预览:iOS 空预览回落 "还没有消息",footnote + inkMuted。
                        Text(c.preview.isEmpty ? "还没有消息" : c.preview)
                            .font(Theme.Fonts.footnote)
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.vertical, 6)
                .tag(c.id)
            }
        }
        .navigationTitle("消息")
        // 和 iOS MessageTabView 同款:先出本地缓存秒开,再拉服务端,再订阅
        // user-level RealtimeHub。每条 user_unread_counts 变更(任何会话来新消息)
        // 即刷新列表 —— 顺序 / 预览 / 未读数实时更新,无轮询。user channel 是常驻的,
        // startUserChannel 幂等(已开则 no-op),所以这里不在 disappear 关它。
        .task {
            // cache-first:先从共享 LocalDatabase 读上次的会话列表即时渲染
            // (对齐 iOS MessageTabView.load 的首屏 hydrate),再让网络刷新覆盖。
            if conversations.isEmpty {
                let cached = ChatDataSource.cachedConversations()
                if !cached.isEmpty { conversations = cached }
            }
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
        .background(Theme.Palette.canvas) // 对齐 iOS canvas 米白,白 bot 气泡浮其上
        .navigationTitle("对话")
        // 和 iOS ConversationView 同款:拉历史 + 订阅 conv-level RealtimeHub。
        // 对端 / bot 写入 messages 即刷新(自己正在发的那条由 SSE 流接管,
        // 发完会 reload 拿 server 真值,所以 sending 期间忽略实时事件防抖动)。
        .task(id: conversationId) {
            // cache-first:先从共享 LocalDatabase 读缓存即时渲染(对齐 iOS
            // ConversationView.loadHistory 的首屏 hydrate),再认会话类型 +
            // 拉服务端历史覆盖。缓存行无附件元数据(纯文字),图片/文件由
            // reload 的网络往返解析 —— 和 iOS 缓存 hydrate(attachments: nil)一致。
            if messages.isEmpty {
                let cached = ChatDataSource.cachedMessages(conversationId: conversationId)
                if !cached.isEmpty { messages = cached }
            }
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
                // 气泡间距对齐 iOS:每个 BubbleView 自带 vertical 4 padding,
                // 横向走 Theme.Metrics.gutter(16),所以这里 LazyVStack spacing 8、
                // 外层不再额外加横向内距(bubble() 里自带 gutter)。
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let loadError {
                        Text(loadError).font(Theme.Fonts.footnote).foregroundStyle(.red)
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
                .padding(.vertical, 12)
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
        // 对齐 iOS BubbleView:bot/对方 气泡 spacing 8(头像↔内容),user 用 Spacer 推到右侧。
        HStack(alignment: .top, spacing: isMine ? 0 : 8) {
            if isMine {
                Spacer(minLength: 48)
            } else if let sender {
                // 群:对方头像用其本人 avatar(有上传图走 ServerImage,否则 seed emoji)。
                senderAvatar(sender, size: 30)
                    .padding(.top, 2)
            } else {
                BrandAvatar(seed: conversationId, size: 30)
                    .padding(.top, 2)
            }
            // iOS bot 抬头↔内容 spacing 4、user 内容 spacing 6。
            VStack(alignment: isMine ? .trailing : .leading, spacing: isMine ? 6 : 4) {
                // 群:非自己气泡顶部显示发送者名字(对齐 iOS 群气泡抬头:rounded 11 semibold + inkMuted)。
                if let sender, !isMine {
                    Text(sender.displayName)
                        .font(Theme.Fonts.rounded(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
                // 图片附件:复用 iOS 同一个 auth-gated ServerImage 加载器(iOS AttachmentGrid 用 cell 110,radius 12)。
                ForEach(imagePaths, id: \.self) { path in
                    ServerImage(path: path,
                                serverURL: HostedConfig.environment.workerURL,
                                contentMode: .fill)
                        .frame(maxWidth: 240, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                // 非图片附件:图标 + 文件名 chip(对齐 iOS FileAttachmentChip)。
                ForEach(files) { att in
                    HStack(spacing: 10) {
                        Image(systemName: "doc.fill")
                            .font(Theme.Fonts.glyph(size: 22))
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(att.filename ?? "文件")
                                .font(Theme.Fonts.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.Palette.ink)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            if let size = att.size {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                    .font(Theme.Fonts.system(size: 11))
                                    .foregroundStyle(Theme.Palette.inkMuted)
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: 260, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.Palette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
                }
                if !content.isEmpty {
                    // 对齐 iOS:正文走共享 MarkdownText(完整 markdown 渲染),不再纯
                    // Text。MarkdownText 已跨平台(放开后);allowCodeRun=false(Mac 无
                    // 代码运行 sheet)、citations=[](Mac 暂未接 web 引用)。气泡底/描边
                    // 沿用:用户淡绿(userBubble)、bot 白(surface)+ hairline,圆角 18。
                    MarkdownText(text: content, allowCodeRun: false, citations: [])
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius, style: .continuous)
                                .fill(isMine ? Theme.Palette.userBubble : Theme.Palette.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius, style: .continuous)
                                .strokeBorder(isMine ? Color.clear : Theme.Palette.hairline, lineWidth: 0.5)
                        )
                }
            }
            if !isMine { Spacer(minLength: 32) }
        }
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.vertical, 4)
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
                .overlay(Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
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
            HStack(alignment: .bottom, spacing: 8) {
                // 附件按钮 → NSOpenPanel(图片/文件)。iOS 用 "+" 圆钮打开附件面板
                // (PhotosPicker + UIDocumentPicker);Mac 等价物是 NSOpenPanel,
                // 复用同一上传通道。样式对齐 iOS:inkMuted 的 "+" glyph 圆钮。
                Button {
                    pickAttachments()
                } label: {
                    Image(systemName: "plus")
                        .font(Theme.Fonts.glyph(size: 18, weight: .medium))
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Theme.Palette.surface))
                        .overlay(Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(sending)
                .help("添加图片或文件")

                HStack(alignment: .bottom, spacing: 6) {
                    // 输入框 placeholder 对齐 iOS:"发消息…";字体 body + ink。
                    TextField("发消息…", text: $input, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(1...6)
                        .padding(.leading, 14)
                        .padding(.vertical, 8)
                        .onSubmit { send() }

                    // 发送钮对齐 iOS:可发时 accent 实心圆 + 白上箭头,否则 surfaceMuted + 弱化箭头。
                    Button {
                        send()
                    } label: {
                        if sending {
                            ProgressView().controlSize(.small)
                                .frame(width: 30, height: 30)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(Theme.Fonts.glyph(size: 15, weight: .bold))
                                .foregroundStyle(canSend ? .white : Theme.Palette.inkMuted.opacity(0.5))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(canSend ? Theme.Palette.accent : Theme.Palette.surfaceMuted))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .padding(.trailing, 6)
                    .padding(.bottom, 4)
                }
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.Palette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                )
            }
        }
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.vertical, 12)
    }

    /// 可发送 = 有正文或已上传附件,且没在发送 / 没有上传中的附件。
    private var canSend: Bool {
        let hasText = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !pendingAttachments.isEmpty) && !sending && uploadingCount == 0
    }

    /// 待发附件预览条,对齐 iOS ComposerView.pendingTray:64×64 cell、
    /// surfaceMuted 底、radius 10、hairline 描边;文件 chip 用 doc.fill(accent)+
    /// 文件名(system 9 / inkMuted);删除钮白×半黑底;上传中显示 ProgressView。
    private var pendingAttachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { att in
                    ZStack(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.Palette.surfaceMuted)
                            .frame(width: 64, height: 64)
                            .overlay {
                                if att.isImage {
                                    ServerImage(path: att.url,
                                                serverURL: HostedConfig.environment.workerURL,
                                                contentMode: .fill)
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                } else {
                                    VStack(spacing: 3) {
                                        Image(systemName: "doc.fill")
                                            .font(Theme.Fonts.glyph(size: 20))
                                            .foregroundStyle(Theme.Palette.accent)
                                        Text(att.filename ?? "文件")
                                            .font(Theme.Fonts.system(size: 9))
                                            .foregroundStyle(Theme.Palette.inkMuted)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                            .truncationMode(.middle)
                                    }
                                    .padding(.horizontal, 4)
                                }
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                            )
                        Button {
                            pendingAttachments.removeAll { $0.id == att.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(Theme.Fonts.body)
                                .foregroundStyle(.white, .black.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                    }
                }
                if uploadingCount > 0 {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.Palette.surfaceMuted)
                            .frame(width: 64, height: 64)
                        VStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text("上传中")
                                .font(Theme.Fonts.system(size: 9, weight: .medium))
                                .foregroundStyle(Theme.Palette.inkMuted)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 68)
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
            // 网络挂了但缓存已 hydrate 出内容:保持安静(缓存消息仍在屏上),
            // 只有什么都没得显示时才报错 —— 对齐 iOS loadHistory 的 error 策略。
            if messages.isEmpty {
                loadError = error.localizedDescription
            }
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
