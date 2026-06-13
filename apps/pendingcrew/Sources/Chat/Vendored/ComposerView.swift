// VENDORED from PendingBot apps/pendingbot/Sources/Features/Message/ComposerView.swift @ 43c8ea2e
// 再对齐 = 对照源文件重拷。仅允许偏离打 `// PENDINGCREW SHIM:` 标注。
import SwiftUI
import PhotosUI
#if os(iOS)
import UIKit
#endif

/// Bottom-of-screen input bar — capsule field flanked by circle buttons.
/// Matches the PendingBot composer:
///   • Left  — circle attach button (hairline border, surface fill)
///   • Center — capsule textfield (1–6 lines, hairline border)
///   • Right — circle send button (state-aware: accent on, muted off)
///
/// The "+" panel is rendered inline below the input row. The host mounts
/// this whole bar inside a UIKit `inputAccessoryView` (see
/// ChatComposerAccessory.swift) so it tracks the keyboard frame-by-frame
/// during an interactive scroll-to-dismiss instead of lagging on SwiftUI's
/// keyboard-avoidance curve.
struct ComposerView: View {
    @Binding var input: String
    @Binding var pending: [PendingAttachment]
    @Binding var photoItems: [PhotosPickerItem]
    @Binding var cameraImage: PlatformImage?
    /// Flipped true by the "文件" action tile; the host owns the
    /// `.fileImporter` sheet bound to it.
    @Binding var showFileImporter: Bool
    /// Flipped true by the "图片" / "拍照" action tiles. The host owns the
    /// `.photosPicker` / camera `.fullScreenCover` bound to these. Presenting
    /// from the main view tree (not from inside the inputAccessoryView's
    /// hosting controller) is what keeps those pickers reliable — same pattern
    /// as `showFileImporter`.
    @Binding var showPhotoPicker: Bool
    @Binding var showCamera: Bool
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
    /// When false, the "+" attachment button and its action panel are hidden
    /// entirely. Crew chat (T4.6 P1) has no attachments, so it passes false
    /// rather than surfacing a "+" that opens tiles wired to dead pickers.
    var showsAttachments: Bool = true
    /// #242 遥控 v1 — optional「派任务」entry. Non-nil renders a terminal
    /// glyph button in the leading accessory slot (where "+" sits for
    /// attachment-enabled hosts); crew chat passes a closure that opens the
    /// task-dispatch sheet. Default nil → no button (all other hosts).
    var onTask: (() -> Void)? = nil

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
                if showsAttachments {
                Button {
                    Haptics.tap()
                    // Scope the action-sheet animation to a withAnimation
                    // block so it doesn't bleed into the keyboard's frame
                    // change. The keyboard goes via UIKit's resignFirstResponder
                    // / becomeFirstResponder path and animates with the system's
                    // native curve; if isFocused were toggled inside withAnimation
                    // it'd retime to easeInOut(0.22) and look like a slow fall.
                    if showActions {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            showActions = false
                        }
                        isFocused = true
                    } else {
                        isFocused = false
                        withAnimation(.easeInOut(duration: 0.22)) {
                            showActions = true
                        }
                    }
                } label: {
                    Image(systemName: showActions ? "xmark" : "plus")
                        .font(Theme.Fonts.glyph(size: 18, weight: .medium))
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .frame(width: 38, height: 38)
                        .floatingComposerSurface(shape: Circle())
                }
                .buttonStyle(.plain)
                }

                if let onTask {
                    Button {
                        Haptics.tap()
                        onTask()
                    } label: {
                        Image(systemName: "terminal")
                            .font(Theme.Fonts.glyph(size: 17, weight: .medium))
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .frame(width: 38, height: 38)
                            .floatingComposerSurface(shape: Circle())
                    }
                    .buttonStyle(.plain)
                }

                HStack(alignment: .bottom, spacing: 6) {
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
                        if focused {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                showActions = false
                            }
                        }
                    }
                    .padding(.leading, 14)
                    .padding(.vertical, 4)

                    Button(action: { isStreaming ? onStop() : onSend() }) {
                        Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                            .font(Theme.Fonts.glyph(size: isStreaming ? 12 : 15, weight: .bold))
                            // Subtle SF Symbol "fly up & replace" when the
                            // arrow morphs into the stop glyph (and back) —
                            // the old symbol lifts up and out, the new one
                            // rises in. Reads as "sent" without being flashy.
                            // Needs the stable accessory host (see
                            // ChatComposerAccessory.swift) to actually fire;
                            // a re-created/AnyView root would skip it.
                            .contentTransition(.symbolEffect(.replace.upUp))
                            .foregroundStyle(
                                isStreaming || canSend
                                    ? .white
                                    : Theme.Palette.inkMuted.opacity(0.5)
                            )
                            .frame(width: 30, height: 30)
                            .background(
                                Circle().fill(
                                    isStreaming || canSend
                                        ? Theme.Palette.accent
                                        : Theme.Palette.surfaceMuted
                                )
                            )
                            // Short ease on color so the gray↔accent flip
                            // when canSend toggles isn't a hard cut. Kept
                            // brief so it never feels laggy after the user
                            // types the first character.
                            .animation(.easeInOut(duration: 0.18), value: canSend)
                            .animation(.easeInOut(duration: 0.18), value: isStreaming)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isStreaming && !canSend)
                    .padding(.trailing, 6)
                    .padding(.bottom, 4)
                }
                .floatingComposerSurface(
                    shape: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
            }
            .padding(.horizontal, Theme.Metrics.gutter)
            .padding(.top, 8)
            // Visual clearance between the capsule and the bar's bottom
            // edge. The home-indicator / keyboard-top safe-area gap is added
            // by the inputAccessoryView container, so this is purely the
            // breathing room above that.
            .padding(.bottom, 12)

            if showActions && showsAttachments {
                ChatActionSheet(
                    onPickPhoto: { showPhotoPicker = true },
                    onPickCamera: { showCamera = true },
                    onPickFile: { showFileImporter = true },
                    onDismiss: { showActions = false },
                    onLookback: onLookback
                )
                .frame(height: 240)
                .background(Theme.Palette.canvas)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // No SwiftUI background here in either state. Both backstops live in
        // the accessory container (ComposerBarContainerView): the progressive
        // blur when docked, a solid canvas when the "+" panel is open. They're
        // painted in UIKit so they reach the home-indicator strip — a SwiftUI
        // `.background` can't, since the hosted content sizes to itself above
        // the strip and the accessory's hosting controller never hands SwiftUI
        // the bottom safe area, so `.ignoresSafeArea(.bottom)` gets no frame
        // down there. The panel's own tiles (ChatActionSheet) and the pending
        // tray still carry their own opaque canvas fills.
        // No outer `.animation(..., value: showActions)` modifier — the
        // showActions toggles are wrapped in withAnimation at their call
        // sites instead, so the keyboard's frame change (driven by
        // resign/becomeFirstResponder, not by showActions) is not retimed
        // to SwiftUI's curve and keeps UIKit's native open/close cadence.
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
                            .overlay(pendingUploadOverlay(att))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
                            )
                        Button {
                            pending.removeAll { $0.id == att.id }
                            Haptics.tap()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(Theme.Fonts.body)
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
            if let data = att.localPreviewData, let image = PlatformImage.decode(data) {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if let remoteId = att.uploadedAttachmentId {
                ServerImage(
                    path: "/v1/uploads/\(remoteId)",
                    serverURL: URL(string: "https://placeholder.invalid")!, // PENDINGCREW SHIM: HostedConfig not available; ServerImage shim ignores serverURL
                    contentMode: .fill
                )
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .font(Theme.Fonts.glyph(size: 22))
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
        } else {
            VStack(spacing: 3) {
                Image(systemName: "doc.fill")
                    .font(Theme.Fonts.glyph(size: 20))
                    .foregroundStyle(Theme.Palette.accent)
                Text(att.filename ?? "文件")
                    .font(Theme.Fonts.system(size: 9))
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func pendingUploadOverlay(_ att: PendingAttachment) -> some View {
        switch att.uploadState {
        case .uploaded:
            EmptyView()
        case .uploading:
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.black.opacity(0.35))
                VStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("上传中")
                        .font(Theme.Fonts.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        case .failed:
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.black.opacity(0.48))
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.Fonts.glyph(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("上传失败")
                        .font(Theme.Fonts.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
    }
}

// ── Floating surface backing ───────────────────────────────────────────────

/// Pure-white pill / circle with a barely-there drop shadow, used as the
/// background for both the "+" button and the input capsule. On iOS 26 we
/// upgrade to Liquid Glass via `.glassEffect`, which adds depth-aware
/// refraction on top of the same white tint and softer shadow.
private extension View {
    @ViewBuilder
    func floatingComposerSurface<S: InsettableShape>(shape: S) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self
                .background(shape.fill(Theme.Palette.surface))
                .glassEffect(.regular, in: shape)
                .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 1)
        } else {
            self
                .background(shape.fill(Theme.Palette.surface))
                .overlay(shape.strokeBorder(Color.black.opacity(0.04), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 2)
        }
    }
}

// ── Progressive blur backdrop ──────────────────────────────────────────────

/// Soft top-to-bottom blur sitting behind the floating composer. Messages
/// scrolling underneath fade from fully visible at the top edge of the
/// inset region to fully blurred down past the home indicator. A single
/// `UIVisualEffectView` with a `CAGradientLayer` mask: the gradient runs
/// from clear → opaque downwards, so the blur layer is invisible at the
/// top and fully revealed at the bottom.
///
/// Earlier draft stacked 4 layered blurs of increasing strength to fake a
/// variable-radius Gaussian, but the visual outcome wasn't worth the
/// complexity — the single masked blur reads as a clean reveal here.
///
/// Used directly (as a UIView) by ComposerBarContainerView, which pins it to
/// the full accessory bounds so it covers the home-indicator strip — see
/// ChatComposerAccessory.swift.
#if os(iOS)
final class ProgressiveBlurBackdropView: UIView {
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let gradient = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        addSubview(blur)
        blur.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // Multi-stop gradient gives a softer ramp than a 0→1 linear; the
        // 0.0/0.35/0.7/1.0 stops with eased alpha hide the seam where the
        // mask first reveals the blur layer.
        gradient.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.15).cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor,
            UIColor.black.withAlphaComponent(1).cgColor,
        ]
        gradient.locations = [0.0, 0.35, 0.7, 1.0]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        blur.layer.mask = gradient
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Disable implicit CALayer animation — the gradient mask should
        // snap to new bounds during keyboard/inset frame changes, not
        // animate independently from UIKit's transition.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = blur.bounds
        CATransaction.commit()
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
        context.coordinator.requestedFocus = isFocused
        if uiView.text != text {
            uiView.text = text
            context.coordinator.refreshPlaceholder(uiView)
            context.coordinator.invalidateHeight(uiView)
        }
        // Sync focus state both ways: SwiftUI → UIKit.
        if isFocused, !uiView.isFirstResponder {
            DispatchQueue.main.async { [weak coordinator = context.coordinator, weak uiView] in
                guard coordinator?.requestedFocus == true, let uiView, !uiView.isFirstResponder else { return }
                uiView.becomeFirstResponder()
            }
        } else if !isFocused, uiView.isFirstResponder {
            DispatchQueue.main.async { [weak coordinator = context.coordinator, weak uiView] in
                guard coordinator?.requestedFocus == false, let uiView, uiView.isFirstResponder else { return }
                uiView.resignFirstResponder()
            }
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
        var requestedFocus = false

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
#elseif os(macOS)

// ── Composer text input (macOS twin) ───────────────────────────────────────

/// Plain SwiftUI multiline input standing in for the UIKit-backed
/// `ComposerTextField` on macOS. No keyboard-frame tracking or hardware-
/// Return interception here — the Mac composer is hosted via a normal
/// `.safeAreaInset` (the ConversationView macOS path), not a UIKit
/// `inputAccessoryView`, so the elaborate first-responder/height dance the
/// iOS version performs isn't needed. Same init signature so `ComposerView`'s
/// body compiles unchanged; `onHardwareReturn` is wired to the Return key via
/// `.onSubmit`, and the vertical-axis `TextField` grows 1–6 lines like the
/// iOS version (⌥/⇧+Return inserts a newline).
struct ComposerTextField: View {
    @Binding var text: String
    let placeholder: String
    @Binding var isFocused: Bool
    let onHardwareReturn: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: Theme.Fonts.scaled(16)))
                    .foregroundStyle(Theme.Palette.inkMuted.opacity(0.6))
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.Fonts.scaled(16)))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(1...6)
                .padding(.vertical, 6)
                .focused($fieldFocused)
                .onSubmit(onHardwareReturn)
        }
        .onChange(of: isFocused) { _, want in
            if fieldFocused != want { fieldFocused = want }
        }
        .onChange(of: fieldFocused) { _, focused in
            if isFocused != focused { isFocused = focused }
        }
    }
}
#endif
