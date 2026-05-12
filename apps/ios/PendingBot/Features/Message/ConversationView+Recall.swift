import Foundation
import Supabase

// Recall + delete + attachment-cache scrub. Extracted from ConversationView
// to keep the main view file focused on layout + state. All methods here
// rely on ConversationView's @State (messages, attachmentIdsByMsgId, error)
// and its `api` / `account` properties; private-in-same-module access lets
// the extension reach them without ceremony.

extension ConversationView {

    /// Hard delete (no tombstone). Allowed by the worker when the caller
    /// owns the message OR the enclosing conversation. Optimistically
    /// drops the row from the view; server confirms via Realtime UPDATE.
    func deleteMessage(_ msg: ChatMessage) async {
        guard let api else { return }
        do {
            try await api.deleteVoid("v1/messages/\(msg.id)")
            messages.removeAll { $0.id == msg.id }
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Round-trip a Realtime `log_payload` field through JSONEncoder
    /// so it can decode as our typed RecallPayload struct. AnyJSON
    /// (supabase-swift's tagged variant) is already encodable, so this
    /// is just JSON → bytes → typed-Swift in two steps.
    func decodeRecallPayload(_ value: AnyJSON) -> RecallPayload? {
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(RecallPayload.self, from: data)
        } catch {
            return nil
        }
    }

    /// Same trick for the `attachments` jsonb column on a Realtime
    /// record. The worker writes `{ ids: [uuid, ...] }`.
    func decodeAttachmentIds(_ value: AnyJSON) -> [String]? {
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(AttachmentRef.self, from: data).ids
        } catch {
            return nil
        }
    }

    /// Drop URLCache.shared entries for each attachment id we know
    /// belonged to a now-recalled message. The worker stops serving
    /// /v1/uploads/:id after recall (404), but iOS's HTTP cache holds
    /// the bytes for up to a year (Cache-Control: immutable). Without
    /// this call a stolen-but-unlocked device could still surface the
    /// image from local disk after the conversation has scrubbed it.
    func scrubAttachmentCache(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let workerURL = account?.workerURL ?? HostedConfig.environment.workerURL
        for id in ids {
            let url = workerURL.appendingPathComponent("v1/uploads/\(id)")
            URLCache.shared.removeCachedResponse(for: URLRequest(url: url))
        }
    }

    /// WeChat-style sender recall. POSTs to /v1/messages/:id/recall and
    /// removes the row from the local view optimistically.
    ///
    ///   • user_user (human↔human): server leaves a `log_kind='recall'`
    ///     tombstone row that both peers will pick up via Realtime
    ///     INSERT — that's what renders as "你/对方撤回了 …".
    ///   • user_bot / group / self: server hard-purges including R2
    ///     attachments. The row just disappears.
    ///
    /// Either way our optimistic remove matches what Realtime will
    /// shortly confirm (status='deleted' UPDATE for the original row).
    func recallMessage(_ msg: ChatMessage) async {
        guard let api else { return }
        // Snapshot first so we can roll back if the POST fails.
        guard let idx = messages.firstIndex(where: { $0.id == msg.id }) else { return }
        let snapshot = messages[idx]
        // Capture attachment ids BEFORE the optimistic remove drops
        // the sidecar entry — we'll use them to scrub URLCache once
        // the server confirms (or roll-back leaves them untouched).
        let attIds = attachmentIdsByMsgId[msg.id] ?? []
        messages.remove(at: idx)
        do {
            try await api.postVoid("v1/messages/\(msg.id)/recall")
            attachmentIdsByMsgId.removeValue(forKey: msg.id)
            scrubAttachmentCache(attIds)
            Haptics.success()
        } catch {
            // Rollback — preserve the prior position on failure.
            messages.insert(snapshot, at: min(idx, messages.count))
            self.error = error.localizedDescription
        }
    }
}
