import XCTest
@testable import PendingBot

final class CallDiagnosticsLogicTests: XCTestCase {
    func testFormattingKeepsUnknownValuesExplicit() {
        XCTAssertEqual(CallDiagnosticsLogic.formatMs(nil), "--")
        XCTAssertEqual(CallDiagnosticsLogic.formatPercent(nil), "--")
        XCTAssertEqual(CallDiagnosticsLogic.formatKbps(nil), "--")
    }

    func testFormattingClampsAudioLevelAndDurations() {
        XCTAssertEqual(CallDiagnosticsLogic.formatAudioLevel(-0.5), "0%")
        XCTAssertEqual(CallDiagnosticsLogic.formatAudioLevel(0.456), "46%")
        XCTAssertEqual(CallDiagnosticsLogic.formatAudioLevel(1.5), "100%")
        XCTAssertEqual(CallDiagnosticsLogic.formatDuration(999), "999ms")
        XCTAssertEqual(CallDiagnosticsLogic.formatDuration(1250), "1.2s")
    }

    func testQualityUsesWorstSignalThreshold() {
        XCTAssertEqual(CallDiagnosticsLogic.quality(rttMs: nil, jitterMs: nil, lossPercent: nil), .unknown)
        XCTAssertEqual(CallDiagnosticsLogic.quality(rttMs: 80, jitterMs: nil, lossPercent: nil), .good)
        XCTAssertEqual(CallDiagnosticsLogic.quality(rttMs: 250, jitterMs: 10, lossPercent: 0), .fair)
        XCTAssertEqual(CallDiagnosticsLogic.quality(rttMs: 80, jitterMs: 80, lossPercent: 0), .poor)
        XCTAssertEqual(CallDiagnosticsLogic.quality(rttMs: 80, jitterMs: 10, lossPercent: 8), .poor)
    }

    func testNetworkBottleneckPrioritizesLossBeforeRateSymptoms() {
        let text = CallDiagnosticsLogic.networkBottleneck(
            rttMs: 700,
            jitterMs: 90,
            lossPercent: 9,
            sentKbps: 1,
            receivedKbps: 1,
            availableOutgoingKbps: 10,
            localSpeaking: true,
        )
        XCTAssertEqual(text, "丢包偏高，优先检查当前网络或中间链路。")
    }

    func testNetworkBottleneckFlagsQuietUplinkOnlyWhenLocalIsSpeaking() {
        XCTAssertEqual(
            CallDiagnosticsLogic.networkBottleneck(
                rttMs: 80,
                jitterMs: 10,
                lossPercent: 0,
                sentKbps: 4,
                receivedKbps: 20,
                availableOutgoingKbps: 100,
                localSpeaking: true,
            ),
            "你在说话但上行音频码率偏低，优先看麦克风权限、采集或上行网络。",
        )
        XCTAssertEqual(
            CallDiagnosticsLogic.networkBottleneck(
                rttMs: 80,
                jitterMs: 10,
                lossPercent: 0,
                sentKbps: 4,
                receivedKbps: 20,
                availableOutgoingKbps: 100,
                localSpeaking: false,
            ),
            "当前未看到明显瓶颈。",
        )
    }

    func testMediaBottleneckIgnoresHumanParticipantsAndUsesBotPriority() {
        let human = participant(kind: .human, displayName: "Alice", underruns: 4, maxGapMs: 900, droppedOutputMs: 1200, playoutDepthMs: 1400, speaking: true)
        let bot = participant(kind: .bot, displayName: "模型", underruns: 1, maxGapMs: 900, droppedOutputMs: 1200, playoutDepthMs: 1400, speaking: true)
        XCTAssertEqual(
            CallDiagnosticsLogic.mediaBottleneck([human, bot]),
            "模型 的容器播放缓冲发生欠载，优先看语音模型输出或 CF container 调度。",
        )
    }

    func testInputQuietTextIncludesDroppedOutputOnlyWhenPositive() {
        XCTAssertEqual(
            CallDiagnosticsLogic.inputQuietText(inputFrames: 12, quietFrames: 3, dropped: nil),
            "入 12 静 3",
        )
        XCTAssertEqual(
            CallDiagnosticsLogic.inputQuietText(inputFrames: 12, quietFrames: 3, dropped: 1500),
            "入 12 静 3 丢 1.5s",
        )
    }

    private func participant(
        kind: CallParticipantDiagnostic.Kind,
        displayName: String,
        underruns: Int? = nil,
        maxGapMs: Int? = nil,
        droppedOutputMs: Int? = nil,
        playoutDepthMs: Int? = nil,
        speaking: Bool = false,
    ) -> CallParticipantDiagnostic {
        CallParticipantDiagnostic(
            kind: kind,
            id: displayName,
            displayName: displayName,
            speaking: speaking,
            audioLevel: speaking ? 1 : 0,
            playoutDepthMs: playoutDepthMs,
            underruns: underruns,
            maxGapMs: maxGapMs,
            droppedOutputMs: droppedOutputMs,
            inputLevel: nil,
            inputFrames: nil,
            quietFrames: nil,
            connected: nil,
        )
    }
}
