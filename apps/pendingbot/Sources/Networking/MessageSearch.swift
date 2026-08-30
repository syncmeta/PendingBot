import Foundation

enum MessageSearchMatchedField: String, Codable, Hashable {
    case text
    case sender
    case attachment
    case time
}

struct MessageSearchAttachmentMetadata: Codable, Hashable, Identifiable {
    let id: String
    let filename: String?
    let mimeType: String
}

struct MessageSearchResult: Codable, Hashable, Identifiable {
    let conversationId: String
    let conversationTitle: String
    let conversationType: String
    let messageId: String
    let messageSeq: Int
    let text: String
    let senderName: String
    let senderId: String?
    let createdAt: String
    let attachmentMetadata: [MessageSearchAttachmentMetadata]
    let matchedFields: [MessageSearchMatchedField]

    var id: String { "\(conversationId):\(messageId)" }
}

struct MessageSearchResponse: Decodable {
    let results: [MessageSearchResult]
    let nextCursor: String?
}

struct MessageSearchTarget: Hashable {
    let messageId: String
    let messageSeq: Int
}

private struct MessageContextResponse: Decodable {
    let rows: [MessageRow]
}

extension APIClient {
    func searchMessages(
        query: String,
        conversationId: String? = nil,
        after: String? = nil,
        before: String? = nil,
        cursor: String? = nil,
        limit: Int = 50
    ) async throws -> MessageSearchResponse {
        var items = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "scope", value: conversationId == nil ? "global" : "current"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let conversationId {
            items.append(URLQueryItem(name: "conversation_id", value: conversationId))
        }
        if let after { items.append(URLQueryItem(name: "after", value: after)) }
        if let before { items.append(URLQueryItem(name: "before", value: before)) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await get("/v1/messages/search", query: items)
    }

    func messagesAround(
        conversationId: String,
        messageSeq: Int,
        before: Int = 50,
        after: Int = 50
    ) async throws -> [MessageRow] {
        let response: MessageContextResponse = try await get(
            "/v1/conversations/\(conversationId)/messages",
            query: [
                URLQueryItem(name: "around_seq", value: String(messageSeq)),
                URLQueryItem(name: "before", value: String(before)),
                URLQueryItem(name: "after", value: String(after)),
            ]
        )
        return response.rows
    }
}
