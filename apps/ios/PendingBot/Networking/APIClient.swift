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

    func deleteVoid(_ path: String) async throws {
        let req = try await makeRequest(method: "DELETE", path: path, query: [], body: nil as Empty?)
        _ = try await sendRaw(req)
    }

    // MARK: - SSE shim (legacy)
    //
    // Old Discuss/Portrait/Surf views opened a streaming POST and parsed SSE
    // chunks. The new architecture pushes those events via Supabase Realtime
    // (postgres_changes on log messages / surf_runs / review_runs). Keep this
    // shim so callers compile during the cutover; replacing the call sites
    // is part of B9.3 (Realtime subscription manager).
    func streamPost<Body: Encodable>(_ path: String, body: Body) async throws -> URLSession.AsyncBytes {
        _ = path; _ = body
        throw APIError.http(status: 501, body: "streamPost replaced by Realtime channels (B9.3)")
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

        var body = Data()
        for (name, value) in extraFields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        return try await send(req)
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
            switch http.statusCode {
            case 401: throw APIError.unauthorized
            case 410: throw APIError.gone(message: bodyMsg)
            default:  throw APIError.http(status: http.statusCode, body: bodyMsg)
            }
        }
    }
}

private struct Empty: Encodable {}

enum APIError: LocalizedError {
    case badURL
    case notHTTP
    case unauthorized
    case gone(message: String)
    case http(status: Int, body: String)
    case decode(underlying: Error, body: String)

    var errorDescription: String? {
        switch self {
        case .badURL:                return "URL 无效"
        case .notHTTP:               return "非 HTTP 响应"
        case .unauthorized:          return "登录已失效，请重新登录"
        case .gone(let m):           return "资源已失效: \(m)"
        case .http(let s, let body): return "HTTP \(s): \(body.prefix(200))"
        case .decode(_, let body):   return "解析失败: \(body.prefix(200))"
        }
    }
}
