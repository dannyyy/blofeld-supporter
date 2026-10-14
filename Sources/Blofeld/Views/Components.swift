import SwiftUI

/// A small rounded count chip, e.g. "5 new".
struct CountBadge: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .opacity(0.8)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous).fill(color.opacity(0.14))
        )
    }
}

/// A status dot used in headers and rows.
///
/// Note: deliberately *static* — a `repeatForever` animation here caused the
/// `MenuBarExtra(.window)` panel to flicker open/closed infinitely. `alert`
/// draws a soft static ring instead of pulsing.
struct StatusDot: View {
    let color: Color
    var alert: Bool = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.35), lineWidth: alert ? 3 : 0)
            )
            .padding(alert ? 2 : 0)
    }
}

/// Opens the Settings window and brings the app (an accessory app does not
/// activate itself) to the front so it never opens hidden behind other apps.
struct OpenSettingsButton<Label: View>: View {
    @Environment(\.openSettings) private var openSettings
    @ViewBuilder var label: Label

    var body: some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        } label: {
            label
        }
        .buttonStyle(.plain)
    }
}

/// Brings its hosting window to the front and activates the app when it appears.
/// Used by the Settings window so it is never buried behind other apps.
struct WindowFronter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Keeps the `MenuBarExtra(.window)` host window sized to its content.
///
/// The panel has no fixed height — it sizes to its content. AppKit grows the
/// hosting window when the content grows but never shrinks it back, so when
/// alerting items resolve and disappear the window stays stretched, leaving
/// gray dead-space below the footer. This reaches the hosting window (the same
/// `view.window` trick `WindowFronter` uses) and resizes it to `height`.
///
/// Two details are load-bearing:
/// - **`height` is the SwiftUI-measured panel height**, not the content view's
///   `fittingSize` — the latter, read in an async hop mid-animation, returned
///   stale/intermediate sizes and left the window taller than the panel.
/// - **The top edge is anchored to where the system placed the window on open**
///   (captured on `didBecomeKey`), not to the window's current top. AppKit's
///   own content-size updates keep the *bottom-left* origin fixed, which moves
///   the top; anchoring to the current frame would lock in that drift and the
///   panel crept down away from the menu bar across polls.
struct MenuBarWindowResizer: NSViewRepresentable {
    var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        // ImageRenderer (snapshot mode) has no window — nothing to resize.
        if AppEnvironment.isSnapshot { return }
        context.coordinator.requestResize(of: nsView, to: height)
    }

    final class Coordinator {
        private weak var observedWindow: NSWindow?
        private var observer: NSObjectProtocol?
        /// The window's top edge as positioned by the system when it opened.
        private var anchorTop: CGFloat?
        private var pendingHeight: CGFloat = 0
        private var scheduled = false

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        /// Coalesces a burst of height changes (e.g. every frame of the spring
        /// animation) into one resize that uses the latest height.
        func requestResize(of view: NSView, to height: CGFloat) {
            pendingHeight = height
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self else { return }
                self.scheduled = false
                guard let window = view?.window else { return }
                self.observe(window)
                self.apply(to: window)
            }
        }

        private func observe(_ window: NSWindow) {
            guard observedWindow !== window else { return }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observedWindow = window
            anchorTop = window.frame.maxY
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] note in
                guard let self, let window = note.object as? NSWindow else { return }
                // The panel just opened: the system has placed it under the
                // status item, so this is the correct top edge.
                self.anchorTop = window.frame.maxY
                self.apply(to: window)
            }
        }

        private func apply(to window: NSWindow) {
            guard pendingHeight > 0 else { return }
            let old = window.frame
            let contentRect = NSRect(x: 0, y: 0,
                                     width: window.contentRect(forFrameRect: old).width,
                                     height: pendingHeight)
            let newSize = window.frameRect(forContentRect: contentRect).size
            let top = anchorTop ?? old.maxY
            // Negligible delta in both size and position — skip to avoid churn
            // / feedback loops.
            if abs(newSize.height - old.height) < 0.5 && abs(top - old.maxY) < 0.5 { return }

            var newFrame = old
            newFrame.size = newSize
            newFrame.origin.y = top - newSize.height
            window.setFrame(newFrame, display: true, animate: false)
        }
    }
}

/// A borderless, hover-highlighting button used for footer actions.
struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Theme.cardFill : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
