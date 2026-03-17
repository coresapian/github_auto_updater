import Foundation
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @AppStorage("serverURL") var serverURL: String = "http://127.0.0.1:8787"
    @AppStorage("refreshInterval") var refreshInterval: Double = 30
    @Published var status: StatusResponse = .placeholder
    @Published var selectedRepo: RepoStatus?
    @Published var mainLogText: String = ""
    @Published var alertLogText: String = ""
    @Published var repoLogText: String = ""
    @Published var errorMessage: String?
    @Published var isLoading: Bool = false

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
}
