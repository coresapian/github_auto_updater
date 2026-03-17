import SwiftUI

struct RootView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "gauge.with.dots.needle.50percent")
                }
            LogsView()
                .tabItem {
                    Label("Logs", systemImage: "doc.text.magnifyingglass")
                }
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .overlay(alignment: .top) {
            if let error = viewModel.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.footnote)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.red.opacity(0.15))
            }
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("Updater") {
                    LabeledContent("Cron installed", value: viewModel.status.cronInstalled ? "Yes" : "No")
                    LabeledContent("Cron entry", value: viewModel.status.cronEntry)
                    LabeledContent("Script", value: viewModel.status.scriptPath)
                }

                Section("Repositories") {
                    ForEach(viewModel.status.repos) { repo in
                        Button {
                            viewModel.selectRepo(repo)
                        } label: {
                            HStack {
                                Circle()
                                    .fill(color(for: repo.state))
                                    .frame(width: 12, height: 12)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(repo.repo)
                                        .font(.headline)
                                    Text(repo.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer()
                                Text(repo.state.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !viewModel.status.backups.isEmpty {
                    Section("Backups") {
                        ForEach(viewModel.status.backups, id: \.self) { backup in
                            Text(backup)
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("GitHub Auto Updater")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh") {
                        Task { await viewModel.refresh() }
                    }
                }
            }
        }
    }

    private func color(for state: RepoHealth) -> Color {
        switch state {
        case .ok:
            return .green
        case .skipped, .warning:
            return .yellow
        case .failed:
            return .red
        case .unknown:
            return .gray
        }
    }
}

struct LogsView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Log", selection: Binding(
                    get: { viewModel.selectedRepo?.repo ?? "main" },
                    set: { newValue in
                        if newValue == "main" {
                            viewModel.selectedRepo = nil
                            viewModel.repoLogText = "Select a repo log below."
                        } else if newValue == "alert" {
                            viewModel.selectedRepo = nil
                        } else if let repo = viewModel.status.repos.first(where: { $0.repo == newValue }) {
                            viewModel.selectRepo(repo)
                        }
                    }
                )) {
                    Text("main").tag("main")
                    Text("alert").tag("alert")
                    ForEach(viewModel.status.repos) { repo in
                        Text(repo.repo).tag(repo.repo)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal)

                TabView {
                    ScrollView {
                        Text(viewModel.mainLogText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                    }
                    .tabItem { Text("Main") }

                    ScrollView {
                        Text(viewModel.alertLogText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                    }
                    .tabItem { Text("Alert") }

                    ScrollView {
                        Text(viewModel.repoLogText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                    }
                    .tabItem { Text("Repo") }
                }
            }
            .navigationTitle("Logs")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh") {
                        Task { await viewModel.refresh() }
                    }
                }
            }
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
                    Stepper(value: $viewModel.refreshInterval, in: 10...300, step: 5) {
                        Text("Refresh interval: \(Int(viewModel.refreshInterval))s")
                    }
                }

                Section("Mac-side capabilities") {
                    Text("The iOS app reads updater status through the helper server. Cron editing and Finder actions remain Mac-side operations.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Refresh now") {
                        Task { await viewModel.refresh() }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
