import SwiftUI

// Group-only surfaces of ConversationView. Three concerns live here:
//
//   • Group-bubble sender resolution — groupSenderFor turns a row's
//     sender_type / sender_id into the GroupBubbleSender used by the
//     bubble's name+avatar header. 1v1 convs short-circuit to nil so
//     they keep the right-side "user" layout.
//
//   • @-mention composer — mentionPrefix detects an in-progress mention
//     trigger at the end of `input`, mentionCandidates filters
//     groupSenders against it, and insertMention rewrites `input` when a
//     candidate is tapped. (The picker view itself lives in
//     ChatComposerAccessory.swift since it renders inside the composer's
//     inputAccessoryView.)
//
//   • Continue-request vote — decideContinue posts the worker's "bot
//     wants to keep going" allow/deny in user_bot/group flows. (The
//     continue-request banner view lives in ChatComposerAccessory.swift;
//     it reads values threaded in from ConversationView.body.)
//
// Everything stays inside ConversationView via extension; body in the
// main file calls these as plain methods/computed vars.

extension ConversationView {

    /// Resolve the sender chip for a group conv bubble. Returns nil for
    /// 1v1 conversations (the user/bot avatar lives in the chat header)
    /// and also nil for our own messages so they keep the right-side
    /// "user" layout instead of being rendered as a bot bubble with
    /// our own name on top.
    func groupSenderFor(_ msg: ChatMessage) -> GroupBubbleSender? {
        guard conversation.conversation_type == "group" else { return nil }
        let me = AccountStore.shared.current?.id
        if msg.isMine(currentUserId: me) { return nil }
        let key: String
        switch msg.sender_type {
        case "bot":  key = "bot:\(msg.sender_id)"
        case "user", "human": key = "user:\(msg.sender_id)"
        default: return nil
        }
        return groupSenders[key]
    }

    /// Detects an in-progress @-mention at the end of `input`. Returns
    /// the substring AFTER the `@` (possibly empty when the user just
    /// typed `@`). nil when there's no @-trigger active. We trigger on
    /// "@" preceded by whitespace or start-of-string so emails / inline
    /// at-signs don't accidentally open the picker.
    var mentionPrefix: String? {
        guard let atRange = input.range(of: "@", options: .backwards) else { return nil }
        // Must be followed only by chars that look like a name token (no
        // whitespace, no newlines) — anything else means the user moved on.
        let after = input[atRange.upperBound...]
        if after.contains(where: { $0.isWhitespace || $0.isNewline }) {
            return nil
        }
        // The `@` must be at the start of input or immediately after a
        // whitespace; reject things like "alice@host" inside an email.
        if atRange.lowerBound > input.startIndex {
            let prev = input[input.index(before: atRange.lowerBound)]
            if !prev.isWhitespace { return nil }
        }
        return String(after)
    }

    /// Filter groupSenders by the in-progress prefix (case-insensitive),
    /// drop "myself" so I don't mention me. Cap at a few rows so the
    /// picker doesn't push the message list off-screen.
    func mentionCandidates(prefix: String) -> [GroupBubbleSender] {
        let me = AccountStore.shared.current?.id ?? ""
        let needle = prefix.lowercased()
        return groupSenders.values
            .filter { sender in
                if sender.kind == .user && sender.id == me { return false }
                if needle.isEmpty { return true }
                return sender.displayName.lowercased().contains(needle)
            }
            .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
            .prefix(6)
            .map { $0 }
    }

    func insertMention(_ sender: GroupBubbleSender, prefix: String) {
        // Drop the trailing "@<prefix>" and re-insert "@<displayName> ".
        // Spaces inside nicknames stay because we replace by length, not
        // by whitespace boundary — DB enforces no-whitespace inside a
        // single nickname so this is unambiguous in practice.
        let dropCount = prefix.count + 1   // include the "@"
        let head = String(input.dropLast(dropCount))
        input = head + "@" + sender.displayName + " "
        Haptics.tap()
    }

    /// Append `@<displayName> ` to the composer without an in-progress `@token`
    /// to replace — used by the "右键/长按头像 → @ 该发送者" path (the user
    /// didn't type `@`, they picked from the avatar). Inserts a leading space
    /// only when needed, and no-ops if the mention token is already present so
    /// hammering the menu doesn't pile up `@X @X`. mentions travel as plain
    /// `@name` text (server parses ids), same as `insertMention`.
    func appendMention(_ sender: GroupBubbleSender) {
        let token = "@" + sender.displayName
        guard !input.contains(token + " ") else { return }
        let sep = (input.isEmpty || input.last?.isWhitespace == true) ? "" : " "
        input = input + sep + token + " "
        Haptics.tap()
    }

    func decideContinue(_ pc: PendingContinue, allow: Bool) async {
        continueDeciding = true
        defer { continueDeciding = false }
        struct Body: Encodable {
            let requestId: String
            let decision: String
        }
        do {
            let url = HostedConfig.environment.workerURL
                .appendingPathComponent("v1/groups/\(conversation.id)/continue-decision")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let token = try await SupabaseStack.shared.auth.session.accessToken
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONEncoder().encode(Body(
                requestId: pc.id,
                decision: allow ? "allowed" : "denied",
            ))
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
                throw NSError(
                    domain: "ContinueVote",
                    code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                    userInfo: [NSLocalizedDescriptionKey: msg],
                )
            }
            // The decision message is inserted by the worker (Realtime
            // delivers it); just clear the local banner.
            self.pendingContinue = nil
            Haptics.tap()
        } catch {
            self.error = "投票失败: \(error.localizedDescription)"
            Haptics.error()
        }
    }
}
