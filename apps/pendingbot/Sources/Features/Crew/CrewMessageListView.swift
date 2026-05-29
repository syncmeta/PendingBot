import SwiftUI

// T4.6 P1 Step 4 — the crew chat message stream. Hand-ports the inline
// list + scroll grammar from ConversationView (which isn't extractable —
// it's inline in that view's body) against the crew store's adapted rows.
// Reuses BubbleView as-is via the sentinel sender_type + GroupBubbleSender
// the adapter produces.
//
// P1 scope: NO inline permission cards (no crew-level GET data source for
// pending requests — see tech-debt; deferred to T4.5 when the
// SessionProxyDO permission frame lands). The list renders bubbles only.
struct CrewMessageListView: View {
    @Bindable var store: CrewChatStore
    let serverURL: URL?
    let currentUserId: String?
    /// Mentions to re-send when retrying a failed bubble (the current
    /// composer selection). Empty → broadcast retry.
    let retryMentions: [CrewMentionInput]
    let detail: CrewDetailV2?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if store.rows.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.rows) { row in
                            BubbleView(
                                message: row.message,
                                botName: row.sender?.displayName ?? "机组",
                                conversationID: store.crewId,
                                currentUserId: currentUserId,
                                groupSender: row.sender,
                                serverURL: serverURL,
                                onRetry: row.message.isFailed ? {
                                    Task { await store.retry(row.id, mentions: retryMentions, detail: detail) }
                                } : nil,
                                menu: {}
                            )
                            .id(row.id)
                        }
                    }
                    // Bottom anchor so scroll-to-bottom lands past the last
                    // bubble's padding.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await store.load(detail: detail) }
            .onChange(of: store.revision) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private static let bottomAnchor = "crew-chat-bottom"

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("还没有消息")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("发条消息或 @机组成员开始协作。")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
