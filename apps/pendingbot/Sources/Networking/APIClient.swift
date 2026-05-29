import Foundation
import Supabase

/// Thin async REST client for Worker writes (POST /v1/messages, /v1/upload, …).
///
/// Reads (lists, conv detail, history) go through supabase-swift directly —
/// there's no GET-side counterpart in this client.
///
/// JWT is fetched fresh from the Supabase auth client per request so we don't
/// hold a stale token across refreshes.
struct APIClient {
    let workerURL: URL
    let session: URLSession

    init(workerURL: URL = HostedConfig.environment.workerURL,
         session: URLSession = .shared) {
        self.workerURL = workerURL
        self.session = session
    }

    // MARK: - Generic verbs

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let req = try await makeRequest(method: "GET", path: path, query: query, body: nil as Empty?)
        return try await send(req)
    }

    func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        let req = try await makeRequest(method: "POST", path: path, query: [], body: body)
        return try await send(req)
    }

    func patch<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        let req = try await makeRequest(method: "PATCH", path: path, query: [], body: body)
        return try await send(req)
    }

    func delete<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let req = try await makeRequest(method: "DELETE", path: path, query: query, body: nil as Empty?)
        return try await send(req)
    }

    func postEmpty<T: Decodable>(_ path: String) async throws -> T {
        let req = try await makeRequest(method: "POST", path: path, query: [], body: nil as Empty?)
        return try await send(req)
    }

    func postVoid(_ path: String) async throws {
        let req = try await makeRequest(method: "POST", path: path, query: [], body: nil as Empty?)
        _ = try await sendRaw(req)
    }

    func postVoid<Body: Encodable>(_ path: String, body: Body) async throws {
        let req = try await makeRequest(method: "POST", path: path, query: [], body: body)
        _ = try await sendRaw(req)
    }

    func deleteVoid(_ path: String) async throws {
        let req = try await makeRequest(method: "DELETE", path: path, query: [], body: nil as Empty?)
        _ = try await sendRaw(req)
    }

    func patchVoid<Body: Encodable>(_ path: String, body: Body) async throws {
        let req = try await makeRequest(method: "PATCH", path: path, query: [], body: body)
        _ = try await sendRaw(req)
    }

    // MARK: - Multipart upload (POST /v1/upload)

    func upload<T: Decodable>(_ path: String, fileData: Data, fileName: String, mime: String,
                              extraFields: [String: String] = [:]) async throws -> T {
        let url = workerURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let boundary = "----PendingBot\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let token = try await currentJwt()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        // String.utf8 → Data is non-failable (unlike .data(using:) which
        // returns Optional from a legacy lossy-conversion API).
        var body = Data()
        for (name, value) in extraFields {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mime)\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body
        return try await send(req)
    }

    // MARK: - Raw download

    /// GET a path and return the raw response body — used for
    /// auth-gated binary payloads like /v1/uploads/:id (file attachments).
    func download(_ path: String) async throws -> Data {
        let req = try await makeRequest(
            method: "GET", path: path, query: [], body: nil as Empty?, accept: "*/*")
        return try await sendRaw(req)
    }

    // MARK: - Internals

    /// Pulls a fresh JWT from supabase-swift. The auth client refreshes
    /// expired tokens transparently here.
    private func currentJwt() async throws -> String {
        try await SupabaseStack.shared.auth.session.accessToken
    }

    private func makeRequest<Body: Encodable>(method: String, path: String, query: [URLQueryItem],
                                              body: Body?, accept: String = "application/json") async throws -> URLRequest {
        var components = URLComponents(url: workerURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        let token = try await currentJwt()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: req)
        try validate(response: response, data: data)
        if data.isEmpty { return try JSONDecoder().decode(T.self, from: Data("{}".utf8)) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decode(underlying: error, body: String(data: data, encoding: .utf8) ?? "<binary>")
        }
    }

    private func sendRaw(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        try validate(response: response, data: data)
        return data
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.notHTTP }
        if !(200..<300).contains(http.statusCode) {
            let bodyMsg = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // Try to parse the typed error envelope produced by jsonError
            // on the worker. Shape: { error: { code, message?, detail? } }.
            // Falls back to raw body when parsing fails (e.g. CDN-emitted
            // error pages, or a route we haven't migrated yet).
            let envelope = (data.flatMap { try? JSONDecoder().decode(ServerErrorEnvelope.self, from: $0) })?.error
            switch http.statusCode {
            case 401: throw APIError.unauthorized
            case 410: throw APIError.gone(message: envelope?.message ?? bodyMsg)
            default:
                throw APIError.http(
                    status: http.statusCode,
                    code: envelope?.code,
                    message: envelope?.message,
                    body: bodyMsg
                )
            }
        }
    }
}

private struct Empty: Encodable {}

/// On-the-wire shape of the worker's typed error envelope. Matches
/// apps/edge/src/lib/http-error.ts:ApiErrorBody. Optional everywhere
/// because we may receive responses from a non-migrated route or from
/// a CDN/edge layer that emits its own body.
struct ServerErrorEnvelope: Decodable {
    let error: ServerErrorPayload?
}

struct ServerErrorPayload: Decodable {
    let code: String?
    let message: String?
    // `detail` deliberately omitted from this Decodable — its shape is
    // free-form per code, and we surface it via the raw JSON body when
    // needed rather than typing every variant.
}

enum APIError: LocalizedError {
    case badURL
    case notHTTP
    case unauthorized
    case gone(message: String)
    /// Non-2xx response. `code` is the typed envelope code when the
    /// worker emitted one; nil for legacy / CDN responses. `message` is
    /// the optional human string from the envelope. `body` is the raw
    /// response body for fallback display and debugging.
    case http(status: Int, code: String?, message: String?, body: String)
    case decode(underlying: Error, body: String)

    /// Stable error code from the typed envelope, when available. iOS
    /// branches on this for things like `quota_exceeded` ->
    /// "go free up space" CTA, `voice_region_unsupported` -> show the
    /// region-supported list, etc.
    var code: String? {
        if case let .http(_, code, _, _) = self { return code }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .badURL:                return "URL 无效"
        case .notHTTP:               return "非 HTTP 响应"
        case .unauthorized:          return "登录已失效，请重新登录"
        case .gone(let m):           return "资源已失效: \(m)"
        case .http(let s, _, let msg, let body):
            // Prefer the envelope message when present — it's the
            // human-readable string the server picked. Fall back to a
            // truncated raw body so legacy responses still surface
            // something useful.
            if let msg, !msg.isEmpty { return msg }
            return "HTTP \(s): \(body.prefix(200))"
        case .decode(_, let body):   return "解析失败: \(body.prefix(200))"
        }
    }
}
