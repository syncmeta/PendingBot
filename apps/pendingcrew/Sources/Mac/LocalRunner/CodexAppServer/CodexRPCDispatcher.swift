#if os(macOS)
import Foundation

/// Routes classified messages. Two id spaces kept strictly separate:
///
/// - `pending`  — our outgoing requests awaiting a response, keyed by OUR id
/// - server-initiated requests — handled via callback, keyed by the SERVER's id
///
/// Both sides may independently use id 0 (or any other integer) without
/// collision because they never share a map.
actor CodexRPCDispatcher {
    private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]
    private var onServerRequest: ((Int, String, [String: Any]) -> Void)?
    private var onNotification: ((String, [String: Any]) -> Void)?

    func setServerRequestHandler(_ h: @escaping (Int, String, [String: Any]) -> Void) {
        onServerRequest = h
    }

    func setNotificationHandler(_ h: @escaping (String, [String: Any]) -> Void) {
        onNotification = h
    }

    /// Suspends the caller until the server sends a `.response` with this id.
    func awaitResponse(id: Int) async throws -> Any? {
        try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
        }
    }

    /// Route one classified message. Only `.response` messages touch `pending`;
    /// `.serverRequest` goes to `onServerRequest`; `.notification` goes to `onNotification`.
    func handle(_ msg: CodexRPCMessage) throws {
        switch msg {
        case let .response(id, result, error):
            guard let cont = pending.removeValue(forKey: id) else { return }
            if let error {
                let msg = error["message"] as? String ?? "unknown"
                cont.resume(throwing: CodexRPCError.malformed("server error: \(msg)"))
            } else {
                cont.resume(returning: result)
            }
        case let .serverRequest(id, method, params):
            onServerRequest?(id, method, params)
        case let .notification(method, params):
            onNotification?(method, params)
        }
    }

    /// Fail every pending continuation at once — call when the connection drops.
    func failAll(_ error: Error) {
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
    }
}
#endif
