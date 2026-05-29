import SwiftUI
import PhotosUI

// T4.6 P1 Step 5 — crew chat composer. Reuses `ComposerView` as-is (its
// bindings are conversation-agnostic), hosted in a `.safeAreaInset(.bottom)`
// by CrewDetailV2View. Adds the @人/@session/@captain mention picker on
// top: typing a trailing `@` reveals candidates; selecting one inserts a
// display token and stages a structured `CrewMentionInput`. No `@` =
// broadcast (server default), which is the empty-mentions case.
//
// P1 simplifications (tech-debt): attachments are not supported — the
// picker-trigger bindings are wired to dummy state and the pickers are
// never presented, so the ComposerView "+" action tiles are inert. Live
// streaming is not used (isStreaming stays false).
struct CrewComposerBar: View {
    @Bindable var store: CrewChatStore
    let detail: CrewDetailV2?

    @State private var input = ""
    /// Structured mentions staged by the picker, in insertion order.
    @State private var staged: [CrewMentionCandidate] = []
    @State private var showPicker = false
    @State private var sending = false

    // Dummy bindings for the attachment surface ComposerView expects.
    // Crew chat has no attachments in P1, so these stay empty/false and the
    // pickers are never presented.
    @State private var pending: [PendingAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var cameraImage: UIImage?
    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false

    /// Exposed so the list can re-send a failed bubble with the same
    /// mention set the composer currently has staged.
    var stagedMentions: [CrewMentionInput] { staged.map(\.mentionInput) }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
    }

    var body: some View {
        VStack(spacing: 0) {
            if showPicker && !filteredCandidates.isEmpty {
                mentionPicker
            }
            if !staged.isEmpty {
                stagedChips
            }
            ComposerView(
                input: $input,
                pending: $pending,
                photoItems: $photoItems,
                cameraImage: $cameraImage,
                showFileImporter: $showFileImporter,
                showPhotoPicker: $showPhotoPicker,
                showCamera: $showCamera,
                canSend: canSend,
                onSend: send
            )
        }
        .onChange(of: input) { _, newValue in
            // Reveal the picker while the caret sits right after a bare `@`.
            showPicker = newValue.hasSuffix("@")
        }
    }

    // MARK: - Send

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        let mentions = staged.map(\.mentionInput)
        sending = true
        // Clear the input immediately for responsiveness; the optimistic
        // bubble carries the text from here on.
        input = ""
        staged = []
        showPicker = false
        Task {
            await store.send(content: text, mentions: mentions, detail: detail)
            sending = false
        }
    }

    // MARK: - Mention picker

    private var filteredCandidates: [CrewMentionCandidate] {
        // While the picker is open the input ends in `@`; show all
        // candidates not already staged.
        let stagedIds = Set(staged.map(\.id))
        return store.mentionCandidates.filter { !stagedIds.contains($0.id) }
    }

    private var mentionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filteredCandidates) { candidate in
                    Button {
                        select(candidate)
                    } label: {
                        Label(candidate.label, systemImage: candidate.glyph)
                            .font(.footnote)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(Color(.secondarySystemBackground))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Metrics.gutter)
            .padding(.vertical, 6)
        }
        .background(Theme.Palette.canvas)
    }

    private var stagedChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(staged) { candidate in
                    HStack(spacing: 4) {
                        Text("@\(candidate.label)")
                            .font(.caption)
                            .lineLimit(1)
                        Button {
                            staged.removeAll { $0.id == candidate.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, Theme.Metrics.gutter)
            .padding(.vertical, 4)
        }
    }

    private func select(_ candidate: CrewMentionCandidate) {
        staged.append(candidate)
        // Drop the trailing `@` that triggered the picker — the staged chip
        // is the visible token now.
        if input.hasSuffix("@") { input.removeLast() }
        showPicker = false
    }
}
