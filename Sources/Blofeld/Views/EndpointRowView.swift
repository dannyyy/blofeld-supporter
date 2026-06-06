import SwiftUI

/// A single endpoint inside a host section. Laid out in two rows so the full
/// endpoint name and both badges always have room:
///
///   ●  payables                         [↻] [↗]
///      4 new   1 retried
struct EndpointRowView: View {
    @EnvironmentObject private var state: AppState
    let hostId: UUID
    let endpoint: EndpointStatus
    @State private var hovering = false

    private var isRetrying: Bool {
        state.retrying.contains(AppState.key(hostId, endpoint.name))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                StatusDot(color: endpoint.hasErrors ? Theme.accent : Theme.ok)

                Text(endpoint.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                if endpoint.hasErrors {
                    HStack(spacing: 4) {
                        if endpoint.canRetry {
                            if isRetrying {
                                Image(systemName: "arrow.clockwise.circle")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.textTertiary)
                                    .frame(width: 28, height: 28)
                            } else {
                                IconButton(systemName: "arrow.clockwise.circle",
                                           help: "Retry all failed messages for this endpoint") {
                                    state.retry(hostId: hostId, endpoint: endpoint.name)
                                }
                            }
                        }
                        if let url = endpoint.servicePulseURL {
                            IconButton(systemName: "arrow.up.forward.square", help: "Open in ServicePulse") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                } else {
                    Text("clear")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.ok.opacity(0.8))
                }
            }

            if endpoint.hasErrors {
                HStack(spacing: 8) {
                    if endpoint.newCount > 0 {
                        CountBadge(count: endpoint.newCount, label: "new", color: Theme.accent)
                    }
                    if endpoint.retriedCount > 0 {
                        CountBadge(count: endpoint.retriedCount, label: "retried", color: Theme.retried)
                    }
                }
                .padding(.leading, 18)   // align under the endpoint name
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous)
                .fill(hovering ? Theme.cardFill : Theme.rowFill)
        )
        .onHover { hovering = $0 }
        .animation(Theme.quickSpring, value: endpoint)
        .animation(Theme.quickSpring, value: isRetrying)
    }
}
