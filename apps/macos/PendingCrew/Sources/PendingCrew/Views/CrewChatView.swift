import SwiftUI

struct CrewChatView: View {
    let announcements: [CrewAnnouncement]
    let sessions: [CrewSession]
    let members: [CrewMember]
    @Binding var draftText: String
    @Binding var mentionedSessionIds: Set<String>
    @Binding var mentionedMemberIds: Set<String>
    let onSend: () -> Void

    private var canSend: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isBroadcast: Bool {
        mentionedSessionIds.isEmpty && mentionedMemberIds.isEmpty
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
                                    mentionedMemberIds = []
                                    draftText = ""
                                },
                                onReplyToMember: { memberId in
                                    mentionedMemberIds = [memberId]
                                    mentionedSessionIds = []
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
            MentionTargetPicker(
                sessions: sessions,
                members: members,
                selectedSessionIds: $mentionedSessionIds,
                selectedMemberIds: $mentionedMemberIds
            )

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    mentionedSessionIds = []
                    mentionedMemberIds = []
                } label: {
                    Image(systemName: isBroadcast ? "at.circle.fill" : "at.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(PendingBotChatStyle.inkMuted)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(PendingBotChatStyle.surface))
                        .overlay(Circle().strokeBorder(PendingBotChatStyle.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help(isBroadcast ? "全员广播" : "清除 @，改为全员广播")

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

struct CrewChatMentionTarget: Identifiable, Hashable {
    enum Kind: Hashable {
        case all
        case member
        case session
    }

    let kind: Kind
    let title: String
    let systemImage: String
    let sessionId: String?
    let memberId: String?

    var id: String {
        if let sessionId { return "session:\(sessionId)" }
        if let memberId { return "member:\(memberId)" }
        return "all"
    }

    static func targets(sessions: [CrewSession], members: [CrewMember]) -> [CrewChatMentionTarget] {
        let memberTargets = members
            .filter { $0.status == "active" }
            .map {
                CrewChatMentionTarget(
                    kind: .member,
                    title: $0.displayName,
                    systemImage: symbol(for: $0),
                    sessionId: nil,
                    memberId: $0.id
                )
            }
        let sessionTargets = sessions.map {
            CrewChatMentionTarget(
                kind: .session,
                title: sessionLabel($0),
                systemImage: "terminal",
                sessionId: $0.id,
                memberId: nil
            )
        }
        return [
            CrewChatMentionTarget(
                kind: .all,
                title: "全员",
                systemImage: "person.3",
                sessionId: nil,
                memberId: nil
            )
        ] + memberTargets + sessionTargets
    }

    private static func sessionLabel(_ session: CrewSession) -> String {
        "\(session.runnerKind):\(session.id.prefix(7))"
    }

    private static func symbol(for member: CrewMember) -> String {
        switch member.memberKind {
        case "human": return "person.crop.circle"
        case "bot", "master_bot": return "sparkles"
        default: return "person.crop.square"
        }
    }
}

private struct MentionTargetPicker: View {
    let sessions: [CrewSession]
    let members: [CrewMember]
    @Binding var selectedSessionIds: Set<String>
    @Binding var selectedMemberIds: Set<String>

    private var targets: [CrewChatMentionTarget] {
        CrewChatMentionTarget.targets(sessions: sessions, members: members)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(targets) { target in
                    MentionChip(
                        title: target.title,
                        isSelected: isSelected(target),
                        systemImage: target.systemImage
                    ) {
                        toggle(target)
                    }
                    .help(target.id)
                }
            }
            .padding(.horizontal, PendingBotChatStyle.gutter)
        }
        .frame(height: 30)
    }

    private func isSelected(_ target: CrewChatMentionTarget) -> Bool {
        switch target.kind {
        case .all:
            selectedSessionIds.isEmpty && selectedMemberIds.isEmpty
        case .session:
            target.sessionId.map { selectedSessionIds.contains($0) } ?? false
        case .member:
            target.memberId.map { selectedMemberIds.contains($0) } ?? false
        }
    }

    private func toggle(_ target: CrewChatMentionTarget) {
        switch target.kind {
        case .all:
            selectedSessionIds = []
            selectedMemberIds = []
        case .session:
            guard let id = target.sessionId else { return }
            if selectedSessionIds.contains(id) {
                selectedSessionIds.remove(id)
            } else {
                selectedSessionIds.insert(id)
            }
        case .member:
            guard let id = target.memberId else { return }
            if selectedMemberIds.contains(id) {
                selectedMemberIds.remove(id)
            } else {
                selectedMemberIds.insert(id)
            }
        }
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
    let onReplyToMember: (String) -> Void

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
                } else if let senderMemberId = announcement.senderMemberId {
                    Button {
                        onReplyToMember(senderMemberId)
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
        if let senderMemberId = announcement.senderMemberId,
           let member = members.first(where: { $0.id == senderMemberId }) {
            return member.displayName
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
