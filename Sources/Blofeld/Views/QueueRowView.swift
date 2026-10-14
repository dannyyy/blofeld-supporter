import SwiftUI

/// A single Service Bus queue inside a namespace card. Same two-row layout as
/// `EndpointRowView`:
///
///   ●  order-processor                    [⤴] [↗]
///      12 dead-lettered
///
/// Resubmit is a write, so it takes two clicks: the first turns the button into
/// a "Resubmit N?" capsule (static, no animation loop), the second runs it.
struct QueueRowView: View {
    @EnvironmentObject private var state: AppState
    let namespaceId: UUID
    let queue: QueueStatus
    @State private var hovering = false
    @State private var confirming = false

    private var isResubmitting: Bool {
        state.resubmitting.contains(AppState.key(namespaceId, queue.name))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                StatusDot(color: dotColor)

                Text(queue.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(queue.name)   // full name on hover — names truncate middle

                Spacer(minLength: 8)

                if queue.notFound {
                    Text("not found")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.danger)
                } else if queue.hasDeadLetters {
                    HStack(spacing: 4) {
                        resubmitControl
                        if let url = queue.portalURL {
                            IconButton(systemName: "arrow.up.forward.square", help: "Open in Azure Portal (Service Bus Explorer)") {
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

            if queue.hasDeadLetters {
                CountBadge(count: queue.deadLetterCount, label: "dead-lettered", color: Theme.accent)
                    .padding(.leading, 18)   // align under the queue name
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous)
                .fill(hovering ? Theme.cardFill : Theme.rowFill)
        )
        .onHover { hovering = $0 }
        .animation(Theme.quickSpring, value: queue)
        .animation(Theme.quickSpring, value: isResubmitting)
        .animation(Theme.quickSpring, value: confirming)
    }

    @ViewBuilder
    private var resubmitControl: some View {
        if isResubmitting {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 28, height: 28)
        } else if confirming {
            Button {
                confirming = false
                state.resubmit(namespaceId: namespaceId, queue: queue.name)
            } label: {
                Text("Resubmit \(min(queue.deadLetterCount, AppState.resubmitLimit))?")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .help("Click again to move these messages back into \(queue.name)")
        } else {
            IconButton(systemName: "arrow.uturn.backward.circle",
                       help: "Resubmit dead-lettered messages to \(queue.name)") {
                confirming = true
                // Revert to the plain button if the user doesn't confirm.
                Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    confirming = false
                }
            }
        }
    }

    private var dotColor: Color {
        if queue.notFound { return Theme.danger }
        return queue.hasDeadLetters ? Theme.accent : Theme.ok
    }
}

/// One namespace card: title, dead-letter total, and its queue rows (or a
/// banner when `az` isn't ready / the namespace can't be read). Mirrors
/// `HostSection`.
struct ServiceBusNamespaceSection: View {
    let namespace: ServiceBusNamespaceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(namespace.name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if !namespace.availability.isOk && namespace.availability != .unknown {
                    Text("unavailable")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                } else if errorMessage != nil {
                    Text("unreachable")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                } else if namespace.totalDeadLetters > 0 {
                    Text("\(namespace.totalDeadLetters)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.accent)
                }
            }

            if !namespace.availability.isOk && namespace.availability != .unknown {
                AzBanner(title: namespace.availability.label, hint: namespace.availability.hint)
            } else if let errorMessage {
                AzBanner(title: errorMessage, hint: nil)
            } else {
                VStack(spacing: 4) {
                    ForEach(namespace.queues) { queue in
                        QueueRowView(namespaceId: namespace.id, queue: queue)
                    }
                }
            }
        }
        .padding(12)
        .cardStyle()
    }

    private var errorMessage: String? {
        if case .error(let message) = namespace.state { return message }
        return nil
    }
}

/// Shown inside a namespace card when `az` is missing / signed out, or the
/// namespace couldn't be listed.
private struct AzBanner: View {
    let title: String
    let hint: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.danger)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                if let hint {
                    Text(hint)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous)
                .fill(Theme.danger.opacity(0.10))
        )
    }
}
