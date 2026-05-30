#if os(iOS)
import AVFoundation
import CoreAudio
import Foundation

/// Locale-aware call tones, generated rather than sampled. A single
/// `CallTonePlayer` synthesis engine renders one or two sine waves whose
/// envelope is gated by a per-region cadence (`on` seconds of tone, then
/// `off` seconds of silence, looped). That keeps the bundle free of audio
/// assets and lets us add regions by editing the tables in `CallTones`.
///
/// Two tones ride this engine:
///   * `RingbackPlayer` — the ring the caller hears while we negotiate
///     (`.connecting`). Cadences follow each country's PSTN ringback
///     standard (ITU-T E.180 supplement 2).
///   * `HangupTonePlayer` — the disconnect / busy tone played for a
///     moment when a connected call ends, again per-region.
///
/// The audio is routed through the shared AVAudioSession the call has
/// already configured for `.voiceChat`. Neither player touches the
/// category — CallSession owns that.

/// The synthesis engine. Holds the AVAudioEngine + source node and
/// renders a `Pattern` until `stop()`. Stateless about *which* tone it is
/// playing — RingbackPlayer / HangupTonePlayer supply the pattern.
@MainActor
final class CallTonePlayer {

    /// Cadence + frequency parameters for one tone.
    /// - freqA: primary tone (Hz)
    /// - freqB: optional second tone for dual-frequency standards (Hz);
    ///   summed with `freqA` and halved so the peak doesn't clip.
    /// - modulation: optional amplitude-modulation frequency (Hz), used
    ///   by UK-style "warble" tones.
    /// - cadence: alternating on/off durations in seconds, looped.
    ///   `[1.0, 4.0]` means 1 s tone, 4 s silence; UK ringback uses
    ///   `[0.4, 0.2, 0.4, 2.0]` for its double-ring.
    struct Pattern: Sendable {
        let freqA: Double
        let freqB: Double?
        let modulation: Double?
        let cadence: [Double]
    }

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    /// Sample index that the render callback uses to step through both
    /// the sine phase and the cadence envelope. Stored as Double so we
    /// don't need to convert per sample.
    ///
    /// The next four are read/written from the audio I/O thread by the
    /// render callback. They're written on the main actor *before*
    /// engine.start() and then only mutated by the render callback
    /// itself (single-threaded), so the unsafe nonisolated attribute is
    /// accurate.
    nonisolated(unsafe) private var samplePosition: Double = 0
    nonisolated(unsafe) private var sampleRate: Double = 48_000
    nonisolated(unsafe) private var pattern: Pattern = CallTonePlayer.silentPattern
    /// Samples of silence rendered before the cadence begins. Lets the
    /// ringback sit quiet for a beat after dialing before the first ring.
    nonisolated(unsafe) private var leadInSamples: Double = 0
    private var isPlaying = false

    /// Start rendering `pattern`. Idempotent: a second `start()` while
    /// already playing is a no-op. Errors are swallowed — a missing tone
    /// is a degraded experience, not a fatal one.
    /// - leadInSeconds: silence held before the cadence's first tone.
    func start(pattern: Pattern, leadInSeconds: Double = 0) {
        guard !isPlaying else { return }
        self.pattern = pattern
        samplePosition = 0

        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        // A fresh app launch can hand back a 0-channel/0-sampleRate
        // format before the audio session is active. Fall back to the
        // standard voice rate so the source node has a valid format.
        let format: AVAudioFormat
        if outputFormat.channelCount > 0 && outputFormat.sampleRate > 0 {
            format = outputFormat
        } else {
            format = AVAudioFormat(
                standardFormatWithSampleRate: 48_000,
                channels: 1,
            )!
        }
        sampleRate = format.sampleRate
        leadInSamples = max(0, leadInSeconds) * sampleRate

        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            // Render callback runs on the audio I/O thread. Snapshot the
            // few values we need without touching MainActor state; the
            // ones we read are written only on the main actor before
            // `engine.start()` and never mutated after.
            guard let self else { return noErr }
            self.render(
                frameCount: Int(frameCount),
                buffers: audioBufferList,
            )
            return noErr
        }
        sourceNode = node

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        // Soft volume — full-amplitude sine on the earpiece is harsh.
        // 0.25 is roughly comparable to the system phone ringback.
        engine.mainMixerNode.outputVolume = 0.25

        do {
            try engine.start()
            isPlaying = true
        } catch {
            // Engine failed to start — most likely the audio session
            // isn't active yet. Leave isPlaying false; caller may retry.
            sourceNode = nil
        }
    }

    /// Stop the engine and release the source node so the next `start()`
    /// can pick up a fresh format (e.g. after the audio route changed).
    func stop() {
        guard isPlaying else { return }
        isPlaying = false
        if engine.isRunning { engine.stop() }
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
    }

    // MARK: - Render

    private nonisolated func render(
        frameCount: Int,
        buffers: UnsafeMutablePointer<AudioBufferList>,
    ) {
        // `sampleRate`, `pattern`, and `leadInSamples` are written on the
        // main actor before engine.start() and never mutated while the
        // engine is running, so this nonisolated read is safe in practice.
        let sr = self.sampleRate
        let pat = self.pattern
        let lead = self.leadInSamples
        let periodSamples = pat.cadence.reduce(0, +) * sr

        let abl = UnsafeMutableAudioBufferListPointer(buffers)
        // Generate mono samples; copy into every output channel.
        var samples = [Float](repeating: 0, count: frameCount)
        let twoPi = 2.0 * Double.pi
        for i in 0..<frameCount {
            let pos = self.samplePosition + Double(i)
            // Lead-in: hold silence until the cadence is due to start.
            if pos < lead {
                samples[i] = 0
                continue
            }
            // Time since the cadence began — drives both the cadence gate
            // and the sine phase, so the first burst opens at a zero
            // crossing.
            let t = pos - lead
            // Cadence gate — fold `t` into one period, then walk the
            // cadence array to decide if we're currently in an "on" slice
            // (even index) or "off" (odd).
            let phaseInPeriod = t.truncatingRemainder(dividingBy: periodSamples)
            var acc = 0.0
            var gate: Float = 0
            for (idx, dur) in pat.cadence.enumerated() {
                let slice = dur * sr
                if phaseInPeriod < acc + slice {
                    gate = (idx % 2 == 0) ? 1.0 : 0.0
                    break
                }
                acc += slice
            }
            if gate == 0 {
                samples[i] = 0
                continue
            }
            // Generate the sine (or sum of two sines, halved). Phase is
            // computed from `t` so each tone burst is continuous with the
            // previous one — no clicks at cadence boundaries because the
            // gate just mutes a continuous wave.
            var amp = sin(twoPi * pat.freqA * t / sr)
            if let fb = pat.freqB {
                amp = (amp + sin(twoPi * fb * t / sr)) * 0.5
            }
            if let mod = pat.modulation {
                // Amplitude-modulate the carrier — produces the UK
                // "warble" by multiplying by a low-frequency sine
                // shifted up to [0, 1].
                let m = 0.5 + 0.5 * sin(twoPi * mod * t / sr)
                amp *= m
            }
            samples[i] = Float(amp) * gate
        }
        self.samplePosition += Double(frameCount)

        for buf in abl {
            guard let raw = buf.mData else { continue }
            let dst = raw.assumingMemoryBound(to: Float.self)
            for i in 0..<frameCount { dst[i] = samples[i] }
        }
    }

    /// Placeholder so the stored `pattern` has a value before `start()`.
    /// Never actually rendered — `start()` always overwrites it.
    nonisolated static let silentPattern = Pattern(
        freqA: 0, freqB: nil, modulation: nil, cadence: [1.0],
    )
}

// MARK: - Region tables

/// Per-region tone standards and the locale lookup. Ringback and hangup
/// tones share the resolution logic; only the frequency/cadence tables
/// differ.
enum CallTones {

    /// Resolve the user's region. `Locale.region` (iOS 16+) reads from
    /// the system region, not the language — a user with Chinese language
    /// on a UK-region phone gets the UK pattern, which is what they
    /// expect. Empty string falls through to the ITU/CEPT default.
    static func currentRegion() -> String {
        let region = Locale.current.region?.identifier
        return (region ?? "").uppercased()
    }

    /// Ringback (the ring the caller hears). Unmapped regions fall to the
    /// ITU/CEPT default (425 Hz, 1 s on / 4 s off).
    ///
    ///   * CN/HK/MO/TW — 450 Hz, 1 s on / 4 s off
    ///   * US/CA — 440 + 480 Hz dual, 2 s on / 4 s off ("North American")
    ///   * GB/IE — 400 Hz amplitude-modulated at 25 Hz, 0.4 / 0.2 / 0.4 / 2 s
    ///   * JP — 400 Hz, 1 s on / 2 s off
    ///   * AU/NZ — 400 + 425 Hz dual, 0.4 / 0.2 / 0.4 / 2 s
    static func ringback(for region: String) -> CallTonePlayer.Pattern {
        switch region {
        case "CN", "HK", "MO", "TW":
            return .init(freqA: 450, freqB: nil, modulation: nil, cadence: [1.0, 4.0])
        case "US", "CA":
            return .init(freqA: 440, freqB: 480, modulation: nil, cadence: [2.0, 4.0])
        case "GB", "IE":
            return .init(freqA: 400, freqB: nil, modulation: 25, cadence: [0.4, 0.2, 0.4, 2.0])
        case "JP":
            return .init(freqA: 400, freqB: nil, modulation: nil, cadence: [1.0, 2.0])
        case "AU", "NZ":
            return .init(freqA: 400, freqB: 425, modulation: nil, cadence: [0.4, 0.2, 0.4, 2.0])
        case "DE", "FR", "IT", "ES", "NL", "BE", "CH", "AT", "SE", "NO", "DK", "FI", "PT", "PL":
            return ringbackDefault   // CEPT countries match ITU default
        default:
            return ringbackDefault
        }
    }

    /// Disconnect / busy tone played briefly when a connected call ends.
    /// Follows each region's PSTN busy-tone standard — a faster cadence
    /// than ringback, which is what makes "the call ended" read as
    /// distinct from "still ringing". Unmapped regions fall to the
    /// ITU/CEPT default (425 Hz, 0.5 s on / 0.5 s off).
    ///
    ///   * CN/HK/MO/TW — 450 Hz, 0.35 s on / 0.35 s off
    ///   * US/CA — 480 + 620 Hz dual, 0.5 s on / 0.5 s off (North American busy)
    ///   * GB/IE — 400 Hz, 0.375 s on / 0.375 s off
    ///   * JP — 400 Hz, 0.5 s on / 0.5 s off
    ///   * AU/NZ — 425 Hz, 0.375 s on / 0.375 s off
    static func hangup(for region: String) -> CallTonePlayer.Pattern {
        switch region {
        case "CN", "HK", "MO", "TW":
            return .init(freqA: 450, freqB: nil, modulation: nil, cadence: [0.35, 0.35])
        case "US", "CA":
            return .init(freqA: 480, freqB: 620, modulation: nil, cadence: [0.5, 0.5])
        case "GB", "IE":
            return .init(freqA: 400, freqB: nil, modulation: nil, cadence: [0.375, 0.375])
        case "JP":
            return .init(freqA: 400, freqB: nil, modulation: nil, cadence: [0.5, 0.5])
        case "AU", "NZ":
            return .init(freqA: 425, freqB: nil, modulation: nil, cadence: [0.375, 0.375])
        default:
            return hangupDefault
        }
    }

    /// ITU-T E.180 ringback default — 425 Hz, 1 s on / 4 s off.
    static let ringbackDefault = CallTonePlayer.Pattern(
        freqA: 425, freqB: nil, modulation: nil, cadence: [1.0, 4.0],
    )

    /// ITU-T busy-tone default — 425 Hz, 0.5 s on / 0.5 s off.
    static let hangupDefault = CallTonePlayer.Pattern(
        freqA: 425, freqB: nil, modulation: nil, cadence: [0.5, 0.5],
    )
}

// MARK: - Ringback

/// Region-aware ringback for outgoing calls — what the user hears during
/// `.connecting` before the bot's audio starts flowing. Holds 1 s of
/// silence after dialing before the first ring, mirroring how a real PSTN
/// call sits quiet for a beat while the exchange routes the call.
@MainActor
final class RingbackPlayer {
    /// Quiet beat after dialing before the cadence starts.
    private static let leadInSeconds: Double = 1.0

    private let player = CallTonePlayer()

    func start() {
        player.start(
            pattern: CallTones.ringback(for: CallTones.currentRegion()),
            leadInSeconds: Self.leadInSeconds,
        )
    }

    func stop() { player.stop() }
}

// MARK: - Hangup tone

/// Region-aware disconnect tone played for a moment when a connected call
/// ends. CallSession starts it on the still-active call audio session and
/// stops it after `playbackSeconds` before tearing the session down.
@MainActor
final class HangupTonePlayer {
    /// How long the disconnect tone sounds before teardown deactivates
    /// the audio session — long enough for the regional cadence to read
    /// (≈1–2 busy-tone cycles), short enough not to drag out the hang up.
    static let playbackSeconds: Double = 1.2

    private let player = CallTonePlayer()

    func start() {
        player.start(pattern: CallTones.hangup(for: CallTones.currentRegion()))
    }

    func stop() { player.stop() }
}
#endif
