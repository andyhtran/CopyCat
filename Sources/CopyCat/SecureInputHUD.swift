import AppKit
import SwiftUI

// Floating toast for Secure Input alerts. A notification banner alone is easy
// to miss (Focus modes, banner timeout); this panel is unmissable at alert
// time, then collapses to a small pill that stays up for the whole episode —
// so a paste attempt minutes later still lands next to a visible explanation.
//
// Lifecycle: showBlocked → expanded card (auto-collapses to pill) →
// showRestored (brief green confirmation) → hidden. Dismiss hides the panel
// for the rest of the episode; the paste-attempt sensor can resurface it.
@MainActor
final class SecureInputHUD {
    static let shared = SecureInputHUD()

    enum Phase: Equatable {
        case hidden
        case expanded
        case pill
        /// Degraded paste in flight: the sensor caught ⌘V and CopyCat is
        /// typing the path despite Secure Input. Brief, then back to the pill.
        case attempting
        case restored
    }

    final class Model: ObservableObject {
        @Published var phase: Phase = .hidden
        @Published var presentation: SecureInputPresentation?
        // Wired by the HUD so the SwiftUI views can drive panel-level behavior
        // (resize + phase changes) without owning the panel.
        var onExpandRequested: (() -> Void)?
        var onDismissRequested: (() -> Void)?
    }

    private let model = Model()
    private var panel: NSPanel?
    private var hosting: NSHostingView<HUDRoot>?
    private var collapseTimer: Timer?
    private var hideTimer: Timer?

    private static let collapseAfter: TimeInterval = 10
    private static let restoredVisibleFor: TimeInterval = 2.5
    private static let attemptVisibleFor: TimeInterval = 3

    private init() {
        model.onExpandRequested = { [weak self] in self?.expand() }
        model.onDismissRequested = { [weak self] in self?.dismissEpisode() }
    }

    // MARK: - Public surface

    func showBlocked(_ presentation: SecureInputPresentation) {
        model.presentation = presentation
        setPhase(.expanded)
        restartCollapseTimer()
        cancelHideTimer()
    }

    func showRestored() {
        setPhase(.restored)
        cancelCollapseTimer()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: Self.restoredVisibleFor, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    /// Degraded-paste feedback: shows briefly, then settles on the blocked
    /// pill (the episode is still live — only this one paste was attempted).
    func showDegradedAttempt(_ presentation: SecureInputPresentation) {
        model.presentation = presentation
        setPhase(.attempting)
        cancelCollapseTimer()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: Self.attemptVisibleFor, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.phase == .attempting else { return }
                self.setPhase(.pill)
            }
        }
    }

    func hide() {
        cancelCollapseTimer()
        cancelHideTimer()
        setPhase(.hidden)
    }

    // MARK: - Phase transitions

    private func expand() {
        setPhase(.expanded)
        restartCollapseTimer()
    }

    private func dismissEpisode() {
        hide()
    }

    private func restartCollapseTimer() {
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: Self.collapseAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.phase == .expanded else { return }
                self.setPhase(.pill)
            }
        }
    }

    private func cancelCollapseTimer() {
        collapseTimer?.invalidate()
        collapseTimer = nil
    }

    private func cancelHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func setPhase(_ phase: Phase) {
        model.phase = phase
        if phase == .hidden {
            panel?.orderOut(nil)
            return
        }
        ensurePanel()
        // SwiftUI applies the published change on the next runloop turn, so
        // measure and place the panel after that turn or fittingSize is stale.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.layoutAndShow()
            }
        }
    }

    // MARK: - Panel plumbing

    private func ensurePanel() {
        guard panel == nil else { return }
        let hosting = NSHostingView(rootView: HUDRoot(model: model))
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
    }

    private func layoutAndShow() {
        guard model.phase != .hidden, let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0, let screen = NSScreen.main else { return }
        // Top-center, just under the menu bar: adjacent to the menu-bar icon
        // that carries the persistent badge, and clear of the top-right corner
        // where notification banners land.
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 10)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }
}

// MARK: - SwiftUI content

private struct HUDRoot: View {
    @ObservedObject var model: SecureInputHUD.Model

    var body: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .expanded:
            if let presentation = model.presentation {
                ExpandedCard(presentation: presentation, model: model)
            }
        case .pill:
            if let presentation = model.presentation {
                BlockedPill(presentation: presentation, model: model)
            }
        case .attempting:
            AttemptingPill()
        case .restored:
            RestoredPill()
        }
    }
}

private struct ExpandedCard: View {
    let presentation: SecureInputPresentation
    @ObservedObject var model: SecureInputHUD.Model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 5) {
                Text(presentation.title)
                    .font(.headline)
                // Advice only — the full cause (presentation.detail) lives in
                // the notification, menu, and log; the toast stays scannable.
                Text(presentation.advice)
                    .font(.callout)
                HStack(spacing: 8) {
                    if let action = presentation.action {
                        Button(action.label) {
                            SecureInputActions.perform(action)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    Button("Dismiss") {
                        model.onDismissRequested?()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 3)
            }
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

private struct BlockedPill: View {
    let presentation: SecureInputPresentation
    @ObservedObject var model: SecureInputHUD.Model

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.orange)
            Text("\(HotkeyBinding.localPaste.displayString) blocked (\(presentation.pillLabel))")
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture {
            model.onExpandRequested?()
        }
    }
}

private struct AttemptingPill: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(.orange)
            Text("\(HotkeyBinding.localPaste.displayString) caught — pasting anyway (experimental)")
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
    }
}

private struct RestoredPill: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text("\(HotkeyBinding.localPaste.displayString) restored — Secure Input cleared")
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
    }
}
