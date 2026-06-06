import SwiftUI

/// Set when rendering an offline snapshot (ImageRenderer can't draw the live
/// vibrancy blur), so the panel uses a solid backdrop instead.
enum AppEnvironment {
    static var isSnapshot = false
}

/// Central design tokens for the "island" aesthetic: dark, rounded, soft.
enum Theme {
    // Layout
    static let panelWidth: CGFloat = 380
    static let cornerRadius: CGFloat = 18
    static let cardCornerRadius: CGFloat = 14
    static let rowCornerRadius: CGFloat = 10
    static let spacing: CGFloat = 10
    static let padding: CGFloat = 14

    // Colors
    static let accent = Color(red: 1.00, green: 0.60, blue: 0.20)      // amber — "new"
    static let retried = Color(red: 0.55, green: 0.65, blue: 1.00)     // periwinkle — "retried"
    static let ok = Color(red: 0.35, green: 0.85, blue: 0.55)          // green — healthy
    static let danger = Color(red: 1.00, green: 0.36, blue: 0.36)      // red — error/auth

    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.35)

    static let cardFill = Color.white.opacity(0.06)
    static let cardStroke = Color.white.opacity(0.08)
    static let rowFill = Color.white.opacity(0.04)

    // Motion
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let quickSpring = Animation.spring(response: 0.30, dampingFraction: 0.80)
}

/// A blurred translucent backing using AppKit's vibrancy material.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

extension View {
    /// Wraps content in a soft rounded "card" with a subtle stroke.
    func cardStyle(cornerRadius: CGFloat = Theme.cardCornerRadius) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Theme.cardStroke, lineWidth: 1)
            )
    }
}
