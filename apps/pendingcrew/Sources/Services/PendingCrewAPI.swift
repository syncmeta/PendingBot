import Foundation

/// 精简 PendingBot Edge client。
///
/// scaffold 阶段只包 device-login 的两个端点 — 创建 challenge 和
/// poll 状态。后续 Phase 上的 crew / runner / config 端点等到真正
/// 需要时再加，避免重蹈老 PendingCrew "提前抽象 → 不匹配实际需求"
/// 的覆辙。
struct PendingCrewAPI {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Device-login

    /// `POST /v1/device-login/challenges`。
    ///
    /// `subjectId` 可选 — 不传 = 让 PendingBot 端选 subject（默认本人
    /// user_account）。传了相当于 "我希望以这个 subject 登录"，PendingBot
    /// 用户 approve 时必须用同一个 subject 否则 409 subject_mismatch
    /// （edge 端反欺骗）。
    func createDeviceLoginChallenge(
        subjectId: String? = nil,
        deviceName: String = currentDeviceName(),
        devicePublicKey: String = "scaffold-placeholder-key-0123456789abcdef"
    ) async throws -> DeviceLoginChallenge {
        struct Body: Encodable {
            let appKind: String
            let deviceName: String
            let devicePublicKey: String
            let scopes: [String]
            let subjectId: String?
        }
        let body = Body(
            appKind: "pendingcrew_macos",
            deviceName: deviceName,
            devicePublicKey: devicePublicKey,
            scopes: ["subject:read", "crew:read", "crew:write", "runner:read", "runner:write"],
            subjectId: subjectId
        )
        return try await post(path: "v1/device-login/challenges", body: body)
    }

    /// `GET /v1/device-login/challenges/:id?secret=...`。
    ///
    /// PendingCrew 周期 poll；approve 那一刻这个调用会返回
    /// `deviceGrantToken`（之后再 poll 同一个 challenge 会 410 expired）。
    func pollDeviceLoginChallenge(
        challengeId: String,
        secret: String
    ) async throws -> DeviceLoginPollResponse {
        let url = baseURL
            .appendingPathComponent("v1/device-login/challenges")
            .appendingPathComponent(challengeId)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "secret", value: secret)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        return try await perform(request)
    }

    // MARK: - Internals

    private func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PendingCrewAPIError.invalidResponse
        }
        if !(200..<300).contains(http.statusCode) {
            // edge 用 { error: { code, message?, detail? } } envelope
            // (apps/edge/src/lib/http-error.ts)，直接解出来给上层。
            let envelope = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error
            throw PendingCrewAPIError.http(
                status: http.statusCode,
                code: envelope?.code,
                message: envelope?.message
            )
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

private struct ErrorEnvelope: Decodable {
    let error: ErrorBody

    struct ErrorBody: Decodable {
        let code: String?
        let message: String?
    }
}

enum PendingCrewAPIError: LocalizedError {
    case invalidResponse
    case http(status: Int, code: String?, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回了非 HTTP 响应"
        case let .http(status, code, message):
            let prefix = "HTTP \(status)"
            if let message, !message.isEmpty { return "\(prefix): \(message)" }
            if let code { return "\(prefix) (\(code))" }
            return prefix
        }
    }
}

#if canImport(IOKit)
import IOKit
#endif

private func currentDeviceName() -> String {
    #if os(macOS)
    return Host.current().localizedName ?? "Mac"
    #elseif os(iOS)
    return UIDevice.current.name
    #else
    return "PendingCrew Device"
    #endif
}

#if os(iOS)
import UIKit
#endif
