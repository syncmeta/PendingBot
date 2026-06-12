import SwiftUI

// T4.6 P1 Step 4 — the crew chat message stream. Hand-ports the inline
// list + scroll grammar from ConversationView (which isn't extractable —
// it's inline in that view's body) against the crew store's adapted rows.
// Reuses BubbleView as-is via the sentinel sender_type + GroupBubbleSender
// the adapter produces.
//
// T4.5: rows whose announcement message_kind=='permission_request' now
// render an inline PermissionRequestCardView (cold load + live frame both
// carry the data); everything else stays a BubbleView. Tapping 批准 / 拒绝
// routes through store.decide(permissionRequestId:approve:detail:).
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
                            rowView(row)
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
            .platformScrollKeyboardDismiss()
            .refreshable { await store.load(detail: detail) }
            .onChange(of: store.revision) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    /// Per-row renderer: permission cards vs normal bubbles. The card View
    /// is iOS-only (PermissionRequestCardView lives under `#if os(iOS)`);
    /// on macOS the permission branch falls back to the bubble so the
    /// shared module still compiles (Crew chat is an iOS-first surface).
    @ViewBuilder
    private func rowView(_ row: CrewChatStore.CrewChatRow) -> some View {
        if let task = row.taskRequest {
            // #242 遥控 v1 — task_request rows render the dispatch card
            // (cross-platform, no iOS-only dependency).
            CrewTaskRequestCardView(payload: task, summary: row.message.content)
                .padding(.vertical, 4)
        } else {
            cardOrBubble(row)
        }
    }

    @ViewBuilder
    private func cardOrBubble(_ row: CrewChatStore.CrewChatRow) -> some View {
        #if os(iOS)
        if let payload = row.permission {
            PermissionRequestCardView(
                sessionLabel: row.permissionSessionLabel ?? "Session",
                payload: payload,
                busy: payload.permission_request_id
                    .map { store.decidingPermissionIds.contains($0) } ?? false,
                onApprove: { decide(payload, approve: true) },
                onDeny: { decide(payload, approve: false) }
            )
            .padding(.vertical, 4)
        } else {
            bubble(row)
        }
        #else
        bubble(row)
        #endif
    }

    #if os(iOS)
    private func decide(_ payload: PermissionRequestPayload, approve: Bool) {
        guard let id = payload.permission_request_id else { return }
        Task { await store.decide(permissionRequestId: id, approve: approve, detail: detail) }
    }
    #endif

    private func bubble(_ row: CrewChatStore.CrewChatRow) -> some View {
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
