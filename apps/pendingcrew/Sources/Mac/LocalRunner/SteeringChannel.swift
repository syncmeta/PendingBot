#if os(macOS)
import Foundation

/// An **ambient steering** channel for a crew session (T4.5 cross-device
/// remote control).
///
/// A viewer can set a standing instruction that the running agent sees as
/// context on *every* turn — with no explicit read action and without touching
/// the user's repo. This is the "a file it always reads, injected as context"
/// idea, distinct from a one-shot `send_prompt`.
///
/// Mechanism (verified 2026-06-02, see `docs/crew-runner-steering.md`): a
/// managed `settings.json` passed to Claude Code via `--settings` registers a
/// `UserPromptSubmit` hook that `cat`s a steering file into the turn's context.
/// Because the hook output rides at the tail (the new user turn), it does **not**
/// break the prompt cache. Plain stdout — no `jq` dependency.
///
/// The managed dir lives outside the working directory (app caches), so the
/// user's repo stays clean; `teardown()` removes it when the session ends.
struct SteeringChannel {
    let directory: URL

    /// Path to hand Claude Code via `--settings`.
    var settingsPath: String { directory.appendingPathComponent("settings.json").path }
    private var hookPath: URL { directory.appendingPathComponent("hook.sh") }
    private var notePath: URL { directory.appendingPathComponent("steering.md") }
    /// Auto-maintained crew context (whiteboard + mailbox digest, spec §9.2),
    /// kept separate from the viewer's manual steering note so neither clobbers
    /// the other. The hook injects both each turn.
    private var crewContextPath: URL { directory.appendingPathComponent("crew-context.md") }

    /// Create the managed dir + hook script + settings file (the note starts
    /// empty → injects nothing until a viewer sets one). `parent` is normally
    /// the app caches dir; tests pass a temp dir.
    static func create(parent: URL, sessionId: String) throws -> SteeringChannel {
        let dir = parent
            .appendingPathComponent("crew-steering", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let channel = SteeringChannel(directory: dir)
        try channel.writeHookAndSettings()
        channel.setNote("") // empty note = no-op injection until set
        channel.setCrewContext("") // empty until the runner polls the inbox
        return channel
    }

    /// Default managed-dir parent: the app caches directory (out of the repo).
    static func defaultParent() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    private func writeHookAndSettings() throws {
        // Plain-stdout hook: emit the steering note as UserPromptSubmit context.
        // Reads the note next to itself so the script is relocatable.
        let hook = """
        #!/bin/bash
        read -r _
        dir="$(cd "$(dirname "$0")" && pwd)"
        cat "$dir/crew-context.md" 2>/dev/null
        cat "$dir/steering.md" 2>/dev/null
        """
        try hook.write(to: hookPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: hookPath.path)

        // Build the settings JSON via JSONSerialization so the hook path is
        // escaped safely. Matches Claude Code's hooks schema.
        let obj: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    ["hooks": [["type": "command", "command": "bash \"\(hookPath.path)\""]]],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: settingsPath))
    }

    /// Replace the standing note. Empty string clears it (next turn injects
    /// nothing). Best-effort — a write failure just leaves the prior note.
    func setNote(_ text: String) {
        try? text.write(to: notePath, atomically: true, encoding: .utf8)
    }

    /// Current note content (for tests / UI echo). Empty if unset.
    func currentNote() -> String {
        (try? String(contentsOf: notePath, encoding: .utf8)) ?? ""
    }

    /// Replace the auto-maintained crew context block (whiteboard + mailbox
    /// digest). Empty clears it. Best-effort.
    func setCrewContext(_ text: String) {
        try? text.write(to: crewContextPath, atomically: true, encoding: .utf8)
    }

    /// Remove the managed dir. Call when the session ends.
    func teardown() {
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
