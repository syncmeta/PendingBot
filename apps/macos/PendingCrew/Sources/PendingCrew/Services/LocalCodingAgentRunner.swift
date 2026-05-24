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

    func renderCommand(for session: CrewSession) -> LocalCodingAgentCommand {
        LocalCodingAgentCommand(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments.map { argument in
                argument
                    .replacingOccurrences(of: "{taskBrief}", with: session.taskBrief)
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
