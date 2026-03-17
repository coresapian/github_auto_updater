import BackgroundTasks
import Foundation
import Security
import SwiftUI
import UIKit
import UserNotifications

private enum HelperTokenKeychain {
    private static let service = "com.core.githubautoupdater"
    private static let account = "helperAuthToken"

    static func readToken() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return token
    }

    static func writeToken(_ token: String) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if token.isEmpty {
            SecItemDelete(baseQuery as CFDictionary)
            return
        }
        let data = Data(token.utf8)
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    static let backgroundTaskIdentifier = "com.core.githubautoupdater.refresh"

    @AppStorage("serverURL") var serverURL: String = "http://127.0.0.1:8787"
    @AppStorage("refreshInterval") var refreshInterval: Double = 30
    @AppStorage("autoRefreshWhileOpen") var autoRefreshWhileOpen: Bool = true
    @AppStorage("backgroundRefreshEnabled") var backgroundRefreshEnabled: Bool = true
    @AppStorage("pairingCode") var pairingCode: String = ""
    @AppStorage("deviceName") var deviceName: String = UIDevice.current.name
    @AppStorage("notificationsEnabled") var notificationsEnabled: Bool = false
    @AppStorage("lastNotifiedRunStamp") var lastNotifiedRunStamp: String = ""

    @Published var helperToken: String {
        didSet {
            let normalized = helperToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized != helperToken {
                helperToken = normalized
                return
            }
            HelperTokenKeychain.writeToken(normalized)
        }
    }
    @Published var status: StatusResponse = .placeholder
    @Published var pairingStatus: PairingStatus = .placeholder
    @Published var selectedRepo: RepoStatus?
    @Published var mainLogText: String = ""
    @Published var alertLogText: String = ""
    @Published var repoLogText: String = ""
    @Published var errorMessage: String?
    @Published var isLoading: Bool = false
    @Published var isTriggeringManualRun: Bool = false
    @Published var isPairing: Bool = false
    @Published var manualRunMessage: String?
    @Published var pairingMessage: String?
    @Published var notificationMessage: String?
    @Published var lastRefreshDate: Date?
    @Published var nextAutomaticRefreshDate: Date?
    @Published var selectedLogSource: LogSource = .main
    @Published var logSearchText: String = ""
    @Published var logSeverityFilter: LogSeverityFilter = .all
    @Published var dashboardRepoFilter: DashboardRepoFilter = .all

    private let api = APIClient()
    private var autoRefreshTask: Task<Void, Never>?
    private var isAppActive = false

    enum DashboardRepoFilter: String, CaseIterable, Identifiable {
        case all
        case needsAttention
        case healthy

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .needsAttention: return "Attention"
            case .healthy: return "Healthy"
            }
        }
    }

    init() {
        helperToken = HelperTokenKeychain.readToken()
    }

    var filteredRepos: [RepoStatus] {
        switch dashboardRepoFilter {
        case .all: return status.repos
        case .needsAttention: return status.repos.filter { $0.state != .ok }
        case .healthy: return status.repos.filter { $0.state == .ok }
        }
    }

    var currentLogLines: [LogLine] {
        let text: String
        switch selectedLogSource {
        case .main: text = mainLogText
        case .alert: text = alertLogText
        case .repo: text = repoLogText
        }
        return text.split(whereSeparator: \.isNewline).enumerated().map { LogLine(text: String($0.element), index: $0.offset) }
    }

    var filteredLogLines: [LogLine] {
        let query = logSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return currentLogLines.filter { line in
            let matchesQuery = query.isEmpty || line.normalized.contains(query)
            let matchesSeverity: Bool
            switch logSeverityFilter {
            case .all:
                matchesSeverity = true
            case .matched:
                matchesSeverity = !query.isEmpty && line.normalized.contains(query)
            default:
                matchesSeverity = line.severity == logSeverityFilter
            }
            return matchesQuery && matchesSeverity
        }
    }

    var activeLogTitle: String {
        switch selectedLogSource {
        case .main: return "Main log"
        case .alert: return "Alert log"
        case .repo: return selectedRepo?.repo ?? "Repo log"
        }
    }

    var hasHelperToken: Bool {
        !helperToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func start() {
        restartAutoRefreshLoop()
    }

    func restartAutoRefreshLoop() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let interval = max(refreshInterval, 10)
                await MainActor.run {
                    self.nextAutomaticRefreshDate = self.autoRefreshWhileOpen ? Date().addingTimeInterval(interval) : nil
                }
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    break
                }
                guard await MainActor.run(body: { self.autoRefreshWhileOpen && self.isAppActive }) else {
                    continue
                }
                await self.refresh(reason: .automatic)
            }
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        isAppActive = phase == .active
        switch phase {
        case .active:
            Task {
                await refresh(reason: .sceneBecameActive)
                await scheduleBackgroundRefreshIfNeeded()
            }
        case .background:
            Task { await scheduleBackgroundRefreshIfNeeded() }
        default:
            break
        }
    }

    func refresh(reason: RefreshReason = .manual) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            pairingStatus = try await api.fetchPairingStatus(baseURL: serverURL)
            let status = try await api.fetchStatus(baseURL: serverURL, authToken: helperToken)
            self.status = status
            self.pairingStatus = status.pairing
            await maybeScheduleFailureNotification(from: status)
            if selectedRepo == nil {
                selectedRepo = status.repos.first
            } else if let selectedRepo {
                self.selectedRepo = status.repos.first(where: { $0.id == selectedRepo.id }) ?? status.repos.first
            }
            async let main = api.fetchLog(baseURL: serverURL, kind: "main", authToken: helperToken)
            async let alert = api.fetchLog(baseURL: serverURL, kind: "alert", authToken: helperToken)
            let (mainLog, alertLog) = try await (main, alert)
            mainLogText = mainLog.content
            alertLogText = alertLog.content
            if selectedLogSource == .repo || selectedRepo != nil {
                await refreshSelectedRepoLog()
            }
            lastRefreshDate = Date()
            errorMessage = nil
            if reason != .backgroundTask {
                await scheduleBackgroundRefreshIfNeeded()
            }
        } catch {
            do {
                pairingStatus = try await api.fetchPairingStatus(baseURL: serverURL)
            } catch {
            }
            errorMessage = error.localizedDescription
        }
    }

    func refreshPairingStatus() async {
        do {
            pairingStatus = try await api.fetchPairingStatus(baseURL: serverURL)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pairCurrentDevice() async {
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let device = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            errorMessage = "Enter the pairing code shown by the Mac helper."
            return
        }
        guard !device.isEmpty else {
            errorMessage = "Enter a device name for this token."
            return
        }
        isPairing = true
        defer { isPairing = false }
        do {
            let response = try await api.exchangePairingCode(baseURL: serverURL, pairingCode: code, deviceName: device)
            helperToken = response.authToken
            pairingCode = ""
            pairingMessage = "Paired as \(response.deviceName). Token \(response.tokenPreview) saved to Keychain."
            errorMessage = nil
            await refresh(reason: .manual)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearHelperToken() {
        helperToken = ""
        pairingMessage = nil
    }

    func requestNotificationPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            notificationsEnabled = granted
            notificationMessage = granted ? "Notifications enabled." : "Notification permission was not granted."
        } catch {
            notificationMessage = error.localizedDescription
        }
    }

    func maybeScheduleFailureNotification(from status: StatusResponse) async {
        guard notificationsEnabled else { return }
        guard let counts = status.latestSummary.counts, counts.failed > 0 else { return }
        let runStamp = status.latestSummary.runStamp ?? status.latestSummary.summary ?? ""
        guard !runStamp.isEmpty, runStamp != lastNotifiedRunStamp else { return }
        let content = UNMutableNotificationContent()
        content.title = "GitHub Auto Updater Failure"
        content.body = status.latestSummary.summary ?? "One or more repos failed during the last updater run."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "github-auto-updater-failure-\(runStamp)", content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            lastNotifiedRunStamp = runStamp
        } catch {
            notificationMessage = error.localizedDescription
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
                    manualRun: manualRun,
                    helperTime: status.helperTime,
                    dashboard: status.dashboard,
                    pairing: pairingStatus,
                    notifications: status.notifications
                )
            }
            manualRunMessage = response.manualRun?.latest?.statusMessage ?? "Manual updater run requested."
            errorMessage = nil
            try? await Task.sleep(for: .seconds(1))
            await refresh(reason: .manual)
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
            let response = try await api.fetchLog(baseURL: serverURL, kind: "repo", repo: selectedRepo.repo, authToken: helperToken)
            repoLogText = response.content
            errorMessage = nil
        } catch {
            repoLogText = "Failed to load repo log: \(error.localizedDescription)"
        }
    }

    func selectRepo(_ repo: RepoStatus) {
        selectedRepo = repo
        selectedLogSource = .repo
        Task { await refreshSelectedRepoLog() }
    }

    func selectLogSource(_ source: LogSource) {
        selectedLogSource = source
        if source == .repo, selectedRepo == nil {
            selectedRepo = status.repos.first
        }
        if source == .repo {
            Task { await refreshSelectedRepoLog() }
        }
    }

    func performBackgroundRefresh() async {
        guard backgroundRefreshEnabled else { return }
        await refresh(reason: .backgroundTask)
        await scheduleBackgroundRefreshIfNeeded()
    }

    func scheduleBackgroundRefreshIfNeeded() async {
        guard backgroundRefreshEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(max(refreshInterval, 15) * 2)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
        }
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

    func formattedDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    deinit {
        autoRefreshTask?.cancel()
    }
}

enum RefreshReason {
    case manual
    case automatic
    case sceneBecameActive
    case backgroundTask
}
