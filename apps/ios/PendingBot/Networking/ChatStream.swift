import Foundation

/// Server-sent event from POST /v1/messages. Mirrors the events Worker
/// emits in `runChatTurn` — keep names in lockstep with apps/edge/src/lib/bot-reply.ts.
enum ChatEvent: Sendable {
    /// First frame of a /v1/messages/start turn — carries the canonical
    /// conv id and user-message id so the client can rekey its optimistic
    /// local row before any token arrives. Not emitted by the regular
    /// /v1/messages endpoint (its caller already has both ids).
    case meta(conversationId: String, userMessageId: String)
    case typing(state: String)
    case token(delta: String)
    case bubble(id: String, index: Int, groupId: String, content: String)
    case done(groupId: String, totalContent: String)
    case interrupted(groupId: String, totalContent: String)
    /// Bot used the [SILENT] control token — nothing to show, the turn
    /// produced no message. UI should leave the conversation as-is.
    case silent(groupId: String)
    /// Bot invoked a tool (search_web / read_url / execute_code / create_skill / query_user_memory).
    /// Worker emits a paired `tool_result` once the tool returns; UI accumulates
    /// the pair into the per-turn trace shown inline above the bot reply.
    case toolCall(name: String, input: String?)
    case toolResult(name: String, summary: String?, error: String?)
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
         session: URLSession = .shared) {
        self.workerURL = workerURL
        self.session = session
    }

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
                    guard (200..<300).contains(http.statusCode) else {
                        // Read up to ~2KB of error body for diagnosis.
                        var errBytes: [UInt8] = []
                        for try await b in bytes {
                            errBytes.append(b)
                            if errBytes.count >= 2048 { break }
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
        case .http(let s, let body): return "HTTP \(s): \(body.prefix(200))"
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
            content: (json["content"] as? String) ?? ""
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
            if let q = json["query"] as? String, !q.isEmpty { return q }
            if let u = json["url"] as? String, !u.isEmpty { return u }
            if let s = json["skill_name"] as? String, !s.isEmpty { return s }
            if let p = json["code_preview"] as? String, !p.isEmpty { return p }
            if let c = json["chars"] as? Int { return "\(c) chars" }
            return nil
        }()
        return .toolCall(name: name, input: input)
    case "tool_result":
        let name = (json["name"] as? String) ?? ""
        let err = (json["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let summary: String? = {
            if let n = json["count"] as? Int { return "\(n) 条结果" }
            if let t = json["title"] as? String, !t.isEmpty { return t }
            if let s = json["skill_name"] as? String, !s.isEmpty { return s }
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
        return .toolResult(name: name, summary: summary, error: err)
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
