import SwiftUI
import PhotosUI
import UIKit

/// Bottom-of-screen input bar — capsule field flanked by circle buttons.
/// Matches the PendingBot composer:
///   • Left  — circle attach button (hairline border, surface fill)
///   • Center — capsule textfield (1–6 lines, hairline border)
///   • Right — circle send button (state-aware: accent on, muted off)
///
/// The "+" panel is rendered inline below the input row. Mounted via
/// `.safeAreaInset(edge: .bottom)` from the host so the message scroll
/// view shrinks predictably when the panel opens — this is what lets
/// the existing scroll position stay put instead of "jumping from above"
/// when the host's animation timing fights with keyboard avoidance.
struct ComposerView: View {
    @Binding var input: String
    @Binding var pending: [PendingAttachment]
    @Binding var photoItems: [PhotosPickerItem]
    @Binding var cameraImage: UIImage?
    /// Flipped true by the "文件" action tile; the host owns the
    /// `.fileImporter` sheet bound to it.
    @Binding var showFileImporter: Bool
    var canSend: Bool
    var onSend: () -> Void
    /// True while a bot reply is streaming. Send button morphs into a stop
    /// button — tapping it calls `onStop` which cancels the SSE turn task.
    var isStreaming: Bool = false
    var onStop: () -> Void = {}
    /// Optional manual lookback trigger. ConversationView passes a closure
    /// when the conv has a single bot (user_bot / self); group + user_user
    /// pass nil and the action sheet hides the tile.
    var onLookback: (() -> Void)? = nil

    @State private var showActions = false
    // Plain Bool, not @FocusState: the actual first responder is the
    // UIKit UITextView inside ComposerTextField, and nothing here is
    // bound via `.focused()`. SwiftUI's focus engine would reset a
    // @FocusState back to false on every parent re-render (which fires
    // on every keystroke, since `input` is host @State), causing
    // updateUIView to resign the text view — keyboard drops per char.
    @State private var isFocused: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if !pending.isEmpty {
                pendingTray
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    Haptics.tap()
                    if showActions {
                        showActions = false
                        isFocused = true
                    } else {
                        isFocused = false
                        showActions = true
                    }
                } label: {
                    Image(systemName: showActions ? "xmark" : "plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Theme.Palette.surface))
                        .overlay(Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)

                ComposerTextField(
                    text: $input,
                    placeholder: "发消息…",
                    isFocused: $isFocused,
                    onHardwareReturn: {
                        // Hardware keyboard's plain Return — Mac Catalyst
                        // and iPad-with-keyboard. Shift+Return falls
                        // through to default UITextView behaviour (newline)
                        // by way of the subclass not consuming it.
                        if canSend { onSend() }
                    }
                )
                .onChange(of: isFocused) { _, focused in
                    if focused { showActions = false }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Theme.Palette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                        )
                )

                Button(action: { isStreaming ? onStop() : onSend() }) {
                    Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(
                            isStreaming || canSend
                                ? .white
                                : Theme.Palette.inkMuted.opacity(0.5)
                        )
                        .frame(width: 38, height: 38)
                        .background(
                            Circle().fill(
                                isStreaming || canSend
                                    ? Theme.Palette.accent
                                    : Theme.Palette.surfaceMuted
                            )
                        )
                }
                .buttonStyle(.plain)
                .disabled(!isStreaming && !canSend)
            }
            .padding(.horizontal, Theme.Metrics.gutter)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .background(Theme.Palette.canvas)

            if showActions {
                ChatActionSheet(
                    photoItems: $photoItems,
                    cameraImage: $cameraImage,
                    onPickFile: { showFileImporter = true },
                    onDismiss: { showActions = false },
                    onLookback: onLookback
                )
                .frame(height: 240)
                .background(Theme.Palette.canvas)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(
            // Solid backstop — without it the safeAreaInset region above
            // the panel is transparent during the open/close transition,
            // and the message list briefly bleeds through.
            Theme.Palette.canvas
        )
        .animation(.easeInOut(duration: 0.22), value: showActions)
    }

    // ── Attachment thumbnails strip ────────────────────────────────────────

    private var pendingTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pending) { att in
                    ZStack(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.Palette.surfaceMuted)
                            .frame(width: 64, height: 64)
                            .overlay(pendingCellContent(att))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                            )
                        Button {
                            pending.removeAll { $0.id == att.id }
                            Haptics.tap()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.body)
                                .foregroundStyle(.white, .black.opacity(0.55))
                        }
                        .offset(x: 6, y: -6)
                    }
                }
            }
            .padding(.horizontal, Theme.Metrics.gutter)
            .padding(.top, 8)
        }
        .background(Theme.Palette.canvas)
    }

    /// 64×64 thumbnail content for one pending attachment — the actual
    /// image for images, an icon + truncated filename for files.
    @ViewBuilder
    private func pendingCellContent(_ att: PendingAttachment) -> some View {
        if att.isImage {
            ServerImage(
                path: "/v1/uploads/\(att.id)",
                serverURL: HostedConfig.environment.workerURL,
                contentMode: .fill
            )
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            VStack(spacing: 3) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.Palette.accent)
                Text(att.filename ?? "文件")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 4)
        }
    }
}

// ── Composer text input ────────────────────────────────────────────────────

/// UITextView-backed input that grows up to 6 lines, distinguishes
/// hardware-Return-as-send from Shift+Return-as-newline, and
/// preserves newlines on paste. SwiftUI's `TextField(axis: .vertical)`
/// can do none of those: it can't see the modifier flags on a
/// keypress, and its `onChange` fires for every newline regardless of
/// source (paste vs typed), which made any paste containing a
/// linebreak fire send immediately.
///
/// Behavior summary:
/// - Soft keyboard Return → newline (no auto-send).
/// - Hardware Return (no modifiers) → calls `onHardwareReturn`, doesn't
///   insert a newline. That's the Mac Catalyst / iPad-keyboard "send".
/// - Hardware Shift+Return → default UITextView behaviour: newline.
/// - Paste → newlines preserved verbatim; no send.
struct ComposerTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @Binding var isFocused: Bool
    let onHardwareReturn: () -> Void

    /// Cap on auto-grown height — matches the old `lineLimit(1...6)`.
    private static let maxLines: CGFloat = 6

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerUITextView {
        let tv = ComposerUITextView()
        tv.delegate = context.coordinator
        tv.font = .systemFont(ofSize: Theme.Fonts.scaled(16))
        tv.textColor = UIColor(Theme.Palette.ink)
        tv.tintColor = UIColor(Theme.Palette.accent)
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false   // lets intrinsicContentSize drive height
        tv.returnKeyType = .default  // soft-keyboard Return inserts \n
        tv.onHardwareReturn = {
            // Hop to the next run loop so SwiftUI sees the latest text
            // binding before the parent reads `input` in its send path.
            DispatchQueue.main.async { onHardwareReturn() }
        }
        // Placeholder is rendered as a child label so its color tracks
        // the surrounding palette (UITextView has no built-in placeholder).
        let ph = UILabel()
        ph.text = placeholder
        ph.font = tv.font
        ph.textColor = UIColor(Theme.Palette.inkMuted).withAlphaComponent(0.6)
        ph.translatesAutoresizingMaskIntoConstraints = false
        tv.addSubview(ph)
        NSLayoutConstraint.activate([
            ph.leadingAnchor.constraint(equalTo: tv.leadingAnchor),
            ph.topAnchor.constraint(equalTo: tv.topAnchor, constant: 6),
        ])
        context.coordinator.placeholder = ph
        context.coordinator.refreshPlaceholder(tv)
        return tv
    }

    func updateUIView(_ uiView: ComposerUITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
            context.coordinator.refreshPlaceholder(uiView)
            context.coordinator.invalidateHeight(uiView)
        }
        // Sync focus state both ways: SwiftUI → UIKit.
        if isFocused, !uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.becomeFirstResponder() }
        } else if !isFocused, uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.resignFirstResponder() }
        }
    }

    @MainActor
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerUITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = (uiView.font?.lineHeight ?? 20)
        let maxHeight = lineHeight * Self.maxLines + uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let height = min(fitted.height, maxHeight)
        // Toggle internal scrolling once the text outgrows the cap so
        // the user can still scroll within the bubble.
        if uiView.isScrollEnabled != (fitted.height > maxHeight) {
            uiView.isScrollEnabled = fitted.height > maxHeight
        }
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextField
        weak var placeholder: UILabel?

        init(_ parent: ComposerTextField) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text ?? ""
            refreshPlaceholder(textView)
            invalidateHeight(textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }

        func refreshPlaceholder(_ textView: UITextView) {
            placeholder?.isHidden = !(textView.text?.isEmpty ?? true)
        }

        func invalidateHeight(_ textView: UITextView) {
            textView.invalidateIntrinsicContentSize()
        }
    }
}

/// UITextView subclass that intercepts plain hardware Return so the
/// host can treat it as "send". Shift+Return falls through to the
/// default behaviour (newline). Soft-keyboard Return arrives via the
/// normal text input pipeline (not `pressesBegan`) and is therefore
/// unaffected — it still inserts a newline.
final class ComposerUITextView: UITextView {
    var onHardwareReturn: (() -> Void)?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let key = presses.first?.key,
           key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter,
           !key.modifierFlags.contains(.shift),
           !key.modifierFlags.contains(.alternate),
           // markedTextRange != nil means an IME (e.g. 拼音) is mid-
           // composition — Return there commits the candidate, not a
           // send. Fall through so UITextView handles the commit.
           markedTextRange == nil {
            onHardwareReturn?()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}
