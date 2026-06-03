#if os(macOS)
import SwiftUI

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
/// 第一版范围(其余随后补,见 docs/tech-debt.md #212):纯文字 1:1/群读写;
/// 未读红点;无附件/图片/语音、无 @提及。

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
            await reload()
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
                        bubble(role: m.role, content: m.content, isMine: m.isMine, imagePaths: m.imagePaths).id(m.id)
                    }
                    if let streamingBotText, !streamingBotText.isEmpty {
                        bubble(role: "assistant", content: streamingBotText, isMine: false).id("streaming")
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

    private func bubble(role: String, content: String, isMine: Bool, imagePaths: [String] = []) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if isMine {
                Spacer(minLength: 56)
            } else {
                BrandAvatar(seed: conversationId, size: 30)
            }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 6) {
                // 图片附件:复用 iOS 同一个 auth-gated ServerImage 加载器。
                ForEach(imagePaths, id: \.self) { path in
                    ServerImage(path: path,
                                serverURL: HostedConfig.environment.workerURL,
                                contentMode: .fill)
                        .frame(maxWidth: 240, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    private var composer: some View {
        HStack(spacing: 8) {
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
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
        }
        .padding(12)
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
        guard !text.isEmpty, !sending else { return }
        input = ""
        sending = true
        streamingBotText = ""
        // optimistic user 气泡(发送后 reload 会用 server canonical 行替换)
        messages.append(ChatMessageRow(id: "local-\(UUID().uuidString)", role: "user", content: text, seq: nil))

        Task {
            do {
                for try await ev in ChatDataSource.sendMessage(conversationId: conversationId, text: text) {
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
            sending = false
            streamingBotText = nil
            await reload() // server truth(替换 optimistic + 流式临时气泡)
        }
    }
}
#endif
