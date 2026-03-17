import Foundation
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @AppStorage("serverURL") var serverURL: String = "http://127.0.0.1:8787"
    @AppStorage("refreshInterval") var refreshInterval: Double = 30
    @AppStorage("helperToken") var helperToken: String = ""

    @Published var status: StatusResponse = .placeholder
    @Published var selectedRepo: RepoStatus?
    @Published var mainLogText: String = ""
    @Published var alertLogText: String = ""
    @Published var repoLogText: String = ""
    @Published var errorMessage: String?
    @Published var isLoading: Bool = false
    @Published var isTriggeringManualRun: Bool = false
    @Published var manualRunMessage: String?

    private let api = APIClient()

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let status = try await api.fetchStatus(baseURL: serverURL)
            self.status = status
            if selectedRepo == nil {
                selectedRepo = status.repos.first
            } else if let selectedRepo {
                self.selectedRepo = status.repos.first(where: { $0.id == selectedRepo.id })
            }
            async let main = api.fetchLog(baseURL: serverURL, kind: "main")
            async let alert = api.fetchLog(baseURL: serverURL, kind: "alert")
            let (mainLog, alertLog) = try await (main, alert)
            mainLogText = mainLog.content
            alertLogText = alertLog.content
            await refreshSelectedRepoLog()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func triggerManualRun() async {
        guard !isTriggeringManualRun else { return }
        isTriggeringManualRun = true
        defer { isTriggeringManualRun = false }
        do {
            let response = try await api.runUpdater(baseURL: serverURL, token: helperToken)
            if let manualRun = response.manualRun {
                status = StatusResponse(
                    cronInstalled: status.cronInstalled,
                    cronEntry: status.cronEntry,
                    scriptPath: status.scriptPath,
                    mainLog: status.mainLog,
                    alertLog: status.alertLog,
                    repoLogDir: status.repoLogDir,
                    backups: status.backups,
                    repos: status.repos,
                    crontab: status.crontab,
                    latestSummary: status.latestSummary,
                    manualRun: manualRun
                )
            }
            manualRunMessage = response.manualRun?.latest?.statusMessage ?? "Manual updater run requested."
            errorMessage = nil
            try? await Task.sleep(for: .seconds(1))
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            manualRunMessage = nil
        }
    }

    func refreshSelectedRepoLog() async {
        guard let selectedRepo else {
            repoLogText = "No repo selected."
            return
        }
        do {
            let response = try await api.fetchLog(baseURL: serverURL, kind: "repo", repo: selectedRepo.repo)
            repoLogText = response.content
        } catch {
            repoLogText = "Failed to load repo log: \(error.localizedDescription)"
        }
    }

    func selectRepo(_ repo: RepoStatus) {
        selectedRepo = repo
        Task { await refreshSelectedRepoLog() }
    }

    func formattedTimestamp(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return raw
    }
}
