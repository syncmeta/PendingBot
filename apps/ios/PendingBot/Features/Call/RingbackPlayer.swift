import AVFoundation
import Foundation

/// Locale-aware ringback tone for outgoing calls — what the user hears
/// during the `.connecting` phase before the bot's audio starts flowing.
///
/// The pattern is generated, not sampled: an AVAudioSourceNode renders
/// one or two sine waves whose envelope is gated by a per-region cadence
/// (`on` seconds of tone, then `off` seconds of silence, looped). That
/// keeps the bundle free of audio assets and lets us add regions by
/// editing the `pattern(for:)` table.
///
/// Cadences follow each country's PSTN ringback standard (ITU-T E.180
/// supplement 2). Wikipedia's "Ringback tone" page is the readable
/// summary. The ones implemented here cover where users actually are:
///
///   * CN — 450 Hz, 1 s on / 4 s off
///   * US/CA — 440 + 480 Hz dual, 2 s on / 4 s off ("North American")
///   * UK — 400 Hz amplitude-modulated at 25 Hz, 0.4 / 0.2 / 0.4 / 2 s
///          (the classic "ring-ring" pair)
///   * JP — 400 Hz, 1 s on / 2 s off
///   * Default (CEPT/ITU) — 425 Hz, 1 s on / 4 s off — used when the
///          locale doesn't match a specific entry above
///
/// The audio is routed through the shared AVAudioSession the call has
/// already configured for `.voiceChat`. RingbackPlayer doesn't touch the
/// category — CallSession owns that.
@MainActor
final class RingbackPlayer {

    /// Cadence + frequency parameters for one country's ringback.
    /// - freqA: primary tone (Hz)
    /// - freqB: optional second tone for dual-frequency standards (Hz);
    ///   summed with `freqA` and halved so the peak doesn't clip.
    /// - modulation: optional amplitude-modulation frequency (Hz), used
    ///   by UK-style "warble" tones.
    /// - cadence: alternating on/off durations in seconds, looped.
    ///   `[1.0, 4.0]` means 1 s tone, 4 s silence; UK uses
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
    /// The next three are read/written from the audio I/O thread by the
    /// render callback. They're written on the main actor *before*
    /// engine.start() and then only mutated by the render callback
    /// itself (single-threaded), so the unsafe nonisolated attribute is
    /// accurate.
    nonisolated(unsafe) private var samplePosition: Double = 0
    nonisolated(unsafe) private var sampleRate: Double = 48_000
    nonisolated(unsafe) private var pattern: Pattern = RingbackPlayer.fallbackPattern
    private var isPlaying = false

    /// Pick the pattern for the user's current region and start the
    /// engine. Idempotent: a second `start()` while already playing is
    /// a no-op. Errors are swallowed — a missing ringback is a degraded
    /// experience, not a fatal one.
    func start() {
        guard !isPlaying else { return }
        pattern = Self.pattern(for: Self.currentRegion())
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
        // Both `sampleRate` and `pattern` are written on the main actor
        // before engine.start() and never mutated while the engine is
        // running, so this nonisolated read is safe in practice.
        let sr = self.sampleRate
        let pat = self.pattern
        let periodSamples = pat.cadence.reduce(0, +) * sr

        let abl = UnsafeMutableAudioBufferListPointer(buffers)
        // Generate mono samples; copy into every output channel.
        var samples = [Float](repeating: 0, count: frameCount)
        let twoPi = 2.0 * Double.pi
        for i in 0..<frameCount {
            let pos = self.samplePosition + Double(i)
            // Cadence gate — fold the absolute sample index into one
            // period, then walk the cadence array to decide if we're
            // currently in an "on" slice (even index) or "off" (odd).
            let phaseInPeriod = pos.truncatingRemainder(dividingBy: periodSamples)
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
            // computed from the absolute sample index so each tone burst
            // is continuous with the previous one — no clicks at cadence
            // boundaries because the gate just mutes a continuous wave.
            var amp = sin(twoPi * pat.freqA * pos / sr)
            if let fb = pat.freqB {
                amp = (amp + sin(twoPi * fb * pos / sr)) * 0.5
            }
            if let mod = pat.modulation {
                // Amplitude-modulate the carrier — produces the UK
                // "warble" by multiplying by a low-frequency sine
                // shifted up to [0, 1].
                let m = 0.5 + 0.5 * sin(twoPi * mod * pos / sr)
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

    // MARK: - Region map

    /// Resolve the user's region. Locale.region (iOS 16+) reads from the
    /// system region, not the language — a user with Chinese language on
    /// a UK-region phone gets the UK pattern, which is what they expect.
    private static func currentRegion() -> String {
        let region = Locale.current.region?.identifier
        return (region ?? "").uppercased()
    }

    /// Pattern lookup. Unmapped regions fall through to the ITU/CEPT
    /// default (425 Hz, 1 s on / 4 s off) — close enough that a user in
    /// a region we haven't tuned for still hears a recognisable ring.
    private static func pattern(for region: String) -> Pattern {
        switch region {
        case "CN", "HK", "MO", "TW":
            return Pattern(freqA: 450, freqB: nil, modulation: nil, cadence: [1.0, 4.0])
        case "US", "CA":
            return Pattern(freqA: 440, freqB: 480, modulation: nil, cadence: [2.0, 4.0])
        case "GB", "IE":
            return Pattern(freqA: 400, freqB: nil, modulation: 25, cadence: [0.4, 0.2, 0.4, 2.0])
        case "JP":
            return Pattern(freqA: 400, freqB: nil, modulation: nil, cadence: [1.0, 2.0])
        case "AU", "NZ":
            return Pattern(freqA: 400, freqB: 425, modulation: nil, cadence: [0.4, 0.2, 0.4, 2.0])
        case "DE", "FR", "IT", "ES", "NL", "BE", "CH", "AT", "SE", "NO", "DK", "FI", "PT", "PL":
            return fallbackPattern   // CEPT countries match ITU default
        default:
            return fallbackPattern
        }
    }

    /// ITU-T E.180 default — 425 Hz, 1 s on / 4 s off. The choice when
    /// the region is unknown or unmapped. `nonisolated` so the stored-
    /// property initializer above can reach it without a MainActor hop.
    nonisolated static let fallbackPattern = Pattern(
        freqA: 425, freqB: nil, modulation: nil, cadence: [1.0, 4.0],
    )
}
