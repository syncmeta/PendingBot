#if os(macOS)
import SwiftUI

/// T0.1 — macOS 消息 tab（完整原生 Mac 版 #212 的主体第一块）。
///
/// 三列里:中列 `MacConversationListColumn`(会话列表)+ detail 列 `MacChatView`
/// (气泡 + 输入框 + 流式发送)。逻辑全复用跨平台 `ChatDataSource`(查询)+
/// `ChatStream`(SSE 发送),UI 纯 SwiftUI 原生。
///
/// 第一版范围(其余随后补,见 docs/tech-debt.md #212):纯文字 1:1/群读写;
/// 无 Realtime(3s 轮询会话列表 + 发送后 reload 消息)、无未读红点细节、无附件/
/// 图片/语音、无 @提及。

// MARK: - 中列:会话列表

struct MacConversationListColumn: View {
    @Binding var selectedConversationId: String?

    @State private var conversations: [ChatConversationSummary] = []
    @State private var loadError: String?
    @State private var didLoad = false

    private let pollInterval: UInt64 = 3_000_000_000

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
                .padding(.vertical, 2)
                .tag(c.id)
            }
        }
        .navigationTitle("消息")
        .task { await pollLoop() }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await refresh()
            didLoad = true
            try? await Task.sleep(nanoseconds: pollInterval)
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

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .navigationTitle("对话")
        .task(id: conversationId) { await reload() }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let loadError {
                        Text(loadError).font(.caption).foregroundStyle(.red)
                    }
                    ForEach(visibleMessages) { m in
                        bubble(role: m.role, content: m.content, isMine: m.isMine).id(m.id)
                    }
                    if let streamingBotText, !streamingBotText.isEmpty {
                        bubble(role: "assistant", content: streamingBotText, isMine: false).id("streaming")
                    }
                    Color.clear.frame(height: 1).id("tail")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: messages.count) { _, _ in scrollToTail(proxy) }
            .onChange(of: streamingBotText) { _, _ in scrollToTail(proxy) }
        }
    }

    private var visibleMessages: [ChatMessageRow] {
        messages.filter { !$0.isHidden }
    }

    private func bubble(role: String, content: String, isMine: Bool) -> some View {
        HStack(spacing: 0) {
            if isMine { Spacer(minLength: 80) }
            Text(content.isEmpty ? " " : content)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        // bot 气泡用半透明灰(深浅模式都看得出气泡形状),
                        // 不用 controlBackgroundColor —— 浅色下它≈白、看不出。
                        .fill(isMine ? Color.accentColor : Color.secondary.opacity(0.15))
                )
                .foregroundStyle(isMine ? Color.white : Color.primary)
            if !isMine { Spacer(minLength: 80) }
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
