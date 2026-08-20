import SwiftUI

/// Backing store for the 机组 tab list page. Loads the cross-crew session
/// aggregate + crew titles, exposes them sorted for the card stream, and
/// runs a light foreground poll while the view is on screen.
///
/// Reads only — creation/steer/cancel live on the detail store + the new-task
/// sheet. One store instance per list surface (compact root or wide list
/// column); the detail column has its own store.
@MainActor
final class CrewListStore: ObservableObject {
    @Published private(set) var sessions: [CrewSessionRow] = []
    @Published private(set) var crewTitles: [String: String] = [:]
    @Published private(set) var isLoading = false
    @Published var loadError: String?

    private var api: APIClient?
    private var pollTask: Task<Void, Never>?

    /// The foreground poll cadence — light enough to be cheap, snappy enough
    /// that a runner picking up a queued session shows within ~15s without a
    /// manual pull.
    private static let pollInterval: Duration = .seconds(15)

    func configure(api: APIClient?) {
        self.api = api
    }

    /// Sessions sorted for display: waiting-permission first (amber, needs the
    /// human), then by updated_at desc. `all == false` hides terminal sessions.
    func sorted(all: Bool) -> [CrewSessionRow] {
        let filtered = all
            ? sessions
            : sessions.filter { CrewSessionStatus(raw: $0.status).isActive }
        return filtered.sorted { lhs, rhs in
            let ls = CrewSessionStatus(raw: lhs.status)
            let rs = CrewSessionStatus(raw: rhs.status)
            let lp = ls == .waitingPermission
            let rp = rs == .waitingPermission
            if lp != rp { return lp }
            let ld = CrewDate.parse(lhs.updated_at ?? lhs.created_at) ?? .distantPast
            let rd = CrewDate.parse(rhs.updated_at ?? rhs.created_at) ?? .distantPast
            return ld > rd
        }
    }

    func crewTitle(for conversationId: String) -> String {
        crewTitles[conversationId] ?? "Crew"
    }

    /// Load once (list + titles). Surfaces errors but keeps stale data.
    func load() async {
        guard let api else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let sessionsCall = api.listAllSessions()
            async let crewsCall = api.listCrews()
            let (loadedSessions, crews) = try await (sessionsCall, crewsCall)
            self.sessions = loadedSessions
            self.crewTitles = Dictionary(
                crews.map { ($0.conversation_id, $0.title ?? "Crew") },
                uniquingKeysWith: { first, _ in first }
            )
            self.loadError = nil
        } catch {
            self.loadError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Refresh just the session list (used by the poll — titles change rarely).
    func refreshSessions() async {
        guard let api else { return }
        if let loaded = try? await api.listAllSessions() {
            self.sessions = loaded
        }
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                if Task.isCancelled { return }
                await self?.refreshSessions()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    deinit {
        pollTask?.cancel()
    }
}
