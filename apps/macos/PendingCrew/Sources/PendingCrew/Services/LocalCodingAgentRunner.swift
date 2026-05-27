import Foundation

struct LocalCodingAgentCommand: Equatable {
    let executableURL: URL
    let arguments: [String]
    let workingDirectoryURL: URL?
}

struct LocalCodingAgentProfile: Equatable {
    let executablePath: String
    let arguments: [String]
    let workingDirectoryPath: String?

    static func defaultProfile(for runnerKind: String, workingDirectoryPath: String?) -> LocalCodingAgentProfile? {
        switch runnerKind {
        case RunnerKind.localCodex.rawValue:
            LocalCodingAgentProfile(
                executablePath: "/usr/bin/env",
                arguments: ["codex", "exec", "{taskBrief}"],
                workingDirectoryPath: workingDirectoryPath
            )
        case RunnerKind.localClaudeCode.rawValue:
            LocalCodingAgentProfile(
                executablePath: "/usr/bin/env",
                arguments: ["claude", "-p", "{taskBrief}"],
                workingDirectoryPath: workingDirectoryPath
            )
        case RunnerKind.localOpencode.rawValue:
            LocalCodingAgentProfile(
                executablePath: "/usr/bin/env",
                arguments: ["opencode", "run", "{taskBrief}"],
                workingDirectoryPath: workingDirectoryPath
            )
        case RunnerKind.localKilo.rawValue:
            LocalCodingAgentProfile(
                executablePath: "/usr/bin/env",
                arguments: ["kilo", "{taskBrief}"],
                workingDirectoryPath: workingDirectoryPath
            )
        default:
            nil
        }
    }

    func renderCommand(for session: CrewSession, taskPrompt: String? = nil) -> LocalCodingAgentCommand {
        let prompt = taskPrompt ?? session.taskBrief
        return LocalCodingAgentCommand(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments.map { argument in
                argument
                    .replacingOccurrences(of: "{taskBrief}", with: prompt)
                    .replacingOccurrences(of: "{sessionId}", with: session.id)
                    .replacingOccurrences(of: "{crewConversationId}", with: session.crewConversationId)
            },
            workingDirectoryURL: workingDirectoryPath.flatMap { path in
                path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : URL(fileURLWithPath: path)
            }
        )
    }
}

struct LocalWorkspacePolicy: Equatable {
    let path: String
    var fileManager: FileManager = .default

    var normalizedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canRunLocalAgent: Bool {
        guard !normalizedPath.isEmpty else { return false }
        guard normalizedPath.hasPrefix("/") else { return false }

        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: normalizedPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

enum LocalCodingAgentContextPacket {
    static func render(session: CrewSession, mailbox: [SessionMailboxItem]) -> String {
        var sections: [String] = []
        sections.append("""
        机组 session id: \(session.id)
        机组 conversation id: \(session.crewConversationId)

        任务:
        \(session.taskBrief)
        """)

        let unread = mailbox.filter { $0.status != "archived" }
        if !unread.isEmpty {
            let lines = unread.map { item in
                let sender = item.senderSessionId.map { "session:\($0)" } ?? item.senderKind ?? "机组"
                return "- [\(item.messageKind)] from \(sender): \(item.summary)"
            }.joined(separator: "\n")
            sections.append("""
            本次注入的机组消息:
            \(lines)
            """)
        }

        sections.append("""
        输出规则:
        - 不要把过程日志刷到机组群聊。
        - 需要同步给其他 session 或人类时，发一条简短公告并明确 @ 对象。
        - 最终只输出可执行结论、变更摘要和验证结果。
        """)

        return sections.joined(separator: "\n\n")
    }
}

struct LocalCodingAgentProcessResult: Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
    let duration: TimeInterval
}

enum LocalCodingAgentOutput {
    static func finalSummary(_ result: LocalCodingAgentProcessResult, maxCharacters: Int = 1_000) -> String {
        let source = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? result.standardError
            : result.standardOutput
        let body = truncate(source.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: maxCharacters)
        if body.isEmpty {
            return "本机执行完成，退出码 \(result.exitCode)"
        }
        return "本机执行完成，退出码 \(result.exitCode)\n\(body)"
    }

    private static func truncate(_ value: String, maxCharacters: Int) -> String {
        guard maxCharacters > 3, value.count > maxCharacters else { return value }
        return String(value.prefix(maxCharacters)) + "..."
    }
}

struct LocalCodingAgentProcessRunner {
    var maxCaptureBytes = 64 * 1024

    func run(_ command: LocalCodingAgentCommand) async throws -> LocalCodingAgentProcessResult {
        let startedAt = Date()
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.currentDirectoryURL = command.workingDirectoryURL

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        return LocalCodingAgentProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: decodeLimited(stdout.fileHandleForReading.readDataToEndOfFile()),
            standardError: decodeLimited(stderr.fileHandleForReading.readDataToEndOfFile()),
            duration: Date().timeIntervalSince(startedAt)
        )
    }

    private func decodeLimited(_ data: Data) -> String {
        let limited = data.count > maxCaptureBytes ? data.prefix(maxCaptureBytes) : data[...]
        return String(data: Data(limited), encoding: .utf8) ?? ""
    }
}
