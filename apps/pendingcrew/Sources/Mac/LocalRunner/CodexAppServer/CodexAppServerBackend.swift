#if os(macOS)
import Foundation
import Combine

/// codex session over app-server. Conforms to SessionBackend so CrewSessionRun
/// treats it like the terminal backend. Output goes to `transcript` (rendered by
/// CodexTranscriptView). `send` runs a turn; `interrupt` cancels the active turn;
/// `stop` ends the process. Per-turn whiteboard + approvals are injected via the
/// providers supplied by the runner.
@MainActor
final class CodexAppServerBackend: ObservableObject, SessionBackend {
    let kind: LocalCodingAgentKind = .codex
    let transcript = CodexTranscript()
    @Published private(set) var status: SessionStatus = .running
    var statusPublisher: Published<SessionStatus>.Publisher { $status }
    /// app-server 有真 turn 生命周期：turn/started→activeTurnId 置位，turn/completed→清空。
    var isBusy: Bool { activeTurnId != nil }

    private let connection: CodexAppServerConnection
    private let cwd: String
    private let model: String?
    private let developerInstructions: String?
    private let mcpServers: [String: Any]?
    /// Pulls the unread-whiteboard string to inject as a leading text input each turn.
    private let whiteboardProvider: () -> String?
    /// Routes a codex approval request into the existing approval UI; returns the
    /// decision string ("accept"/"decline"/…) once the human answers.
    private let approvalProvider: (_ summary: String, _ decisions: [String]) async -> String

    private var threadId: String?
    private var activeTurnId: String?

    init(executable: String, argv: [String], cwd: String, env: [String: String],
         model: String?, developerInstructions: String?, mcpServers: [String: Any]?,
         whiteboardProvider: @escaping () -> String?,
         approvalProvider: @escaping (_ summary: String, _ decisions: [String]) async -> String) {
        self.connection = CodexAppServerConnection(executable: executable, argv: argv, cwd: cwd, env: env)
        self.cwd = cwd
        self.model = model
        self.developerInstructions = developerInstructions
        self.mcpServers = mcpServers
        self.whiteboardProvider = whiteboardProvider
        self.approvalProvider = approvalProvider
    }

    /// Boot: handshake → thread/start → send the first turn (if any).
    func boot(initialPrompt: String?) {
        Task {
            do {
                try await connection.start(
                    onServerRequest: { [weak self] id, method, params in
                        Task { await self?.handleServerRequest(id: id, method: method, params: params) }
                    },
                    onNotification: { [weak self] method, params in
                        Task { @MainActor in
                            self?.transcript.apply(method: method, params: params)
                            self?.trackTurn(method: method, params: params)
                        }
                    },
                    onTerminate: { [weak self] code in
                        Task { @MainActor in
                            guard let self, self.status == .running else { return }   // stop() already set .exited; don't clobber
                            self.status = .exited(code)
                        }
                    })
                let result = try await connection.request(
                    method: "thread/start",
                    params: CodexProtocol.threadStartParams(
                        cwd: cwd, model: model, developerInstructions: developerInstructions,
                        mcpServers: mcpServers)) as? [String: Any]
                self.threadId = (result?["thread"] as? [String: Any])?["id"] as? String
                if let p = initialPrompt, !p.isEmpty { self.send(p) }
            } catch {
                self.status = .exited(1)
            }
        }
    }

    func send(_ text: String) {
        guard let threadId else { return }
        let wb = whiteboardProvider()
        Task {
            _ = try? await connection.request(
                method: "turn/start",
                params: CodexProtocol.turnStartParams(threadId: threadId, text: text, whiteboard: wb))
        }
    }

    func interrupt() {
        guard let threadId, let turnId = activeTurnId else { return }
        Task {
            _ = try? await connection.request(
                method: "turn/interrupt",
                params: CodexProtocol.turnInterruptParams(threadId: threadId, turnId: turnId))
        }
    }

    func stop() {
        guard status == .running else { return }
        status = .exited(nil)
        Task { await connection.terminate() }
    }

    private func trackTurn(method: String, params: [String: Any]) {
        if method == "turn/started" { activeTurnId = (params["turn"] as? [String: Any])?["id"] as? String }
        if method == "turn/completed" { activeTurnId = nil }
    }

    private func handleServerRequest(id: Int, method: String, params: [String: Any]) async {
        guard method.hasSuffix("requestApproval") else { return }
        let summary = (params["command"] as? String) ?? (params["reason"] as? String) ?? method
        let decisions = (params["availableDecisions"] as? [String]) ?? ["accept", "decline"]
        let decision = await approvalProvider(summary, decisions)
        try? await connection.respond(serverId: id, result: ["decision": decision])
    }
}
#endif
