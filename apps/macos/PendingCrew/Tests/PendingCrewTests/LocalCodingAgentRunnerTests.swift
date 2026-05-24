import XCTest
@testable import PendingCrew

final class LocalCodingAgentRunnerTests: XCTestCase {
    func testDefaultCodexProfileRendersSessionCommand() throws {
        let session = CrewSession(
            id: "session-1",
            crewConversationId: "crew-1",
            responsibleSubjectId: "subject-1",
            runnerKind: "local_codex",
            status: "running",
            taskBrief: "整理 Crew 地基",
            progressSummary: nil,
            createdAt: "2026-05-24T00:00:00Z",
            startedAt: nil,
            finishedAt: nil
        )

        let profile = try XCTUnwrap(LocalCodingAgentProfile.defaultProfile(for: session.runnerKind, workingDirectoryPath: "/tmp/work"))
        let command = profile.renderCommand(for: session)

        XCTAssertEqual(command.executableURL.path, "/usr/bin/env")
        XCTAssertEqual(command.arguments, ["codex", "exec", "整理 Crew 地基"])
        XCTAssertEqual(command.workingDirectoryURL?.path, "/tmp/work")
    }

    func testCloudSandboxHasNoLocalProfile() {
        XCTAssertNil(LocalCodingAgentProfile.defaultProfile(for: "cloud_sandbox", workingDirectoryPath: "/tmp/work"))
    }

    func testOutputSummaryPrefersStdoutAndTruncates() {
        let result = LocalCodingAgentProcessResult(
            exitCode: 0,
            standardOutput: String(repeating: "a", count: 120),
            standardError: "stderr",
            duration: 1.25
        )

        let summary = LocalCodingAgentOutput.finalSummary(result, maxCharacters: 40)

        XCTAssertTrue(summary.hasPrefix("本机执行完成"))
        XCTAssertTrue(summary.contains("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        XCTAssertTrue(summary.hasSuffix("..."))
    }
}
