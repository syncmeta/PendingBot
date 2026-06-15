#if os(macOS)
import Foundation

/// Observable transcript built from codex streaming notifications. v1 renders on
/// `item/completed` (authoritative final per item); deltas/item-started are opted out.
@MainActor
final class CodexTranscript: ObservableObject {
    @Published private(set) var items: [CodexThreadItem] = []
    @Published private(set) var turnActive = false
    @Published private(set) var activeTurnId: String?

    func apply(method: String, params: [String: Any]) {
        switch method {
        case "turn/started":
            activeTurnId = (params["turn"] as? [String: Any])?["id"] as? String
            turnActive = true
        case "turn/completed":
            turnActive = false; activeTurnId = nil
        case "item/completed":
            guard let itemObj = params["item"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: itemObj),
                  let item = try? JSONDecoder().decode(CodexThreadItem.self, from: data) else { return }
            if let idx = items.firstIndex(where: { $0.id == item.id }) { items[idx] = item }
            else { items.append(item) }
        default:
            break   // item/started, deltas, token usage — ignored in v1
        }
    }
}
#endif
