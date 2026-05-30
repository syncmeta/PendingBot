#if os(iOS)
import Foundation

enum CallDiagnosticsLogic {
    static func formatMs(_ value: Int?) -> String {
        guard let value else { return "--" }
        return "\(value)ms"
    }

    static func formatPercent(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f%%", value)
    }

    static func formatKbps(_ value: Int?) -> String {
        guard let value else { return "--" }
        return "\(value)k"
    }

    static func formatAudioLevel(_ value: Double) -> String {
        let percent = Int((min(max(value, 0), 1) * 100).rounded())
        return "\(percent)%"
    }

    static func formatDuration(_ ms: Int) -> String {
        if ms >= 1000 {
            return String(format: "%.1fs", Double(ms) / 1000)
        }
        return "\(ms)ms"
    }

    static func inputQuietText(inputFrames: Int, quietFrames: Int, dropped: Int?) -> String {
        var text = "入 \(inputFrames) 静 \(quietFrames)"
        if let dropped, dropped > 0 {
            text += " 丢 \(formatDuration(dropped))"
        }
        return text
    }

    static func quality(
        rttMs: Int?,
        jitterMs: Int?,
        lossPercent: Double?,
    ) -> CallDiagnosticsSnapshot.Quality {
        if (lossPercent ?? 0) >= 8 || (jitterMs ?? 0) >= 80 || (rttMs ?? 0) >= 600 {
            return .poor
        }
        if (lossPercent ?? 0) >= 3 || (jitterMs ?? 0) >= 40 || (rttMs ?? 0) >= 250 {
            return .fair
        }
        if rttMs != nil || jitterMs != nil || lossPercent != nil {
            return .good
        }
        return .unknown
    }

    static func networkBottleneck(
        rttMs: Int?,
        jitterMs: Int?,
        lossPercent: Double?,
        sentKbps: Int?,
        receivedKbps: Int?,
        availableOutgoingKbps: Int?,
        localSpeaking: Bool,
    ) -> String {
        if let lossPercent, lossPercent >= 8 {
            return "丢包偏高，优先检查当前网络或中间链路。"
        }
        if let jitterMs, jitterMs >= 80 {
            return "抖动偏高，音频卡顿多半来自网络不稳定。"
        }
        if let rttMs, rttMs >= 600 {
            return "延迟很高，瓶颈在你到语音服务之间的网络路径。"
        }
        if localSpeaking, let sentKbps, sentKbps < 8 {
            return "你在说话但上行音频码率偏低，优先看麦克风权限、采集或上行网络。"
        }
        if let availableOutgoingKbps, availableOutgoingKbps < 30 {
            return "可用上行带宽偏低，我这边上行可能是瓶颈。"
        }
        if let receivedKbps, receivedKbps < 8 {
            return "下行音频很少，可能是对方/模型没出声，也可能是下行链路问题。"
        }
        return "当前未看到明显瓶颈。"
    }

    static func mediaBottleneck(_ participants: [CallParticipantDiagnostic]) -> String? {
        for p in participants where p.kind == .bot {
            if (p.underruns ?? 0) > 0 {
                return "\(p.displayName) 的容器播放缓冲发生欠载，优先看语音模型输出或 CF container 调度。"
            }
            if (p.maxGapMs ?? 0) >= 700 {
                return "\(p.displayName) 的模型音频增量间隔偏大，瓶颈更像语音模型输出。"
            }
            if let dropped = p.droppedOutputMs, dropped > 0 {
                return "\(p.displayName) 的机器人输出太长，已丢弃 \(dropped)ms 旧音频来降低延迟。"
            }
            if let depth = p.playoutDepthMs, depth >= 1200 {
                return "\(p.displayName) 的播放缓冲积压 \(depth)ms，会表现为机器人出声延迟；这不是本机网络丢包。"
            }
            if let depth = p.playoutDepthMs, depth < 80, p.speaking {
                return "\(p.displayName) 的容器播放缓冲偏浅，可能出现机器人声音卡顿。"
            }
        }
        return nil
    }
}
#endif
