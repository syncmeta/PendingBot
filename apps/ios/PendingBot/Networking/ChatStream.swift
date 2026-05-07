import Foundation

/// Server-sent event from POST /v1/messages. Mirrors the events Worker
/// emits in `runChatTurn` — keep names in lockstep with apps/edge/src/lib/bot-reply.ts.
enum ChatEvent: Sendable {
    case typing(state: String)
    case token(delta: String)
    case bubble(id: String, index: Int, groupId: String, content: String)
    case done(groupId: String, totalContent: String)
    case interrupted(groupId: String, totalContent: String)
    /// Bot used the [SILENT] control token — nothing to show, the turn
    /// produced no message. UI should leave the conversation as-is.
    case silent(groupId: String)
    /// Bot invoked a tool (search_web / read_url / execute_code / create_skill).
    /// Worker emits a paired `tool_result` once the tool returns; UI accumulates
    /// the pair into the per-turn trace shown inline above the bot reply.
    case toolCall(name: String, input: String?)
    case toolResult(name: String, summary: String?, error: String?)
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
    func send(body: [String: Any]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: workerURL.appendingPathComponent("v1/messages"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
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
                    var pendingEventName = ""
                    var pendingDataLines: [String] = []

                    func flush() {
                        guard !pendingEventName.isEmpty else { return }
                        let dataJoined = pendingDataLines.joined(separator: "\n")
                        let evt = decode(eventName: pendingEventName, dataJSON: dataJoined)
                        continuation.yield(evt)
                        pendingEventName = ""
                        pendingDataLines.removeAll()
                    }

                    for try await line in bytes.lines {
                        if line.isEmpty {
                            flush()
                            continue
                        }
                        if line.hasPrefix("event:") {
                            pendingEventName = line.dropFirst("event:".count)
                                .trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            // Spec: "data:" with optional space; we keep the
                            // trailing whitespace-trimmed payload.
                            let payload = line.dropFirst("data:".count)
                                .trimmingCharacters(in: .whitespaces)
                            pendingDataLines.append(String(payload))
                        }
                        // (id:/retry:/comment lines are ignored.)
                    }
                    // Server may close without a trailing blank line.
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
            if let exit = json["exit_code"] as? Int { return "exit \(exit)" }
            return nil
        }()
        return .toolResult(name: name, summary: summary, error: err)
    case "error":
        return .error(message: (json["message"] as? String) ?? "")
    default:
        return .unknown(name: eventName, raw: dataJSON)
    }
}
