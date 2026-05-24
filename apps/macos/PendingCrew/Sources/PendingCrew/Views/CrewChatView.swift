import SwiftUI

struct CrewChatView: View {
    let announcements: [CrewAnnouncement]
    let sessions: [CrewSession]
    let members: [CrewMember]
    @Binding var draftText: String
    @Binding var mentionedSessionIds: Set<String>
    let onSend: () -> Void

    private var canSend: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            composer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 420)
        .background(PendingBotChatStyle.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PendingBotChatStyle.hairline, lineWidth: 0.5)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if announcements.isEmpty {
                        ContentUnavailableView("还没有消息", systemImage: "bubble.left.and.bubble.right")
                            .padding(.vertical, 48)
                    } else {
                        ForEach(announcements) { announcement in
                            CrewAnnouncementBubble(
                                announcement: announcement,
                                sessions: sessions,
                                members: members,
                                onReplyToSession: { sessionId in
                                    mentionedSessionIds = [sessionId]
                                    draftText = ""
                                }
                            )
                            .id(announcement.id)
                        }
                    }
                }
                .padding(.vertical, 10)
            }
            .onChange(of: announcements.map(\.id)) { _, ids in
                guard let last = ids.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            MentionSessionPicker(sessions: sessions, selectedSessionIds: $mentionedSessionIds)

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    mentionedSessionIds = []
                } label: {
                    Image(systemName: mentionedSessionIds.isEmpty ? "at.circle.fill" : "at.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(PendingBotChatStyle.inkMuted)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(PendingBotChatStyle.surface))
                        .overlay(Circle().strokeBorder(PendingBotChatStyle.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help(mentionedSessionIds.isEmpty ? "全员广播" : "清除 @，改为全员广播")

                HStack(alignment: .bottom, spacing: 6) {
                    TextEditor(text: $draftText)
                        .font(.system(size: 15))
                        .foregroundStyle(PendingBotChatStyle.ink)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 34, maxHeight: 92)
                        .padding(.leading, 10)
                        .padding(.vertical, 3)

                    Button(action: onSend) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(canSend ? .white : PendingBotChatStyle.inkMuted.opacity(0.55))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(canSend ? PendingBotChatStyle.accent : PendingBotChatStyle.surfaceMuted))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .padding(.trailing, 6)
                    .padding(.bottom, 4)
                }
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(PendingBotChatStyle.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(PendingBotChatStyle.hairline, lineWidth: 0.5)
                )
            }
            .padding(.horizontal, PendingBotChatStyle.gutter)
            .padding(.bottom, 12)
        }
        .padding(.top, 8)
        .background(.bar)
    }
}

private struct MentionSessionPicker: View {
    let sessions: [CrewSession]
    @Binding var selectedSessionIds: Set<String>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                MentionChip(
                    title: "全员",
                    isSelected: selectedSessionIds.isEmpty,
                    systemImage: "person.3"
                ) {
                    selectedSessionIds = []
                }

                ForEach(sessions) { session in
                    MentionChip(
                        title: sessionLabel(session),
                        isSelected: selectedSessionIds.contains(session.id),
                        systemImage: "terminal"
                    ) {
                        if selectedSessionIds.contains(session.id) {
                            selectedSessionIds.remove(session.id)
                        } else {
                            selectedSessionIds.insert(session.id)
                        }
                    }
                    .help(session.id)
                }
            }
            .padding(.horizontal, PendingBotChatStyle.gutter)
        }
        .frame(height: 30)
    }

    private func sessionLabel(_ session: CrewSession) -> String {
        "\(session.runnerKind):\(session.id.prefix(6))"
    }
}

private struct MentionChip: View {
    let title: String
    let isSelected: Bool
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: isSelected ? "checkmark.circle.fill" : systemImage)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? PendingBotChatStyle.userBubble : PendingBotChatStyle.surface)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(PendingBotChatStyle.hairline, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct CrewAnnouncementBubble: View {
    let announcement: CrewAnnouncement
    let sessions: [CrewSession]
    let members: [CrewMember]
    let onReplyToSession: (String) -> Void

    private var isMine: Bool {
        announcement.senderKind == "human"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isMine {
                Spacer(minLength: 56)
                mineBubble
            } else {
                peerBubble
                Spacer(minLength: 40)
            }
        }
        .padding(.horizontal, PendingBotChatStyle.gutter)
        .padding(.vertical, 4)
    }

    private var peerBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            SenderAvatar(label: senderLabel, kind: announcement.senderKind)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(senderLabel)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(PendingBotChatStyle.inkMuted)
                    Text(shortTime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                BubbleContent(
                    text: announcement.summary,
                    targetText: targetLabel,
                    fill: PendingBotChatStyle.surface,
                    border: PendingBotChatStyle.hairline,
                    alignment: .leading
                )

                if let senderSessionId = announcement.senderSessionId {
                    Button {
                        onReplyToSession(senderSessionId)
                    } label: {
                        Label("回复", systemImage: "arrowshape.turn.up.left")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PendingBotChatStyle.inkMuted)
                }
            }
        }
    }

    private var mineBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(shortTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("你")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(PendingBotChatStyle.inkMuted)
            }

            BubbleContent(
                text: announcement.summary,
                targetText: targetLabel,
                fill: PendingBotChatStyle.userBubble,
                border: .clear,
                alignment: .trailing
            )
        }
    }

    private var senderLabel: String {
        if let senderSessionId = announcement.senderSessionId {
            return sessionLabel(senderSessionId)
        }
        switch announcement.senderKind {
        case "human": return "人类"
        case "master_bot": return "Master Bot"
        case "system": return "系统"
        default: return announcement.senderKind
        }
    }

    private var targetLabel: String {
        if announcement.recipientMode == "all_sessions" {
            return "@全员"
        }
        let targets = announcement.mentions.map { mention -> String in
            if let sessionId = mention.targetSessionId {
                return "@\(sessionLabel(sessionId))"
            }
            if let memberId = mention.targetMemberId {
                return "@\(memberLabel(memberId))"
            }
            return "@?"
        }
        return targets.isEmpty ? "@-" : targets.joined(separator: " ")
    }

    private var shortTime: String {
        String(announcement.createdAt.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }

    private func sessionLabel(_ sessionId: String) -> String {
        guard let session = sessions.first(where: { $0.id == sessionId }) else {
            return "session:\(sessionId.prefix(8))"
        }
        return "\(session.runnerKind):\(session.id.prefix(6))"
    }

    private func memberLabel(_ memberId: String) -> String {
        guard let member = members.first(where: { $0.id == memberId }) else {
            return "member:\(memberId.prefix(8))"
        }
        return member.displayName
    }
}

private struct BubbleContent: View {
    let text: String
    let targetText: String
    let fill: Color
    let border: Color
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            Text(text)
                .textSelection(.enabled)
                .font(.system(size: 15))
                .foregroundStyle(PendingBotChatStyle.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(targetText)
                .font(.caption)
                .foregroundStyle(PendingBotChatStyle.inkMuted)
                .lineLimit(2)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: PendingBotChatStyle.bubbleRadius, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PendingBotChatStyle.bubbleRadius, style: .continuous)
                .strokeBorder(border, lineWidth: 0.5)
        )
        .frame(maxWidth: 520, alignment: alignment == .trailing ? .trailing : .leading)
    }
}

private struct SenderAvatar: View {
    let label: String
    let kind: String

    var body: some View {
        ZStack {
            Circle()
                .fill(avatarFill)
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 30, height: 30)
        .help(label)
    }

    private var symbol: String {
        switch kind {
        case "master_bot": return "sparkles"
        case "system": return "gearshape"
        default: return "terminal"
        }
    }

    private var avatarFill: Color {
        switch kind {
        case "master_bot": return PendingBotChatStyle.accentHover
        case "system": return PendingBotChatStyle.inkMuted
        default: return PendingBotChatStyle.accent
        }
    }
}

private enum PendingBotChatStyle {
    static let accent = Color(hex: 0x044735)
    static let accentHover = Color(hex: 0x0A6049)
    static let userBubble = Color(hex: 0xE3EEEA)
    static let canvas = Color(hex: 0xFDFCFA)
    static let surface = Color(hex: 0xFFFFFF)
    static let surfaceMuted = Color(hex: 0xEFEEE9)
    static let ink = Color(hex: 0x1B1A14)
    static let inkMuted = Color(hex: 0x6E6A5C)
    static let hairline = Color(hex: 0xE2E0D7)
    static let gutter: CGFloat = 16
    static let bubbleRadius: CGFloat = 18
}

private extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self = Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
