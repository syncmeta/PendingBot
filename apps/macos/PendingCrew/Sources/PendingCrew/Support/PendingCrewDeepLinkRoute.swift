import Foundation

struct PendingCrewDeepLinkRoute: Equatable {
    let crewId: String
    let sessionId: String?

    init?(url: URL) {
        guard url.scheme == "pendingcrew" else { return nil }

        var parts: [String] = []
        if let host = url.host(percentEncoded: false), !host.isEmpty {
            parts.append(host)
        }
        parts.append(contentsOf: url.pathComponents.filter { $0 != "/" })

        guard parts.count >= 2, parts[0] == "crew" else { return nil }
        crewId = parts[1]

        if parts.count >= 4, parts[2] == "session" {
            sessionId = parts[3]
        } else {
            sessionId = nil
        }
    }
}
