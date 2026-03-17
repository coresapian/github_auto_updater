import SwiftUI

struct RootView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "rectangle.grid.2x2.fill") }
            LogsView()
                .tabItem { Label("Logs", systemImage: "doc.text.magnifyingglass") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task {
            viewModel.start()
            await viewModel.refresh(reason: .manual)
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.handleScenePhase(newPhase)
        }
        .onChange(of: viewModel.refreshInterval) { _, _ in viewModel.restartAutoRefreshLoop() }
        .onChange(of: viewModel.autoRefreshWhileOpen) { _, _ in viewModel.restartAutoRefreshLoop() }
        .overlay(alignment: .top) {
            if let error = viewModel.errorMessage, !error.isEmpty {
                ErrorBanner(error: error)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ConnectionStatusCard()

                    LazyVGrid(columns: columns, spacing: 12) {
                        MetricCard(title: "Healthy", value: "\(viewModel.status.dashboard.healthyRepos)", subtitle: "repos")
                        MetricCard(title: "Attention", value: "\(viewModel.status.dashboard.attentionRepos)", subtitle: "warning / failed")
                        MetricCard(title: "Backups", value: "\(viewModel.status.dashboard.backupsCount)", subtitle: "directories")
                        MetricCard(title: "Alerts", value: viewModel.status.dashboard.alertLogPresent ? "Present" : "Clear", subtitle: "alert log")
                    }

                    updaterCard
                    pairingCard
                    notificationsCard
                    manualRunCard
                    repoSection
                    if !viewModel.status.backups.isEmpty { backupsCard }
                }
                .padding()
            }
            .navigationTitle("GitHub Auto Updater")
            .refreshable { await viewModel.refresh(reason: .manual) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.refresh(reason: .manual) }
                    } label: {
                        if viewModel.isLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                }
            }
        }
    }

    private var updaterCard: some View {
        DashboardCard(title: "Updater status", systemImage: "bolt.badge.clock") {
            VStack(alignment: .leading, spacing: 10) {
                StatusRow(label: "Cron installed", value: viewModel.status.cronInstalled ? "Yes" : "No")
                StatusRow(label: "Refresh cadence", value: everyLabel(seconds: Int(viewModel.refreshInterval)))
                StatusRow(label: "Script", value: viewModel.status.scriptPath.isEmpty ? "Unknown" : viewModel.status.scriptPath)
                StatusRow(label: "Bonjour", value: "\(viewModel.status.discovery.bonjourServiceName) / \(viewModel.status.discovery.bonjourServiceType)")
                if let summary = viewModel.status.latestSummary.summary, !summary.isEmpty { StatusRow(label: "Last summary", value: summary) }
                if let counts = viewModel.status.latestSummary.counts { StatusRow(label: "Last counts", value: counts.compactDescription) }
                StatusRow(label: "Helper time", value: viewModel.formattedDate(viewModel.status.helperTime))
            }
        }
    }

    private var pairingCard: some View {
        DashboardCard(title: "Pairing & discovery", systemImage: "lock.shield.fill") {
            VStack(alignment: .leading, spacing: 10) {
                StatusRow(label: "Auth required", value: viewModel.pairingStatus.authRequired ? "Yes" : "No")
                StatusRow(label: "Auth mode", value: viewModel.pairingStatus.authMode)
                StatusRow(label: "Helper instance", value: viewModel.pairingStatus.helperInstanceID.isEmpty ? "Unknown" : viewModel.pairingStatus.helperInstanceID)
                if let code = viewModel.pairingStatus.pairingCodeLabel, !code.isEmpty { StatusRow(label: "Pairing code", value: code) }
                if let expiry = viewModel.pairingStatus.pairingCodeExpiresAt, !expiry.isEmpty { StatusRow(label: "Pairing expires", value: viewModel.formattedTimestamp(expiry)) }
                StatusRow(label: "Discovered helpers", value: "\(viewModel.discoveredServers.count)")
                Text(viewModel.pairingStatus.pairingInstructions)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var notificationsCard: some View {
        DashboardCard(title: "Notifications", systemImage: "bell.badge.fill") {
            VStack(alignment: .leading, spacing: 10) {
                StatusRow(label: "Local notifications", value: viewModel.notificationsEnabled ? "Enabled" : "Disabled")
                StatusRow(label: "Remote notifications", value: viewModel.remoteNotificationsEnabled ? "Enabled" : "Disabled")
                StatusRow(label: "Helper push hooks", value: viewModel.status.notifications.configured ? viewModel.status.notifications.channels.joined(separator: ", ") : "Not configured")
                StatusRow(label: "Registered APNs devices", value: "\(viewModel.status.notifications.registeredDeviceCount ?? 0)")
                StatusRow(label: "APNs helper config", value: (viewModel.status.notifications.apnsConfigured ?? false) ? "Configured" : "Not configured")
                if let sentAt = viewModel.status.notifications.lastSentAt, !sentAt.isEmpty { StatusRow(label: "Last helper notification", value: viewModel.formattedTimestamp(sentAt)) }
                if let result = viewModel.status.notifications.lastResult, !result.isEmpty {
                    Text(result).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var manualRunCard: some View {
        DashboardCard(title: "Manual run", systemImage: "play.circle.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    Task { await viewModel.triggerManualRun() }
                } label: {
                    HStack {
                        if viewModel.isTriggeringManualRun { ProgressView().controlSize(.small) }
                        Text(viewModel.isTriggeringManualRun ? "Requesting…" : "Run updater now")
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isTriggeringManualRun || viewModel.status.manualRun.current != nil)

                if let action = viewModel.status.manualRun.current ?? viewModel.status.manualRun.latest {
                    ManualRunActionCard(action: action)
                }
                if let info = viewModel.manualRunMessage, !info.isEmpty { Text(info).font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    private var repoSection: some View {
        DashboardCard(title: "Repositories", systemImage: "shippingbox.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Repo filter", selection: $viewModel.dashboardRepoFilter) {
                    ForEach(AppViewModel.DashboardRepoFilter.allCases) { filter in Text(filter.title).tag(filter) }
                }
                .pickerStyle(.segmented)
                if viewModel.filteredRepos.isEmpty {
                    ContentUnavailableView("No repositories", systemImage: "shippingbox")
                } else {
                    ForEach(viewModel.filteredRepos) { repo in RepoCard(repo: repo) { viewModel.selectRepo(repo) } }
                }
            }
        }
    }

    private var backupsCard: some View {
        DashboardCard(title: "Backups", systemImage: "externaldrive.fill.badge.clock") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(viewModel.status.backups, id: \.self) { backup in
                    Text(backup).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func everyLabel(seconds: Int) -> String {
        if seconds < 60 { return "Every \(seconds)s" }
        return "Every \(seconds / 60)m"
    }
}

struct LogsView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Source", selection: Binding(get: { viewModel.selectedLogSource }, set: { viewModel.selectLogSource($0) })) {
                        ForEach(LogSource.allCases) { source in Text(source.title).tag(source) }
                    }
                    .pickerStyle(.segmented)
                    if viewModel.selectedLogSource == .repo {
                        Picker("Repository", selection: Binding(get: { viewModel.selectedRepo?.id ?? "" }, set: { id in
                            guard let repo = viewModel.status.repos.first(where: { $0.id == id }) else { return }
                            viewModel.selectRepo(repo)
                        })) {
                            ForEach(viewModel.status.repos) { repo in Text(repo.repo).tag(repo.id) }
                        }
                        .pickerStyle(.menu)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search current log", text: $viewModel.logSearchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Picker("Severity", selection: $viewModel.logSeverityFilter) {
                        ForEach(LogSeverityFilter.allCases) { severity in Text(severity.title).tag(severity) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Label(viewModel.activeLogTitle, systemImage: "doc.text")
                        Spacer()
                        Text("\(viewModel.filteredLogLines.count)/\(viewModel.currentLogLines.count) lines")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if viewModel.filteredLogLines.isEmpty {
                    Section { ContentUnavailableView("No matching lines", systemImage: "line.3.horizontal.decrease.circle") }
                } else {
                    Section {
                        ForEach(viewModel.filteredLogLines) { line in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Image(systemName: icon(for: line.severity)).foregroundStyle(color(for: line.severity))
                                    Text("Line \(line.index + 1)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }
                                Text(line.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Logs")
            .refreshable { await viewModel.refresh(reason: .manual) }
        }
    }

    private func icon(for severity: LogSeverityFilter) -> String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .matched: return "scope"
        default: return "info.circle.fill"
        }
    }
    private func color(for severity: LogSeverityFilter) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .yellow
        case .matched: return .blue
        default: return .secondary
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Mac helper URL", text: $viewModel.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Helper token / bearer token", text: $viewModel.helperToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Stepper(value: $viewModel.refreshInterval, in: 10 ... 300, step: 5) { Text("Refresh interval: \(Int(viewModel.refreshInterval))s") }
                    Toggle("Auto refresh while open", isOn: $viewModel.autoRefreshWhileOpen)
                    Toggle("Background refresh", isOn: $viewModel.backgroundRefreshEnabled)
                }

                Section("Discovered helpers") {
                    if viewModel.discoveredServers.isEmpty {
                        Text("No Bonjour helpers discovered yet. Make sure the Mac helper is running on the same network.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.discoveredServers) { server in
                            Button {
                                viewModel.useDiscoveredServer(server)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(server.name)
                                    Text(server.url).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Pair this device") {
                    TextField("Device name", text: $viewModel.deviceName)
                    TextField("Pairing code", text: $viewModel.pairingCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button { Task { await viewModel.pairCurrentDevice() } } label: {
                        HStack {
                            if viewModel.isPairing { ProgressView().controlSize(.small) }
                            Text(viewModel.isPairing ? "Pairing…" : "Pair with Mac helper")
                        }
                    }.disabled(viewModel.isPairing)
                    Button("Refresh pairing status") { Task { await viewModel.refreshPairingStatus() } }
                    if let message = viewModel.pairingMessage, !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    Text(viewModel.pairingStatus.pairingInstructions).font(.footnote).foregroundStyle(.secondary)
                    if let code = viewModel.pairingStatus.pairingCodeLabel, !code.isEmpty { LabeledContent("Current code", value: code) }
                    if let expiry = viewModel.pairingStatus.pairingCodeExpiresAt, !expiry.isEmpty { LabeledContent("Expires", value: viewModel.formattedTimestamp(expiry)) }
                    LabeledContent("Saved token", value: viewModel.hasHelperToken ? "Present in Keychain" : "Not saved")
                    if viewModel.hasHelperToken { Button("Clear saved token", role: .destructive) { viewModel.clearHelperToken() } }
                }

                Section("Notifications") {
                    Toggle("Local failure notifications", isOn: $viewModel.notificationsEnabled)
                    Button("Request local notification permission") { Task { await viewModel.requestNotificationPermission() } }
                    Toggle("Remote notifications (APNs)", isOn: $viewModel.remoteNotificationsEnabled)
                    Button("Register this device for remote notifications") { Task { await viewModel.requestRemoteNotificationRegistration() } }
                    if !viewModel.apnsDeviceToken.isEmpty {
                        Text("APNs token: \(viewModel.apnsDeviceToken.prefix(12))…")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let message = viewModel.notificationMessage, !message.isEmpty {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    if viewModel.status.notifications.configured {
                        Text("Helper push channels: \(viewModel.status.notifications.channels.joined(separator: ", "))")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("No helper push channels configured yet. Set helper env vars to enable ntfy, webhook, or APNs delivery.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("Release & review") {
                    Text("Use the included TestFlight checklist and release workflow docs before shipping. Real APNs delivery requires Apple push credentials on the helper.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section { Button("Refresh now") { Task { await viewModel.refresh(reason: .manual) } } }
            }
            .navigationTitle("Settings")
        }
    }
}

struct ErrorBanner: View {
    let error: String
    var body: some View {
        Text(error).font(.footnote).padding(8).frame(maxWidth: .infinity).background(.red.opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct ConnectionStatusCard: View {
    @EnvironmentObject private var viewModel: AppViewModel
    var body: some View {
        DashboardCard(title: "Connection", systemImage: "dot.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 8) {
                StatusRow(label: "Server", value: viewModel.serverURL)
                StatusRow(label: "Last refresh", value: viewModel.formattedDate(viewModel.lastRefreshDate))
                StatusRow(label: "Next auto refresh", value: viewModel.formattedDate(viewModel.nextAutomaticRefreshDate))
                StatusRow(label: "Helper token", value: viewModel.hasHelperToken ? "Present in Keychain" : "Not configured")
            }
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.title.bold())
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct DashboardCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct StatusRow: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).font(.subheadline)
        }
    }
}

struct RepoCard: View {
    let repo: RepoStatus
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: repo.state.systemImage).foregroundStyle(color).font(.title3)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(repo.repo).font(.headline)
                        Spacer()
                        Text(repo.state.label).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(repo.summary).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    if let updatedAt = repo.updatedAt {
                        Text(updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
    private var color: Color {
        switch repo.state {
        case .ok: return .green
        case .skipped, .warning: return .yellow
        case .failed: return .red
        case .unknown: return .gray
        }
    }
}

struct ManualRunActionCard: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let action: ManualRunAction
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(action.stateLabel).font(.headline).foregroundStyle(color)
                Spacer()
                if action.progress.totalRepos > 0 {
                    Text("\(action.progress.completedRepos)/\(action.progress.totalRepos)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if action.progress.totalRepos > 0 {
                ProgressView(value: Double(action.progress.completedRepos), total: Double(action.progress.totalRepos))
                Text("\(action.progress.percent)% complete").font(.caption).foregroundStyle(.secondary)
            }
            if let repo = action.progress.lastTouchedRepo { StatusRow(label: "Last repo", value: repo) }
            StatusRow(label: "Requested", value: viewModel.formattedTimestamp(action.requestedAt))
            if let startedAt = action.startedAt { StatusRow(label: "Started", value: viewModel.formattedTimestamp(startedAt)) }
            if let finishedAt = action.finishedAt { StatusRow(label: "Finished", value: viewModel.formattedTimestamp(finishedAt)) }
            Text(action.statusMessage).font(.caption).foregroundStyle(.secondary)
            if let summary = action.latestSummary?.summary, !summary.isEmpty { Text(summary).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var color: Color {
        switch action.state {
        case "queued": return .orange
        case "running": return .blue
        case "succeeded": return .green
        case "failed": return .red
        default: return .gray
        }
    }
}
