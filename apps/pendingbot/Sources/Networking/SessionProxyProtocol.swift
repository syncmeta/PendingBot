import Foundation

/// Swift mirror of the SessionProxyDO wire protocol
/// (`apps/edge/src/lib/session-proxy-protocol.ts`, spec v2 §8.2 + §9.6) —
/// **the viewer subset**.
///
/// This is the live (WebSocket) half of T4.5 cross-device control on the
/// PendingBot phone/iPad side. A viewer subscribes to a session's proxy DO,
/// receives the runner's real-time `session.state` fan-out, and sends
/// `session.command` (e.g. `cancel`) back. The runner side (publishing state,
/// raising permission requests, building `SessionState` from a `RunnerEvent`
/// transcript) lives in PendingCrew Mac and is intentionally NOT mirrored here
/// — iOS PendingBot is never a runner.
///
/// Frames are encoded/decoded with `JSONSerialization` rather than Codable
/// because the protocol's `payload` / `state` fields are free-form
/// `Record<string, unknown>` on the wire. The two apps don't share a Swift
/// module, so this is a deliberate hand-copy of the stable protocol — the same
/// pattern the HTTP `CrewSessionLogEvent` models follow.

enum ProxyRole: String, Sendable {
    case viewer
    case runner
}

// MARK: - JSONValue (minimal, Equatable free-form JSON)

/// A small Equatable JSON tree for the protocol's free-form `payload` fields,
/// so a command's payload stays type-safe to build. Numbers normalize to
/// `Double` (JSON has one number type); integer payloads round-trip exactly
/// within 2^53.
enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    /// Back to a JSONSerialization-compatible value (for encoding).
    var anyValue: Any {
        switch self {
        case let .string(s): return s
        case let .number(n): return n
        case let .bool(b): return b
        case .null: return NSNull()
        case let .array(a): return a.map(\.anyValue)
        case let .object(o): return o.mapValues(\.anyValue)
        }
    }
}

// MARK: - SessionStateSnapshot (viewer ← runner, inbound decode)

/// The viewer-side decode of a runner's `session.state` fan-out. The runner
/// publishes `{status, eventCount, lastEvent?}` and the DO broadcasts it
/// verbatim inside `{type:"session.state", state:{…}}`. Sendable so the proxy
/// client can hand it across the actor boundary to the SwiftUI viewer.
struct SessionStateSnapshot: Equatable, Sendable {
    var status: String
    var eventCount: Int
    var lastEvent: String?

    /// Parse one inbound `session.state` frame. Returns nil for any other frame
    /// type / malformed JSON so the client can cheaply try this on `.unknown`
    /// frames without a separate type check. `eventCount` tolerates the JSON
    /// number being a double.
    static func parse(_ raw: String) -> SessionStateSnapshot? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "session.state",
              let state = obj["state"] as? [String: Any] else {
            return nil
        }
        let status = (state["status"] as? String) ?? ""
        let count = (state["eventCount"] as? NSNumber)?.intValue ?? 0
        let last = state["lastEvent"] as? String
        return SessionStateSnapshot(status: status, eventCount: count, lastEvent: last)
    }
}

// MARK: - Outbound (viewer → DO)

/// A frame a viewer sends up to the DO. The DO routes `session.command` to the
/// session's runner (assigning a `commandId` if absent) and persists it to the
/// durable mailbox; it routes `permission.decision` to the runner + back to
/// other viewers. Shapes match the TS `SessionCommandMsg` / `PermissionDecisionMsg`.
enum SessionProxyViewerOutbound: Sendable {
    /// Send a command to the session's runner (e.g. `cancel`, `send_prompt`).
    /// `payload` is free-form; the DO assigns the `commandId`.
    case command(kind: String, payload: [String: JSONValue]?)
    /// Approve/reject a pending permission request raised by the runner.
    case permissionDecision(requestId: String, decision: String)

    func wireDict() -> [String: Any] {
        switch self {
        case let .command(kind, payload):
            var cmd: [String: Any] = ["kind": kind]
            if let payload { cmd["payload"] = JSONValue.object(payload).anyValue }
            return ["type": "session.command", "command": cmd]
        case let .permissionDecision(requestId, decision):
            return ["type": "permission.decision", "requestId": requestId, "decision": decision]
        }
    }

    func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: wireDict(), options: [.sortedKeys])
    }
}

// MARK: - Inbound (DO → viewer)

/// A frame a viewer receives from the DO. Only the viewer-relevant variants are
/// modeled: the `subscribed` ack, protocol errors, and everything else as
/// `.unknown` (the live `session.state` fan-out lands here and is decoded
/// separately via `SessionStateSnapshot.parse` — keeping this enum free of the
/// free-form state shape). Runner-facing frames (`session.command` /
/// `permission.decision`) never reach a viewer.
enum SessionProxyInbound: Equatable, Sendable {
    case subscribed(sessionId: String, role: ProxyRole)
    case error(code: String, message: String)
    /// Valid JSON we don't classify (incl. `session.state`). Carries the raw
    /// frame so the client can try `SessionStateSnapshot.parse` on it.
    case unknown(String)

    /// Parse one inbound frame. Never throws — bad frames degrade to `.unknown`
    /// so the receive loop can't be crashed by garbage.
    static func parse(_ raw: String) -> SessionProxyInbound {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return .unknown(raw)
        }
        switch type {
        case "subscribed":
            let sid = (obj["sessionId"] as? String) ?? ""
            let role = (obj["role"] as? String).flatMap(ProxyRole.init) ?? .viewer
            return .subscribed(sessionId: sid, role: role)
        case "error":
            return .error(code: (obj["code"] as? String) ?? "",
                          message: (obj["message"] as? String) ?? "")
        default:
            // session.state / permission.request are decoded by the client off
            // the raw frame; anything else is genuinely unclassified.
            return .unknown(raw)
        }
    }
}
