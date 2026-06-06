import SwiftUI

/// Sidebar selection for the settings window.
private enum SettingsSection: Hashable {
    case general
    case host(UUID)
}

/// The preferences window (opened via the gear / SettingsLink / Cmd-,).
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection: SettingsSection? = .general

    var body: some View {
        // A plain HSplitView (not NavigationSplitView) so the sidebar sits below
        // a normal title bar — NavigationSplitView's title-bar-integrated sidebar
        // toggle was overlapping the window's traffic-light controls.
        HSplitView {
            sidebar
                .frame(width: 210)
            detail
                .frame(minWidth: 470, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 720, height: 500)
        .background(WindowFronter())
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("General", systemImage: "gearshape")
                    .tag(SettingsSection.general)
            }
            Section("Monitored Hosts") {
                ForEach(state.config.hosts) { host in
                    Label(host.name.isEmpty ? "Untitled host" : host.name,
                          systemImage: "server.rack")
                        .tag(SettingsSection.host(host.id))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 0) {
                Button(action: addHost) {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Add host")

                Button(action: removeSelectedHost) {
                    Image(systemName: "minus")
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Remove selected host")
                .disabled(!isHostSelected)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private var isHostSelected: Bool {
        if case .host = selection { return true }
        return false
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general:
            GeneralSettingsView()
        case .host(let id):
            if let binding = hostBinding(id) {
                HostDetailView(host: binding)
                    .id(id)
            } else {
                placeholder
            }
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Select a section")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Mutations (crash-safe, id based)

    /// A binding that always resolves the host by id, so it survives array
    /// mutations (the previous index-based binding crashed on removal).
    private func hostBinding(_ id: UUID) -> Binding<HostConfig>? {
        guard state.config.hosts.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: {
                state.config.hosts.first(where: { $0.id == id })
                    ?? HostConfig(name: "", apiHost: "", servicePulseHost: "", endpoints: [])
            },
            set: { newValue in
                if let idx = state.config.hosts.firstIndex(where: { $0.id == id }) {
                    state.config.hosts[idx] = newValue
                }
            }
        )
    }

    private func addHost() {
        let host = HostConfig(name: "New Host", apiHost: "", servicePulseHost: "", endpoints: [])
        state.config.hosts.append(host)
        selection = .host(host.id)
    }

    private func removeSelectedHost() {
        guard case .host(let id) = selection else { return }
        selection = .general                      // move selection away first
        state.config.hosts.removeAll { $0.id == id }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject private var state: AppState
    /// Renders the content without the outer `ScrollView` (ImageRenderer can't
    /// lay out a `ScrollView`'s content for offline snapshots).
    var snapshot = false

    private var content: some View {
        VStack(alignment: .leading, spacing: 24) {
            systemSection
            pollingSection
            NotificationDeliveryCard()
            diagnosticsSection
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        Group {
            if snapshot {
                content
            } else {
                ScrollView { content }
            }
        }
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        .preferredColorScheme(.dark)
        .navigationTitle("General")
    }

    // MARK: System

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(icon: "gearshape.fill", tint: .purple, title: "System")
            SettingsCard {
                ToggleRow(icon: "power",
                          tint: Theme.ok,
                          title: "Start at login",
                          subtitle: "Launch automatically when you log in",
                          isOn: $state.config.launchAtLogin)
                Divider().overlay(Theme.cardStroke).padding(.leading, 39)
                ToggleRow(icon: "bell.fill",
                          tint: Theme.danger,
                          title: "Notifications",
                          subtitle: "Alert when new errors are detected",
                          isOn: $state.config.notificationsEnabled)
            }
        }
    }

    // MARK: Polling

    private var pollingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(icon: "timer", tint: Theme.accent, title: "Polling")
            SettingsCard {
                PollingControl(pollSeconds: $state.config.pollSeconds)
            }
        }
    }

    // MARK: Diagnostics

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(icon: "wrench.and.screwdriver.fill",
                                  tint: .teal, title: "Diagnostics")
            SettingsCard {
                HStack(spacing: 10) {
                    Button("Open log file") { EventLog.shared.openLogFile() }
                    Button("Reveal config folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.configURL])
                    }
                    Spacer()
                }
            }
        }
    }
}

// MARK: - Reusable settings pieces

/// A section heading: a tinted SF Symbol next to a bold title.
private struct SettingsSectionHeader: View {
    let icon: String
    let tint: Color
    let title: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.leading, 2)
    }
}

/// A rounded "island" card that hosts grouped controls.
private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

/// An icon + title + subtitle row with a trailing switch.
private struct ToggleRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.blue)
        }
        .padding(.vertical, 8)
    }
}

/// The progressive polling-interval control: a slider over the discrete
/// `PollInterval.options`, so dragging gives fine 15 s steps near the bottom
/// and coarse 15 min steps near the top.
private struct PollingControl: View {
    @Binding var pollSeconds: Int

    private var sliderIndex: Binding<Double> {
        Binding(
            get: { Double(PollInterval.index(of: pollSeconds)) },
            set: { newValue in
                let i = Int(newValue.rounded())
                    .clamped(to: 0...(PollInterval.options.count - 1))
                pollSeconds = PollInterval.options[i]
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Check every")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(PollInterval.label(for: pollSeconds))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
            }
            Slider(value: sliderIndex,
                   in: 0...Double(PollInterval.options.count - 1),
                   step: 1)
                .tint(Theme.accent)
            Text("How often to check each endpoint for new errors")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: - Notification delivery

/// Shows whether notification registration is valid and lets the user fire a
/// test notification — handy because a menu-bar (LSUIElement) app silently
/// fails to deliver notifications when authorization was never granted.
private struct NotificationDeliveryCard: View {
    @ObservedObject private var notifications = NotificationService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(icon: "bell.badge.fill",
                                  tint: Theme.danger, title: "Notification Delivery")
            SettingsCard {
                HStack {
                    Text("Registration")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: notifications.authorizationStatus.isValid
                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(notifications.authorizationStatus.isValid
                                             ? Theme.ok : Theme.accent)
                        Text(notifications.authorizationStatus.label)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .font(.system(size: 13))
                }
                .padding(.vertical, 4)

                if let error = notifications.lastError {
                    Divider().overlay(Theme.cardStroke)
                    HStack(alignment: .top) {
                        Text("Last error")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.danger)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.vertical, 4)
                }

                Divider().overlay(Theme.cardStroke).padding(.vertical, 4)

                HStack(spacing: 10) {
                    Button("Send test notification") {
                        notifications.sendTestNotification()
                    }
                    .disabled(!notifications.authorizationStatus.isValid)

                    switch notifications.authorizationStatus {
                    case .notDetermined:
                        Button("Request permission") {
                            notifications.requestAuthorization()
                        }
                    case .denied:
                        Button("Open notification settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    default:
                        EmptyView()
                    }
                    Spacer()
                }

                Text("Notifications only appear when registration is valid. If a test notification doesn't show, check that Blofeld is allowed under System Settings › Notifications.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 4)
            }
        }
        .onAppear { notifications.refreshStatus() }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Host detail

private struct HostDetailView: View {
    @Binding var host: HostConfig

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Display name", text: $host.name)
                TextField("ServiceControl API", text: $host.apiHost,
                          prompt: Text("https://servicecontrol.example.com"))
                TextField("ServicePulse", text: $host.servicePulseHost,
                          prompt: Text("https://servicepulse.example.com"))
            }

            Section("Endpoints") {
                if host.endpoints.isEmpty {
                    Text("No endpoints yet. Add the endpoint names you want to watch.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach($host.endpoints) { $endpoint in
                    HStack {
                        TextField("Endpoint name", text: $endpoint.name,
                                  prompt: Text("my-service-name"))
                        Button {
                            host.endpoints.removeAll { $0.id == endpoint.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove endpoint")
                    }
                }
                Button {
                    host.endpoints.append(EndpointConfig(name: ""))
                } label: {
                    Label("Add endpoint", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(host.name.isEmpty ? "Host" : host.name)
    }
}
