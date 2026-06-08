import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Trailing swipe-to-reveal action buttons for a row.
///
/// SwiftUI's built-in `.swipeActions` only lights up inside `List`. The tabs
/// in this app use `LazyVStack` (so we can keep the rounded card chrome) and
/// therefore need their own implementation. The card itself never fades —
/// the round action buttons emerge from behind the trailing edge with a
/// staggered spring as the user drags.
///
/// Optionally accepts a `leadingTrigger` — a right-swipe gesture that fires
/// a single callback the moment the user releases past a threshold. The
/// drag plays a ratcheting haptic (light → heavy) and a "click" the instant
/// it crosses the trigger line, mimicking pulling a hanging-light cord to
/// the stop. There is no static reveal state for the leading edge: it's
/// drag-and-go.
struct SwipeRevealAction: Identifiable {
    let id = UUID()
    let systemImage: String
    let tint: Color
    let action: () -> Void
}

/// Right-swipe-to-fire gesture. Shown behind the leading edge of the card
/// during the drag; fires `action` when the user releases past the trigger
/// line. `tint` colors the icon + label; `label` is the chip text shown
/// under the icon.
struct SwipeLeadingTrigger {
    let systemImage: String
    let label: String
    let armedLabel: String
    let tint: Color
    let action: () -> Void
}

struct SwipeRevealRow<Content: View>: View {
    let actions: [SwipeRevealAction]
    let leadingTrigger: SwipeLeadingTrigger?
    /// Fired by a genuine tap on the card (row not swiped open). The row
    /// content is purely visual — navigation MUST go through here, never
    /// through a NavigationLink/Button embedded in `content`: those fire
    /// on touch-up even when the touch travelled sideways (a swipe stays
    /// inside the row's bounds so the button never cancels itself), which
    /// is exactly the "swiping opens the conversation" bug. A TapGesture
    /// is cancelled by the drag, so routing the tap here keeps the two
    /// interactions cleanly separate.
    let onTap: (() -> Void)?
    let content: () -> Content

    init(
        actions: [SwipeRevealAction],
        leadingTrigger: SwipeLeadingTrigger? = nil,
        onTap: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.actions = actions
        self.leadingTrigger = leadingTrigger
        self.onTap = onTap
        self.content = content
    }

    private let buttonSize: CGFloat = 48
    private let buttonGap: CGFloat = 12
    private let edgePadding: CGFloat = 14
    /// Drag distance past which a release commits the leading-trigger
    /// action. Sized so the user has to make a deliberate pull — short
    /// enough to feel light, long enough that an accidental horizontal
    /// scroll won't fire it.
    private let leadingTriggerWidth: CGFloat = 96
    /// Spacing between successive ratcheting haptic ticks during the
    /// leading drag — every `tickStride` pt advanced fires one click.
    private let tickStride: CGFloat = 9
    /// Keep the per-row drag recognizer out of the way of fast vertical
    /// flicks. Quick list scrolls often carry 10-25pt of incidental X
    /// motion before UIScrollView settles into its pan; starting the row
    /// swipe in that band makes the list feel randomly inert.
    private let horizontalSwipeMinimumDistance: CGFloat = 32
    private let horizontalDominanceRatio: CGFloat = 1.35

    private var actionsWidth: CGFloat {
        let n = CGFloat(actions.count)
        return n * buttonSize + max(0, n - 1) * buttonGap + edgePadding * 2
    }

    @State private var settled: CGFloat = 0
    @State private var dragDX: CGFloat = 0
    @State private var lockedToHorizontal = false
    @State private var lastTickDX: CGFloat = 0
    @State private var didArm: Bool = false

    private var rawOffset: CGFloat { settled + dragDX }
    /// Card offset including the leading-trigger rubber band. Past the
    /// trigger line the card resists further travel — sqrt-easing the
    /// excess gives the same "rope under tension" feel UIScrollView uses
    /// for its bounce.
    private var clampedOffset: CGFloat {
        let raw = rawOffset
        if raw <= 0 {
            return max(-actionsWidth, raw)
        }
        // Leading lane is only available when the row isn't already in a
        // trailing-revealed state — otherwise a right-drag after an open
        // would visually overshoot AND threaten to fire the trigger.
        guard leadingTrigger != nil, settled == 0 else { return 0 }
        if raw <= leadingTriggerWidth { return raw }
        let excess = raw - leadingTriggerWidth
        return leadingTriggerWidth + (sqrt(excess + 1) - 1) * 6
    }
    private var revealProgress: CGFloat {
        guard actionsWidth > 0 else { return 0 }
        return min(1, max(0, -clampedOffset / actionsWidth))
    }
    private var leadingProgress: CGFloat {
        guard leadingTrigger != nil else { return 0 }
        return min(1, max(0, clampedOffset / leadingTriggerWidth))
    }
    private var isOpen: Bool { settled <= -actionsWidth + 0.5 }

    var body: some View {
        ZStack(alignment: .trailing) {
            actionStack
            if leadingTrigger != nil {
                leadingTriggerLane
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            content()
                .offset(x: clampedOffset)
                .contentShape(Rectangle())
        }
        .contentShape(Rectangle())
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
        // Tap is its own gesture so the DragGesture can keep a generous
        // minimumDistance. The threshold must be high enough that SwiftUI's
        // arbiter doesn't hold the single-touch sequence pending while
        // waiting for our drag to confirm — anything near the ScrollView
        // pan threshold starves UIScrollView's single-touch pan and the
        // list only scrolls under a 2-finger pan (which routes through
        // UIScrollView's 2-touch path, bypassing SwiftUI's per-row pending
        // drag). Keep this above the incidental horizontal travel produced
        // by a quick vertical flick.
        .onTapGesture {
            if isOpen { close() } else { onTap?() }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: horizontalSwipeMinimumDistance)
                .onChanged { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    if !lockedToHorizontal {
                        // Only commit to a horizontal swipe once the finger
                        // has moved clearly sideways and is materially more
                        // horizontal than vertical. A mere dx > dy test is
                        // too twitchy for fast list flicks, where the first
                        // coalesced sample can be slightly diagonal.
                        let absDX = abs(dx)
                        let absDY = abs(dy)
                        guard absDX >= horizontalSwipeMinimumDistance,
                              absDX > absDY * horizontalDominanceRatio
                        else { return }
                        lockedToHorizontal = true
                        lastTickDX = 0
                        didArm = false
                    }
                    dragDX = dx
                    if leadingTrigger != nil && settled == 0 && rawOffset > 0 {
                        emitLeadingHapticsIfNeeded()
                    }
                }
                .onEnded { value in
                    let dx = value.translation.width
                    defer {
                        lockedToHorizontal = false
                        lastTickDX = 0
                        didArm = false
                    }
                    guard lockedToHorizontal else {
                        dragDX = 0
                        return
                    }
                    let velocity = value.predictedEndTranslation.width - dx
                    // Right-swipe: commit the leading trigger if the user
                    // released past the trigger line OR flicked past a
                    // velocity threshold (so a fast snappy pull also fires).
                    if let trigger = leadingTrigger,
                       settled == 0,
                       rawOffset > 0,
                       (rawOffset >= leadingTriggerWidth || velocity > 600) {
                        Haptics.success()
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                            dragDX = 0
                            settled = 0
                        }
                        trigger.action()
                        return
                    }
                    let shouldOpen: Bool = isOpen
                        ? !(dx > buttonSize * 0.5 || velocity > 200)
                        : (-dx > buttonSize * 0.5 || velocity < -200)
                    // Right-swipe that didn't reach the trigger — pair the
                    // spring snap-back with a soft "thud" so the cancel
                    // *feels* like a rubber band releasing, not a silent
                    // glide back.
                    if leadingTrigger != nil, settled == 0, rawOffset > 0 {
                        #if os(iOS)
                        UIImpactFeedbackGenerator(style: .soft)
                            .impactOccurred(intensity: 0.7)
                        #endif
                    }
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                        dragDX = 0
                        settled = shouldOpen ? -actionsWidth : 0
                    }
                }
        )
    }

    // ── Leading-trigger UI + haptics ────────────────────────────────────────

    @ViewBuilder
    private var leadingTriggerLane: some View {
        if let trigger = leadingTrigger {
            let armed = leadingProgress >= 0.999
            HStack(spacing: 8) {
                Image(systemName: trigger.systemImage)
                    .font(Theme.Fonts.glyph(size: armed ? 18 : 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(trigger.tint))
                    .scaleEffect(0.6 + leadingProgress * 0.5)
                    .shadow(color: trigger.tint.opacity(0.25 * leadingProgress),
                            radius: 6, y: 2)
                Text(armed ? trigger.armedLabel : trigger.label)
                    .font(Theme.Fonts.rounded(size: 12, weight: .semibold))
                    .foregroundStyle(trigger.tint)
                    .opacity(min(1, leadingProgress * 2))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.leading, 14)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: armed)
        }
    }

    /// Two-stage haptic: ratcheting clicks every `tickStride` pt during the
    /// drag (intensity ramps with progress, like dragging a stiffening
    /// spring), then a single rigid "stop" the moment the trigger arms —
    /// the lamp-cord click that tells the user "let go now."
    private func emitLeadingHapticsIfNeeded() {
        #if os(iOS)
        let dx = max(0, dragDX)
        // Ratcheting ticks while approaching the trigger.
        if dx < leadingTriggerWidth, dx - lastTickDX >= tickStride {
            let intensity = 0.25 + leadingProgress * 0.55
            let style: UIImpactFeedbackGenerator.FeedbackStyle =
                leadingProgress < 0.5 ? .light : .soft
            UIImpactFeedbackGenerator(style: style)
                .impactOccurred(intensity: intensity)
            lastTickDX = dx
        }
        // Hard click the instant we cross the trigger line.
        if !didArm, dx >= leadingTriggerWidth {
            didArm = true
            UIImpactFeedbackGenerator(style: .rigid)
                .impactOccurred(intensity: 1.0)
        }
        // If the user pulls back before releasing, re-arm so they can
        // hear the click again the next time they cross the line.
        if didArm, dx < leadingTriggerWidth - tickStride {
            didArm = false
            lastTickDX = dx
        }
        #endif
    }

    private var actionStack: some View {
        HStack(spacing: buttonGap) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { idx, action in
                let appearance = appearance(forIndex: idx)
                Button {
                    Haptics.tap()
                    action.action()
                    close()
                } label: {
                    // Native Liquid Glass disc on iOS 26 (interactive so it
                    // reacts to the press), with a thin material fallback on
                    // older systems. Icon stays in the action's tint. The
                    // shadow's alpha rides `appearance` so it fades in
                    // alongside the staggered reveal — no shadow trailing
                    // the disc before the disc itself is visible.
                    Image(systemName: action.systemImage)
                        .font(Theme.Fonts.glyph(size: 19, weight: .semibold))
                        .foregroundStyle(action.tint)
                        .frame(width: buttonSize, height: buttonSize)
                        .glassDisc()
                        .shadow(color: Color.black.opacity(0.07 * appearance), radius: 4, y: 1)
                }
                .buttonStyle(.plain)
                .scaleEffect(appearance)
                .opacity(appearance)
            }
        }
        .padding(.horizontal, edgePadding)
        .frame(width: actionsWidth)
    }

    /// 0 → hidden, 1 → fully visible. Each button gets its own slice of the
    /// reveal so they pop in with a slight stagger as the drag deepens.
    private func appearance(forIndex idx: Int) -> CGFloat {
        let n = max(1, actions.count)
        // First button starts revealing earlier than the next one.
        let start = CGFloat(n - 1 - idx) / CGFloat(n) * 0.55
        let end = start + 0.6
        return min(1, max(0, (revealProgress - start) / (end - start)))
    }

    private func close() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            settled = 0
            dragDX = 0
        }
    }
}

private extension View {
    @ViewBuilder
    func glassDisc() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Circle())
        } else {
            self
                .background(Circle().fill(.thinMaterial))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
}
