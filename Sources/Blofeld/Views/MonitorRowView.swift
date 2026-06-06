import SwiftUI

/// One Datadog monitor inside a query section:
///
///   ●  Payables has failed messages …            alert   [↗]
struct MonitorRowView: View {
    let monitor: MonitorStatus
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(color: dotColor, alert: monitor.state == .alert)

            Text(monitor.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(monitor.name)   // full name on hover — names truncate middle

            Spacer(minLength: 8)

            if monitor.state != .ok {
                Text(monitor.state.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(stateColor)
            }

            if let url = monitor.url {
                IconButton(systemName: "arrow.up.forward.square", help: "Open in Datadog") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous)
                .fill(hovering ? Theme.cardFill : Theme.rowFill)
        )
        .onHover { hovering = $0 }
        .animation(Theme.quickSpring, value: monitor)
    }

    /// Status dot colour: red alert, amber warn, green ok, dim for no-data/unknown.
    private var dotColor: Color {
        switch monitor.state {
        case .alert: return Theme.danger
        case .warn: return Theme.accent
        case .ok: return Theme.ok
        case .noData, .unknown: return Theme.textTertiary
        }
    }

    private var stateColor: Color {
        switch monitor.state {
        case .alert: return Theme.danger
        case .warn: return Theme.accent
        default: return Theme.textSecondary
        }
    }
}

/// One query card in the panel: title, alert/total count, and its monitor rows
/// (or a hint when the `pup` CLI isn't ready). Mirrors `HostSection`.
struct MonitorQuerySection: View {
    let query: MonitorQueryStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(query.name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if !query.availability.isOk {
                    Text("unavailable")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                } else if query.alertCount > 0 {
                    Text("\(query.alertCount)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.danger)
                } else if query.totalCount > 0 {
                    Text("\(query.totalCount)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if !query.availability.isOk {
                PupBanner(availability: query.availability)
            } else if query.monitors.isEmpty {
                Text("No monitors match this query.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 2)
            } else {
                VStack(spacing: 4) {
                    ForEach(query.sortedForDisplay) { monitor in
                        MonitorRowView(monitor: monitor)
                    }
                    if query.truncatedBy > 0 {
                        Text("+\(query.truncatedBy) more")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 2)
                    }
                }
            }
        }
        .padding(12)
        .cardStyle()
    }
}

/// Shown inside a query card when the `pup` CLI is missing / not authenticated.
private struct PupBanner: View {
    let availability: PupAvailability

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.danger)
            VStack(alignment: .leading, spacing: 3) {
                Text(availability.label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                if let hint = availability.hint {
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
