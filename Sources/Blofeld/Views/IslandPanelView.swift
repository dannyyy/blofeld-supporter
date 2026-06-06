import SwiftUI

/// The custom dropdown panel that hangs off the menu bar — the "island".
struct IslandPanelView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.cardStroke)

            if state.hosts.isEmpty && state.monitorQueries.isEmpty {
                emptyState
            } else {
                // Rendered directly (no ScrollView): a ScrollView with only a
                // maxHeight collapses to ~0 inside MenuBarExtra(.window), which
                // left the body blank. The panel sizes to its content instead.
                contentList
            }

            if !state.toasts.isEmpty {
                ToastOverlay(toasts: state.toasts, onDismiss: state.dismissToast)
            }

            Divider().overlay(Theme.cardStroke)
            footer
        }
        .frame(width: Theme.panelWidth)
        .background(
            ZStack {
                if AppEnvironment.isSnapshot {
                    Color(red: 0.10, green: 0.10, blue: 0.12)
                } else {
                    VisualEffectBlur(material: .hudWindow)
                    Color.black.opacity(0.28)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .animation(Theme.spring, value: state.hosts)
        .animation(Theme.spring, value: state.monitorQueries)
        // The panel has no editable text — force the normal arrow pointer instead
        // of the I-beam that SwiftUI text content otherwise shows.
        .onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.arrow.set()
            case .ended:
                NSCursor.arrow.set()
            }
        }
    }

    private var contentList: some View {
        VStack(spacing: Theme.spacing) {
            ForEach(state.hosts) { host in
                HostSection(host: host)
            }
            ForEach(state.monitorQueries) { query in
                MonitorQuerySection(query: query)
            }
        }
        .padding(Theme.padding)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppAssets.panelLogo(pointSize: 22))
                .renderingMode(.template)
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 1) {
                Text("Blofeld Supporter")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(statusLine)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            StatusDot(color: overallColor, alert: !state.isHealthy)
                .padding(.trailing, 2)
        }
        .padding(.horizontal, Theme.padding)
        .padding(.vertical, 12)
    }

    private var statusLine: String {
        if state.anyNeedsAuth { return "Authentication required" }
        if state.isHealthy { return "All clear" }
        var parts: [String] = []
        if state.totalErrors > 0 { parts.append("\(state.totalErrors) error\(state.totalErrors == 1 ? "" : "s")") }
        if state.totalAlertingMonitors > 0 { parts.append("\(state.totalAlertingMonitors) alerting") }
        return parts.isEmpty ? "All clear" : parts.joined(separator: " · ")
    }

    private var overallColor: Color {
        if state.anyNeedsAuth { return Theme.danger }
        if state.totalAlertingMonitors > 0 { return Theme.danger }
        return state.totalErrors == 0 ? Theme.ok : Theme.accent
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(lastUpdatedText)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)

            Spacer()

            ActivityButton()

            IconButton(systemName: "arrow.clockwise",
                       help: state.isRefreshing ? "Refreshing…" : "Refresh now") {
                state.refresh()
            }
            .disabled(state.isRefreshing)
            .opacity(state.isRefreshing ? 0.4 : 1)

            OpenSettingsButton {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .help("Settings")

            IconButton(systemName: "power", help: "Quit Blofeld Supporter") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, Theme.padding)
        .padding(.vertical, 8)
    }

    private var lastUpdatedText: String {
        guard let date = state.lastUpdated else { return "Not yet updated" }
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 5 { return "Updated just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return "Updated " + f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("Nothing to monitor yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("Add a ServiceControl host or a Datadog monitor query in Settings to start monitoring.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
            OpenSettingsButton {
                Text("Open Settings")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, Theme.padding)
    }
}

/// One host card: title, auth state, and its endpoint rows.
private struct HostSection: View {
    let host: HostStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(host.name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if host.needsAuth {
                    Text("auth required")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                } else if isError {
                    Text("unreachable")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                } else if host.totalCount > 0 {
                    Text("\(host.totalCount)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.accent)
                }
            }

            if host.needsAuth {
                AuthBanner(hostId: host.id)
            } else if case .error(let message) = host.authState {
                ErrorBanner(message: message)
            } else {
                VStack(spacing: 4) {
                    ForEach(host.endpoints) { endpoint in
                        EndpointRowView(hostId: host.id, endpoint: endpoint)
                    }
                }
            }
        }
        .padding(12)
        .cardStyle()
    }

    private var isError: Bool {
        if case .error = host.authState { return true }
        return false
    }
}

/// Shown when a host's API could not be reached / returned an error.
private struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.danger)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous)
                .fill(Theme.danger.opacity(0.10))
        )
    }
}

/// Footer button that opens a popover with recent activity (the event log).
private struct ActivityButton: View {
    @ObservedObject private var log = EventLog.shared
    @State private var showing = false

    var body: some View {
        IconButton(systemName: "list.bullet.rectangle", help: "Activity log") {
            showing.toggle()
        }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ActivityLogView(entries: log.entries)
        }
    }
}

private struct ActivityLogView: View {
    let entries: [LogEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Activity")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Open log file") {
                    EventLog.shared.openLogFile()
                }
                .font(.system(size: 11))
                Button("Clear") { EventLog.shared.clear() }
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if entries.isEmpty {
                Text("No activity yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(entries.reversed()) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(color(for: entry.level))
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 4)
                                Text(time(entry.date))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(entry.message)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 520, height: 300)
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .success: return Theme.ok
        case .error: return Theme.danger
        case .info: return Theme.retried
        }
    }

    private func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}

/// Shown when a host's API is behind the SSO wall. Opens the in-app WKWebView
/// login flow.
private struct AuthBanner: View {
    @EnvironmentObject private var state: AppState
    let hostId: UUID

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.danger)
            Text("Sign in to load errors for this host.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button {
                state.authenticate(hostId: hostId)
            } label: {
                Text("Authenticate")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous)
                .fill(Theme.danger.opacity(0.10))
        )
    }
}
