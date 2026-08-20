#if os(iOS)
import SwiftUI
import UIKit
import PhotosUI

// Mounts the chat composer (plus the banners that sit above it) as a UIKit
// `inputAccessoryView` instead of a SwiftUI `.safeAreaInset(edge: .bottom)`.
//
// Why: with `.safeAreaInset`, the composer follows the keyboard via SwiftUI's
// keyboard avoidance, which steps along an animation curve. The message list's
// `.scrollDismissesKeyboard(.interactively)` moves the keyboard frame-by-frame
// as the finger drags, so the two desync — the bar lags the finger, jerks, and
// briefly overlaps on release. An `inputAccessoryView` is physically attached
// to the keyboard, so it tracks the interactive drag perfectly (iMessage /
// WeChat behaviour).
//
// Structure:
//   • AccessoryOwnerController is a permanent first responder. Its
//     `inputAccessoryView` is the bar, so the bar stays docked above the home
//     indicator even when no keyboard is up. When the text view inside the bar
//     becomes first responder the keyboard rises and the bar rides on top
//     (the text view is a descendant of the accessory, so iOS keeps them
//     glued); when it resigns we re-grab first responder to keep the bar.
//   • ComposerBarContainerView self-sizes to the hosted SwiftUI content so the
//     "+" panel / attachment tray / @-mention picker grow the bar.
//   • The SwiftUI message list keeps its automatic keyboard avoidance — iOS
//     reports the accessory as part of the keyboard frame, so the list insets
//     correctly in both docked and raised states.
//
// State note: this view holds NO @State of its own — every value/binding/
// closure is threaded in from ConversationView.body where the real @State
// lives, because @State/@Environment do not cross the hosting-controller
// boundary. Bindings and closures (get/set + capture of `self`) do cross
// cleanly, which is why ConversationView keeps owning the state.

// MARK: - SwiftUI content

/// The bottom stack rendered inside the accessory: optional banners above the
/// composer row. Mirrors the exact ordering the old `.safeAreaInset` block had.
struct ComposerAccessoryContent: View {
    @Binding var input: String
    @Binding var pendingAttachments: [PendingAttachment]
    @Binding var photoPickerItems: [PhotosPickerItem]
    @Binding var cameraImage: UIImage?
    @Binding var showFileImporter: Bool
    @Binding var showPhotoPicker: Bool
    @Binding var showCamera: Bool

    let pendingContinue: ConversationView.PendingContinue?
    let continueDeciding: Bool
    let conversationType: String
    let mentionActive: Bool
    let mentionCandidates: [GroupBubbleSender]
    let canSend: Bool
    let isStreaming: Bool

    let onSend: () -> Void
    let onStop: () -> Void
    let onLookback: (() -> Void)?
    let onGuessModel: (() -> Void)?
    let onSwitchModel: (() -> Void)?
    let onInsertMention: (GroupBubbleSender) -> Void
    let onDecideContinue: (ConversationView.PendingContinue, Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let pc = pendingContinue {
                ContinueRequestBannerView(pc: pc, deciding: continueDeciding, onDecide: onDecideContinue)
                    .readableColumnWidth()
            }
            if conversationType == "group", mentionActive, !mentionCandidates.isEmpty {
                MentionPickerView(candidates: mentionCandidates, onPick: onInsertMention)
                    .readableColumnWidth()
            }
            ComposerView(
                input: $input,
                pending: $pendingAttachments,
                photoItems: $photoPickerItems,
                cameraImage: $cameraImage,
                showFileImporter: $showFileImporter,
                showPhotoPicker: $showPhotoPicker,
                showCamera: $showCamera,
                canSend: canSend,
                onSend: onSend,
                isStreaming: isStreaming,
                onStop: onStop,
                onLookback: onLookback,
                onGuessModel: onGuessModel,
                onSwitchModel: onSwitchModel
            )
            .readableColumnWidth()
        }
    }
}

// MARK: - Banners (parameterized copies of the old ConversationView+Group
// view-builders, which read @State directly and so couldn't cross the
// hosting boundary).

private struct ContinueRequestBannerView: View {
    let pc: ConversationView.PendingContinue
    let deciding: Bool
    let onDecide: (ConversationView.PendingContinue, Bool) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("机器人还有话想说,让它继续吗?")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if deciding {
                ProgressView()
            } else {
                Button {
                    onDecide(pc, false)
                } label: {
                    Text("✕ 闭嘴")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
                Button {
                    onDecide(pc, true)
                } label: {
                    Text("✓ 继续")
                        .font(Theme.Fonts.body)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.vertical, 10)
        .background(Theme.Palette.surface)
    }
}

private struct MentionPickerView: View {
    let candidates: [GroupBubbleSender]
    let onPick: (GroupBubbleSender) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(candidates, id: \.id) { sender in
                Button {
                    onPick(sender)
                } label: {
                    HStack(spacing: 10) {
                        switch sender.kind {
                        case .bot:
                            BotAvatar(emojiSeed: sender.id, colorSeed: sender.id, size: 24)
                        case .user:
                            UserAvatar(seed: sender.avatarSeed, attachmentId: sender.avatarPath, size: 24)
                        }
                        Text(sender.displayName)
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Theme.Palette.ink)
                        Spacer()
                        if sender.kind == .bot {
                            Text("机器人")
                                .font(Theme.Fonts.rounded(size: 10, weight: .medium))
                                .foregroundStyle(Theme.Palette.inkMuted)
                        }
                    }
                    .padding(.horizontal, Theme.Metrics.gutter)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().opacity(0.4)
            }
        }
        .background(Theme.Palette.surface)
        .overlay(
            Rectangle().frame(height: 0.5).foregroundStyle(Theme.Palette.hairline),
            alignment: .top
        )
    }
}

// MARK: - Live values bridge

/// Holds the current composer values/bindings/closures. The hosting
/// controller's root view (`ComposerAccessoryRoot`) is created ONCE and
/// observes this model; ConversationView pushes fresh values in on each render
/// by mutating the model and bumping `revision`.
///
/// Why not just reassign the hosting controller's `rootView` every render?
/// Because that (especially wrapped in `AnyView`) defeats SwiftUI's view-
/// identity diffing, so implicit animations like the send button's
/// `.animation(.easeInOut, value: canSend)` / `value: isStreaming` never fire
/// — the button snaps instead of morphing. A stable root + observed model
/// keeps the identity intact so those animations work.
final class ComposerAccessoryModel: ObservableObject {
    /// Bumped on every push so the stable root re-renders with the latest
    /// (non-@Published) bindings/values/closures below.
    @Published var revision = 0

    var input: Binding<String> = .constant("")
    var pendingAttachments: Binding<[PendingAttachment]> = .constant([])
    var photoPickerItems: Binding<[PhotosPickerItem]> = .constant([])
    var cameraImage: Binding<UIImage?> = .constant(nil)
    var showFileImporter: Binding<Bool> = .constant(false)
    var showPhotoPicker: Binding<Bool> = .constant(false)
    var showCamera: Binding<Bool> = .constant(false)
    var pendingContinue: ConversationView.PendingContinue?
    var continueDeciding = false
    var conversationType = ""
    var mentionActive = false
    var mentionCandidates: [GroupBubbleSender] = []
    var canSend = false
    var isStreaming = false
    var onSend: () -> Void = {}
    var onStop: () -> Void = {}
    var onLookback: (() -> Void)?
    var onGuessModel: (() -> Void)?
    var onSwitchModel: (() -> Void)?
    var onInsertMention: (GroupBubbleSender) -> Void = { _ in }
    var onDecideContinue: (ConversationView.PendingContinue, Bool) -> Void = { _, _ in }

    /// Copy the freshly-built content's fields in, then trigger one re-render.
    func push(_ c: ComposerAccessoryContent) {
        input = c.$input
        pendingAttachments = c.$pendingAttachments
        photoPickerItems = c.$photoPickerItems
        cameraImage = c.$cameraImage
        showFileImporter = c.$showFileImporter
        showPhotoPicker = c.$showPhotoPicker
        showCamera = c.$showCamera
        pendingContinue = c.pendingContinue
        continueDeciding = c.continueDeciding
        conversationType = c.conversationType
        mentionActive = c.mentionActive
        mentionCandidates = c.mentionCandidates
        canSend = c.canSend
        isStreaming = c.isStreaming
        onSend = c.onSend
        onStop = c.onStop
        onLookback = c.onLookback
        onGuessModel = c.onGuessModel
        onSwitchModel = c.onSwitchModel
        onInsertMention = c.onInsertMention
        onDecideContinue = c.onDecideContinue
        revision += 1
    }
}

/// Stable root hosted in the accessory's UIHostingController. Created once;
/// rebuilds `ComposerAccessoryContent` from the observed model on each
/// `revision` bump while keeping its SwiftUI identity (so child animations fire).
struct ComposerAccessoryRoot: View {
    @ObservedObject var model: ComposerAccessoryModel

    var body: some View {
        // Subscribe to revision so a push re-renders us. (The other fields are
        // plain, not @Published — they're read fresh here each time.)
        let _ = model.revision
        return ComposerAccessoryContent(
            input: model.input,
            pendingAttachments: model.pendingAttachments,
            photoPickerItems: model.photoPickerItems,
            cameraImage: model.cameraImage,
            showFileImporter: model.showFileImporter,
            showPhotoPicker: model.showPhotoPicker,
            showCamera: model.showCamera,
            pendingContinue: model.pendingContinue,
            continueDeciding: model.continueDeciding,
            conversationType: model.conversationType,
            mentionActive: model.mentionActive,
            mentionCandidates: model.mentionCandidates,
            canSend: model.canSend,
            isStreaming: model.isStreaming,
            onSend: model.onSend,
            onStop: model.onStop,
            onLookback: model.onLookback,
            onGuessModel: model.onGuessModel,
            onSwitchModel: model.onSwitchModel,
            onInsertMention: model.onInsertMention,
            onDecideContinue: model.onDecideContinue
        )
    }
}

// MARK: - UIKit bridge

/// Installs the first-responder owner that vends the composer as an
/// `inputAccessoryView`. Its own view is inert (zero-impact, non-interactive);
/// the visible bar is the separate accessory.
struct ChatComposerAccessory: UIViewControllerRepresentable {
    /// Freshly built by ConversationView.body each render. We don't host this
    /// directly — we copy its fields into the controller's stable model (see
    /// ComposerAccessoryModel) so SwiftUI keeps the hosted view's identity.
    let content: ComposerAccessoryContent

    /// Reports the composer's measured content height (excluding the bottom
    /// safe-area strip) back to ConversationView, so the message list can
    /// reserve that much bottom inset while the keyboard is down — otherwise
    /// the floating accessory covers the last message. Updated as the bar
    /// grows (attachment tray / "+" panel / multi-line text).
    let composerHeight: Binding<CGFloat>

    /// Whether the software keyboard is up — used to fade out the progressive
    /// blur backdrop (it reads as a weird shadow over the keyboard).
    let keyboardVisible: Bool

    func makeUIViewController(context: Context) -> AccessoryOwnerController {
        AccessoryOwnerController()
    }

    func updateUIViewController(_ uiViewController: AccessoryOwnerController, context: Context) {
        let sink = composerHeight
        uiViewController.composerHeightSink = { h in
            // Hop off the layout pass before mutating SwiftUI state.
            DispatchQueue.main.async {
                if abs(sink.wrappedValue - h) > 0.5 { sink.wrappedValue = h }
            }
        }
        uiViewController.setKeyboardVisible(keyboardVisible)
        uiViewController.push(content)
    }

    static func dismantleUIViewController(_ uiViewController: AccessoryOwnerController, coordinator: ()) {
        uiViewController.tearDown()
    }
}

final class AccessoryOwnerController: UIViewController {
    private let model = ComposerAccessoryModel()
    private lazy var host = UIHostingController(rootView: ComposerAccessoryRoot(model: model))
    private lazy var barContainer = ComposerBarContainerView(host: host)
    private var isTearingDown = false
    private var observingKeyboardHide = false

    /// Set by the representable; receives the composer's content height
    /// (excluding the bottom safe-area strip) whenever it changes.
    var composerHeightSink: ((CGFloat) -> Void)?

    override var canBecomeFirstResponder: Bool { !isTearingDown }
    override var inputAccessoryView: UIView? { barContainer }

    override func loadView() {
        let rootView = AccessoryOwnerRootView()
        rootView.backgroundColor = .clear
        rootView.isUserInteractionEnabled = false
        rootView.onMoveToWindow = { [weak self] window in
            guard let self else { return }
            if window != nil {
                self.startKeyboardHideObserver()
                self.dockComposerIfPossible()
            } else {
                self.stopKeyboardHideObserver()
            }
        }
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        host.view.backgroundColor = .clear
        // Lets the hosting view's intrinsicContentSize track the SwiftUI
        // content so the container can self-size when the "+" panel opens.
        host.sizingOptions = [.intrinsicContentSize]
        barContainer.onContentHeight = { [weak self] h in self?.composerHeightSink?(h) }
    }

    /// Push fresh values into the stable root's model (no rootView swap).
    func push(_ content: ComposerAccessoryContent) {
        model.push(content)
        barContainer.contentDidChange()
        dockComposerIfPossible()
    }

    func setKeyboardVisible(_ visible: Bool) {
        barContainer.setKeyboardVisible(visible)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Reset in case the view is returning after a presented sheet/cover
        // (camera, photo picker) temporarily took the screen.
        isTearingDown = false
        startKeyboardHideObserver()
        // Dock the bar BEFORE the screen is visible so it's already in place
        // when the push transition lands. Becoming first responder in
        // viewDidAppear instead makes the bar visibly slide up after arrival.
        dockComposerIfPossible()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Fallback: if the view wasn't yet in the window during viewWillAppear
        // and couldn't take first responder there, grab it now.
        dockComposerIfPossible()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Drop the bar when leaving the screen (navigation pop, or a sheet
        // covering us) so it doesn't linger over whatever comes next.
        stopKeyboardHideObserver()
        resignFirstResponder()
    }

    /// When the text view resigns (interactive dismiss completes, or the "+"
    /// panel opens), first responder would otherwise fall to nil and the bar
    /// would vanish. Re-grab it so the bar stays docked at the bottom.
    @objc private func keyboardWillHide(_ note: Notification) {
        guard !isTearingDown, view.window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isTearingDown, self.view.window != nil else { return }
            self.dockComposerIfPossible()
        }
    }

    func tearDown() {
        isTearingDown = true
        stopKeyboardHideObserver()
        resignFirstResponder()
    }

    private func dockComposerIfPossible() {
        guard !isTearingDown,
              view.window != nil,
              !isFirstResponder,
              !barContainer.containsFirstResponder
        else { return }
        becomeFirstResponder()
    }

    private func startKeyboardHideObserver() {
        guard !observingKeyboardHide else { return }
        observingKeyboardHide = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    private func stopKeyboardHideObserver() {
        guard observingKeyboardHide else { return }
        observingKeyboardHide = false
        NotificationCenter.default.removeObserver(
            self,
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }
}

private final class AccessoryOwnerRootView: UIView {
    var onMoveToWindow: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onMoveToWindow?(window)
    }
}

private extension UIView {
    var containsFirstResponder: Bool {
        if isFirstResponder { return true }
        return subviews.contains { $0.containsFirstResponder }
    }
}

/// Self-sizing container for the accessory. Drives its height from the hosted
/// SwiftUI content plus the bottom safe area (the home-indicator strip when
/// docked; zero when riding the keyboard, which iOS reports automatically).
final class ComposerBarContainerView: UIView {
    private let host: UIViewController
    private let backdrop = ProgressiveBlurBackdropView()
    /// Solid canvas behind the whole bar, shown only while the "+" panel is
    /// open (the progressive blur is hidden then). Pinned to the full container
    /// — including the home-indicator strip — so the panel's opaque backstop
    /// reaches the bottom edge instead of letting messages show through the
    /// strip. The SwiftUI ComposerView can't paint down there itself: its
    /// hosted content sizes above the strip and the accessory's hosting
    /// controller never hands SwiftUI the bottom safe area, so an
    /// `.ignoresSafeArea(.bottom)` background gets no frame in the strip.
    private let canvasBackdrop: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(Theme.Palette.canvas)
        v.isUserInteractionEnabled = false
        v.alpha = 0
        return v
    }()
    private var lastHeight: CGFloat = -1
    private var lastContentHeight: CGFloat = -1
    private var keyboardVisible = false
    private var lastBackdropShown = true
    private var lastCanvasShown = false

    /// Above this content height the bar is showing the "+" panel (240pt).
    /// Used to split the docked state (blur) from the panel state (solid
    /// canvas). Comfortably above the tray / banner heights, below the panel
    /// height.
    private let panelHeightThreshold: CGFloat = 200

    /// Reports the content height (excluding the bottom safe-area strip) when
    /// it changes, so the message list can reserve matching bottom inset.
    var onContentHeight: ((CGFloat) -> Void)?

    init(host: UIViewController) {
        self.host = host
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 56))
        // Required for the inputAccessoryView system to honour
        // intrinsicContentSize as the bar's height.
        autoresizingMask = .flexibleHeight

        // Solid canvas backstop, furthest back. Same full-bar pinning as the
        // blur below — see the property comment for why the strip needs a UIKit
        // layer here rather than a SwiftUI background.
        canvasBackdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(canvasBackdrop)
        NSLayoutConstraint.activate([
            canvasBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvasBackdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvasBackdrop.topAnchor.constraint(equalTo: topAnchor),
            canvasBackdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Progressive blur backdrop pinned to the FULL bar (all four edges,
        // including the home-indicator strip the system reserves below the
        // docked accessory). Painting it here in UIKit — rather than as the
        // SwiftUI ComposerView's `.background` — is what makes it reach the
        // strip: the hosted SwiftUI content sizes to itself and sits above the
        // strip, and the accessory's hosting controller doesn't propagate the
        // bottom safe area to SwiftUI, so a SwiftUI `.ignoresSafeArea(.bottom)`
        // never gets a frame down there. An Auto Layout view pinned to the
        // container edges always covers it. Sits behind the host content,
        // in front of the canvas backstop.
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            // Content sits above the safe-area strip; the strip is added back
            // into intrinsicContentSize so the bar reserves room for it. The
            // backdrop above covers that strip.
            host.view.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func contentDidChange() {
        invalidateIntrinsicContentSize()
    }

    func setKeyboardVisible(_ visible: Bool) {
        guard visible != keyboardVisible else { return }
        keyboardVisible = visible
        refreshBackdrop()
    }

    /// Crossfade the two backstops across three states. Never a hard cut.
    ///   • Docked (keyboard down, panel closed) → blur visible, canvas hidden.
    ///   • Panel open (keyboard down, panel up)  → canvas visible, blur hidden
    ///     (the blur reads as a stray shadow behind the tiles; the solid canvas
    ///     covers the home-indicator strip the panel can't reach itself).
    ///   • Keyboard up → both hidden (either backstop reads as a weird shadow
    ///     over the keyboard).
    private func refreshBackdrop() {
        let panelOpen = contentHeight() > panelHeightThreshold
        let blurShown = !keyboardVisible && !panelOpen
        let canvasShown = !keyboardVisible && panelOpen
        if blurShown != lastBackdropShown {
            lastBackdropShown = blurShown
            UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
                self.backdrop.alpha = blurShown ? 1 : 0
            }
        }
        if canvasShown != lastCanvasShown {
            lastCanvasShown = canvasShown
            UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
                self.canvasBackdrop.alpha = canvasShown ? 1 : 0
            }
        }
    }

    /// Composer content height, excluding the bottom safe-area strip.
    private func contentHeight() -> CGFloat {
        let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        let fitted = host.view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return fitted.height
    }

    private func measuredHeight() -> CGFloat {
        contentHeight() + safeAreaInsets.bottom
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight())
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        invalidateIntrinsicContentSize()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Catch height changes that come from the hosted content itself
        // (e.g. the "+" panel toggling) rather than from setContent. The
        // guard prevents an invalidate→layout→invalidate loop.
        let content = contentHeight()
        let h = content + safeAreaInsets.bottom
        if abs(h - lastHeight) > 0.5 {
            lastHeight = h
            invalidateIntrinsicContentSize()
        }
        if abs(content - lastContentHeight) > 0.5 {
            lastContentHeight = content
            onContentHeight?(content)
        }
        // Panel open/close changes content height — re-evaluate the backdrop.
        refreshBackdrop()
    }
}
#endif
