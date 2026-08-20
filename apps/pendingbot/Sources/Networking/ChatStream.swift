import Foundation

/// Server-sent event from POST /v1/messages. Mirrors the events Worker
/// emits in `runChatTurn` — keep names in lockstep with apps/edge/src/lib/bot-reply.ts.
enum ChatEvent: Sendable {
    /// Synthetic — not a real SSE frame. Fired the instant the HTTP
    /// response headers come back with a 2xx status, before any wire
    /// event has been parsed. The UI uses this to flip the optimistic
    /// user bubble from "sending" (light green) to "sent" (full green),
    /// so the user sees a distinct ack between "still uploading" and
    /// "server accepted, generating reply".
    case connected
    /// First frame of a /v1/messages/start turn — carries the canonical
    /// conv id and user-message id so the client can rekey its optimistic
    /// local row before any token arrives. Not emitted by the regular
    /// /v1/messages endpoint (its caller already has both ids).
    case meta(conversationId: String, userMessageId: String)
    case typing(state: String)
    case token(delta: String)
    case bubble(id: String, index: Int, groupId: String, content: String, messageSeq: Int?)
    case done(groupId: String, totalContent: String)
    case interrupted(groupId: String, totalContent: String)
    /// Bot used the [SILENT] control token — nothing to show, the turn
    /// produced no message. UI should leave the conversation as-is.
    case silent(groupId: String)
    /// Bot invoked a tool (search_web / read_url / execute_code / create_skill / query_user_memory).
    /// Worker emits a paired `tool_result` once the tool returns; UI accumulates
    /// the pair into the per-turn trace shown inline above the bot reply.
    case toolCall(name: String, input: String?)
    case toolResult(name: String, summary: String?, error: String?, detail: String?)
    /// Cumulative web-search citations for this turn. Server emits after each
    /// `search_web` returns; the list grows monotonically (deduped by url).
    /// UI resolves inline `[N]` markers in the bot's reply against `items`
    /// (1-based) so taps open the source page.
    case citations(items: [MessageCitation])
    case error(message: String)
    case unknown(name: String, raw: String)
}

/// One-shot SSE call to POST /v1/messages. Caller iterates the returned
/// AsyncThrowingStream; closing the iteration (or the parent Task being
/// cancelled) propagates to URLSession's data task and aborts the upstream
/// request — Worker sees `request.signal.aborted` and stops the LLM stream.
///
/// Body and headers come from APIClient's auth helpers; this struct just
/// owns the SSE wire format.
struct ChatStream {
    let workerURL: URL
    let session: URLSession

    init(workerURL: URL = HostedConfig.environment.workerURL,
         session: URLSession = Self.longLivedSession) {
        self.workerURL = workerURL
        self.session = session
    }

    /// Dedicated session for SSE — `URLSession.shared` ships with a 60s
    /// `timeoutIntervalForRequest` (the "max gap between bytes" timeout),
    /// which is shorter than the silent stretches some Worker turns produce.
    /// In particular OpenAI's `image_generation` built-in tool runs entirely
    /// server-side and can sit for 30–90s between the `in_progress` event
    /// and the base64 result — during that window no bytes flow over the
    /// SSE connection and the 60s default fires, surfacing as a spurious
    /// "已超时" to the user. Worker also writes a 15s keepalive comment on
    /// the stream so this timeout shouldn't normally fire, but we keep a
    /// generous client-side ceiling as a safety net:
    ///   • request: 10 min between bytes (matches OpenAI SDK default)
    ///   • resource: 30 min total — well below AI Gateway's 1h cap and
    ///     longer than any plausible single-turn agent loop.
    /// Cloudflare Workers streaming responses don't have a hard wall-clock
    /// limit, so these client-side numbers are the binding constraint.
    nonisolated(unsafe) static let longLivedSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 600   // 10 min between bytes
        cfg.timeoutIntervalForResource = 1800 // 30 min total
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// Body shape is intentionally `[String: Any]` — chat POST has optional
    /// fields (recentContext, oldestContextMessageId, attachmentIds) and we
    /// don't want a typed model that has to mirror Worker's zod schema.
    /// `path` defaults to the regular endpoint; pass "v1/messages/start" for
    /// the lazy-cloud-conv first-turn flow.
    func send(body: [String: Any], path: String = "v1/messages") -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: workerURL.appendingPathComponent(path))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    // Cloudflare auto-gzips SSE when the client sends the
                    // default `Accept-Encoding: gzip, deflate, br`, which
                    // makes URLSession only deliver bytes at deflate-block
                    // boundaries — tokens arrive in big batches and the
                    // typewriter feel disappears. Force identity so chunks
                    // flow through as-is.
                    req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    let token = try await SupabaseStack.shared.auth.session.accessToken
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    if (200..<300).contains(http.statusCode) {
                        continuation.yield(.connected)
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        // Read enough error body for diagnosis; server-side
                        // tool failures often include provider response text.
                        var errBytes: [UInt8] = []
                        for try await b in bytes {
                            errBytes.append(b)
                            if errBytes.count >= 8192 { break }
                        }
                        let body = String(decoding: errBytes, as: UTF8.self)
                        throw ChatStreamError.http(status: http.statusCode, body: body)
                    }

                    // SSE wire format: blank line separates events. Each event
                    // is a sequence of `key: value` lines. We only care about
                    // `event:` and `data:`; everything else is ignored.
                    //
                    // We can't use `bytes.lines` here — on Mac Catalyst (and
                    // possibly other platforms) `URLSession.AsyncBytes`'
                    // line splitter swallows empty lines, which means the
                    // blank-line separator that flushes one SSE event never
                    // appears, every event gets accumulated into one giant
                    // pending state, and we only see the *last* event at
                    // stream-close time (with all prior events' data lines
                    // concatenated as its data). Symptom: iOS appears to
                    // miss every `token` / `bubble` event and only sees a
                    // single garbled `done`.
                    //
                    // Parse bytes ourselves: split on LF, treat empty lines
                    // as event terminators explicitly.
                    var pendingEventName = ""
                    var pendingDataLines: [String] = []
                    var lineBytes: [UInt8] = []

                    func flush() {
                        guard !pendingEventName.isEmpty else { return }
                        let dataJoined = pendingDataLines.joined(separator: "\n")
                        let evt = decode(eventName: pendingEventName, dataJSON: dataJoined)
                        continuation.yield(evt)
                        pendingEventName = ""
                        pendingDataLines.removeAll()
                    }

                    func handleLine(_ line: String) {
                        if line.isEmpty {
                            flush()
                            return
                        }
                        if line.hasPrefix("event:") {
                            pendingEventName = line.dropFirst("event:".count)
                                .trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let payload = line.dropFirst("data:".count)
                                .trimmingCharacters(in: .whitespaces)
                            pendingDataLines.append(String(payload))
                        }
                        // (id:/retry:/comment lines are ignored.)
                    }

                    for try await byte in bytes {
                        if byte == 0x0A { // LF
                            // Strip optional trailing CR for CRLF servers.
                            if lineBytes.last == 0x0D { lineBytes.removeLast() }
                            let line = String(decoding: lineBytes, as: UTF8.self)
                            lineBytes.removeAll(keepingCapacity: true)
                            handleLine(line)
                        } else {
                            lineBytes.append(byte)
                        }
                    }
                    // Server may close without a trailing newline + blank.
                    if !lineBytes.isEmpty {
                        let line = String(decoding: lineBytes, as: UTF8.self)
                        handleLine(line)
                    }
                    flush()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

enum ChatStreamError: LocalizedError {
    case http(status: Int, body: String)
    var errorDescription: String? {
        switch self {
        case .http(let s, let body): return "HTTP \(s): \(body.prefix(4000))"
        }
    }
}

// MARK: - Decode

private func decode(eventName: String, dataJSON: String) -> ChatEvent {
    let json = (try? JSONSerialization.jsonObject(with: Data(dataJSON.utf8))) as? [String: Any] ?? [:]
    switch eventName {
    case "meta":
        return .meta(
            conversationId: (json["conversationId"] as? String) ?? "",
            userMessageId: (json["userMessageId"] as? String) ?? ""
        )
    case "typing":
        return .typing(state: (json["state"] as? String) ?? "")
    case "token":
        return .token(delta: (json["delta"] as? String) ?? "")
    case "bubble":
        return .bubble(
            id: (json["id"] as? String) ?? "",
            index: (json["index"] as? Int) ?? 0,
            groupId: (json["bubble_group_id"] as? String) ?? "",
            content: (json["content"] as? String) ?? "",
            messageSeq: json["message_seq"] as? Int
        )
    case "done":
        return .done(
            groupId: (json["bubble_group_id"] as? String) ?? "",
            totalContent: (json["total_content"] as? String) ?? ""
        )
    case "interrupted":
        return .interrupted(
            groupId: (json["bubble_group_id"] as? String) ?? "",
            totalContent: (json["total_content"] as? String) ?? ""
        )
    case "silent":
        return .silent(groupId: (json["bubble_group_id"] as? String) ?? "")
    case "tool_call":
        let name = (json["name"] as? String) ?? ""
        // Each tool emits its own input shape — flatten the relevant
        // field into a single string so the UI doesn't have to switch.
        let input: String? = {
            if name == "request_execute_code" {
                let reason = (json["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let preview = (json["code_preview"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (json["code"] as? String)?
                        .split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .first(where: { !$0.isEmpty })
                        .map { String($0) }
                if let reason, let preview { return "\(reason) · \(preview)" }
                if let preview { return preview }
                if let reason { return reason }
            }
            if name == "delegate_to_specialist" {
                // `target` is the specialist enum (claude / openai / gemini)
                // and is what we want to surface as the trace input —
                // the prompt itself can be very long and isn't useful in
                // the collapsed summary row.
                if let t = json["target"] as? String, !t.isEmpty { return t }
            }
            if let q = json["query"] as? String, !q.isEmpty { return q }
            if let u = json["url"] as? String, !u.isEmpty { return u }
            if let s = json["skill_name"] as? String, !s.isEmpty { return s }
            if let p = json["code_preview"] as? String, !p.isEmpty { return p }
            if let c = json["code"] as? String, !c.isEmpty {
                return c
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first(where: { !$0.isEmpty })
                    .map { String($0) }
            }
            if let c = json["chars"] as? Int { return "\(c) chars" }
            return nil
        }()
        return .toolCall(name: name, input: input)
    case "tool_result":
        let name = (json["name"] as? String) ?? ""
        let err = (json["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // `detail` doubles as a deep-link carrier for delegate_to_specialist:
        // the worker emits `sub_conversation_id` on the tool_result, which we
        // stash here so the trace row can later route a tap into the
        // sub-conversation view. Existing detail uses (stderr, etc.) take
        // precedence for the other tools so this is purely additive.
        let detail = (json["detail"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? (json["stderr"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? {
                if name == "delegate_to_specialist",
                   let sub = json["sub_conversation_id"] as? String, !sub.isEmpty {
                    return "sub_conversation:\(sub)"
                }
                return nil
            }()
        let summary: String? = {
            if name == "delegate_to_specialist" {
                // delegate emits both `target` and `chars` on the result;
                // build a more readable summary than the bare "Nxx 字回答".
                let target = (json["target"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let chars = json["chars"] as? Int
                if let target, let chars { return "\(target) · \(chars) 字回答" }
                if let target { return target }
            }
            if let n = json["count"] as? Int { return "\(n) 条结果" }
            if let t = json["title"] as? String, !t.isEmpty { return t }
            if let s = json["skill_name"] as? String, !s.isEmpty { return s }
            if let decision = json["decision"] as? String, !decision.isEmpty {
                switch decision {
                case "approved": return "已批准"
                case "denied": return "已拒绝"
                case "timeout": return "已超时"
                default: return decision
                }
            }
            if let exit = json["exit_code"] as? Int {
                let tail = (json["stdout_tail"] as? String)
                    .flatMap { $0.isEmpty ? nil : $0 }
                if let tail { return "exit \(exit) · \(tail)" }
                return "exit \(exit)"
            }
            if let n = json["chars"] as? Int {
                return n > 0 ? "\(n) 字回答" : "暂无相关记忆"
            }
            return nil
        }()
        return .toolResult(name: name, summary: summary, error: err, detail: detail)
    case "citations":
        // `items` is a JSON array of {url, title, snippet?}. Re-encode the
        // sub-tree and decode through Codable so the model layer owns the
        // shape — keeps this switch from sprawling.
        if let items = json["items"] as? [Any],
           let data = try? JSONSerialization.data(withJSONObject: items),
           let decoded = try? JSONDecoder().decode([MessageCitation].self, from: data) {
            return .citations(items: decoded)
        }
        return .citations(items: [])
    case "error":
        return .error(message: (json["message"] as? String) ?? "")
    default:
        return .unknown(name: eventName, raw: dataJSON)
    }
}
