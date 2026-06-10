import SwiftUI

/// Markdown compose sheet for human-to-human letters. The send action
/// hands `(title, bodyMd)` back to the caller, which makes the network
/// call (and decides what to do on success — typically dismiss the
/// settings sheet too). The editor itself is intentionally simple:
/// SwiftUI TextEditor + a small insert-helper toolbar + an optional
/// preview tab that renders the same MarkdownText component the article
/// view uses, so what you preview here is exactly what the recipient
/// sees on their 来信 tab.
///
/// Why no third-party markdown-editor library: there isn't a mature,
/// pure-SwiftUI markdown editor on the level of CodeMirror/EasyMDE.
/// The serious options are all WKWebView wrappers (extra weight, layout
/// quirks, accessibility regressions) or TextKit 2 syntax-highlighters
/// people roll themselves. For a one-shot compose flow, plain TextEditor
/// + a preview toggle is the fastest path that still feels native, and
/// it reuses the renderer we already trust.
struct LetterComposeSheet: View {
    let recipient: LetterRecipient
    /// Returns true on a successful send so the sheet can dismiss; false
    /// keeps the editor open so the user can retry without retyping.
    let onSend: (String?, String) async -> Bool

    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var body_md: String = ""
    @State private var mode: Mode = .edit
    @State private var sending: Bool = false
    @FocusState private var bodyFocused: Bool

    private enum Mode: Hashable { case edit, preview }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                modePicker
                Divider()

                Group {
                    switch mode {
                    case .edit:    editorPane
                    case .preview: previewPane
                    }
                }
            }
            .navigationTitle("写信给「\(recipient.displayName)」")
            .inlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .platformLeading) {
                    Button("取消") { dismiss() }.disabled(sending)
                }
                ToolbarItem(placement: .platformTrailing) {
                    Button {
                        Task { await trySend() }
                    } label: {
                        if sending { ProgressView() } else { Text("发送") }
                    }
                    .disabled(sending || trimmedBody.isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(sending)
        .tint(Theme.Palette.accent)
    }

    // MARK: - Mode picker

    @ViewBuilder
    private var modePicker: some View {
        Picker("", selection: $mode) {
            Text("写").tag(Mode.edit)
            Text("预览").tag(Mode.preview)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Edit pane

    @ViewBuilder
    private var editorPane: some View {
        VStack(spacing: 0) {
            // Title is optional — empty falls back to the first non-empty
            // line of the body when the row lands on the recipient side.
            TextField("信的标题（可留空）", text: $title)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.serif(size: 19, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 8)
                .submitLabel(.next)
                .onSubmit { bodyFocused = true }

            Divider().padding(.horizontal, 18)

            // The actual editor. TextEditor doesn't have a placeholder
            // out of the box, so we overlay one when empty + unfocused.
            ZStack(alignment: .topLeading) {
                TextEditor(text: $body_md)
                    .focused($bodyFocused)
                    .scrollContentBackground(.hidden)
                    .font(Theme.Fonts.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                if body_md.isEmpty && !bodyFocused {
                    Text("用 markdown 写。\n\n# 标题、**加粗**、*斜体*、[链接](https://…)、列表、引用、代码块都支持。")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .padding(.horizontal, 19)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }

            // Insert helpers — wraps current TextEditor selection in
            // markdown markers, or appends them when there's no
            // selection. We keep it a 6-button row so the keyboard
            // stays visible above it.
            insertHelpers
        }
    }

    @ViewBuilder
    private var insertHelpers: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                helperButton("H", "标题") { insertLinePrefix("## ") }
                helperButton("B", "加粗") { wrapSelection("**", "**") }
                helperButton("I", "斜体") { wrapSelection("*", "*") }
                helperButton("•", "列表") { insertLinePrefix("- ") }
                helperButton("\u{201C}", "引用") { insertLinePrefix("> ") }
                helperButton("</>", "代码") { wrapSelection("`", "`") }
                helperButton("🔗", "链接") {
                    appendAtEnd("[链接文字](https://)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(Theme.Palette.surfaceMuted)
    }

    private func helperButton(_ glyph: String, _ a11y: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(Theme.Fonts.rounded(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .frame(minWidth: 36, minHeight: 28)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.Palette.surface)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11y)
    }

    // MARK: - Preview pane

    @ViewBuilder
    private var previewPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !title.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(title)
                        .font(Theme.Fonts.serif(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if trimmedBody.isEmpty {
                    Text("还没写正文。")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Palette.inkMuted)
                } else {
                    MarkdownText(text: body_md, variant: .article)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .background(Theme.Palette.canvas)
    }

    // MARK: - Insert helpers

    /// TextEditor doesn't expose its NSRange selection in pure SwiftUI,
    /// so "wrap selection" degrades to "append markers at end of body"
    /// when nothing's selected. Good enough for a one-shot compose.
    private func wrapSelection(_ open: String, _ close: String) {
        let trimmed = body_md.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            body_md = open + close
        } else {
            body_md += " " + open + "文字" + close
        }
        bodyFocused = true
    }

    private func insertLinePrefix(_ prefix: String) {
        if body_md.isEmpty {
            body_md = prefix
        } else if body_md.hasSuffix("\n") {
            body_md += prefix
        } else {
            body_md += "\n" + prefix
        }
        bodyFocused = true
    }

    private func appendAtEnd(_ snippet: String) {
        if body_md.isEmpty {
            body_md = snippet
        } else if body_md.hasSuffix("\n") {
            body_md += snippet
        } else {
            body_md += " " + snippet
        }
        bodyFocused = true
    }

    // MARK: - Send

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedBody: String {
        body_md.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trySend() async {
        guard !trimmedBody.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        let ok = await onSend(trimmedTitle.isEmpty ? nil : trimmedTitle, body_md)
        if ok {
            dismiss()
        }
    }
}
