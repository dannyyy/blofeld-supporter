import SwiftUI

enum ToastKind {
    case success, error, info

    var color: Color {
        switch self {
        case .success: return Theme.ok
        case .error: return Theme.danger
        case .info: return Theme.retried
        }
    }
    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
    var logLevel: LogLevel {
        switch self {
        case .success: return .success
        case .error: return .error
        case .info: return .info
        }
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let kind: ToastKind
    let message: String

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
}

/// Transient feedback messages stacked at the bottom of the panel.
struct ToastOverlay: View {
    let toasts: [Toast]
    let onDismiss: (UUID) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(toasts) { toast in
                HStack(spacing: 8) {
                    Image(systemName: toast.kind.icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(toast.kind.color)
                    Text(toast.message)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.black.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(toast.kind.color.opacity(0.4), lineWidth: 1)
                )
                .onTapGesture { onDismiss(toast.id) }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Theme.padding)
        .padding(.bottom, 6)
    }
}
