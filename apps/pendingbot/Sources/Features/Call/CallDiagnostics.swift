#if os(iOS)
import SwiftUI

#if canImport(WebRTC)
import WebRTC
#endif

struct CallParticipantDiagnostic: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable {
        case human
        case bot
        case local
        case remote
    }

    let kind: Kind
    let id: String
    let displayName: String
    let speaking: Bool
    let audioLevel: Double
    let playoutDepthMs: Int?
    let underruns: Int?
    let maxGapMs: Int?
    let droppedOutputMs: Int?
    let inputLevel: Double?
    let inputFrames: Int?
    let quietFrames: Int?
    let connected: Bool?

    var identityKey: String { "\(kind.rawValue):\(id)" }
}

struct CallDiagnosticsSnapshot: Sendable, Equatable {
    enum Quality: String, Sendable {
        case unknown
        case excellent
        case good
        case fair
        case poor

        var title: String {
            switch self {
            case .unknown: return "未知"
            case .excellent: return "优秀"
            case .good: return "良好"
            case .fair: return "一般"
            case .poor: return "较差"
            }
        }

        var tint: Color {
            switch self {
            case .unknown: return .secondary
            case .excellent, .good: return .green
            case .fair: return .orange
            case .poor: return .red
            }
        }
    }

    var updatedAt: Date?
    var transport: String = "未知"
    var connectionState: String = "未连接"
    var route: String?
    var quality: Quality = .unknown
    var rttMs: Int?
    var jitterMs: Int?
    var packetLossPercent: Double?
    var sentKbps: Int?
    var receivedKbps: Int?
    var availableOutgoingKbps: Int?
    var localAudioLevel: Double = 0
    var remoteAudioLevel: Double = 0
    var localSpeaking: Bool = false
    var remoteSpeaking: Bool = false
    var activeSpeaker: String?
    var bottleneck: String = "等待数据"
    var participants: [CallParticipantDiagnostic] = []
}

// `GroupMediaDiagnostics` moved to the cross-platform `RealtimeSocket.swift`
// (it's a hub-frame wire type so the shared socket can compile on macOS).
// iOS call UI below references it unchanged (same module).

@MainActor
struct CallDiagnosticsButton: View {
    let snapshot: CallDiagnosticsSnapshot
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
            Haptics.tap()
        } label: {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(Theme.Fonts.glyph(size: 18, weight: .semibold))
                .foregroundStyle(snapshot.quality.tint)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(.secondarySystemBackground)))
        }
        .accessibilityLabel("通话诊断")
    }
}

@MainActor
struct CallDiagnosticsPanel: View {
    let snapshot: CallDiagnosticsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("通话诊断")
                    .font(Theme.Fonts.headline)
                Spacer()
                Text(snapshot.quality.title)
                    .font(Theme.Fonts.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(snapshot.quality.tint)
            }
            Text(snapshot.bottleneck)
                .font(Theme.Fonts.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                ],
                spacing: 10,
            ) {
                metric("网络延迟", value: CallDiagnosticsLogic.formatMs(snapshot.rttMs))
                metric("抖动", value: CallDiagnosticsLogic.formatMs(snapshot.jitterMs))
                metric("丢包", value: CallDiagnosticsLogic.formatPercent(snapshot.packetLossPercent))
                metric("上行", value: CallDiagnosticsLogic.formatKbps(snapshot.sentKbps))
                metric("下行", value: CallDiagnosticsLogic.formatKbps(snapshot.receivedKbps))
                metric("可用上行", value: CallDiagnosticsLogic.formatKbps(snapshot.availableOutgoingKbps))
            }
            if !snapshot.participants.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("说话状态")
                        .font(Theme.Fonts.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    ForEach(snapshot.participants, id: \.identityKey) { p in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(p.speaking ? Color.green : Color.secondary.opacity(0.35))
                                .frame(width: 8, height: 8)
                            Text(p.displayName)
                                .font(Theme.Fonts.subheadline)
                                .lineLimit(1)
                            Spacer()
                            if let inputFrames = p.inputFrames, let quietFrames = p.quietFrames {
                                Text(CallDiagnosticsLogic.inputQuietText(inputFrames: inputFrames, quietFrames: quietFrames, dropped: p.droppedOutputMs))
                                    .font(Theme.Fonts.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            } else if let dropped = p.droppedOutputMs, dropped > 0 {
                                Text("丢弃 \(CallDiagnosticsLogic.formatDuration(dropped))")
                                    .font(Theme.Fonts.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            } else if let depth = p.playoutDepthMs {
                                Text("缓冲 \(CallDiagnosticsLogic.formatDuration(depth))")
                                    .font(Theme.Fonts.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("音量 \(CallDiagnosticsLogic.formatAudioLevel(p.audioLevel))")
                                    .font(Theme.Fonts.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Text(snapshot.transport)
                if let route = snapshot.route { Text(route) }
                Spacer()
                if let updatedAt = snapshot.updatedAt {
                    Text(Self.timeFormatter.string(from: updatedAt))
                }
            }
            .font(Theme.Fonts.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: 360)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemBackground).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(.separator).opacity(0.55), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 8)
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.Fonts.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(Theme.Fonts.subheadline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

#if canImport(WebRTC)

@MainActor
final class WebRTCDiagnosticsSampler {
    private let peerConnection: RTCPeerConnection
    private let transportName: String
    private let remoteLabel: String
    private let onSnapshot: (CallDiagnosticsSnapshot) -> Void

    private var task: Task<Void, Never>?
    private var previousAt: Date?
    private var previousBytesSentById: [String: Double] = [:]
    private var previousBytesReceivedById: [String: Double] = [:]
    private var previousInboundPacketsById: [String: PacketCounters] = [:]
    private var previousRemotePacketsById: [String: PacketCounters] = [:]

    init(
        peerConnection: RTCPeerConnection,
        transportName: String,
        remoteLabel: String,
        onSnapshot: @escaping (CallDiagnosticsSnapshot) -> Void,
    ) {
        self.peerConnection = peerConnection
        self.transportName = transportName
        self.remoteLabel = remoteLabel
        self.onSnapshot = onSnapshot
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.sample()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func sample() async {
        let report = await withCheckedContinuation { cont in
            peerConnection.statistics { report in
                cont.resume(returning: report)
            }
        }
        onSnapshot(makeSnapshot(report))
    }

    private func makeSnapshot(_ report: RTCStatisticsReport) -> CallDiagnosticsSnapshot {
        let now = Date()
        var rttMs: Int?
        var jitterMs: Int?
        var lossPercent: Double?
        var sentByteDelta = 0.0
        var receivedByteDelta = 0.0
        var inboundPacketDelta = 0.0
        var inboundLostDelta = 0.0
        var remotePacketDelta = 0.0
        var remoteLostDelta = 0.0
        var sawInboundPacketDelta = false
        var sawRemotePacketDelta = false
        var availableOutgoingKbps: Int?
        var route: String?
        var localAudioLevel = 0.0
        var remoteAudioLevel = 0.0

        var candidateTypes: [String: String] = [:]
        var selectedLocalCandidateId: String?
        var selectedRemoteCandidateId: String?
        var observedBytesSentIds = Set<String>()
        var observedBytesReceivedIds = Set<String>()
        var observedInboundPacketIds = Set<String>()
        var observedRemotePacketIds = Set<String>()

        for stat in report.statistics.values {
            if stat.type == "local-candidate" || stat.type == "remote-candidate" {
                if let type = doubleOrString(stat.values["candidateType"]) as? String {
                    candidateTypes[stat.id] = type
                }
            }
        }

        for stat in report.statistics.values {
            switch stat.type {
            case "candidate-pair":
                let selected = boolValue(stat.values["selected"])
                    || boolValue(stat.values["nominated"])
                    || stringValue(stat.values["state"]) == "succeeded"
                guard selected else { continue }
                if let rtt = doubleValue(stat.values["currentRoundTripTime"]) {
                    rttMs = Int((rtt * 1000).rounded())
                }
                if let bitrate = doubleValue(stat.values["availableOutgoingBitrate"]) {
                    availableOutgoingKbps = Int((bitrate / 1000).rounded())
                }
                selectedLocalCandidateId = stringValue(stat.values["localCandidateId"])
                selectedRemoteCandidateId = stringValue(stat.values["remoteCandidateId"])
            case "outbound-rtp":
                guard isAudio(stat) else { continue }
                observedBytesSentIds.insert(stat.id)
                if let bytes = doubleValue(stat.values["bytesSent"]),
                   let delta = delta(
                       id: stat.id,
                       current: bytes,
                       previous: &previousBytesSentById,
                   ) {
                    sentByteDelta += delta
                }
            case "inbound-rtp":
                guard isAudio(stat) else { continue }
                observedBytesReceivedIds.insert(stat.id)
                if let bytes = doubleValue(stat.values["bytesReceived"]),
                   let delta = delta(
                       id: stat.id,
                       current: bytes,
                       previous: &previousBytesReceivedById,
                   ) {
                    receivedByteDelta += delta
                }
                observedInboundPacketIds.insert(stat.id)
                if let counters = packetCounters(stat),
                   let packetDelta = packetDelta(
                       id: stat.id,
                       current: counters,
                       previous: &previousInboundPacketsById,
                   ) {
                    inboundPacketDelta += packetDelta.received
                    inboundLostDelta += packetDelta.lost
                    sawInboundPacketDelta = true
                }
                if let jitter = doubleValue(stat.values["jitter"]) {
                    jitterMs = max(jitterMs ?? 0, Int((jitter * 1000).rounded()))
                }
                remoteAudioLevel = max(remoteAudioLevel, doubleValue(stat.values["audioLevel"]) ?? 0)
            case "remote-inbound-rtp":
                guard isAudio(stat) else { continue }
                observedRemotePacketIds.insert(stat.id)
                if let counters = packetCounters(stat),
                   let packetDelta = packetDelta(
                       id: stat.id,
                       current: counters,
                       previous: &previousRemotePacketsById,
                   ) {
                    remotePacketDelta += packetDelta.received
                    remoteLostDelta += packetDelta.lost
                    sawRemotePacketDelta = true
                }
                if rttMs == nil, let rtt = doubleValue(stat.values["roundTripTime"]) {
                    rttMs = Int((rtt * 1000).rounded())
                }
            case "media-source":
                guard isAudio(stat) else { continue }
                localAudioLevel = max(localAudioLevel, doubleValue(stat.values["audioLevel"]) ?? 0)
            default:
                break
            }
        }

        if let localId = selectedLocalCandidateId {
            let local = candidateTypes[localId] ?? "?"
            let remote = selectedRemoteCandidateId.flatMap { candidateTypes[$0] } ?? "?"
            route = "\(local)→\(remote)"
        }

        let elapsed = previousAt.map { now.timeIntervalSince($0) } ?? 0
        let sentKbps = rateKbps(bytes: sentByteDelta, elapsed: elapsed)
        let receivedKbps = rateKbps(bytes: receivedByteDelta, elapsed: elapsed)

        if sawInboundPacketDelta, inboundPacketDelta + inboundLostDelta > 0 {
            lossPercent = inboundLostDelta / max(1, inboundPacketDelta + inboundLostDelta) * 100
        } else if sawRemotePacketDelta, remotePacketDelta + remoteLostDelta > 0 {
            lossPercent = remoteLostDelta / max(1, remotePacketDelta + remoteLostDelta) * 100
        }

        previousAt = now
        pruneMissing(from: &previousBytesSentById, keeping: observedBytesSentIds)
        pruneMissing(from: &previousBytesReceivedById, keeping: observedBytesReceivedIds)
        pruneMissing(from: &previousInboundPacketsById, keeping: observedInboundPacketIds)
        pruneMissing(from: &previousRemotePacketsById, keeping: observedRemotePacketIds)

        let localSpeaking = localAudioLevel > 0.025
        let remoteSpeaking = remoteAudioLevel > 0.025
        var snapshot = CallDiagnosticsSnapshot()
        snapshot.updatedAt = now
        snapshot.transport = transportName
        snapshot.connectionState = "\(peerConnection.iceConnectionState)"
        snapshot.route = route
        snapshot.rttMs = rttMs
        snapshot.jitterMs = jitterMs
        snapshot.packetLossPercent = lossPercent
        snapshot.sentKbps = sentKbps
        snapshot.receivedKbps = receivedKbps
        snapshot.availableOutgoingKbps = availableOutgoingKbps
        snapshot.localAudioLevel = localAudioLevel
        snapshot.remoteAudioLevel = remoteAudioLevel
        snapshot.localSpeaking = localSpeaking
        snapshot.remoteSpeaking = remoteSpeaking
        snapshot.activeSpeaker = localSpeaking ? "我" : (remoteSpeaking ? remoteLabel : nil)
        snapshot.quality = CallDiagnosticsLogic.quality(rttMs: rttMs, jitterMs: jitterMs, lossPercent: lossPercent)
        snapshot.bottleneck = CallDiagnosticsLogic.networkBottleneck(
            rttMs: rttMs,
            jitterMs: jitterMs,
            lossPercent: lossPercent,
            sentKbps: sentKbps,
            receivedKbps: receivedKbps,
            availableOutgoingKbps: availableOutgoingKbps,
            localSpeaking: localSpeaking,
        )
        snapshot.participants = [
            CallParticipantDiagnostic(
                kind: .local,
                id: "local",
                displayName: "我",
                speaking: localSpeaking,
                audioLevel: localAudioLevel,
                playoutDepthMs: nil,
                underruns: nil,
                maxGapMs: nil,
                droppedOutputMs: nil,
                inputLevel: nil,
                inputFrames: nil,
                quietFrames: nil,
                connected: true,
            ),
            CallParticipantDiagnostic(
                kind: .remote,
                id: "remote",
                displayName: remoteLabel,
                speaking: remoteSpeaking,
                audioLevel: remoteAudioLevel,
                playoutDepthMs: nil,
                underruns: nil,
                maxGapMs: nil,
                droppedOutputMs: nil,
                inputLevel: nil,
                inputFrames: nil,
                quietFrames: nil,
                connected: nil,
            ),
        ]
        return snapshot
    }

    private func isAudio(_ stat: RTCStatistics) -> Bool {
        stringValue(stat.values["kind"]) == "audio"
            || stringValue(stat.values["mediaType"]) == "audio"
            || stringValue(stat.values["trackIdentifier"])?.contains("audio") == true
    }

    private func rateKbps(bytes: Double, elapsed: TimeInterval) -> Int? {
        guard elapsed > 0.2, bytes >= 0 else { return nil }
        return Int(((bytes * 8) / elapsed / 1000).rounded())
    }

    private struct PacketCounters {
        let received: Double
        let lost: Double
    }

    private func packetCounters(_ stat: RTCStatistics) -> PacketCounters? {
        guard let received = doubleValue(stat.values["packetsReceived"]) else { return nil }
        return PacketCounters(
            received: received,
            lost: doubleValue(stat.values["packetsLost"]) ?? 0,
        )
    }

    private func delta(
        id: String,
        current: Double,
        previous: inout [String: Double],
    ) -> Double? {
        defer { previous[id] = current }
        guard let old = previous[id], current >= old else { return nil }
        return current - old
    }

    private func packetDelta(
        id: String,
        current: PacketCounters,
        previous: inout [String: PacketCounters],
    ) -> PacketCounters? {
        defer { previous[id] = current }
        guard let old = previous[id] else { return nil }
        let received = current.received - old.received
        let lost = current.lost - old.lost
        guard received >= 0, lost >= 0 else { return nil }
        return PacketCounters(received: received, lost: lost)
    }

    private func pruneMissing<T>(from previous: inout [String: T], keeping observed: Set<String>) {
        previous = previous.filter { observed.contains($0.key) }
    }

    private func doubleValue(_ value: NSObject?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? NSString { return Double(s as String) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func stringValue(_ value: NSObject?) -> String? {
        if let s = value as? NSString { return s as String }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private func boolValue(_ value: NSObject?) -> Bool {
        if let n = value as? NSNumber { return n.boolValue }
        if let s = stringValue(value) { return s == "true" || s == "1" }
        return false
    }

    private func doubleOrString(_ value: NSObject?) -> Any? {
        stringValue(value) ?? doubleValue(value)
    }
}

#endif
#endif
