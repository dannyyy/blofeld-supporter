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
/// `view.window` trick `WindowFronter` uses) and resizes it to the content's
/// fitting size, keeping the **top edge anchored** so it shrinks from the
/// bottom (correct for a window that hangs down from the menu bar).
///
/// `trigger` exists only so SwiftUI re-invokes `updateNSView` when the content
/// height changes — a representable with no inputs is not re-run on layout.
struct MenuBarWindowResizer: NSViewRepresentable {
    var trigger: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        // ImageRenderer (snapshot mode) has no window — nothing to resize.
        if AppEnvironment.isSnapshot { return }
        DispatchQueue.main.async {
            guard let window = nsView.window,
                  let content = window.contentView else { return }
            let fitting = content.fittingSize
            guard fitting.height > 0 else { return }

            let targetContent = NSRect(origin: .zero, size: fitting)
            let newSize = window.frameRect(forContentRect: targetContent).size
            let old = window.frame
            // Negligible delta — skip to avoid churn / feedback loops.
            if abs(newSize.height - old.height) < 0.5 { return }

            var newFrame = old
            newFrame.size = newSize
            newFrame.origin.y = old.maxY - newSize.height // anchor the top edge
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
