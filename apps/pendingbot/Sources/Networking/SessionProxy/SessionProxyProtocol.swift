// VENDORED from apps/pendingcrew/Sources/Mac/LocalRunner/SessionProxyProtocol.swift
// @ 4087018333705de981bf6227593c8c5d04115734
//
// Viewer-side adaptation for PendingBot (iOS + macOS remote control). Changes
// vs the PendingCrew runner original:
//   * dropped the `#if os(macOS)` guard — PendingBot is a dual-platform viewer
//     and this codec is pure Foundation, so it compiles everywhere.
//   * added `PermissionRequestFrame` — the viewer-facing decode of the runner's
//     `permission.request` fan-out (the runner original never decodes it; on
//     that side it degrades to `.unknown`). PendingBot needs it to re-pull the
//     permission-requests list when the runner raises one live.
// Everything else is a verbatim copy so the wire shape stays a single source
// of truth. Do NOT diverge the frame shapes from the .ts protocol.
import Foundation

/// Swift mirror of the SessionProxyDO wire protocol
/// (`apps/edge/src/lib/session-proxy-protocol.ts`, spec v2 §8.2 + §9.6).

public enum ProxyRole: String, Sendable {
    case viewer
    case runner
}

// MARK: - JSONValue (minimal, Equatable free-form JSON)

/// A small Equatable JSON tree, used for the protocol's free-form `payload`
/// fields so inbound frames stay testable by value. Numbers normalize to
/// `Double` (JSON has one number type); integer payloads round-trip exactly
/// within 2^53.
public enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    /// Wrap a JSONSerialization-produced value. Returns nil for types that
    /// can't appear in JSON.
    public init?(_ any: Any) {
        switch any {
        case let s as String: self = .string(s)
        case let b as Bool where Self.isBoolNSNumber(any): self = .bool(b)
        case let n as NSNumber: self = .number(n.doubleValue)
        case is NSNull: self = .null
        case let arr as [Any]:
            self = .array(arr.compactMap(JSONValue.init))
        case let obj as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (k, v) in obj {
                guard let jv = JSONValue(v) else { return nil }
                out[k] = jv
            }
            self = .object(out)
        default:
            return nil
        }
    }

    /// Back to a JSONSerialization-compatible value (for encoding).
    public var anyValue: Any {
        switch self {
        case let .string(s): return s
        case let .number(n): return n
        case let .bool(b): return b
        case .null: return NSNull()
        case let .array(a): return a.map(\.anyValue)
        case let .object(o): return o.mapValues(\.anyValue)
        }
    }

    // `NSNumber` boxes Bool and numerics identically; distinguish a real
    // JSON bool by its CFTypeID so `true` doesn't decode as `1.0`.
    private static func isBoolNSNumber(_ any: Any) -> Bool {
        (any as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    }
}

// MARK: - SessionStateSnapshot (viewer ← runner, inbound decode)

/// The viewer-side decode of a runner's `session.state` fan-out. The runner
/// publishes `{status, eventCount, lastEvent?}` and the DO broadcasts it
/// verbatim inside `{type:"session.state", state:{…}}`.
public struct SessionStateSnapshot: Equatable, Sendable {
    public var status: String
    public var eventCount: Int
    public var lastEvent: String?

    public init(status: String, eventCount: Int, lastEvent: String?) {
        self.status = status
        self.eventCount = eventCount
        self.lastEvent = lastEvent
    }

    /// Parse one inbound `session.state` frame. Returns nil for any other frame
    /// type / malformed JSON so a caller can cheaply try this on `.unknown`
    /// frames without a separate type check.
    public static func parse(_ raw: String) -> SessionStateSnapshot? {
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

// MARK: - PermissionRequestFrame (viewer ← runner, inbound decode)

/// The viewer-side decode of a runner's `permission.request` fan-out. The wire
/// shape (`{type:"permission.request", request:{id?, action, payload?,
/// riskLevel?}}`) mirrors the `.ts` `PermissionRequestMsg`. PendingBot uses this
/// only as a *trigger* — the frame may carry no `id`, so the viewer re-pulls the
/// authoritative permission-requests list over HTTP rather than rendering the
/// frame directly.
public struct PermissionRequestFrame: Equatable, Sendable {
    public var id: String?
    public var action: String
    public var riskLevel: String?

    public init(id: String?, action: String, riskLevel: String?) {
        self.id = id
        self.action = action
        self.riskLevel = riskLevel
    }

    public static func parse(_ raw: String) -> PermissionRequestFrame? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "permission.request",
              let request = obj["request"] as? [String: Any] else {
            return nil
        }
        let action = (request["action"] as? String) ?? ""
        return PermissionRequestFrame(
            id: request["id"] as? String,
            action: action,
            riskLevel: request["riskLevel"] as? String
        )
    }
}

// MARK: - Outbound (viewer → DO)

/// A frame a viewer sends up to the DO. The DO routes `session.command` to the
/// runner (assigning a `commandId` if absent) and persists it; it routes
/// `permission.decision` to the runner + back to other viewers. Shapes match the
/// `.ts` `SessionCommandMsg` / `PermissionDecisionMsg`.
public enum SessionProxyViewerOutbound: Sendable {
    /// First frame after the socket opens. Role must match what the HTTP route
    /// authorized; `token` is a defence-in-depth echo.
    case subscribe(role: ProxyRole, token: String?)
    /// Send a command to the session's runner (e.g. `cancel`, `send_prompt`).
    case command(kind: String, payload: [String: JSONValue]?)
    /// Approve/reject a pending permission request raised by the runner.
    case permissionDecision(requestId: String, decision: String)

    public func wireDict() -> [String: Any] {
        switch self {
        case let .subscribe(role, token):
            var d: [String: Any] = ["type": "subscribe", "role": role.rawValue]
            if let token { d["token"] = token }
            return d
        case let .command(kind, payload):
            var cmd: [String: Any] = ["kind": kind]
            if let payload { cmd["payload"] = JSONValue.object(payload).anyValue }
            return ["type": "session.command", "command": cmd]
        case let .permissionDecision(requestId, decision):
            return ["type": "permission.decision", "requestId": requestId, "decision": decision]
        }
    }

    public func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: wireDict(), options: [.sortedKeys])
    }
}

// MARK: - Inbound (DO → viewer)

/// A frame the viewer receives from the DO. Only viewer-relevant variants are
/// modeled; runner-only frames degrade to `.unknown`.
public enum SessionProxyViewerInbound: Equatable, Sendable {
    /// Ack of subscribe.
    case subscribed(sessionId: String, role: ProxyRole)
    /// Live state fan-out from the runner.
    case state(SessionStateSnapshot)
    /// A permission request raised by the runner (trigger to re-pull the list).
    case permissionRequest(PermissionRequestFrame)
    /// A protocol/error frame from the DO.
    case error(code: String, message: String)
    /// Valid JSON we don't act on, or anything unclassifiable.
    case unknown(String)

    /// Parse one inbound frame. Never throws — bad frames degrade to `.unknown`.
    public static func parse(_ raw: String) -> SessionProxyViewerInbound {
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
        case "session.state":
            if let snapshot = SessionStateSnapshot.parse(raw) { return .state(snapshot) }
            return .unknown(raw)
        case "permission.request":
            if let frame = PermissionRequestFrame.parse(raw) { return .permissionRequest(frame) }
            return .unknown(raw)
        case "error":
            return .error(code: (obj["code"] as? String) ?? "",
                          message: (obj["message"] as? String) ?? "")
        default:
            // session.command / session.command.ack / permission.decision are
            // runner-facing; a viewer ignores them.
            return .unknown(raw)
        }
    }
}
